import CoreKit
import SwiftUI

// MARK: - Cell content

/// Text styling for a table cell, mirroring the web CRM's per-cell classes
/// (muted foreground, strikethrough for inactive rows, medium/semibold weight).
struct CRMTextStyle: Equatable {
  var muted = false
  var strikethrough = false
  var weight: Font.Weight = .regular
  var monospacedDigit = false

  static let plain = CRMTextStyle()
  static let muted = CRMTextStyle(muted: true)
  static let medium = CRMTextStyle(weight: .medium)
  static let semibold = CRMTextStyle(weight: .semibold)
}

/// One rendered table cell. A small, closed set of presentations ported from the
/// web CRM column configs — text, status pills, outline badges, avatar + name,
/// icon/flag-led text, and the readiness score composite.
enum CRMCellContent {
  /// The universal "no value" cell — a muted em dash, matching the web's "-".
  case empty
  case text(String, CRMTextStyle)
  case pill(String, CRMStatusPillType)
  case badge(String, filled: Bool)
  case avatar(url: URL?, name: String, subtitle: String?, strikethrough: Bool, shape: CRMAvatarShape = .circle)
  case symbol(String, text: String, CRMTextStyle)
  case flag(String?, text: String, CRMTextStyle)
  /// Readiness overall: "NN%" beside a High/Mid/Low pill.
  case readiness(Int)
}

// MARK: - Sorting

private enum CRMSortKind: Hashable {
  case string
  case number
  case date
  /// Extract the digits from a string and sort numerically (support-case `short_id`).
  case numericString
  /// Sort by a hydrated relation object's `name`/`title`.
  case relationName
}

private struct CRMSortSpec: Hashable {
  var field: String
  var kind: CRMSortKind
}

/// A sortable value with web-parity null handling (nulls sort first ascending).
private enum CRMSortValue {
  case number(Double)
  case string(String)
  case absent

  func compare(to other: CRMSortValue) -> ComparisonResult {
    switch (self, other) {
    case (.absent, .absent): return .orderedSame
    case (.absent, _): return .orderedAscending
    case (_, .absent): return .orderedDescending
    case let (.number(a), .number(b)):
      return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    case let (.string(a), .string(b)):
      return a.localizedStandardCompare(b)
    // Mixed types: numbers sort before strings (rare; only on dirty data).
    case (.number, .string): return .orderedAscending
    case (.string, .number): return .orderedDescending
    }
  }
}

/// A `SortComparator` over `CRMRecord`, driven by a column's key + sort spec.
/// Fully value-typed (no captured closures) so SwiftUI's `Table(sortOrder:)`
/// binding can hold, diff, and persist it.
struct CRMColumnComparator: SortComparator, Hashable {
  let key: String
  fileprivate let spec: CRMSortSpec
  var order: SortOrder = .forward

  fileprivate init(key: String, spec: CRMSortSpec, order: SortOrder = .forward) {
    self.key = key
    self.spec = spec
    self.order = order
  }

  func compare(_ lhs: CRMRecord, _ rhs: CRMRecord) -> ComparisonResult {
    let result = value(in: lhs).compare(to: value(in: rhs))
    return order == .forward ? result : result.reversed
  }

  private func value(in record: CRMRecord) -> CRMSortValue {
    switch spec.kind {
    case .string:
      guard let s = record[spec.field]?.stringValue, !s.isEmpty else { return .absent }
      return .string(s)
    case .number:
      guard let n = record[spec.field]?.crmDouble else { return .absent }
      return .number(n)
    case .date:
      guard let s = record[spec.field]?.stringValue, let t = crmDateInterval(s) else { return .absent }
      return .number(t)
    case .numericString:
      let digits = (record[spec.field]?.stringValue ?? "").filter(\.isNumber)
      guard let n = Double(digits) else { return .absent }
      return .number(n)
    case .relationName:
      guard let name = crmRelationName(record, spec.field) else { return .absent }
      return .string(name)
    }
  }
}

private extension ComparisonResult {
  var reversed: ComparisonResult {
    switch self {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }
}

// MARK: - Column

/// A table column: identity + header + width + how to sort + how to render a
/// cell. Ported one-to-one from the web CRM `Column<T>` configs.
struct CRMColumn: Identifiable {
  let id: String
  let header: String
  let width: CGFloat
  let alignment: Alignment
  fileprivate let sort: CRMSortSpec
  let cell: (CRMRecord) -> CRMCellContent

  fileprivate init(
    _ id: String,
    _ header: String,
    width: CGFloat,
    alignment: Alignment = .leading,
    sort: CRMSortSpec? = nil,
    cell: @escaping (CRMRecord) -> CRMCellContent
  ) {
    self.id = id
    self.header = header
    self.width = width
    self.alignment = alignment
    self.sort = sort ?? CRMSortSpec(field: id, kind: .string)
    self.cell = cell
  }

  var comparator: CRMColumnComparator { CRMColumnComparator(key: id, spec: sort) }
}

// MARK: - Formatting helpers

private extension JSONValue {
  var crmDouble: Double? {
    switch self {
    case .number(let n): return n
    case .string(let s): return Double(s)
    default: return nil
    }
  }
}

private extension String {
  var crmTrimmedNonEmpty: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}

private let crmDayParser: DateFormatter = {
  let f = DateFormatter()
  f.calendar = Calendar(identifier: .gregorian)
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: "UTC")
  f.dateFormat = "yyyy-MM-dd"
  return f
}()

/// Parse a `YYYY-MM-DD` (or leading-date ISO) string to a `Date`.
private func crmParseDate(_ raw: String) -> Date? {
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { return nil }
  if let d = crmDayParser.date(from: String(value.prefix(10))) { return d }
  return ISO8601DateFormatter().date(from: value)
}

private func crmDateInterval(_ raw: String) -> Double? {
  crmParseDate(raw).map(\.timeIntervalSince1970)
}

/// Display string for a stored date value, or nil if missing/unparseable.
func crmDateDisplay(_ raw: String?) -> String? {
  guard let raw, let date = crmParseDate(raw) else { return nil }
  return date.formatted(date: .abbreviated, time: .omitted)
}

/// EUR currency, whole units (web uses 0 fraction digits, narrow symbol).
private func crmEuro(_ record: CRMRecord, _ key: String, divideBy: Double = 1) -> String? {
  guard let n = record[key]?.crmDouble else { return nil }
  return (n / divideBy).formatted(.currency(code: "EUR").precision(.fractionLength(0)))
}

/// A hydrated relation object's display name (`name` then `title`).
func crmRelationName(_ record: CRMRecord, _ key: String) -> String? {
  guard let object = record[key]?.objectValue else { return nil }
  return (object["name"]?.stringValue ?? object["title"]?.stringValue)?.crmTrimmedNonEmpty
}

private func crmRelationImageURL(_ record: CRMRecord, _ key: String) -> URL? {
  guard let object = record[key]?.objectValue,
    let raw = object["profile_image_url"]?.stringValue ?? object["logo_image_url"]?.stringValue,
    let url = URL(string: raw)
  else { return nil }
  return url
}

/// Whole years since a start date, anniversary-adjusted (web `years_active`).
private func crmYearsSince(_ raw: String) -> Int? {
  guard let start = crmParseDate(raw) else { return nil }
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC") ?? .current
  let years = cal.dateComponents([.year], from: start, to: Date()).year ?? 0
  return max(0, years)
}

private func crmDaysBetweenTodayAnd(_ raw: String) -> Int? {
  guard let date = crmParseDate(raw) else { return nil }
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC") ?? .current
  let today = cal.startOfDay(for: Date())
  let day = cal.startOfDay(for: date)
  return cal.dateComponents([.day], from: today, to: day).day
}

// MARK: - Per-entity column configs

/// The table columns for an entity, ported from the web CRM's entity table
/// configs. Returns nil for entities with no table presentation (they stay a
/// list): events, notes/docs, signals workspaces/sessions, tasks (which keep
/// their bespoke checklist).
func crmTableColumns(for contract: CRMEntityContract) -> [CRMColumn]? {
  switch contract.id {
  case "organizations": return organizationColumns
  case "contacts": return contactColumns
  case "projects": return projectColumns
  case "milestones": return milestoneColumns
  case "readiness_assessments": return readinessColumns
  case "offers": return offerColumns
  case "licenses": return licenseColumns
  case "leads": return leadColumns
  case "services": return serviceColumns
  case "policies": return policyColumns
  case "support_cases": return supportCaseColumns
  case "interactions": return interactionColumns
  default: return nil
  }
}

/// The column to sort by initially — web parity is `created_at desc` where a
/// date-ish column exists, else the first column ascending.
func crmDefaultSort(for columns: [CRMColumn]) -> [CRMColumnComparator] {
  if let created = columns.first(where: { $0.id == "created_at" || $0.id == "created" }) {
    return [CRMColumnComparator(key: created.id, spec: created.sort, order: .reverse)]
  }
  return columns.first.map { [$0.comparator] } ?? []
}

private let organizationColumns: [CRMColumn] = [
  CRMColumn("name", "Organization", width: 300) { r in
    let name = r["name"]?.stringValue ?? "—"
    let legal = r["legal_name"]?.stringValue?.crmTrimmedNonEmpty
    let subtitle = (legal != nil && legal!.caseInsensitiveCompare(name) != .orderedSame) ? legal : nil
    return .avatar(url: r.avatarURL, name: name, subtitle: subtitle, strikethrough: false, shape: .squircle)
  },
  CRMColumn("industry", "Industry", width: 180) { r in
    guard let raw = r["industry"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    let name = CRMFieldContract.industryLabel(for: raw)
    return name.isEmpty || name == "Not specified" ? .empty : .text(name, .plain)
  },
  CRMColumn("country", "Country", width: 150) { r in
    guard let country = r["country"]?.stringValue?.crmTrimmedNonEmpty,
      let c = CountryCatalog.country(forStoredValue: country) else { return .empty }
    return .flag(CountryCatalog.flag(forStoredValue: country), text: c.name, .plain)
  },
  CRMColumn("contact_count", "Contacts", width: 100, alignment: .trailing,
    sort: CRMSortSpec(field: "contact_count", kind: .number)) { r in
    guard let n = r["contact_count"]?.crmDouble else { return .empty }
    return .text(Int(n).formatted(), .medium)
  },
  CRMColumn("created_at", "Created", width: 120,
    sort: CRMSortSpec(field: "created_at", kind: .date)) { r in
    crmDateDisplay(r["created_at"]?.stringValue).map { .text($0, .muted) } ?? .empty
  },
]

private let contactColumns: [CRMColumn] = [
  CRMColumn("name", "Contact", width: 300) { r in
    let name = r["name"]?.stringValue ?? "—"
    let email = r["email"]?.stringValue?.crmTrimmedNonEmpty
    return .avatar(url: r.avatarURL, name: name, subtitle: email, strikethrough: false)
  },
  CRMColumn("organization", "Organization", width: 200, sort: CRMSortSpec(field: "organization", kind: .relationName)) { r in
    guard let name = crmRelationName(r, "organization") else { return .empty }
    let flag = (r["organization"]?.objectValue?["country"]?.stringValue).flatMap { CountryCatalog.flag(forStoredValue: $0) }
    return .flag(flag, text: name, .plain)
  },
  CRMColumn("signals_outreach_status", "Signals status", width: 140) { r in
    guard let raw = r["signals_outreach_status"]?.stringValue?.crmTrimmedNonEmpty else {
      return .text("Not selected", .muted)
    }
    return .text(SignalsOutreach.statusLabel(raw), .plain)
  },
  CRMColumn("preferred_language", "Language", width: 90) { r in
    let lang = r["preferred_language"]?.stringValue ?? ""
    return lang == "pt" ? .text("PT", .medium) : .text("EN", .muted)
  },
  CRMColumn("country", "Country", width: 150) { r in
    guard let country = r["country"]?.stringValue?.crmTrimmedNonEmpty,
      let c = CountryCatalog.country(forStoredValue: country) else { return .empty }
    return .flag(CountryCatalog.flag(forStoredValue: country), text: c.name, .plain)
  },
]

private let projectColumns: [CRMColumn] = [
  CRMColumn("title", "Project", width: 280) { r in
    .text(r["title"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("organization", "Organization", width: 220, sort: CRMSortSpec(field: "organization", kind: .relationName)) { r in
    guard let name = crmRelationName(r, "organization") else { return .empty }
    let flag = (r["organization"]?.objectValue?["country"]?.stringValue).flatMap { CountryCatalog.flag(forStoredValue: $0) }
    return .flag(flag, text: name, .plain)
  },
  CRMColumn("status", "Status", width: 140) { r in
    guard let s = r["status"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .pill(s, .projectStatus)
  },
  CRMColumn("start_date", "Start Date", width: 120, sort: CRMSortSpec(field: "start_date", kind: .date)) { r in
    crmDateDisplay(r["start_date"]?.stringValue).map { .text($0, .plain) } ?? .empty
  },
  CRMColumn("end_date", "End Date", width: 120, sort: CRMSortSpec(field: "end_date", kind: .date)) { r in
    crmDateDisplay(r["end_date"]?.stringValue).map { .text($0, .plain) } ?? .empty
  },
]

private let milestoneColumns: [CRMColumn] = [
  CRMColumn("title", "Milestone", width: 320) { r in
    .text(r["title"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("project", "Project", width: 200, sort: CRMSortSpec(field: "project", kind: .relationName)) { r in
    crmRelationName(r, "project").map { .text($0, .plain) } ?? .empty
  },
  CRMColumn("due_date", "Date", width: 150, sort: CRMSortSpec(field: "due_date", kind: .date)) { r in
    crmDateDisplay(r["due_date"]?.stringValue).map { .text($0, .plain) } ?? .empty
  },
  CRMColumn("days", "Days", width: 100, sort: CRMSortSpec(field: "due_date", kind: .date)) { r in
    guard let raw = r["due_date"]?.stringValue, let days = crmDaysBetweenTodayAnd(raw) else { return .empty }
    if days == 0 { return .text("Today", .semibold) }
    let unit = abs(days) == 1 ? "day" : "days"
    return days < 0 ? .text("\(abs(days)) \(unit) past", .muted) : .text("\(days) \(unit) to", .plain)
  },
]

private let readinessColumns: [CRMColumn] = [
  CRMColumn("created_at", "Date", width: 160, sort: CRMSortSpec(field: "created_at", kind: .date)) { r in
    crmDateDisplay(r["created_at"]?.stringValue).map { .text($0, .muted) } ?? .empty
  },
  CRMColumn("name", "Contact", width: 280) { r in
    let name = r["name"]?.stringValue ?? "—"
    let email = r["email"]?.stringValue?.crmTrimmedNonEmpty
    return .avatar(url: nil, name: name, subtitle: email, strikethrough: false)
  },
  CRMColumn("organization", "Organization", width: 200) { r in
    guard let org = r["organization"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    let role = r["role"]?.stringValue?.crmTrimmedNonEmpty
    return .avatar(url: nil, name: org, subtitle: role, strikethrough: false, shape: .squircle)
  },
  CRMColumn("overall_score", "Overall Score", width: 170, alignment: .trailing,
    sort: CRMSortSpec(field: "overall_score", kind: .number)) { r in
    guard let n = r["overall_score"]?.crmDouble else { return .empty }
    return .readiness(Int(n.rounded()))
  },
]

private let offerColumns: [CRMColumn] = [
  CRMColumn("title", "Title", width: 300) { r in
    if let org = crmRelationName(r, "organization") {
      let flag = (r["organization"]?.objectValue?["country"]?.stringValue).flatMap { CountryCatalog.flag(forStoredValue: $0) }
      return .flag(flag, text: org, .semibold)
    }
    return .text(r["title"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("total_amount", "Amount", width: 140, alignment: .trailing,
    sort: CRMSortSpec(field: "total_amount", kind: .number)) { r in
    let currency = r["currency"]?.stringValue ?? "EUR"
    guard let n = r["total_amount"]?.crmDouble else { return .empty }
    return .text(n.formatted(.currency(code: currency).precision(.fractionLength(0))), .medium)
  },
  CRMColumn("status", "Status", width: 130) { r in
    guard let s = r["status"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .pill(s, .offerStatus)
  },
  CRMColumn("created_at", "Created", width: 130, sort: CRMSortSpec(field: "created_at", kind: .date)) { r in
    crmDateDisplay(r["created_at"]?.stringValue).map { .text($0, .muted) } ?? .empty
  },
]

private let licenseColumns: [CRMColumn] = [
  CRMColumn("organization", "Organization", width: 220, sort: CRMSortSpec(field: "organization", kind: .relationName)) { r in
    guard let name = crmRelationName(r, "organization") else { return .empty }
    let inactive = r["is_active"]?.boolValue == false
    return .avatar(url: crmRelationImageURL(r, "organization"), name: name, subtitle: nil, strikethrough: inactive, shape: .squircle)
  },
  CRMColumn("lead", "Lead", width: 180, sort: CRMSortSpec(field: "lead", kind: .relationName)) { r in
    crmRelationName(r, "lead").map { .text($0, .muted) } ?? .empty
  },
  CRMColumn("product", "Product", width: 110) { r in
    let product = r["product"]?.stringValue ?? ""
    return .badge(product == "other" ? "Other" : "Signals", filled: false)
  },
  CRMColumn("plan_type", "Plan", width: 100) { r in
    guard let plan = r["plan_type"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .badge(plan.capitalized, filled: false)
  },
  CRMColumn("seats", "Seats", width: 72, alignment: .trailing,
    sort: CRMSortSpec(field: "seats", kind: .number)) { r in
    guard let n = r["seats"]?.crmDouble else { return .empty }
    return .text(Int(n).formatted(), .muted)
  },
  CRMColumn("payment_type", "Payment", width: 120) { r in
    switch r["payment_type"]?.stringValue {
    case "stripe": return .text("Stripe (self-pay)", .plain)
    case "invoice": return .text("Invoiced", .plain)
    default: return .empty
    }
  },
  CRMColumn("years_active", "Years", width: 80, alignment: .trailing,
    sort: CRMSortSpec(field: "start_date", kind: .date)) { r in
    guard let raw = r["start_date"]?.stringValue, let years = crmYearsSince(raw) else { return .empty }
    return .text(years.formatted(), .muted)
  },
  CRMColumn("amount_eur", "ARR", width: 120, alignment: .trailing,
    sort: CRMSortSpec(field: "amount_eur", kind: .number)) { r in
    crmEuro(r, "amount_eur").map { .text($0, .medium) } ?? .empty
  },
  CRMColumn("start_date", "Start", width: 110, sort: CRMSortSpec(field: "start_date", kind: .date)) { r in
    crmDateDisplay(r["start_date"]?.stringValue).map { .text($0, .muted) } ?? .empty
  },
  CRMColumn("renewal_date", "Renewal", width: 130, sort: CRMSortSpec(field: "renewal_date", kind: .date)) { r in
    guard let raw = r["renewal_date"]?.stringValue, let display = crmDateDisplay(raw) else { return .empty }
    let expired = (crmDaysBetweenTodayAnd(raw) ?? 0) < 0
    return .text(expired ? "\(display) (expired)" : display, expired ? .muted : .plain)
  },
  CRMColumn("is_active", "Active", width: 90) { r in
    let active = r["is_active"]?.boolValue ?? true
    return .badge(active ? "Yes" : "No", filled: active)
  },
]

private let leadColumns: [CRMColumn] = [
  CRMColumn("title", "Lead", width: 300, sort: CRMSortSpec(field: "organization", kind: .relationName)) { r in
    let name = crmRelationName(r, "organization") ?? r["title"]?.stringValue ?? "—"
    let flag = (r["organization"]?.objectValue?["country"]?.stringValue).flatMap { CountryCatalog.flag(forStoredValue: $0) }
    return .flag(flag, text: name, .semibold)
  },
  CRMColumn("status", "Status", width: 180) { r in
    guard let s = r["status"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .pill(s, .leadStatus)
  },
  CRMColumn("start_date", "Start", width: 120, sort: CRMSortSpec(field: "start_date", kind: .date)) { r in
    crmDateDisplay(r["start_date"]?.stringValue).map { .text($0, .muted) } ?? .empty
  },
]

private let serviceColumns: [CRMColumn] = [
  CRMColumn("name", "Service", width: 300) { r in
    let name = r["name"]?.stringValue ?? "—"
    let summary = r["summary"]?.stringValue?.crmTrimmedNonEmpty
    let icon = r["icon"]?.stringValue?.crmTrimmedNonEmpty ?? "square.stack.3d.up"
    if let summary { return .avatar(url: nil, name: name, subtitle: summary, strikethrough: false) }
    return .symbol(icon, text: name, .semibold)
  },
  CRMColumn("price", "Price", width: 120, alignment: .trailing,
    sort: CRMSortSpec(field: "price", kind: .number)) { r in
    crmEuro(r, "price").map { .text($0, .medium) } ?? .empty
  },
  CRMColumn("group_type", "Group", width: 130) { r in
    .pill(r["group_type"]?.stringValue?.crmTrimmedNonEmpty ?? "Unknown", .serviceGroup)
  },
  CRMColumn("category", "Category", width: 150) { r in
    guard let c = r["category"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .pill(c, .serviceCategory)
  },
]

private let policyColumns: [CRMColumn] = [
  CRMColumn("title", "Policy", width: 280) { r in
    .text(r["title"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("organization", "Organization", width: 220, sort: CRMSortSpec(field: "organization", kind: .relationName)) { r in
    crmRelationName(r, "organization").map { .text($0, .plain) } ?? .empty
  },
  CRMColumn("effective_date", "Effective Date", width: 150, sort: CRMSortSpec(field: "effective_date", kind: .date)) { r in
    crmDateDisplay(r["effective_date"]?.stringValue).map { .text($0, .plain) } ?? .empty
  },
  CRMColumn("description", "Characters", width: 130, alignment: .trailing,
    sort: CRMSortSpec(field: "description", kind: .number)) { r in
    let count = (r["description"]?.stringValue ?? "").count
    return .text(count.formatted(), .medium)
  },
]

private let supportCaseColumns: [CRMColumn] = [
  CRMColumn("short_id", "Case", width: 110, sort: CRMSortSpec(field: "short_id", kind: .numericString)) { r in
    .text(r["short_id"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("subject", "Subject", width: 260) { r in
    .text(r["subject"]?.stringValue ?? "—", .plain)
  },
  CRMColumn("customer_name", "Customer", width: 240) { r in
    let name = r["customer_name"]?.stringValue?.crmTrimmedNonEmpty ?? "—"
    let email = r["customer_email"]?.stringValue?.crmTrimmedNonEmpty
    return .avatar(url: nil, name: name, subtitle: email, strikethrough: false)
  },
  CRMColumn("status", "Status", width: 160) { r in
    guard let s = r["status"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .badge(supportCaseStatusLabel(s), filled: false)
  },
  CRMColumn("priority", "Priority", width: 110) { r in
    let priority = r["priority"]?.stringValue ?? "normal"
    return .text(priority.capitalized, priority == "normal" ? .muted : .semibold)
  },
]

private func supportCaseStatusLabel(_ value: String) -> String {
  switch value {
  case "new": return "New"
  case "triaged": return "Triaged"
  case "waiting_on_customer": return "Waiting on customer"
  case "waiting_on_us": return "Waiting on us"
  case "resolved": return "Resolved"
  case "closed": return "Closed"
  default: return value
  }
}

private let interactionColumns: [CRMColumn] = [
  CRMColumn("title", "Title", width: 300) { r in
    let type = r["type"]?.stringValue ?? "message"
    return .symbol(interactionSymbol(type), text: r["title"]?.stringValue ?? "—", .semibold)
  },
  CRMColumn("type", "Type", width: 120) { r in
    guard let t = r["type"]?.stringValue?.crmTrimmedNonEmpty else { return .empty }
    return .pill(t, .interactionType)
  },
  CRMColumn("occurred_at", "Date", width: 150, sort: CRMSortSpec(field: "occurred_at", kind: .date)) { r in
    let raw = r["occurred_at"]?.stringValue ?? r["created_at"]?.stringValue
    return crmDateDisplay(raw).map { .text($0, .muted) } ?? .empty
  },
]

private func interactionSymbol(_ type: String) -> String {
  switch type {
  case "email": return "envelope"
  case "call": return "phone"
  case "meeting": return "calendar"
  case "note": return "doc.text"
  case "web": return "globe"
  default: return "bubble.left"
  }
}

// MARK: - List-row accessories

/// A trailing status indicator for a list row — a typed status pill or a plain
/// outline badge.
enum CRMRowStatus {
  case pill(String, CRMStatusPillType)
  case badge(String, filled: Bool)
}

/// Right-aligned list-row metadata: the entity's headline metric (currency) and
/// its status, pulled out of the stacked subtitle so rows read with hierarchy
/// instead of a column of equal-weight grey lines. Reuses the same status
/// mapping as the tables so list and table agree.
struct CRMRowAccessories {
  var metric: String?
  var status: CRMRowStatus?
  var isEmpty: Bool { metric == nil && status == nil }
}

func crmRowAccessories(for contract: CRMEntityContract, record: CRMRecord) -> CRMRowAccessories {
  func status(_ field: String, _ type: CRMStatusPillType) -> CRMRowStatus? {
    record[field]?.stringValue?.crmTrimmedNonEmpty.map { .pill($0, type) }
  }
  switch contract.id {
  case "licenses":
    let active = record["is_active"]?.boolValue
    return CRMRowAccessories(
      metric: crmEuro(record, "amount_eur"),
      status: active.map { .badge($0 ? "Active" : "Inactive", filled: $0) })
  case "offers":
    let currency = record["currency"]?.stringValue ?? "EUR"
    let metric = record["total_amount"]?.crmDouble
      .map { $0.formatted(.currency(code: currency).precision(.fractionLength(0))) }
    return CRMRowAccessories(metric: metric, status: status("status", .offerStatus))
  case "projects":
    return CRMRowAccessories(status: status("status", .projectStatus))
  case "leads":
    return CRMRowAccessories(status: status("status", .leadStatus))
  case "services":
    return CRMRowAccessories(metric: crmEuro(record, "price"), status: status("group_type", .serviceGroup))
  case "interactions":
    return CRMRowAccessories(status: status("type", .interactionType))
  case "support_cases":
    let badge = record["status"]?.stringValue?.crmTrimmedNonEmpty
      .map { CRMRowStatus.badge(supportCaseStatusLabel($0), filled: false) }
    return CRMRowAccessories(status: badge)
  default:
    return CRMRowAccessories()
  }
}

/// Field names an entity surfaces as trailing accessories, so the stacked
/// subtitle can exclude them and not repeat the metric/status.
func crmRowAccessoryFields(for contract: CRMEntityContract) -> Set<String> {
  switch contract.id {
  case "licenses": return ["amount_eur", "is_active"]
  case "offers": return ["total_amount", "currency", "status"]
  case "projects": return ["status"]
  case "leads": return ["status"]
  case "services": return ["group_type", "price"]
  case "interactions": return ["type"]
  case "support_cases": return ["status"]
  default: return []
  }
}
