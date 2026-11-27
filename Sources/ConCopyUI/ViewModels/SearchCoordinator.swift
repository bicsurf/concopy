import Foundation
import ConCopyCore

/// Coordinates search query debouncing, filtering parameters, and asynchronous database queries.
@MainActor
public final class SearchCoordinator: ObservableObject {
    @Published public var searchQuery: String = ""
    @Published public var selectedListId: UUID? = nil
    @Published public var isFavoritesOnly: Bool = false
    @Published public var selectedTypeFilter: ClipTypeFilter = .all
    @Published public var currentSortMode: ClipSortMode = .updatedAtDesc
    @Published public var visibleLimit: Int = 100

    private var searchTask: Task<Void, Never>?
    private(set) var currentSearchVersion: UInt64 = 0

    public init(
        searchQuery: String = "",
        selectedListId: UUID? = nil,
        isFavoritesOnly: Bool = false,
        selectedTypeFilter: ClipTypeFilter = .all,
        currentSortMode: ClipSortMode = .updatedAtDesc,
        visibleLimit: Int = 100
    ) {
        self.searchQuery = searchQuery
        self.selectedListId = selectedListId
        self.isFavoritesOnly = isFavoritesOnly
        self.selectedTypeFilter = selectedTypeFilter
        self.currentSortMode = currentSortMode
        self.visibleLimit = visibleLimit
    }

    public func cancel() {
        searchTask?.cancel()
    }

    public func executeSearch(
        databaseManager: DatabaseManager,
        onSuccess: @escaping @MainActor ([ClipRecord], Bool, UInt64) -> Void,
        onFailure: @escaping @MainActor (Error, UInt64) -> Void
    ) {
        searchTask?.cancel()
        currentSearchVersion &+= 1
        let version = currentSearchVersion
        let query = searchQuery
        let listID = selectedListId
        let favorites = isFavoritesOnly
        let typeFilter = selectedTypeFilter
        let mode = currentSortMode
        let limit = visibleLimit

        searchTask = Task { [weak self] in
            do {
                if !query.isEmpty {
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    try databaseManager.searchClips(
                        query: query,
                        listId: listID,
                        primaryTypes: typeFilter.matchingPrimaryTypes,
                        favoritesOnly: favorites,
                        sortMode: mode,
                        limit: limit + 1
                    )
                }.value

                guard !Task.isCancelled, let self, self.currentSearchVersion == version else { return }
                let fetched = Array(result.prefix(limit))
                let hasMore = result.count > limit
                onSuccess(fetched, hasMore, version)
            } catch {
                guard !Task.isCancelled, let self, self.currentSearchVersion == version else { return }
                onFailure(error, version)
            }
        }
    }
}
