import Foundation
import SwiftUI

@main
@MainActor
struct TinyCloudMusicIOSApp: App {
    @State private var container = IOSAppContainer(
        isTesting: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    )

    var body: some Scene {
        WindowGroup {
            IOSRootView(container: container)
        }
    }
}
