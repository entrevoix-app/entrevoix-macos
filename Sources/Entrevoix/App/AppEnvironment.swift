/// The composition-root result shared by all scenes. It owns references but no UI state.
@MainActor
final class AppEnvironment {
    let appStore: AppStore
    let sceneRoot: AppSceneRoot

    init(appStore: AppStore) {
        self.appStore = appStore
        sceneRoot = AppSceneRoot(appStore: appStore)
    }
}

@MainActor
final class AppSceneRoot {
    let appStore: AppStore

    init(appStore: AppStore) {
        self.appStore = appStore
    }
}
