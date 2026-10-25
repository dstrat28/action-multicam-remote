import CarPlay

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayCameraController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        controller?.disconnect()
        let store = MulticamAppServices.shared.store
        store.resumeCameraConnections()
        let controller = CarPlayCameraController(store: store, interfaceController: interfaceController)
        self.controller = controller
        controller.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.disconnect()
        controller = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MulticamAppServices.shared.store.resumeCameraConnections()
        controller?.activate()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        controller?.pause()
    }
}
