import CoreKit
import SwiftUI

/// Native port of the web CRM's `StatusPill` (`envisioning-core/src/components/ui/
/// feedback/status-pill.tsx`). Same variants, same value→label mapping, same
/// colour intent — a capsule whose tint carries the status semantics. Keep the
/// two in sync: the web component is the source of truth for which values map to
/// which colour, and the entity table columns below rely on this matching.
///
/// Colours are expressed as tones (a single accent `Color`) rendered as a
/// saturated foreground on a faint fill, matching the existing badge convention
/// in this app (`.background(color.opacity(…), in: Capsule())`).
enum CRMPillTone: Hashable {
  /// Muted grey — the neutral/"unknown"/secondary fallback.
  case neutral
  /// Strong, near-foreground emphasis (web's dark `neutral-900` pills).
  case emphasis
  /// The app's lime accent — success/active/completed.
  case accent
  case blue
  case amber
  case purple
  case red
  case green
  case orange
  case indigo
  case cyan
  case mint

  var color: Color {
    switch self {
    case .neutral: return crmSecondaryText
    case .emphasis: return .primary
    case .accent: return .primary
    case .blue: return .blue
    case .amber: return .yellow
    case .purple: return .purple
    case .red: return .red
    case .green: return .green
    case .orange: return .orange
    case .indigo: return .indigo
    case .cyan: return .cyan
    case .mint: return .mint
    }
  }

  var foreground: Color {
    switch self {
    // Neutral/emphasis read best straight; tinted tones use the saturated hue.
    case .neutral: return crmSecondaryText
    case .emphasis: return .primary
    default: return color
    }
  }

  var fill: Color { color.opacity(0.15) }
}

/// The web `StatusPill` `type` prop. Each case knows how to turn a raw stored
/// value into a display label and a colour tone.
enum CRMStatusPillType: Hashable {
  case projectStatus
  case taskStatus
  case interactionType
  case serviceGroup
  case serviceCategory
  case readinessScore
  case leadStatus
  case offerStatus
  case signalsPlan
  case tokenStatus

  /// Web normalisation: lowercase, spaces → hyphens.
  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
  }

  private func capitalizedFirst(_ value: String) -> String {
    guard let first = value.first else { return value }
    return first.uppercased() + value.dropFirst().lowercased()
  }

  func label(for value: String) -> String {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch self {
    case .taskStatus, .interactionType, .offerStatus:
      return capitalizedFirst(raw)
    case .signalsPlan:
      return raw.isEmpty ? "—" : capitalizedFirst(raw)
    default:
      // project-status, service-group, lead-status, readiness-score: label = raw.
      return raw.isEmpty ? "—" : raw
    }
  }

  func tone(for value: String) -> CRMPillTone {
    let key = normalized(value)
    switch self {
    case .leadStatus:
      return .neutral
    case .offerStatus:
      switch key {
      case "draft": return .emphasis
      case "sent": return .neutral
      default: return .neutral
      }
    case .projectStatus:
      switch key {
      case "planning": return .blue
      case "in-progress": return .amber
      case "review": return .purple
      case "completed": return .accent
      case "on-hold", "archived": return .neutral
      case "cancelled": return .red
      default: return .neutral
      }
    case .serviceGroup:
      switch key {
      case "base": return .blue
      case "research": return .red
      case "license": return .purple
      case "optional": return .neutral
      default: return .neutral
      }
    case .serviceCategory:
      switch key {
      case "visualization": return .cyan
      case "architecture": return .mint
      case "signals": return .orange
      default: return .neutral
      }
    case .taskStatus:
      switch key {
      case "pending": return .emphasis
      case "in-progress": return .amber
      case "completed": return .accent
      case "cancelled": return .red
      default: return .neutral
      }
    case .interactionType:
      switch key {
      case "email": return .blue
      case "call": return .green
      case "meeting": return .purple
      case "message": return .orange
      case "note": return .neutral
      case "web": return .indigo
      default: return .neutral
      }
    case .readinessScore:
      switch key {
      case "high": return .orange
      case "mid", "medium": return .amber
      case "low": return .neutral
      default: return .neutral
      }
    case .signalsPlan:
      switch key {
      case "starter": return .neutral
      case "pro": return .neutral
      case "partner": return .neutral
      default: return .neutral
      }
    case .tokenStatus:
      switch key {
      case "active": return .green
      case "expired": return .red
      default: return .neutral
      }
    }
  }
}

/// A capsule status indicator matching the web CRM's `StatusPill`.
struct CRMStatusPill: View {
  let value: String
  let type: CRMStatusPillType

  var body: some View {
    let tone = type.tone(for: value)
    Text(type.label(for: value))
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(tone.foreground)
      .background(tone.fill, in: Capsule())
  }
}

/// A plain outline badge (web's `Badge variant="outline"` — license Product/Plan,
/// contact Partner/Client, etc.). Optional lime fill for the "active" affirmative.
struct CRMOutlineBadge: View {
  let text: String
  var filled: Bool = false

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(filled ? Color.primary : .secondary)
      .background(
        Capsule().fill(filled ? Color.accentColor.opacity(0.15) : Color.clear)
      )
      .overlay(
        Capsule().strokeBorder(filled ? Color.accentColor.opacity(0.4) : crmSecondaryText.opacity(0.35))
      )
  }
}
