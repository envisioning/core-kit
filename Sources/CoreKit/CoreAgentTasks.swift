import Foundation

// Typed task access over the registry-driven agent API (`/api/agent/tasks`).
// The macOS menubar and its Reminders sync work with the typed `CRMTask`
// domain model; the iOS app renders tasks generically from `CRMRecord`. Both
// now hit the same `tasks.*` operations through `CoreAgentClient`, so there is
// one task code path and no bespoke `/api/tasks` client to drift.

private let taskDateOnlyFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

private func parseTaskDate(_ value: JSONValue?) -> Date? {
  guard let string = value?.stringValue, !string.isEmpty else { return nil }
  if let date = ISO8601DateFormatter().date(from: string) { return date }
  return taskDateOnlyFormatter.date(from: string)
}

extension CRMTask {
  /// Builds the typed task from an agent-normalized `tasks` record. The server
  /// emits both camelCase and snake_case keys plus nested relation objects, so
  /// we read the camelCase timestamps (full ISO) and fall back to the snake_case
  /// date-only `due_date` when needed.
  public init?(record: CRMRecord) {
    guard let id = record["id"]?.stringValue, !id.isEmpty else { return nil }

    func relationObject(_ key: String) -> [String: JSONValue]? {
      record[key]?.objectValue
    }

    self.id = id
    self.title = record["title"]?.stringValue ?? ""
    self.notes = record["notes"]?.stringValue
    self.dueDate = parseTaskDate(record["dueDate"] ?? record["due_date"])
    self.priority = nil
    self.status = record["status"]?.stringValue ?? "pending"
    self.createdAt = parseTaskDate(record["createdAt"] ?? record["created_at"])
    self.updatedAt = parseTaskDate(record["updatedAt"] ?? record["updated_at"]) ?? Date()
    self.completedAt = parseTaskDate(record["completedAt"] ?? record["completed_at"])

    self.contactId = (record["contactId"] ?? record["contact_id"])?.stringValue
    self.projectId = (record["projectId"] ?? record["project_id"])?.stringValue
    self.milestoneId = (record["milestoneId"] ?? record["milestone_id"])?.stringValue
    self.leadId = (record["leadId"] ?? record["lead_id"])?.stringValue
    self.organizationId = (record["organizationId"] ?? record["organization_id"])?.stringValue

    if let contact = relationObject("contact"), let contactId = contact["id"]?.stringValue {
      self.contact = CRMContact(
        id: contactId,
        name: contact["name"]?.stringValue ?? "",
        email: contact["email"]?.stringValue,
        organizationId: contact["organization_id"]?.stringValue,
        updatedAt: Date()
      )
    } else {
      self.contact = nil
    }

    if let project = relationObject("project"), let projectId = project["id"]?.stringValue {
      self.project = CRMProject(
        id: projectId,
        title: project["title"]?.stringValue ?? "",
        status: project["status"]?.stringValue ?? "",
        updatedAt: Date()
      )
    } else {
      self.project = nil
    }

    if let lead = relationObject("lead"), let leadId = lead["id"]?.stringValue {
      self.lead = CRMLead(
        id: leadId,
        title: lead["title"]?.stringValue ?? "",
        status: lead["status"]?.stringValue ?? "",
        updatedAt: Date()
      )
    } else {
      self.lead = nil
    }

    if let milestone = relationObject("milestone"), let milestoneId = milestone["id"]?.stringValue {
      self.milestone = CRMMilestone(
        id: milestoneId,
        title: milestone["title"]?.stringValue ?? "",
        updatedAt: Date()
      )
    } else {
      self.milestone = nil
    }

    self.organization = nil
  }
}

extension CRMTaskCreate {
  /// Field payload for `tasks.create`. Keys are snake_case to match the entity
  /// contract; the server accepts these directly.
  var agentValues: [String: JSONValue] {
    var values: [String: JSONValue] = ["title": .string(title)]
    if let notes, !notes.isEmpty { values["notes"] = .string(notes) }
    if let dueDate { values["due_date"] = .string(taskDateOnlyFormatter.string(from: dueDate)) }
    return values
  }
}

extension CRMTaskPatch {
  /// Field payload for `tasks.update`. Only set fields are sent; the server
  /// derives `completed_at` from `status`, so it is not sent explicitly.
  var agentValues: [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    if let title { values["title"] = .string(title) }
    if let notes { values["notes"] = .string(notes) }
    if let dueDate { values["due_date"] = .string(taskDateOnlyFormatter.string(from: dueDate)) }
    if let status { values["status"] = .string(status) }
    return values
  }
}

extension CoreAgentClient {
  /// Pulls every task (paginated) as typed models for the menubar list and sync.
  public func listTasks(pageSize: Int = 200) async throws -> [CRMTask] {
    var records: [CRMRecord] = []
    var offset = 0
    while true {
      let page = try await list(entity: "tasks", limit: pageSize, offset: offset)
      records.append(contentsOf: page.data)
      guard !page.data.isEmpty, records.count < page.meta.count else { break }
      offset += page.data.count
    }
    return records.compactMap(CRMTask.init(record:))
  }

  public func createTask(_ payload: CRMTaskCreate) async throws -> CRMTask {
    let record = try await save(entity: "tasks", values: payload.agentValues)
    guard let task = CRMTask(record: record) else { throw CoreAgentClientError.invalidResponse }
    return task
  }

  public func updateTask(id: String, patch: CRMTaskPatch) async throws -> CRMTask {
    let record = try await save(entity: "tasks", id: id, values: patch.agentValues)
    guard let task = CRMTask(record: record) else { throw CoreAgentClientError.invalidResponse }
    return task
  }
}
