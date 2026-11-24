import Foundation
import StereoDownloads

/// For the app delegate: forwards iOS's background-session relaunch to the downloads module.
public enum StereoBackgroundEvents {
    public static func handleEventsForBackgroundURLSession(_ identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundSessionEvents.store(completionHandler, for: identifier)
    }
}
