import os

enum Logger {
    private static let log = os.Logger(subsystem: "local.tilebar", category: "core")

    static func log(_ msg: String) {
        log.log("\(msg, privacy: .public)")
    }
}
