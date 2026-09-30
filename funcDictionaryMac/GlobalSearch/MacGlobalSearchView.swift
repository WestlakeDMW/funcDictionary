import SwiftUI

/// 系统级检索面板内容：顶部搜索框 + 按项目分组的结果列表。
/// 匹配度最高的 App（主组）展开，其余 App 折叠为标题行，点击展开。
struct MacGlobalSearchView: View {
    @ObservedObject var viewModel: GlobalSearchViewModel
    let onClose: () -> Void
    @FocusState private var isSearchFieldFocused: Bool
    @State private var suppressHover = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .overlay(Color.primary.opacity(0.08))
            content
                .frame(maxHeight: .infinity)
            Divider()
                .overlay(Color.primary.opacity(0.08))
            footer
        }
        .frame(width: GlobalSearchPanelController.panelWidth, height: panelHeight)
        .background(
            VisualEffectBackground()
                .ignoresSafeArea()
        )
        .onExitCommand { onClose() }
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private var panelHeight: CGFloat {
        let rows = viewModel.rows.count
        guard !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 240
        }
        let estimated = 92 + min(CGFloat(rows), 16) * 52 + 36
        return min(max(estimated, 280), GlobalSearchPanelController.panelMaxHeight)
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                "用自然语言搜索功能，例如“登录时校验用户”",
                text: $viewModel.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 19))
            .focused($isSearchFieldFocused)
            .onSubmit {
                viewModel.activateSelected()
            }
            .onMoveCommand { direction in
                // 键盘移动期间禁用 hover 改选，避免光标恰好停在别的行上。
                suppressHover = true
                viewModel.moveSelection(direction)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    suppressHover = false
                }
            }
            if viewModel.isRefreshingIndex {
                ProgressView()
                    .controlSize(.small)
            } else if !viewModel.query.isEmpty {
                Text("esc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState
        } else if viewModel.response.groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("没有匹配的功能")
                    .font(.headline)
                Text("换个说法试试，例如“登录”“删除图片”“payment”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: viewModel.selectedResultID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("result-\(newID)", anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("funcDictionary 快速检索")
                .font(.headline)
            Text("跨项目用自然语言查找 func。匹配度最高的 App 展开显示，其余折叠。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text("\(viewModel.projectCount) 个项目 · \(viewModel.definitionCount) 个词条")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 行

    @ViewBuilder
    private func rowView(_ row: GlobalSearchViewModel.GlobalSearchRow) -> some View {
        switch row.kind {
        case .groupHeader(let projectID, let projectName, let isPrimary, let totalMatches, let isExpanded):
            groupHeader(
                projectID: projectID,
                projectName: projectName,
                isPrimary: isPrimary,
                totalMatches: totalMatches,
                isExpanded: isExpanded
            )
        case .result(let result):
            resultRow(result)
        }
    }

    private func groupHeader(
        projectID: String,
        projectName: String,
        isPrimary: Bool,
        totalMatches: Int,
        isExpanded: Bool
    ) -> some View {
        Button {
            guard !isPrimary else { return }
            viewModel.toggleGroup(projectID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.system(size: 13, weight: .semibold))
                if isPrimary {
                    Text("最佳匹配")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text("\(totalMatches) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isPrimary {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPrimary)
    }

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        let isSelected = viewModel.selectedResultID == result.definitionID
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "curlybraces")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.displayName.isEmpty ? result.canonicalName : result.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !result.canonicalName.isEmpty,
                       result.canonicalName != result.displayName {
                        Text(result.canonicalName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                let detail = !result.comment.isEmpty
                    ? result.comment
                    : (!result.purpose.isEmpty ? result.purpose : result.functionName)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(Int((result.score * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering, !suppressHover else { return }
            viewModel.hoverSelect(result.definitionID)
        }
        .onTapGesture {
            viewModel.activate(result: result)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.displayName)，\(result.canonicalName)")
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            keyHint("↑↓", label: "选择")
            keyHint("↩", label: "打开")
            keyHint("esc", label: "关闭")
            Spacer()
            keyHint("⌘⇧Space", label: "全局呼出")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 面板底材质：HUD 毛玻璃，保证在任何壁纸上都有对比度。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
