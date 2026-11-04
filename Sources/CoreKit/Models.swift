import Foundation

// MARK: - Sync Protocol
public protocol Syncable: Codable, Identifiable, Equatable {
  var id: String { get }
  var updatedAt: Date { get }
}

public struct CRMTask: Codable, Identifiable, Equatable, Syncable {
  public let id: String
  public var title: String
  public var notes: String?
  public var dueDate: Date?
  public var priority: Int?
  public var status: String
  public var createdAt: Date?
  public var updatedAt: Date
  public var completedAt: Date?

  public init(id: String, title: String, notes: String? = nil, dueDate: Date? = nil, priority: Int? = nil, status: String, createdAt: Date? = nil, updatedAt: Date, completedAt: Date? = nil) {
    self.id = id; self.title = title; self.notes = notes; self.dueDate = dueDate; self.priority = priority; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt; self.completedAt = completedAt
  }
  // Relations
  public var contactId: String?
  public var projectId: String?
  public var milestoneId: String?
  public var leadId: String?
  public var organizationId: String?
  public var contact: CRMContact?
  public var project: CRMProject?
  public var lead: CRMLead?
  public var milestone: CRMMilestone?
  public var organization: CRMOrganization?

  enum CodingKeys: String, CodingKey {
    case id, title, notes, status, priority, createdAt, updatedAt, dueDate, completedAt
    case contactId, projectId, milestoneId, leadId, organizationId
    case contact, project, lead, milestone, organization
    // flattened relation names some APIs return
    case contactName, projectTitle, leadTitle, milestoneTitle, organizationName
    case labels
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.title = try c.decode(String.self, forKey: .title)
    self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    self.dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.status = try c.decode(String.self, forKey: .status)
    self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)

    self.contactId = try c.decodeIfPresent(String.self, forKey: .contactId)
    self.projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
    self.milestoneId = try c.decodeIfPresent(String.self, forKey: .milestoneId)
    self.leadId = try c.decodeIfPresent(String.self, forKey: .leadId)
    self.organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId)

    // Prefer embedded objects if present
    self.contact = try c.decodeIfPresent(CRMContact.self, forKey: .contact)
    self.project = try c.decodeIfPresent(CRMProject.self, forKey: .project)
    self.lead = try c.decodeIfPresent(CRMLead.self, forKey: .lead)
    self.milestone = try c.decodeIfPresent(CRMMilestone.self, forKey: .milestone)
    self.organization = try c.decodeIfPresent(CRMOrganization.self, forKey: .organization)

    // Fallback: construct minimal objects from flattened name/title fields + ids
    if contact == nil, let id = contactId,
      let name = try c.decodeIfPresent(String.self, forKey: .contactName)
    {
      self.contact = CRMContact(
        id: id, name: name, email: nil, organizationId: nil, updatedAt: Date())
    }
    if project == nil, let id = projectId,
      let title = try c.decodeIfPresent(String.self, forKey: .projectTitle)
    {
      self.project = CRMProject(id: id, title: title, status: "", updatedAt: Date())
    }
    if lead == nil, let id = leadId,
      let title = try c.decodeIfPresent(String.self, forKey: .leadTitle)
    {
      self.lead = CRMLead(id: id, title: title, status: "", updatedAt: Date())
    }
    if milestone == nil, let id = milestoneId,
      let title = try c.decodeIfPresent(String.self, forKey: .milestoneTitle)
    {
      self.milestone = CRMMilestone(id: id, title: title, updatedAt: Date())
    }
    if organization == nil, let id = organizationId,
      let name = try c.decodeIfPresent(String.self, forKey: .organizationName)
    {
      self.organization = CRMOrganization(id: id, name: name, updatedAt: Date())
    }

    // Fallback: labels.{contact,project,lead,milestone,organization}
    if let labels = try? c.decode([String: String?].self, forKey: .labels) {
      if contact == nil, let id = contactId, let name = labels["contact"] ?? nil {
        self.contact = CRMContact(
          id: id, name: name, email: nil, organizationId: nil, updatedAt: Date())
      }
      if project == nil, let id = projectId, let title = labels["project"] ?? nil {
        self.project = CRMProject(id: id, title: title, status: "", updatedAt: Date())
      }
      if lead == nil, let id = leadId, let title = labels["lead"] ?? nil {
        self.lead = CRMLead(id: id, title: title, status: "", updatedAt: Date())
      }
      if milestone == nil, let id = milestoneId, let title = labels["milestone"] ?? nil {
        self.milestone = CRMMilestone(id: id, title: title, updatedAt: Date())
      }
      if organization == nil, let id = organizationId, let name = labels["organization"] ?? nil {
        self.organization = CRMOrganization(id: id, name: name, updatedAt: Date())
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(notes, forKey: .notes)
    try c.encodeIfPresent(dueDate, forKey: .dueDate)
    try c.encodeIfPresent(priority, forKey: .priority)
    try c.encode(status, forKey: .status)
    try c.encodeIfPresent(createdAt, forKey: .createdAt)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encodeIfPresent(completedAt, forKey: .completedAt)
    try c.encodeIfPresent(contactId, forKey: .contactId)
    try c.encodeIfPresent(projectId, forKey: .projectId)
    try c.encodeIfPresent(milestoneId, forKey: .milestoneId)
    try c.encodeIfPresent(leadId, forKey: .leadId)
    try c.encodeIfPresent(organizationId, forKey: .organizationId)
    try c.encodeIfPresent(contact, forKey: .contact)
    try c.encodeIfPresent(project, forKey: .project)
    try c.encodeIfPresent(lead, forKey: .lead)
    try c.encodeIfPresent(milestone, forKey: .milestone)
    try c.encodeIfPresent(organization, forKey: .organization)
  }
}

public struct CRMTaskCreate: Codable {
  public var title: String
  public var notes: String?
  public var dueDate: Date?
  public var priority: Int?

  public init(title: String, notes: String? = nil, dueDate: Date? = nil, priority: Int? = nil) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
  }
}

public struct CRMTaskPatch: Codable {
  public var title: String?
  public var notes: String?
  public var dueDate: Date?
  public var priority: Int?
  public var status: String?
  public var completedAt: Date?

  public init(
    title: String? = nil, notes: String? = nil, dueDate: Date? = nil, priority: Int? = nil,
    status: String? = nil, completedAt: Date? = nil
  ) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
    self.status = status
    self.completedAt = completedAt
  }
}

public struct CRMContact: Codable, Equatable, Identifiable, Syncable {
  public var id: String
  public var name: String
  public var email: String?
  public var organizationId: String?
  public var updatedAt: Date

  public init(id: String, name: String, email: String? = nil, organizationId: String? = nil, updatedAt: Date) {
    self.id = id; self.name = name; self.email = email; self.organizationId = organizationId; self.updatedAt = updatedAt
  }
}

public struct CRMProject: Codable, Equatable, Identifiable, Syncable {
  public var id: String
  public var title: String
  public var status: String
  public var updatedAt: Date

  public init(id: String, title: String, status: String, updatedAt: Date) {
    self.id = id; self.title = title; self.status = status; self.updatedAt = updatedAt
  }
}

public struct CRMLead: Codable, Equatable, Identifiable, Syncable {
  public var id: String
  public var title: String
  public var status: String
  public var updatedAt: Date

  public init(id: String, title: String, status: String, updatedAt: Date) {
    self.id = id; self.title = title; self.status = status; self.updatedAt = updatedAt
  }
}

public struct CRMMilestone: Codable, Equatable, Identifiable, Syncable {
  public var id: String
  public var title: String
  public var updatedAt: Date

  public init(id: String, title: String, updatedAt: Date) {
    self.id = id; self.title = title; self.updatedAt = updatedAt
  }
}

public struct CRMOrganization: Codable, Equatable, Identifiable, Syncable {
  public var id: String
  public var name: String
  public var updatedAt: Date

  public init(id: String, name: String, updatedAt: Date) {
    self.id = id; self.name = name; self.updatedAt = updatedAt
  }
}

public enum SyncDirection: String, Codable { case crmToReminders, remindersToCrm }

public struct Mapping: Codable, Equatable {
  public var taskId: String
  public var reminderId: String
  public var lastDirection: SyncDirection
  public var lastUpdatedAt: Date

  public init(taskId: String, reminderId: String, lastDirection: SyncDirection, lastUpdatedAt: Date) {
    self.taskId = taskId; self.reminderId = reminderId; self.lastDirection = lastDirection; self.lastUpdatedAt = lastUpdatedAt
  }
}

public struct Checkpoint: Codable, Equatable {
  public var listId: String
  public var lastPullAt: Date?
  public var lastPushAt: Date?

  public init(listId: String, lastPullAt: Date? = nil, lastPushAt: Date? = nil) {
    self.listId = listId; self.lastPullAt = lastPullAt; self.lastPushAt = lastPushAt
  }
}
