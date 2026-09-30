import XCTest
@testable import funcDictionary

@MainActor
final class funcDictionaryTests: XCTestCase {
    func testCompositionRootUsesNavigationControllerForPhone() {
        let root = AppCompositionRoot().makeRootViewController()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(root is UINavigationController)
        } else {
            XCTAssertTrue(root is UISplitViewController)
        }
    }
}
