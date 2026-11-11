import UIKit
import CloudKit

/// Remote notifications for CloudKit subscriptions (friend finished their day, someone joined).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// The completion-handler form, called back on the main thread and always within the time
    /// iOS allows (about 30 s): a refresh stuck on a bad connection must not get the app killed.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        var finished = false
        let finish: (UIBackgroundFetchResult) -> Void = { result in
            guard !finished else { return }
            finished = true
            completionHandler(result)
        }
        Task {
            await GroupStore.shared.refresh()
            finish(.newData)
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            finish(.failed)
        }
    }
}
