import AppKit
import Combine
import Foundation
import SwiftUI

/// 全局检索的数据与状态层：加载全部项目词典 → 构建索引快照（后台）→
/// 防抖执行检索（后台）→ 维护键盘导航用的扁平行模型。
@MainActor
final class GlobalSearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var response: GlobalSearchResponse = .empty
    @Published private(set) var isRefreshingIndex = false
    @Published private(set) var projectCount = 0
    @Published private(set) var definitionCount = 0
    @Published private(set) var expandedGroupIDs: Set<String> = []
    @Published private(set) var selectedResultID: String?

    /// 选中某行后如何“打开”该 func（面板控制器注入：跳主窗口 + 收起面板）。
    var onOpen: ((_ projectID: String, _ definitionID: String) -> Void)?

    private let store: AppStore
    private var index: GlobalSearchIndex?
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    // 仅在 init 注册、deinit 移除的观察者 token；deinit 是 nonisolated 的，
    // 需要豁免 Sendable 检查。
    private nonisolated(unsafe) var storeObserver: NSObjectProtocol?

    init(store: AppStore) {
        self.store = store
        storeObserver = NotificationCenter.default.addObserver(
            forName: .funcDictionaryStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStoreChange()
            }
        }
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    // MARK: 面板生命周期

    /// 每次呼出面板都清空状态并从存储重建索引快照：保证搜到的是最新
    /// 词典，也不必维护增量失效链路。
    func prepareForPresentation() {
        searchTask?.cancel()
        query = ""
        response = .empty
        selectedResultID = nil
        expandedGroupIDs = []
        rebuildIndex(thenSearch: false)
    }

    private func handleStoreChange() {
        // 面板从未打开过就不预构建；已构建则静默刷新并重跑当前查询。
        guard index != nil || indexTask != nil else { return }
        rebuildIndex(thenSearch: true)
    }

    // MARK: 索引

    private func rebuildIndex(thenSearch: Bool) {
        indexTask?.cancel()
        index = nil
        let scopes = loadScopes()
        projectCount = scopes.count
        definitionCount = scopes.reduce(0) { $0 + $1.definitions.count }
        isRefreshingIndex = true
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let index = GlobalSearchIndex(scopes: scopes)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.index = index
                self.indexTask = nil
                self.isRefreshingIndex = false
                if thenSearch {
                    self.scheduleSearch()
                }
            }
        }
    }

    private func loadScopes() -> [GlobalSearchScope] {
        do {
            let projects = try store.repository.projects(includeArchived: false)
            return projects.map { project in
                GlobalSearchScope(
                    project: project,
                    definitions: (try? store.repository.definitions(in: project.id)) ?? []
                )
            }
        } catch {
            return []
        }
    }

    // MARK: 检索

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            response = .empty
            selectedResultID = nil
            expandedGroupIDs = []
            return
        }
        guard let index else {
            // 呼出后索引尚未就绪：首个按键会触发补建，建好回来自动重跑。
            if indexTask == nil {
                rebuildIndex(thenSearch: true)
            }
            return
        }
        searchTask = Task { [weak self] in
            // 防抖 120ms：连续击键只执行最后一次。
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                GlobalSearchEngine.search(query: text, index: index)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(response: result)
        }
    }

    private func apply(response: GlobalSearchResponse) {
        self.response = response
        expandedGroupIDs = []
        selectedResultID = response.groups.first?.results.first?.definitionID
    }

    // MARK: 行模型（分组渲染 + 键盘导航）

    struct GlobalSearchRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case groupHeader(
                projectID: String,
                projectName: String,
                isPrimary: Bool,
                totalMatches: Int,
                isExpanded: Bool
            )
            case result(GlobalSearchResult)
        }

        let id: String
        let kind: Kind
    }

    var rows: [GlobalSearchRow] {
        var rows: [GlobalSearchRow] = []
        for group in response.groups {
            let expanded = group.isPrimary || expandedGroupIDs.contains(group.projectID)
            rows.append(
                GlobalSearchRow(
                    id: "header-\(group.projectID)",
                    kind: .groupHeader(
                        projectID: group.projectID,
                        projectName: group.projectName,
                        isPrimary: group.isPrimary,
                        totalMatches: group.totalMatches,
                        isExpanded: expanded
                    )
                )
            )
            guard expanded else { continue }
            for result in group.results {
                rows.append(
                    GlobalSearchRow(id: "result-\(result.definitionID)", kind: .result(result))
                )
            }
        }
        return rows
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        let resultIDs = rows.compactMap { row -> String? in
            if case .result(let result) = row.kind { return result.definitionID }
            return nil
        }
        guard !resultIDs.isEmpty else { return }
        guard let current = selectedResultID, let index = resultIDs.firstIndex(of: current) else {
            selectedResultID = resultIDs[0]
            return
        }
        switch direction {
        case .down:
            selectedResultID = resultIDs[min(index + 1, resultIDs.count - 1)]
        case .up:
            selectedResultID = resultIDs[max(index - 1, 0)]
        default:
            break
        }
    }

    func hoverSelect(_ definitionID: String) {
        selectedResultID = definitionID
    }

    func toggleGroup(_ projectID: String) {
        if expandedGroupIDs.contains(projectID) {
            expandedGroupIDs.remove(projectID)
        } else {
            expandedGroupIDs.insert(projectID)
        }
    }

    func activateSelected() {
        guard let selectedResultID else { return }
        activate(definitionID: selectedResultID)
    }

    func activate(result: GlobalSearchResult) {
        activate(definitionID: result.definitionID)
    }

    private func activate(definitionID: String) {
        let projectID = response.groups.first { group in
            group.results.contains { $0.definitionID == definitionID }
        }?.projectID
        guard let projectID else { return }
        onOpen?(projectID, definitionID)
    }
}
