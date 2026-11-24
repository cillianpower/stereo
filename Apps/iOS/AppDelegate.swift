import StereoUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app when background downloads finish while it's suspended.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        StereoBackgroundEvents.handleEventsForBackgroundURLSession(identifier, completionHandler: completionHandler)
    }
}
