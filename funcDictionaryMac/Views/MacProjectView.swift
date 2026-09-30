import AppKit
import SwiftUI

struct MacProjectView: View {
    @ObservedObject var model: MacAppModel
    let projectID: String

    var body: some View {
        VStack(spacing: 0) {
            if let project = model.project(withID: projectID) {
                projectHeader(project)
                Divider()
                HSplitView {
                    definitionList
                        .frame(minWidth: 300, idealWidth: 350, maxWidth: 440)
                    definitionDetail
                        .frame(minWidth: 490)
                }
            } else {
                ContentUnavailableView("项目不存在", systemImage: "folder.badge.questionmark")
            }
        }
        .onAppear { model.selectProject(projectID) }
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.title2.weight(.semibold))
                Text(model.linkedWorkspaceName(for: project) ?? "尚未关联源码目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(syncSummary(for: project), systemImage: syncSymbol(for: project))
                .font(.caption)
                .foregroundStyle(syncNeedsAttention(for: project.id) ? Color.orange : Color.secondary)
                .help(syncHelp(for: project.id))
            Button(model.linkedWorkspaceName(for: project) == nil ? "关联源码" : "更换目录") {
                chooseWorkspace()
            }
            Button("复制接入说明") { model.copyAgentInstructions(for: project.id) }
                .disabled(model.linkedWorkspaceName(for: project) == nil)
            Menu {
                Button("在 Finder 中打开目录") {
                    NSWorkspace.shared.open(model.workspaceURL(for: project))
                }
                .disabled(model.linkedWorkspaceName(for: project) == nil)
                Divider()
                Button("重命名项目…") { model.beginRenamingActiveProject() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多项目操作")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    private func syncSummary(for project: Project) -> String {
        guard model.linkedWorkspaceName(for: project) != nil else { return "未关联源码目录" }
        let projectID = project.id
        guard let status = model.syncEvents.first(where: { $0.projectID == projectID })?.status else {
            return model.lastUpdateDates[projectID] == nil ? "自动更新已开启" : "已更新"
        }
        return switch status {
        case .applied(let revision): "已更新 · rev \(revision)"
        case .needsAttention(let revision, let count): "已更新 · \(count) 项待处理 · rev \(revision)"
        case .duplicate: "已是最新"
        case .stale, .failed: "需要处理"
        }
    }

    private func syncSymbol(for project: Project) -> String {
        guard model.linkedWorkspaceName(for: project) != nil else { return "folder.badge.questionmark" }
        let projectID = project.id
        guard let status = model.syncEvents.first(where: { $0.projectID == projectID })?.status else {
            return model.lastUpdateDates[projectID] == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        }
        return switch status {
        case .applied, .duplicate: "checkmark.circle"
        case .needsAttention, .stale, .failed: "exclamationmark.circle"
        }
    }

    private func syncNeedsAttention(for projectID: String) -> Bool {
        guard let status = model.syncEvents.first(where: { $0.projectID == projectID })?.status else { return false }
        return switch status {
        case .needsAttention, .stale, .failed: true
        case .applied, .duplicate: false
        }
    }

    private func syncHelp(for projectID: String) -> String {
        guard let project = model.project(withID: projectID), model.linkedWorkspaceName(for: project) != nil else {
            return "先关联源码目录，才能接收 Agent 的词典更新。"
        }
        guard let event = model.syncEvents.first(where: { $0.projectID == projectID }) else {
            if let date = model.lastUpdateDates[projectID] {
                return "上次成功更新：\(date.formatted(date: .abbreviated, time: .shortened))。Agent 的新提交仍会自动处理。"
            }
            return "Agent 提交词典变更后自动更新。"
        }
        let date = event.date.formatted(date: .abbreviated, time: .shortened)
        return switch event.status {
        case .applied(let revision): "\(date) 写入 rev \(revision)。"
        case .needsAttention(let revision, let count): "\(date) 已更新到 rev \(revision)，但有 \(count) 项内容冲突；请在对应词条的‘需要处理’区域选择保留内容。"
        case .duplicate: "\(date) 收到的变更已处理过。"
        case .stale(let expected, let actual): "\(date) 版本不匹配：当前需要 rev \(expected)，提交使用了 rev \(actual)。Agent 需重读词典后重提。"
        case .failed(let message): "\(date) 更新失败：\(message)"
        }
    }

    private var definitionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("功能词典").font(.headline)
                Spacer()
                Text("\(model.filteredDefinitions.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("描述功能、输入函数名或旧叫法", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("mac-definition-search-field")
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)

            if model.filteredDefinitions.isEmpty {
                ContentUnavailableView {
                    Label(model.definitions.isEmpty ? "词典还没有条目" : "没有匹配结果", systemImage: "text.magnifyingglass")
                } description: {
                    Text(model.definitions.isEmpty
                         ? "复制 Agent 接入说明，让 Agent 为项目建立第一批词条。"
                         : "试试功能用途、函数名、文件名或以前使用过的叫法。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedDefinitionID) {
                    ForEach(model.filteredDefinitions, id: \.id) { definition in
                        DefinitionListRow(definition: definition)
                            .tag(Optional(definition.id))
                            .contextMenu {
                                Button("复制定位信息") { copyLocator(for: definition) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var definitionDetail: some View {
        if let definition = model.selectedDefinition {
            MacDefinitionDetailView(model: model, definition: definition)
        } else {
            ContentUnavailableView("选择一个功能", systemImage: "text.book.closed")
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择项目源码目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.setWorkspaceURL(url) }
    }

    private func copyLocator(for definition: Definition) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(definition.locatorMarkdown, forType: .string)
    }
}

struct DefinitionListRow: View {
    let definition: Definition

    private var location: String {
        let file = definition.codeLocator.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return "代码位置待补充" }
        if let line = definition.codeLocator.lineHint { return "\(file):\(line)" }
        return file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.identity.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(definition.function.purpose.nonEmptyValue ?? definition.codeLocator.comment.nonEmptyValue ?? "暂无功能说明")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(definition.codeLocator.function.nonEmptyValue ?? definition.codeLocator.symbol.nonEmptyValue ?? "未关联函数")
                Text("·")
                Text(location)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct MacDefinitionDetailView: View {
    @ObservedObject var model: MacAppModel
    let definition: Definition
    @State private var isEditing = false

    private var workspaceURL: URL? {
        guard let project = model.project(withID: definition.projectID) else { return nil }
        return model.workspaceURL(for: project)
    }

    private var codeURL: URL? {
        DefinitionFileLink.resolve(file: definition.codeLocator.file, in: workspaceURL)
    }

    private var callSites: [CallSite] {
        model.definitions.flatMap { caller in
            caller.relations.compactMap { relation in
                guard relation.type == .calls, relation.targetDefinitionID == definition.id else { return nil }
                return CallSite(caller: caller, relation: relation)
            }
        }
        .sorted {
            let left = $0.relation.metadata["file"] ?? $0.caller.codeLocator.file
            let right = $1.relation.metadata["file"] ?? $1.caller.codeLocator.file
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(definition.identity.displayName)
                        .font(.largeTitle.weight(.semibold))
                    Text(definition.identity.canonicalName)
                        .font(.title3.monospaced())
                        .foregroundStyle(.secondary)
                    if let purpose = definition.function.purpose.nonEmptyValue {
                        Text(purpose).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button { isEditing = true } label: { Label("编辑说明", systemImage: "pencil") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac-edit-definition-button")
                    Button { copyLocator() } label: { Label("复制定位信息", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("mac-copy-locator-button")
                }

                codeLocationSection
                conflictsSection
                callersSection
                aliasesSection
                historySection
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) {
            MacDefinitionEditorView(model: model, definition: definition)
        }
    }

    private var codeLocationSection: some View {
        DetailSection(title: "代码位置", systemImage: "curlybraces") {
            DetailValueRow(label: "函数", value: definition.codeLocator.function.nonEmptyValue ?? definition.codeLocator.symbol)
            if let signature = definition.codeLocator.signature.nonEmptyValue {
                DetailValueRow(label: "签名", value: signature)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("文件").foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                if let codeURL {
                    Button {
                        NSWorkspace.shared.open(codeURL)
                    } label: {
                        Text(locationText).underline()
                            .font(.callout.monospaced())
                    }
                    .buttonStyle(.link)
                    .help("在默认代码编辑器中打开")
                } else {
                    Text(locationText).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let comment = definition.codeLocator.comment.nonEmptyValue {
                DetailValueRow(label: "人工备注", value: comment)
            }
        }
    }

    private var callersSection: some View {
        DetailSection(title: "被哪里使用", systemImage: "arrow.turn.down.right") {
            if callSites.isEmpty {
                Text("暂无已确认的直接调用位置。Agent 应提供调用文件、行号和依据。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(callSites) { callSite in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(callSite.caller.identity.displayName) {
                            model.selectedDefinitionID = callSite.caller.id
                        }
                        .buttonStyle(.link)
                        .font(.body.weight(.medium))
                        if let url = callSite.fileURL(in: workspaceURL) {
                            Button(callSite.location) { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link)
                                .font(.caption.monospaced())
                        } else {
                            Text(callSite.location)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let evidence = callSite.relation.metadata["evidence"], !evidence.isEmpty {
                            Text(evidence).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private var conflictsSection: some View {
        let unresolved = model.conflicts.filter {
            $0.definitionID == definition.id && $0.status == .needsReview
        }
        if !unresolved.isEmpty {
            DetailSection(title: "需要处理", systemImage: "exclamationmark.bubble") {
                ForEach(unresolved, id: \.id) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字段：\(conflict.field)").font(.caption.monospaced())
                        DetailValueRow(label: "当前内容", value: conflict.localValue)
                        DetailValueRow(label: "Agent 更新", value: conflict.remoteValue)
                        HStack {
                            Button("保留当前") { model.resolveConflict(conflict, useRemoteValue: false) }
                            Button("采用 Agent 更新") { model.resolveConflict(conflict, useRemoteValue: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    @ViewBuilder
    private var aliasesSection: some View {
        if !definition.fuzzyTerms.isEmpty || definition.humanPriority != nil {
            DetailSection(title: "其他叫法与说明", systemImage: "text.quote") {
                if !definition.fuzzyTerms.isEmpty {
                    Text(definition.fuzzyTerms.map(\.text).joined(separator: "、"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let priority = definition.humanPriority {
                    DetailValueRow(label: "重要性", value: [priority.label, priority.note].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
        }
    }

    private var historySection: some View {
        DisclosureGroup {
            if definition.implementationHistory.isEmpty {
                Text("暂无变更记录").foregroundStyle(.secondary).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(definition.implementationHistory.sorted { $0.revision > $1.revision }, id: \.revision) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("rev \(event.revision)").font(.caption.monospaced())
                                Text(event.changeType).font(.caption.weight(.medium))
                                Spacer()
                                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            ForEach(event.changes.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(event.changes[key] ?? "")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            Label("变更记录", systemImage: "clock.arrow.circlepath").font(.headline)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var locationText: String {
        guard let file = definition.codeLocator.file.nonEmptyValue else { return "尚未记录文件位置" }
        if let line = definition.codeLocator.lineHint { return "\(file):\(line)" }
        return file
    }

    private func copyLocator() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(definition.locatorMarkdown, forType: .string)
    }
}

struct MacDefinitionEditorView: View {
    @ObservedObject var model: MacAppModel
    @Environment(\.dismiss) private var dismiss
    let definition: Definition

    @State private var displayName: String
    @State private var purpose: String
    @State private var comment: String

    init(model: MacAppModel, definition: Definition) {
        self.model = model
        self.definition = definition
        _displayName = State(initialValue: definition.identity.displayName)
        _purpose = State(initialValue: definition.function.purpose)
        _comment = State(initialValue: definition.codeLocator.comment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑功能说明").font(.title2.weight(.semibold))
            Form {
                TextField("功能名称", text: $displayName)
                TextField("功能用途", text: $purpose, axis: .vertical).lineLimit(3...7)
                TextField("人工备注", text: $comment, axis: .vertical).lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540, height: 430)
    }

    private func save() {
        model.saveDefinitionEdits(original: definition, displayName: displayName, purpose: purpose, comment: comment)
        dismiss()
    }
}

private struct CallSite: Identifiable {
    let caller: Definition
    let relation: Relation
    var id: String { relation.id }

    var location: String {
        let file = relation.metadata["file"] ?? ""
        let line = relation.metadata["line"] ?? ""
        if !file.isEmpty, !line.isEmpty { return "\(file):\(line)" }
        if !file.isEmpty { return file }
        return "调用位置待补充"
    }

    func fileURL(in workspace: URL?) -> URL? {
        guard let file = relation.metadata["file"] else { return nil }
        return DefinitionFileLink.resolve(file: file, in: workspace)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct DetailValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(value.isEmpty ? "未填写" : value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

enum DefinitionFileLink {
    static func resolve(file: String, in workspace: URL?) -> URL? {
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: trimmed) ? URL(fileURLWithPath: trimmed) : nil
        }
        guard let workspace else { return nil }
        let candidate = workspace.appendingPathComponent(trimmed).standardizedFileURL
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

private extension Definition {
    var locatorMarkdown: String {
        var lines = ["\(identity.displayName) (`\(identity.canonicalName)`)", "ID: \(id)"]
        if !function.purpose.isEmpty { lines.append("用途：\(function.purpose)") }
        if !codeLocator.function.isEmpty { lines.append("函数：\(codeLocator.function)") }
        if !codeLocator.signature.isEmpty { lines.append("签名：\(codeLocator.signature)") }
        if !codeLocator.file.isEmpty {
            let location = codeLocator.lineHint.map { "\(codeLocator.file):\($0)" } ?? codeLocator.file
            lines.append("位置：\(location)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var nonEmptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
