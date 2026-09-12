import Foundation
import SwiftUI
import UIKit

final class TinyCloudMusicIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MusicDownloadTransfer.registerBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
@MainActor
struct TinyCloudMusicIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(TinyCloudMusicIOSAppDelegate.self) private var appDelegate
    @State private var container = IOSAppContainer(
        isTesting: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    )

    var body: some Scene {
        WindowGroup {
            IOSRootView(container: container)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                container.didBecomeActive()
            case .background:
                container.didEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
