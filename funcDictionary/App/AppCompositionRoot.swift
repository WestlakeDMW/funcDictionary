import UIKit


@MainActor
final class AppCompositionRoot {
    private let store: AppStore

    init(store: AppStore = AppStore()) {
        self.store = store
    }

    func makeRootViewController() -> UIViewController {
        let projectViewController = ProjectListViewController(store: store)
        let dictionaryViewController = DictionaryViewController(store: store)

        if UIDevice.current.userInterfaceIdiom == .phone {
            let navigationController = UINavigationController(rootViewController: projectViewController)
            projectViewController.onProjectSelected = { [weak projectViewController, dictionaryViewController] project in
                dictionaryViewController.setProject(project)
                guard let navigationController = projectViewController?.navigationController,
                      navigationController.topViewController !== dictionaryViewController else {
                    return
                }
                navigationController.pushViewController(dictionaryViewController, animated: true)
            }
            return navigationController
        }

        projectViewController.onProjectSelected = { [weak dictionaryViewController] project in
            dictionaryViewController?.setProject(project)
        }
        let splitViewController = UISplitViewController(style: .doubleColumn)
        splitViewController.preferredSplitBehavior = .tile
        splitViewController.setViewController(
            UINavigationController(rootViewController: projectViewController),
            for: .primary
        )
        splitViewController.setViewController(
            UINavigationController(rootViewController: dictionaryViewController),
            for: .secondary
        )
        splitViewController.preferredDisplayMode = .oneBesideSecondary
        return splitViewController
    }

    func makeSearchViewController() -> UIViewController {
        SearchViewController(store: store)
    }
}