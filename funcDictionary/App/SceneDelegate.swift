import UIKit


@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let rootViewController = (UIApplication.shared.delegate as? AppDelegate)?
            .compositionRoot
            .makeRootViewController()
            ?? AppCompositionRoot().makeRootViewController()

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        window.tintColor = .systemBlue
        self.window = window
        window.makeKeyAndVisible()
    }

    @objc func performSearch() {
        let searchViewController = (UIApplication.shared.delegate as? AppDelegate)?
            .compositionRoot
            .makeSearchViewController()
            ?? AppCompositionRoot().makeSearchViewController()
        guard let root = window?.rootViewController else { return }
        if let splitViewController = root as? UISplitViewController,
           let navigationController = splitViewController.viewController(for: .secondary) as? UINavigationController {
            navigationController.pushViewController(searchViewController, animated: true)
            return
        }
        if let navigationController = root as? UINavigationController {
            navigationController.pushViewController(searchViewController, animated: true)
        }
    }

    @objc func performSync() {
        let alert = UIAlertController(
            title: "Sync",
            message: "Sync will be available when the project store is connected.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
    }

    @objc func performCopyContext() {
        guard let dictionary = activeDictionaryViewController() else {
            presentMenuActionError("Open a dictionary before copying context.")
            return
        }
        dictionary.copyContextFromMenu()
    }

    @objc func performSendToAgent() {
        guard let dictionary = activeDictionaryViewController() else {
            presentMenuActionError("Open a dictionary before sending context to an Agent.")
            return
        }
        dictionary.sendToAgentFromMenu()
    }

    @objc func performReviewProposals() {
        guard let dictionary = activeDictionaryViewController() else {
            presentMenuActionError("Open a dictionary before reviewing proposals.")
            return
        }
        dictionary.openReviewFromMenu()
    }

    private func activeDictionaryViewController() -> DictionaryViewController? {
        guard let root = window?.rootViewController else { return nil }
        if let split = root as? UISplitViewController,
           let navigationController = split.viewController(for: .secondary) as? UINavigationController {
            return navigationController.topViewController as? DictionaryViewController
        }
        if let navigationController = root as? UINavigationController {
            return navigationController.visibleViewController as? DictionaryViewController
        }
        return nil
    }

    private func presentMenuActionError(_ message: String) {
        let alert = UIAlertController(title: "Dictionary Action Unavailable", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
    }
}