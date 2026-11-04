import CoreKit
import EnvisioningUI
import SwiftUI

/// Fetch/state for a global search query. Internal (not private) so the ⌘K
/// command palette (`CRMCommandPaletteView`) can drive the same backend call
/// and result filtering — one source of truth for "search Core".
@MainActor
public final class CRMGlobalSearchModel: ObservableObject {
  public init() {}

  @Published public var results: [AgentSearchResult] = []
  @Published public var isLoading = false
  @Published public var errorMessage: String?
  /// The last query a search actually *finished* for. "No results" is only
  /// honest once this matches the current query — until then a search is still
  /// pending (debounce window or in flight), so the view shows "Searching…"
  /// rather than prematurely claiming nothing was found.
  @Published public private(set) var settledQuery: String?

  public func search(
    _ query: String,
    repository: CRMRepository,
    allowedEntities: Set<String>
  ) async {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { results = []; errorMessage = nil; settledQuery = query; return }
    errorMessage = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await repository.search(query)
      results = response.data.filter { allowedEntities.contains($0.entity) }
      errorMessage = nil
      settledQuery = query
    } catch is CancellationError {
      return
    } catch let error as URLError where error.code == .cancelled {
      // A debounced keystroke cancels the in-flight request; URLSession reports
      // that as `URLError.cancelled`, not `CancellationError`. It's expected
      // churn, not a failure — swallow it so typing doesn't flash an error.
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

public struct CRMGlobalSearchView: View {
  let space: AgentSpace
  let contracts: [CRMEntityContract]
  let repository: CRMRepository
  @Binding var query: String
  @StateObject private var model = CRMGlobalSearchModel()

  public init(space: AgentSpace, contracts: [CRMEntityContract], repository: CRMRepository, query: Binding<String>) {
    self.space = space; self.contracts = contracts; self.repository = repository; self._query = query
  }

  public var body: some View {
    // The `List` is ALWAYS the root under the search field. Swapping the root
    // view's identity (placeholder → progress → list) on the first keystroke
    // makes iOS deactivate the tab-bar search (`isPresented` drops) and the
    // keyboard closes. Keeping one stable container and rendering the
    // placeholder/searching/empty states as an overlay keeps focus alive.
    List(model.results) { result in
      NavigationLink(value: result) {
        CRMSearchResultRow(result: result, contract: contract(for: result))
      }
      .envisioningListRows()
    }
    .envisioningListSurface()
    .overlay {
      if query.isEmpty {
        EnvisioningEmptyState(
          space == .crm ? "Search Core" : "Search Content",
          systemImage: "magnifyingglass"
        )
      } else if model.results.isEmpty, let error = model.errorMessage {
        EnvisioningRetryState("Unable to Search", message: error) {
          Task { await performSearch() }
        }
      } else if model.results.isEmpty && searchSettled {
        // Only claim "no results" once a search has actually finished for this
        // exact query — otherwise a search is still pending, show progress.
        ContentUnavailableView.search(text: query)
      } else if model.results.isEmpty {
        EnvisioningLoadingState("Searching…")
      }
    }
    .navigationTitle("Search")
    .task(id: query) {
      if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
      guard !Task.isCancelled else { return }
      await performSearch()
    }
    .navigationDestination(for: AgentSearchResult.self) { result in
      if let contract = contract(for: result) {
        CRMSearchResultLoader(
          result: result,
          contract: contract,
          allContracts: contracts,
          repository: repository
        )
      }
    }
  }

  private func performSearch() async {
    await model.search(
      query,
      repository: repository,
      allowedEntities: Set(contracts.map(\.id))
    )
  }

  /// True once the model has finished a search for the query currently in the
  /// field (and isn't mid-fetch). Gates the honest "no results" state.
  private var searchSettled: Bool {
    !model.isLoading
      && model.settledQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func contract(for result: AgentSearchResult) -> CRMEntityContract? {
    contracts.first { $0.id == result.entity }
  }
}

/// One search-result row (avatar/icon + name + entity/description lines).
/// Shared by the sidebar/tab search surface and the ⌘K command palette so the
/// two never drift apart.
public struct CRMSearchResultRow: View {
  let result: AgentSearchResult
  let contract: CRMEntityContract?

  public init(result: AgentSearchResult, contract: CRMEntityContract?) {
    self.result = result; self.contract = contract
  }

  public var body: some View {
    let supportsAvatar = CRMEntityIdentity.resolve(id: result.entity).showsAvatar
    let imageURL = result.imageUrl.flatMap { URL(string: $0) }
    let detailLines = [contract?.singularLabel, result.description]
      .compactMap { $0 }
      .filter { !$0.isEmpty }

    HStack(spacing: CRMListRow.iconSpacing) {
      if supportsAvatar {
        CachedRemoteAvatar(
          url: imageURL,
          name: result.name,
          fallbackSymbol: contract?.icon,
          shape: .resolve(entityID: result.entity)
        )
      } else {
        Image(crmSymbol: contract?.icon, fallback: "doc.text.magnifyingglass")
          .frame(width: 40, height: 40)
          .symbolRenderingMode(.hierarchical)
      }
      VStack(alignment: .leading, spacing: CRMListRow.indicatorSpacing) {
        Text(result.name).font(.body.weight(.medium))
        ForEach(detailLines, id: \.self) { line in
          Text(line).font(.caption).foregroundStyle(crmSecondaryText).lineLimit(1)
        }
      }
    }
  }
}

/// Hydrates the full record for a chosen search result, then shows the shared
/// `EntityDetailView`. Used by the sidebar/tab search surface; the ⌘K palette
/// instead routes the selection into the main window.
private struct CRMSearchResultLoader: View {
  let result: AgentSearchResult
  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  @State private var record: CRMRecord?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let record {
        EntityDetailView(
          contract: contract,
          allContracts: allContracts,
          record: record,
          repository: repository,
          onToast: { _ in },
          onChanged: {}
        )
      } else if let errorMessage {
        EnvisioningRetryState("Unable to Open", message: errorMessage) {
          Task { await load() }
        }
      } else {
        EnvisioningLoadingState("Opening \(result.name)…")
      }
    }
    .task { await load() }
  }

  private func load() async {
    errorMessage = nil
    do {
      record = try await repository.record(
        entity: result.entity,
        id: result.id,
        primaryField: contract.primaryField
      ).record
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
