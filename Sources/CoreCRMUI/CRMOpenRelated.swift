import CoreKit
import SwiftUI

/// A record to navigate to — the target of a relation field value or a related
/// section item. Carried up to the detail view, which owns the navigation.
public struct CRMRelatedTarget: Hashable, Identifiable {
  public let entityID: String
  public let recordID: String
  public let title: String?
  public var id: String { "\(entityID)/\(recordID)" }

  public init(entityID: String, recordID: String, title: String?) {
    self.entityID = entityID
    self.recordID = recordID
    self.title = title
  }
}

/// An action that opens a related record in the *main* detail column.
///
/// Related content lives in two places that can't push navigation themselves: a
/// `.inspector` side panel (structurally outside the column's `NavigationStack`)
/// and editable relation-field rows (a `Picker`, not a link). Both call this
/// environment action instead of embedding a `NavigationLink`; the detail view
/// turns it into a push on the column's own stack, so the viewer becomes the
/// target's page. `isEnabled` is false where no handler is injected (create/edit
/// forms), so those surfaces render no open affordance.
public struct CRMOpenRelatedAction {
  public let handler: ((CRMRelatedTarget) -> Void)?

  public var isEnabled: Bool { handler != nil }

  public func callAsFunction(_ target: CRMRelatedTarget) { handler?(target) }

  public static let disabled = CRMOpenRelatedAction(handler: nil)

  public init(handler: ((CRMRelatedTarget) -> Void)?) {
    self.handler = handler
  }
}

private struct CRMOpenRelatedKey: EnvironmentKey {
  static let defaultValue = CRMOpenRelatedAction.disabled
}

extension EnvironmentValues {
  public var crmOpenRelated: CRMOpenRelatedAction {
    get { self[CRMOpenRelatedKey.self] }
    set { self[CRMOpenRelatedKey.self] = newValue }
  }
}
