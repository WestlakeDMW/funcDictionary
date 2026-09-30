import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        Form {
            Section("本机词典") {
                LabeledContent("存储") {
                    Label(
                        model.store.isUsingFallbackStorage ? "临时内存存储" : "保存在本机",
                        systemImage: model.store.isUsingFallbackStorage ? "exclamationmark.triangle" : "internaldrive"
                    )
                    .foregroundStyle(model.store.isUsingFallbackStorage ? .orange : .primary)
                }
                LabeledContent("当前项目") {
                    Text(model.activeProject?.name ?? "未选择")
                        .foregroundStyle(.secondary)
                }
                Text("每个项目有独立词典。跨设备同步暂不开放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("全局检索") {
                Toggle(isOn: Binding(
                    get: { model.isGlobalSearchHotKeyEnabled },
                    set: { model.setGlobalSearchHotKeyEnabled($0) }
                )) {
                    LabeledContent {
                        Text("⌘ ⇧ Space")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("系统级快捷键呼出检索")
                        Text("任意 App 前台按下即可在屏幕中央检索全部词典的 func。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("检索按语义相关度排序；匹配度最高的 App 展开显示，其余 App 折叠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(28)
        .navigationTitle("设置")
    }
}
