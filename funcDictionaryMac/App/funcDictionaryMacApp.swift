import AppKit
import SwiftUI

@main
@MainActor
struct FuncDictionaryMacApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    @StateObject private var bootstrap = MacAppBootstrap()

    var body: some Scene {
        Window("funcDictionary", id: "main") {
            MacBootstrapView(bootstrap: bootstrap)
        }
        .commands {
            MacCommands(bootstrap: bootstrap)
        }

        Settings {
            MacSettingsBootstrapView(bootstrap: bootstrap)
        }
    }
}

@MainActor
final class MacAppBootstrap: ObservableObject {
    @Published private(set) var model: MacAppModel?
    @Published private(set) var globalSearch: GlobalSearchPanelController?
    @Published private(set) var isLoading = true
    private var hasStarted = false
    private var pendingLinks: [URL] = []

    func open(_ url: URL) {
        if let model { model.handleLink(url) }
        else { pendingLinks.append(url) }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let store = await AppStore.makeLoaded()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let suite = "funcDictionary.mac.uiTesting"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            model = MacAppModel(store: store, defaults: defaults)
        } else {
            model = MacAppModel(store: store)
        }
        let searchController = GlobalSearchPanelController(model: model!)
        globalSearch = searchController
        searchController.start()
        isLoading = false
        for url in pendingLinks { model?.handleLink(url) }
        pendingLinks.removeAll()
    }
}

struct MacBootstrapView: View {
    @ObservedObject var bootstrap: MacAppBootstrap

    var body: some View {
        Group {
            if let model = bootstrap.model {
                MacRootView(model: model)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在准备本地词典…")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 960, minHeight: 620)
            }
        }
        .task {
            await bootstrap.start()
        }
        .onOpenURL { bootstrap.open($0) }
    }
}

struct MacSettingsBootstrapView: View {
    @ObservedObject var bootstrap: MacAppBootstrap

    var body: some View {
        Group {
            if let model = bootstrap.model {
                MacSettingsView(model: model)
            } else {
                ProgressView("正在准备本地词典…")
                    .frame(width: 520, height: 260)
            }
        }
        .task {
            await bootstrap.start()
        }
    }
}

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }
}

struct MacCommands: Commands {
    @ObservedObject var bootstrap: MacAppBootstrap

    var body: some Commands {
        if let model = bootstrap.model {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") {
                    model.isShowingNewProjectSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("检索") {
                Button("全局功能检索…") {
                    bootstrap.globalSearch?.togglePanel()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
