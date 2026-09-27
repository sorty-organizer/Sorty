//
//  DebugLogger.swift
//  Sorty
//
//  Debug logging utility
//

import Foundation

package struct DebugLogger {
    /// Simple log convenience method
    package static func log(_ message: @autoclosure () -> String) {
        LogManager.shared.log(message(), level: .debug, category: "DebugLogger")
    }
    
    package static func log(sessionId: String = "debug-session", runId: String = "run1", hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
        let context: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "originalData": data
        ]
        
        LogManager.shared.log(message, level: .debug, category: "DebugLogger", data: context)
    }
}
