import SwiftUI

@main
struct MediaPocketApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().task {
                #if DEBUG
                await SourceRestorationProbe.runIfRequested()
                #endif
            }
        }
    }
}
