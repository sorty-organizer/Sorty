//
//  DebugLogger.swift
//  Sorty
//
//  Debug logging utility
//

package struct DebugLogger {
    /// Simple log convenience method
    package static func log(_ message: @autoclosure () -> String) {
        LogManager.shared.log(message(), level: .debug, category: "DebugLogger")
    }
}
