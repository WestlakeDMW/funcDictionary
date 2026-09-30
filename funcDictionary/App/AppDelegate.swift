import UIKit


@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let compositionRoot = AppCompositionRoot()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    #if targetEnvironment(macCatalyst)
    override func buildMenu(with builder: UIMenuBuilder) {
        guard builder.system == .main else { return }

        let search = UIKeyCommand(
            input: "f",
            modifierFlags: [.command],
            action: #selector(SceneDelegate.performSearch),
            discoverabilityTitle: "Search Dictionary"
        )
        let sync = UIKeyCommand(
            input: "r",
            modifierFlags: [.command, .shift],
            action: #selector(SceneDelegate.performSync),
            discoverabilityTitle: "Sync Dictionary"
        )
        let copyContext = UIKeyCommand(
            input: "c",
            modifierFlags: [.command, .alternate],
            action: #selector(SceneDelegate.performCopyContext),
            discoverabilityTitle: "Copy Context"
        )
        let sendToAgent = UIKeyCommand(
            input: "s",
            modifierFlags: [.command, .alternate],
            action: #selector(SceneDelegate.performSendToAgent),
            discoverabilityTitle: "Send to Agent"
        )
        let reviewProposals = UIKeyCommand(
            input: "p",
            modifierFlags: [.command, .shift],
            action: #selector(SceneDelegate.performReviewProposals),
            discoverabilityTitle: "Review Proposals"
        )
        let dictionaryMenu = UIMenu(
            title: "Dictionary",
            identifier: UIMenu.Identifier("com.funcdictionary.menu.dictionary"),
            options: [],
            children: [search, sync, copyContext, sendToAgent, reviewProposals]
        )
        builder.insertSibling(dictionaryMenu, afterMenu: .file)
    }
    #endif
}