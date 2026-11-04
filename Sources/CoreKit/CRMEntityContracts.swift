import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var stringValue: String? {
    switch self {
    case .string(let value): value
    case .number(let value): String(value)
    default: nil
    }
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var searchableText: String {
    switch self {
    case .string(let value): return value
    case .number(let value): return String(value)
    case .bool(let value): return value ? "yes true" : "no false"
    case .object(let value): return value.values.map(\.searchableText).joined(separator: " ")
    case .array(let value): return value.map(\.searchableText).joined(separator: " ")
    case .null: return ""
    }
  }
}

public struct CRMRecord: Codable, Hashable, Identifiable, Sendable {
  public var fields: [String: JSONValue]

  public init(fields: [String: JSONValue] = [:]) {
    self.fields = fields
  }

  public var id: String {
    fields["id"]?.stringValue ?? ""
  }

  public subscript(key: String) -> JSONValue? {
    get { fields[key] }
    set { fields[key] = newValue }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    fields = try container.decode([String: JSONValue].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }
}

public extension CRMRecord {
  public func displayName(primaryField: String, fallback: String = "") -> String {
    if primaryField.hasSuffix("_id") {
      let relationKey = String(primaryField.dropLast(3))
      if let relation = self[relationKey]?.objectValue,
         let value = relation["name"]?.stringValue ?? relation["title"]?.stringValue,
         !value.isEmpty { return value }
    }
    if let value = self[primaryField]?.stringValue, !value.isEmpty { return value }
    if let value = self["organization"]?.objectValue?["name"]?.stringValue, !value.isEmpty { return value }
    return fallback.isEmpty ? id : fallback
  }
}

public struct CRMContactBirthday: Hashable, Sendable {
  public let month: Int
  public let day: Int
  public let year: Int?

  public init?(record: CRMRecord) {
    guard let month = Self.integer(record["birthday_month"]),
      let day = Self.integer(record["birthday_day"]),
      (1...12).contains(month),
      day > 0
    else { return nil }

    let year = Self.integer(record["birthday_year"])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(
      from: DateComponents(year: year ?? 2000, month: month, day: day)
    ),
      calendar.component(.month, from: date) == month,
      calendar.component(.day, from: date) == day
    else { return nil }

    self.month = month
    self.day = day
    self.year = year
  }

  public func formatted(locale: Locale = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(
      from: DateComponents(year: year ?? 2000, month: month, day: day)
    )!
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.setLocalizedDateFormatFromTemplate(year == nil ? "MMMMd" : "yMMMMd")
    return formatter.string(from: date)
  }

  private static func integer(_ value: JSONValue?) -> Int? {
    switch value {
    case .number(let number) where number.rounded() == number:
      return Int(number)
    case .string(let string):
      return Int(string)
    default:
      return nil
    }
  }
}

public struct CRMFieldOption: Codable, Hashable, Identifiable, Sendable {
  public let value: String
  public let label: String
  public var id: String { value }

  public init(value: String, label: String) {
    self.value = value
    self.label = label
  }
}

/// One selectable option in an entity's configurable `characteristics`
/// vocabulary, served by `/api/agent/meta/characteristics`. Stored on a record
/// as a `{ name: Bool }` map — a name is "on" when its value is `true`.
public struct CRMCharacteristicOption: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  /// Underscore-aware, title-cased label — mirrors the web display
  /// (`event_timeline` → `Event Timeline`).
  public var displayName: String {
    Self.displayName(for: name)
  }

  /// Prettifies a raw characteristic name. Exposed so surfaces that only hold
  /// the stored map keys (not the full option) format identically.
  public static func displayName(for name: String) -> String {
    name
      .split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

/// The characteristics vocabulary keyed by registry entity id — e.g.
/// `["contacts": [...], "leads": [...]]`.
public typealias CRMCharacteristicsVocabulary = [String: [CRMCharacteristicOption]]

public struct CRMFieldContract: Codable, Hashable, Identifiable, Sendable {
  public let name: String
  public let label: String
  public let kind: String
  public let section: String?
  public let required: Bool?
  public let placeholder: String?
  public let options: [CRMFieldOption]?
  public let optionsSource: String?
  public let relationEntity: String?
  public let relationKey: String?
  public let storage: String?
  public let colSpan: Int?
  public let maxLength: Int?
  public let min: Double?
  public let max: Double?
  public let hidden: Bool?
  public let readOnly: Bool?
  public var id: String { name }
}

extension CRMFieldContract {
  /// Human-readable label for an `industry`-kind stored value. Industry codes
  /// arrive from the web CRM as `ent_<slug>` taxonomy ids (e.g.
  /// `ent_manufacturing`) and the registry ships no option list for them, so the
  /// apps derive the label deterministically: strip the `ent_` namespace prefix
  /// and title-case the remaining slug (`ent_financial_services` → "Financial
  /// Services"). A field `option` whose value matches still wins upstream; this
  /// is the fallback for the common case where none is published.
  public static func industryLabel(for storedValue: String) -> String {
    let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return storedValue }
    let slug = trimmed.hasPrefix("ent_") ? String(trimmed.dropFirst(4)) : trimmed
    let pretty = slug
      .split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
    return pretty.isEmpty ? trimmed : pretty
  }
}

/// An assignable team member, served by `/api/agent/members`. Backs the
/// `optionsSource: "members"` field hint (task `assigned_to`): registry-driven
/// pickers resolve their candidate list from this instead of an entity `.list`.
public struct CRMMember: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let email: String?

  public init(id: String, name: String?, email: String?) {
    self.id = id
    self.name = name
    self.email = email
  }

  /// Best label for a picker row: display name, falling back to email, then id.
  public var displayLabel: String {
    if let name, !name.isEmpty { return name }
    if let email, !email.isEmpty { return email }
    return id
  }
}

public struct CRMEntityCapabilities: Codable, Hashable, Sendable {
  public let list: Bool
  public let read: Bool
  public let create: Bool
  public let update: Bool
  public let delete: Bool
}

public struct CRMAccessState: Codable, Hashable, Sendable {
  public let canRead: Bool
  public let canWrite: Bool?
  public let missingScopes: [String]
}

public struct CRMBoardContract: Codable, Hashable, Sendable {
  public let field: String
}

public struct CRMRelatedCreateContract: Codable, Hashable, Sendable {
  public let label: String
  public let webPath: String
  public let prefillField: String?
}

public enum CRMRelatedPresentation: String, Codable, Hashable, Sendable {
  case list
  case compact
  case timeline
  case cards
}

public struct CRMRelatedSectionContract: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let entity: String
  public let icon: String
  public let emptyMessage: String
  /// Optional while cached schema-v1 metadata ages out; current Core always sends this value.
  public let presentation: CRMRelatedPresentation?
  public let create: CRMRelatedCreateContract?
  public let allowsUnlink: Bool?
  public let access: CRMAccessState?
}

public struct CRMEntityContract: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let singularLabel: String
  public let pluralLabel: String
  public let icon: String
  public let primaryField: String
  public let secondaryFields: [String]
  public let capabilities: CRMEntityCapabilities
  /// Absent in schema versions 1–3, where capabilities were already scope-filtered.
  public let access: CRMAccessState?
  public let board: CRMBoardContract?
  public let related: [CRMRelatedSectionContract]?
  public let fields: [CRMFieldContract]
}

extension CRMEntityContract {
  public var hasReadAccess: Bool { access?.canRead ?? true }
  public var hasWriteAccess: Bool { access?.canWrite ?? true }
  public var canList: Bool { capabilities.list && hasReadAccess }
  public var canCreate: Bool { capabilities.create && hasWriteAccess }
  public var canUpdate: Bool { capabilities.update && hasWriteAccess }
  public var canDelete: Bool { capabilities.delete && hasWriteAccess }

  /// Fields a list can filter on, derived from the published contract rather
  /// than a hardcoded per-entity list — the registry has no `filterable` flag,
  /// so the rule is "the server ships a closed set of values for this field":
  /// a `select` carrying inline `options`, or a `toggle` (yes/no).
  ///
  /// Deliberately excluded:
  /// - `optionsSource` selects (members, organizations, …) — those resolve
  ///   against a live directory that can be arbitrarily large, so they belong
  ///   in search, not a menu of every value.
  /// - `industry` — the registry ships no option list for it (labels are
  ///   derived client-side), so there is no closed set to enumerate.
  /// - hidden and read-only fields, matching every other surface.
  public var filterableFields: [CRMFieldContract] {
    fields.filter { field in
      guard field.hidden != true, field.readOnly != true else { return false }
      if field.kind == "toggle" { return true }
      guard field.kind == "select", field.optionsSource == nil else { return false }
      return field.options?.isEmpty == false
    }
  }

  /// The field carrying this entity's own calendar date (event date, due date,
  /// …) — distinct from the `created_at` audit timestamp that "Newest/Oldest"
  /// already sort on. Drives the optional "By date" sort. Nil when the entity
  /// has no such field, in which case that sort option is hidden.
  ///
  /// Resolved by name in priority order (the registry ships event dates as
  /// plain text, so kind alone can't identify them), with a `date`-kind field
  /// as a last resort. Audit timestamps are never chosen.
  public var dateField: String? {
    let priority = [
      "event_date", "session_date", "start_date", "due_date", "date",
      "effective_date", "renewal_date", "published_at", "start_at",
    ]
    let present = Set(fields.map(\.name))
    if let named = priority.first(where: { present.contains($0) }) { return named }
    return fields.first { field in
      field.kind == "date"
        && field.name != "created_at"
        && field.name != "updated_at"
    }?.name
  }
}

/// One value a list is filtered by. `field` is the record key; `value` is the
/// stored representation (`"true"`/`"false"` for toggles), so matching compares
/// against the raw record rather than a display label. `kind` is the field's
/// contract kind, which decides how an absent value is read.
public struct CRMListFilter: Hashable, Sendable {
  public let field: String
  public let value: String
  public let kind: String

  public init(field: String, value: String, kind: String) {
    self.field = field
    self.value = value
    self.kind = kind
  }

  /// Whether a record satisfies this filter.
  ///
  /// Toggles treat a missing or null value as `false`: the backend stores an
  /// unset boolean as null rather than `false`, so filtering "No" has to match
  /// those or it would return nothing. Every other kind fails closed — a record
  /// without the field does not match.
  public func matches(_ record: CRMRecord) -> Bool {
    if kind == "toggle" {
      return String(record[field]?.boolValue ?? false) == value
    }
    guard let stored = record[field], stored != .null else { return false }
    return stored.stringValue == value
  }
}

public struct CRMRelatedItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let href: String
  public let subtitle: String?
  public let tag: String?
  public let navigable: Bool?
}

public struct CRMRelatedData: Codable, Hashable, Sendable {
  public let relation: String
  public let items: [CRMRelatedItem]
  public let createDefaults: [String: String]?
}

public struct CRMEntityContractData: Codable, Sendable {
  public let space: String
  public let schemaVersion: Int
  public let entities: [CRMEntityContract]
  public let grantedScopes: [String]?
}

public enum CRMNavigationAvailability: String, Codable, Hashable, Sendable {
  case available
  case comingSoon
  case webOnly
}

public struct CRMNavigationItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let webPath: String
  public let symbol: String
  public let entityId: String?
  public let availability: CRMNavigationAvailability
}

public struct CRMNavigationGroup: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let items: [CRMNavigationItem]
}

public struct CRMNavigationData: Codable, Sendable {
  public let space: String
  public let schemaVersion: Int
  public let topLevel: [CRMNavigationItem]
  public let groups: [CRMNavigationGroup]
}

extension CRMNavigationData {
  /// All navigation items across top-level and groups.
  private var allItems: [CRMNavigationItem] {
    topLevel + groups.flatMap(\.items)
  }

  /// The server-published list `webPath` for an entity (e.g. `/dashboard/support-cases`),
  /// or `nil` if the entity has no web page. The slug in `webPath` is authoritative —
  /// it can differ from the entity id (`signals_accounts` → `/dashboard/signals`), so
  /// never derive it from the id by hand.
  public func webPath(forEntity entityId: String) -> String? {
    allItems.first { $0.entityId == entityId }?.webPath
  }

  /// The web permalink for a single record, mirroring the web app's
  /// `<listPath>/<id>` detail route (the same convention as its `<listPath>/new`
  /// create route). Returns `nil` when the entity has no web page or the record
  /// has no id — callers hide the share affordance in that case (fail closed).
  public func recordWebURL(
    entityId: String,
    recordID: String,
    baseURL: URL = ServerConfig.baseURL
  ) -> URL? {
    guard !recordID.isEmpty, let path = webPath(forEntity: entityId) else { return nil }
    return baseURL.appending(path: path).appending(path: recordID)
  }
}

public struct CRMRegistryHTTPContract: Codable, Hashable, Sendable {
  public let method: String
  public let path: String
}

public struct CRMOperationAccessState: Codable, Hashable, Sendable {
  public let canExecute: Bool
  public let missingScopes: [String]
}

public struct CRMOperationContract: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let entity: String
  public let kind: String
  public let http: CRMRegistryHTTPContract
  public let outputSchemaId: String
  public let access: CRMOperationAccessState?
}

public struct CRMRelationContract: Codable, Hashable, Identifiable, Sendable {
  public let key: String
  public let source: String
  public let target: String
  public let cardinality: String
  public let presentation: CRMRelatedSectionContract
  public let access: CRMAccessState?
  public var id: String { key }
}

public struct CRMRegistryNavigationContract: Codable, Sendable {
  public let schemaVersion: Int
  public let topLevel: [CRMNavigationItem]
  public let groups: [CRMNavigationGroup]
}

public struct CRMRegistryData: Codable, Sendable {
  public let generated: String?
  public let space: String
  public let schemaVersion: Int
  public let registryVersion: Int
  public let metadataSchemaVersion: Int
  public let grantedScopes: [String]?
  public let entities: [CRMEntityContract]
  public let relations: [CRMRelationContract]
  public let operations: [CRMOperationContract]
  public let navigation: CRMRegistryNavigationContract

  public var entityContractData: CRMEntityContractData {
    CRMEntityContractData(
      space: space,
      schemaVersion: metadataSchemaVersion,
      entities: entities,
      grantedScopes: grantedScopes
    )
  }

  public var navigationData: CRMNavigationData {
    CRMNavigationData(
      space: space,
      schemaVersion: navigation.schemaVersion,
      topLevel: navigation.topLevel,
      groups: navigation.groups
    )
  }
}

public struct CRMDashboardSummary: Codable, Hashable, Sendable {
  public let organizations: Int?
  public let contacts: Int?
  public let leads: Int?
  public let projects: Int?
  public let milestones: Int?
  public let tasks: Int?
  public let offers: Int?
  public let interactions: Int?
  public let services: Int?
  public let licenses: Int?
  public let policies: Int?
  public let supportCases: Int?
  public let readinessAssessments: Int?
  public let signalsAccounts: Int?
  public let signalsWorksessions: Int?
  public let totalMRR: Double?
  public let growthHistograms: [GrowthHistogramSeries]?
  public let activeProjects: [DashboardPreviewItem]?
  public let activeLicenses: [DashboardPreviewItem]?
  public let myTasks: [DashboardPreviewItem]?
  public let upcomingMilestones: [DashboardPreviewItem]?
  public let unavailableEntities: [String]?
  public let generatedAt: String
}

extension CRMDashboardSummary {
  /// The dashboard count for a registry entity id, or `nil` when the summary
  /// carries no count for it. Single source for the entity → count mapping used
  /// across the apps; keep in step with the registry's entity ids.
  public func count(forEntity entity: String) -> Int? {
    switch entity {
    case "organizations": organizations
    case "contacts": contacts
    case "leads": leads
    case "projects": projects
    case "milestones": milestones
    case "tasks": tasks
    case "offers": offers
    case "interactions": interactions
    case "services": services
    case "licenses": licenses
    case "policies": policies
    case "support_cases": supportCases
    case "readiness_assessments": readinessAssessments
    case "signals_accounts": signalsAccounts
    case "signals_worksessions": signalsWorksessions
    default: nil
    }
  }
}

public struct DashboardPreviewItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String?
  public let date: String?
  public let entity: String?
}

public struct GrowthHistogramPoint: Codable, Hashable, Identifiable, Sendable {
  public let key: String
  public let label: String
  public let total: Double
  public let positive: Double
  public let negative: Double
  public var id: String { key }

  /// Server-decoded in the CRM dashboard, but also built client-side from
  /// Plausible series for the website tiles — hence the explicit init.
  public init(key: String, label: String, total: Double, positive: Double, negative: Double) {
    self.key = key
    self.label = label
    self.total = total
    self.positive = positive
    self.negative = negative
  }
}

public struct GrowthHistogramSeries: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let valueFormat: String
  public let currencyCode: String?
  public let positiveLabel: String
  public let remainderLabel: String?
  public let negativeLabel: String?
  public let points: [GrowthHistogramPoint]

  public init(
    id: String,
    title: String,
    valueFormat: String,
    currencyCode: String? = nil,
    positiveLabel: String,
    remainderLabel: String? = nil,
    negativeLabel: String? = nil,
    points: [GrowthHistogramPoint]
  ) {
    self.id = id
    self.title = title
    self.valueFormat = valueFormat
    self.currencyCode = currencyCode
    self.positiveLabel = positiveLabel
    self.remainderLabel = remainderLabel
    self.negativeLabel = negativeLabel
    self.points = points
  }
}

public struct AgentDataEnvelope<Value: Codable & Sendable>: Codable, Sendable {
  public let data: Value
}

public struct AgentListMeta: Codable, Sendable {
  public let count: Int
  public let limit: Int
  public let offset: Int
}

public struct AgentListEnvelope<Value: Codable & Sendable>: Codable, Sendable {
  public let data: [Value]
  public let meta: AgentListMeta
}

public struct AgentSearchResult: Codable, Hashable, Identifiable, Sendable {
  public let entity: String
  public let id: String
  public let name: String
  public let description: String?
  public let status: String?
  public let imageUrl: String?
  public let href: String
}

public struct AgentSearchMeta: Codable, Sendable {
  public let count: Int
  public let query: String
  public let entity: String?
}

public struct AgentSearchEnvelope: Codable, Sendable {
  public let data: [AgentSearchResult]
  public let meta: AgentSearchMeta
}
