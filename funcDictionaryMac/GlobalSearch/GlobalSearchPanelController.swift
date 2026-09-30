import AppKit
import Combine
import SwiftUI

/// Spotlight 式居中检索面板的窗口管理：浮动层级、跨 Space 显示、可成为
/// key window；失焦或 Esc 自动收起，收起时把焦点还给呼出前的 App。
@MainActor
final class GlobalSearchPanelController {
    static let panelWidth: CGFloat = 660
    static let panelMaxHeight: CGFloat = 520

    let viewModel: GlobalSearchViewModel
    private let panel: FuncSearchPanel
    private let hotKeyController = GlobalSearchHotKeyController()
    private var cancellables: Set<AnyCancellable> = []
    private var previouslyFrontmostApp: NSRunningApplication?

    init(model: MacAppModel) {
        viewModel = GlobalSearchViewModel(store: model.store)

        let panel = FuncSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelMaxHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        configurePanel(panel)

        let closeAction: () -> Void = { [weak self] in
            self?.hidePanel(restoreFocus: true)
        }
        let rootView = MacGlobalSearchView(viewModel: viewModel, onClose: closeAction)
        let hostingView = NSHostingView(rootView: rootView)
        panel.contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14
        hostingView.layer?.masksToBounds = true

        viewModel.onOpen = { [weak self, weak model] projectID, definitionID in
            model?.openDefinitionInMainWindow(projectID: projectID, definitionID: definitionID)
            self?.hidePanel(restoreFocus: false)
        }
        hotKeyController.onToggle = { [weak self] in
            self?.togglePanel()
        }

        model.$isGlobalSearchHotKeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setHotKeyEnabled(enabled)
            }
            .store(in: &cancellables)
    }

    func start() {
        setHotKeyEnabled(UserDefaults.standard.object(forKey: MacAppModel.globalSearchHotKeyEnabledKey) as? Bool ?? true)
    }

    func setHotKeyEnabled(_ enabled: Bool) {
        if enabled {
            // UI 测试进程不注册系统级热键，避免污染宿主机。
            guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
            hotKeyController.register()
        } else {
            hotKeyController.unregister()
        }
    }

    func togglePanel() {
        if panel.isVisible {
            hidePanel(restoreFocus: true)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        previouslyFrontmostApp = NSWorkspace.shared.frontmostApplication
        viewModel.prepareForPresentation()
        panel.setFrame(Self.centeredFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusSearchField()
    }

    private func hidePanel(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus, let app = previouslyFrontmostApp, app != NSRunningApplication.current {
            app.activate(options: [])
        }
        previouslyFrontmostApp = nil
    }

    private func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let contentView = self.panel.contentView else { return }
            if let field = Self.firstTextField(in: contentView) {
                self.panel.makeFirstResponder(field)
            }
        }
    }

    private static func firstTextField(in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let hit = firstTextField(in: subview) {
                return hit
            }
        }
        return nil
    }

    /// 在鼠标所在屏幕的可见区域内居中，整体略偏上（Spotlight 惯例）。
    static func centeredFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(panelMaxHeight, max(320, visible.height - 160))
        let width = min(panelWidth, visible.width - 80)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2 + visible.height * 0.08
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func configurePanel(_ panel: FuncSearchPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

/// 可成为 key window 的无边框面板；失去 key（点击面板外部）时自动收起。
final class FuncSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isVisible {
            orderOut(nil)
        }
    }

    /// SwiftUI 的 onExitCommand 之外再兜一层 Esc。
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
