import CoreKit
import EnvisioningUI
import SwiftUI

/// A small capsule badge for the "approach" variables (language, org type).
public struct OutreachChip: View {
  public init(text: String) { self.text = text }
  public let text: String
  public var body: some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(EnvisioningSurface.elevated, in: .capsule)
      .foregroundStyle(crmSecondaryText)
  }
}

/// Contextual outreach actions shown on a contact's detail page (injected by
/// `EntityDetailView` when the contact is in the Signals funnel). This is where
/// the status moves, so the worklist stays a clean triage view.
struct SignalsOutreachSection: View {
  let record: CRMRecord
  let repository: CRMRepository
  var onToast: (String) -> Void
  var onChanged: () -> Void

  @State private var busy = false

  private var status: String { record["signals_outreach_status"]?.stringValue ?? "" }

  public var body: some View {
    Section("Signals outreach") {
      LabeledContent("Status", value: SignalsOutreach.statusLabel(status))

      if let next = SignalsOutreach.nextStatus(after: status) {
        Button {
          Task { await advance(to: next) }
        } label: {
          Label("Mark \(SignalsOutreach.statusLabel(next))", systemImage: "arrow.right.circle")
        }
        .tint(.primary)
        .disabled(busy)
      }
    }
  }

  private func advance(to next: String) async {
    busy = true
    defer { busy = false }
    do {
      _ = try await repository.save(
        entity: "contacts",
        id: record.id,
        values: ["signals_outreach_status": .string(next)],
        primaryField: "name")
      onToast("Moved to \(SignalsOutreach.statusLabel(next))")
      onChanged()
    } catch {
      onToast("Couldn't update outreach status")
    }
  }
}
