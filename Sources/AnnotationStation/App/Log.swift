import Foundation
import os

/// Unified-logging wrapper. Messages go to the system log (visible via `log stream`, see
/// Scripts/run.sh) and, when the binary is run from a terminal, to stdout as well.
enum Log {
    static let subsystem = "com.gabe.annotation-station"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[AnnotationStation] \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[AnnotationStation] ERROR: \(message)")
    }
}
