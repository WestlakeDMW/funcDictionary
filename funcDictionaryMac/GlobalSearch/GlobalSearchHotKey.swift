import AppKit
import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的系统级快捷键：不需要辅助功能权限，
/// 任意 App 在前台时都能触发。事件回调固定在主线程上派发。
@MainActor
final class GlobalSearchHotKeyController {
    /// 默认 ⌘⇧Space：不与系统默认（⌘Space Spotlight、⌃⌘Space 表情）冲突。
    static let defaultKeyCode: Int = kVK_Space
    static let defaultModifiers: Int = cmdKey | shiftKey

    var onToggle: (() -> Void)?

    private let hotKeyID = EventHotKeyID(signature: OSType(0x4644_4348) /* 'FDCH' */, id: 1)
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?

    func register() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let controller = Unmanaged<GlobalSearchHotKeyController>
                .fromOpaque(userData).takeUnretainedValue()
            // Carbon 应用级事件在主线程事件循环上派发。
            MainActor.assumeIsolated {
                controller.onToggle?()
            }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            handlerRef = nil
            return
        }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(Self.defaultKeyCode),
            UInt32(Self.defaultModifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if registerStatus == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        // Carbon 清理是线程无关的 C 调用；存储已声明 nonisolated(unsafe)。
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
