import AppKit
import SwiftUI

struct MacRootView: View {
    @ObservedObject var model: MacAppModel
    @State private var listSelection: MacSidebarSelection? = .projects

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(minWidth: 1_080, minHeight: 700)
        .sheet(isPresented: $model.isShowingNewProjectSheet) {
            NewProjectSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingRenameProjectSheet) {
            RenameProjectSheet(model: model)
        }
        .alert("funcDictionary", isPresented: errorPresented) {
            Button("好") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            listSelection = model.sidebarSelection
        }
        .onChange(of: listSelection) { _, selection in
            guard let selection, model.sidebarSelection != selection else { return }
            // Keep the List's AppKit-owned selection separate from the app-wide
            // route. This also keeps command-driven navigation stable.
            DispatchQueue.main.async {
                model.sidebarSelection = selection
                model.handleSidebarSelection(selection)
            }
        }
        .onChange(of: model.sidebarSelection) { _, selection in
            guard listSelection != selection else { return }
            DispatchQueue.main.async {
                listSelection = selection
            }
        }
    }

    private var sidebar: some View {
        List(selection: $listSelection) {
            Section("项目") {
                Label("项目总览", systemImage: "square.grid.2x2")
                    .tag(MacSidebarSelection.projects)

                ForEach(model.projects, id: \.id) { project in
                    Button {
                        model.selectProject(project.id)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                Text("\(model.definitionCount(for: project.id)) 个 Definition")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .tag(MacSidebarSelection.project(project.id))
                    .accessibilityIdentifier("mac-project-row-\(project.id)")
                    .contextMenu {
                        Button("归档项目", role: .destructive) {
                            model.archiveProject(project)
                        }
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .navigationTitle("funcDictionary")
        .toolbar {
            ToolbarItem {
                Button {
                    model.isShowingNewProjectSheet = true
                } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .help("选择一个源码目录并添加项目词典")
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.sidebarSelection {
        case .projects:
            ContentUnavailableView {
                Label("选择一个项目", systemImage: "folder")
            } description: {
                Text("搜索功能、查看代码位置和调用关系。")
            } actions: {
                Button("添加项目") { model.isShowingNewProjectSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        case .project(let projectID):
            MacProjectView(model: model, projectID: projectID)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.clearError() }
            }
        )
    }
}

struct NewProjectSheet: View {
    @ObservedObject var model: MacAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sourceDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建项目")
                .font(.title2.weight(.semibold))
            Text("选择源码目录后，App 会准备供 Agent 读取和更新的词典。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("项目名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
                .accessibilityIdentifier("mac-project-name-field")

            HStack {
                Label(sourceDirectory?.lastPathComponent ?? "尚未选择源码目录", systemImage: "folder")
                    .foregroundStyle(sourceDirectory == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Button("选择目录…") { chooseSourceDirectory() }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加项目") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceDirectory == nil)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let sourceDirectory else { return }
        model.createProject(named: name)
        model.setWorkspaceURL(sourceDirectory)
        dismiss()
    }

    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择源码目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sourceDirectory = panel.url }
    }
}

struct RenameProjectSheet: View {
    @ObservedObject var model: MacAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名项目")
                .font(.title2.weight(.semibold))
            TextField("项目名称", text: $model.renameProjectDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { rename() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.renameProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private func rename() {
        model.renameActiveProject(to: model.renameProjectDraft)
        dismiss()
    }
}
