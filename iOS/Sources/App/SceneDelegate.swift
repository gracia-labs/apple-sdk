//
//  Owns the window under the UIScene lifecycle: one navigation controller around the viewer.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        let nav = UINavigationController(rootViewController: ViewerViewController())
        // A translucent dark bar over the Metal view; the splats supply their own black background.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.tintColor = .white
        nav.overrideUserInterfaceStyle = .dark

        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
    }
}
