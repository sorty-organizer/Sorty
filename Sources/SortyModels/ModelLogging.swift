//
//  ModelLogging.swift
//  SortyModels
//
//  Logging for the models layer. Uses how code is used: model types emit
//  low-volume diagnostics (bookmark failures, store fallbacks) that must not
//  drag the analytics/logging stack into this leaf target, so they sink to
//  unified logging instead of LogManager/DebugLogger up in SortyCore.
//

import Foundation
import os

/// Severity for model-layer diagnostics. Mirrors the levels these call sites
/// used on LogManager so the mechanical swap preserves intent.
public enum ModelLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case fault
}

/// Minimal logger for SortyModels. Debug/info stay out of the persisted app
/// log files (as before, when LogManager sampled them out); warnings and
/// above remain visible in Console during diagnosis.
public enum ModelLog {
    private static let logger = Logger(subsystem: "com.sorty.app", category: "models")

    public static func log(
        _ message: @autoclosure () -> String,
        level: ModelLogLevel = .info,
        category _: String = "General",
        data: [String: String] = [:]
    ) {
        let resolved = message()
        let rendered: String
        if data.isEmpty {
            rendered = resolved
        } else {
            let context = data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            rendered = "\(resolved) [\(context)]"
        }
        switch level {
        case .debug:
            logger.debug("\(rendered, privacy: .public)")
        case .info:
            logger.info("\(rendered, privacy: .public)")
        case .warning, .error:
            logger.error("\(rendered, privacy: .public)")
        case .fault:
            logger.fault("\(rendered, privacy: .public)")
        }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        log(message(), level: .debug)
    }
}
