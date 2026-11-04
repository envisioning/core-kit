import CoreKit
import Observation
import SwiftUI

/// The shared favorites of one CRM space, for the screens that star records.
///
/// The host creates one and puts it in the environment
/// (`.environment(center)`); `EntityListView` and `EntityDetailView` then show
/// a star on every record that can be favorited. Without one in the
/// environment they show none, so a host that has no favorites UI (Meet today)
/// is unchanged. The repository does the work and keeps the cache and every
/// other open surface in the process in step; this holds what the screens read.
@MainActor
@Observable
public final class CRMFavoriteCenter {
  public private(set) var favorites: [CRMFavorite] = []
  /// The last failure of `toggle`, for a host that wants to surface it.
  public var errorMessage: String?

  public let repository: CRMRepository
  public var space: AgentSpace { repository.space }

  @ObservationIgnored nonisolated(unsafe) private var observer: Task<Void, Never>?

  public init(repository: CRMRepository) {
    self.repository = repository
  }

  deinit {
    observer?.cancel()
  }

  /// Shows the cached favorites at once, follows changes made anywhere in this
  /// process, then refreshes from the server. Call it again after the account
  /// changes; it rebinds to the current one.
  public func load() async {
    observer?.cancel()
    observer = nil
    guard repository.hasToken else {
      favorites = []
      return
    }
    if let cached = try? await repository.cachedFavorites() { favorites = cached }
    if let stream = try? await repository.observeFavorites() {
      observer = Task { [weak self] in
        for await list in stream {
          guard !Task.isCancelled, let self else { return }
          self.favorites = list
        }
      }
    }
    await refresh()
  }

  /// Fetches the list from the server. A failure keeps what is shown.
  public func refresh() async {
    if let list = try? await repository.refreshFavorites() { favorites = list }
  }

  /// Drops everything shown, for a sign-out or an account switch.
  public func reset() {
    observer?.cancel()
    observer = nil
    favorites = []
  }

  public func isFavorite(_ target: CRMFavoriteTarget) -> Bool {
    favorites.contains { $0.target == target }
  }

  /// The favorite reference for a record shown in this space, or nil when it
  /// cannot be favorited. CMS events are CMS wherever they are opened.
  public func target(for record: CRMRecord, in contract: CRMEntityContract) -> CRMFavoriteTarget? {
    CRMFavoriteTarget(
      contract: contract,
      record: record,
      space: contract.id == "events" ? .cms : space
    )
  }

  /// Stars or unstars at once, then confirms with the server and puts the old
  /// state back if that fails. Returns whether it was saved.
  @discardableResult
  public func toggle(_ target: CRMFavoriteTarget) async -> Bool {
    let previous = favorites
    let wasFavorite = isFavorite(target)
    if wasFavorite {
      favorites.removeAll { $0.target == target }
    } else {
      favorites.insert(
        CRMFavorite(kind: target.kind, targetRef: target.targetRef, createdAt: Date()),
        at: 0
      )
    }
    do {
      if wasFavorite {
        try await repository.removeFavorite(target: target)
      } else {
        _ = try await repository.addFavorite(target: target)
      }
      return true
    } catch {
      favorites = previous
      errorMessage = error.localizedDescription
      return false
    }
  }
}

/// A star that toggles one favorite. Draws nothing when the environment has no
/// `CRMFavoriteCenter`.
public struct CRMFavoriteToggleButton: View {
  @Environment(CRMFavoriteCenter.self) private var center: CRMFavoriteCenter?
  let target: CRMFavoriteTarget
  var onError: (String) -> Void

  @State private var isSaving = false

  public init(target: CRMFavoriteTarget, onError: @escaping (String) -> Void = { _ in }) {
    self.target = target
    self.onError = onError
  }

  public var body: some View {
    if let center {
      let isFavorite = center.isFavorite(target)
      Button {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
          let saved = await center.toggle(target)
          isSaving = false
          if !saved { onError("Unable to update favorite") }
        }
      } label: {
        Image(systemName: isFavorite ? "star.fill" : "star")
          .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
      .help(isFavorite ? "Remove from favorites" : "Add to favorites")
      .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
      .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
  }
}
