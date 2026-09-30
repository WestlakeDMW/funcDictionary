import AppKit
import SwiftUI

struct MacHarnessCenterView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject private var harnessCenter: HarnessCenterModel

    init(model: MacAppModel) {
        self.model = model
        _harnessCenter = ObservedObject(wrappedValue: model.harnessCenter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                promptEditor
                Divider()
                Text("连接器")
                    .font(.title2.weight(.semibold))
                Text("先关联源码目录，再由 Agent 阅读仓库并建立函数词典。CLI 测试只验证可执行文件；实际登录和模型调用在任务运行时验证。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: 14) {
                    ForEach(harnessCenter.connections) { connection in
                        HarnessConnectionCard(
                            model: model,
                            harnessCenter: harnessCenter,
                            harness: connection.harness,
                            connection: connection
                        )
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Harness 中心")
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 8) {
                Circle()
                    .fill(model.activeProject == nil ? Color.secondary : Color.green)
                    .frame(width: 8, height: 8)
                if let project = model.activeProject {
                    Text("当前项目：\(project.name)")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(model.workspaceURL(for: project).path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("先选择一个项目，再发送 Agent Context")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制 CLI 接入命令") {
                    model.copyCLILinkCommand()
                }
                Button("关联仓库…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "选择需要建立函数词典的源码根目录"
                    if panel.runModal() == .OK, let url = panel.url { model.setWorkspaceURL(url) }
                }
                .disabled(model.activeProject == nil)
                Button {
                    model.harnessCenter.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("刷新 Harness 连接状态")
                .accessibilityIdentifier("mac-refresh-harness-button")
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("词典化任务", systemImage: "text.bubble")
                .font(.headline)
            TextEditor(text: $model.agentPrompt)
                .font(.body)
                .frame(minHeight: 74, maxHeight: 110)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .accessibilityIdentifier("mac-harness-prompt-editor")
            Text("App 会附带协作规范、完整词典和增量校验工具。Codex 词典化任务使用 workspace-write；规范要求仅写入词典目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HarnessConnectionCard: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var harnessCenter: HarnessCenterModel
    let harness: HarnessID
    let connection: HarnessConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(harness.displayName)
                        .font(.headline)
                    Text(harness.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(connection.status.title, systemImage: connection.status.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 8) {
                TextField(
                    "自动发现或填写可执行文件路径",
                    text: executablePathBinding
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .accessibilityIdentifier("mac-harness-path-\(harness.rawValue)")

                Button("选择…") {
                    chooseExecutable()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("选择 \(harness.displayName) 可执行文件")

                if connection.status == .testing {
                    Button("取消") {
                        harnessCenter.cancel(harness)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("取消 \(harness.displayName) 操作")
                    .accessibilityIdentifier("mac-cancel-harness-\(harness.rawValue)")
                } else {
                    Button("测试连接") {
                        harnessCenter.test(harness)
                    }
                    .buttonStyle(.bordered)
                    .disabled(connection.executableURL == nil)
                    .accessibilityLabel("测试 \(harness.displayName) 连接")
                    .accessibilityIdentifier("mac-test-harness-\(harness.rawValue)")
                }
            }

            DisclosureGroup("参数模板") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("{project} {context} {prompt}", text: argumentTemplateBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Text("占位符会被替换为项目目录、agent-context.json 路径和发送说明。zcode 可在这里适配自己的 CLI 参数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 5)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(connection.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("开始词典化") {
                    model.requestSendContext(to: harness)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activeProject == nil || connection.executableURL == nil || connection.status == .testing)
                .accessibilityLabel("发送当前 Context 到 \(harness.displayName)")
                .accessibilityIdentifier("mac-send-context-\(harness.rawValue)")
            }

            if !connection.lastOutput.isEmpty {
                Text(connection.lastOutput)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private var executablePathBinding: Binding<String> {
        Binding(
            get: { connection.configuration.executablePath },
            set: { harnessCenter.setExecutablePath($0, for: harness) }
        )
    }

    private var argumentTemplateBinding: Binding<String> {
        Binding(
            get: { connection.configuration.argumentTemplate },
            set: { harnessCenter.setArgumentTemplate($0, for: harness) }
        )
    }

    private var icon: String {
        switch harness {
        case .codex: "terminal"
        case .hermes: "wand.and.stars"
        case .zcode: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var statusColor: Color {
        switch connection.status {
        case .connected: .green
        case .available: .blue
        case .testing: .orange
        case .failed: .red
        case .unavailable: .secondary
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 \(harness.displayName) 可执行文件"
        panel.message = "选择本机 Harness CLI 的可执行文件。"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            harnessCenter.setExecutablePath(url.path, for: harness)
        }
    }
}
