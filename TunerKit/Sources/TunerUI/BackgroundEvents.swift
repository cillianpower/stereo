import Foundation
import TunerDownloads

/// For the app delegate: forwards iOS's background-session relaunch to the downloads module.
public enum TunerBackgroundEvents {
    public static func handleEventsForBackgroundURLSession(_ identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundSessionEvents.store(completionHandler, for: identifier)
    }
}
