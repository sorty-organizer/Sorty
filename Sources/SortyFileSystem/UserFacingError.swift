//
//  UserFacingError.swift
//  Sorty
//
//  Plain-language error text for alerts, banners, and status labels.
//

import Foundation

extension Error {
    /// Message safe to show in UI. Use this instead of `localizedDescription`
    /// anywhere a person reads the text; keep `localizedDescription` for logs.
    /// Maps common URL and file errors to plain sentences and strips Foundation's
    /// "(NSURLErrorDomain error -1001.)" style suffixes.
    public var userFacingMessage: String {
        if let localized = self as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty,
           !UserFacingErrorText.isGeneric(description) {
            return UserFacingErrorText.stripCodeSuffix(description)
        }

        let nsError = self as NSError
        if let mapped = UserFacingErrorText.message(domain: nsError.domain, code: nsError.code) {
            return mapped
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let mapped = UserFacingErrorText.message(domain: underlying.domain, code: underlying.code) {
            return mapped
        }

        let cleaned = UserFacingErrorText.stripCodeSuffix(nsError.localizedDescription)
        if cleaned.isEmpty || UserFacingErrorText.isGeneric(cleaned) {
            return "Something went wrong. Try again."
        }
        return cleaned
    }
}

enum UserFacingErrorText {
    static func message(domain: String, code: Int) -> String? {
        switch domain {
        case NSURLErrorDomain:
            return urlMessage(code)
        case NSCocoaErrorDomain:
            return cocoaMessage(code)
        case NSPOSIXErrorDomain:
            return posixMessage(code)
        default:
            return nil
        }
    }

    private static func urlMessage(_ code: Int) -> String? {
        switch code {
        case NSURLErrorTimedOut:
            return "The server took too long to respond. Make sure it's running and reachable."
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "Couldn't reach the server. Make sure it's running and the address is correct."
        case NSURLErrorNotConnectedToInternet:
            return "You're offline. Check your internet connection."
        case NSURLErrorNetworkConnectionLost:
            return "The connection dropped. Try again."
        case NSURLErrorDNSLookupFailed:
            return "Couldn't look up the server address. Check the URL and your connection."
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return "The server address isn't valid. Check the URL in Settings."
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            return "Couldn't make a secure connection to the server."
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorZeroByteResource:
            return "The server sent a response Sorty couldn't read."
        case NSURLErrorUserAuthenticationRequired:
            return "The server rejected the credentials. Check your API key."
        case NSURLErrorCancelled:
            return "The request was cancelled."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "This server requires HTTPS."
        case NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return "Network access isn't available right now."
        default:
            return nil
        }
    }

    private static func cocoaMessage(_ code: Int) -> String? {
        switch code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return "The file or folder no longer exists."
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "Sorty doesn't have permission to access this location."
        case NSFileWriteFileExistsError:
            return "An item with that name already exists."
        case NSFileWriteOutOfSpaceError:
            return "There isn't enough disk space."
        case NSFileWriteVolumeReadOnlyError:
            return "This disk is read-only."
        case NSFileLockingError:
            return "The file is in use by another app."
        case NSFileReadCorruptFileError:
            return "The file is damaged or in an unexpected format."
        case NSFeatureUnsupportedError:
            // Most often trashItem on a network share or external disk without a Trash.
            return "This disk doesn't support that action, such as moving items to the Trash."
        case NSUserCancelledError:
            return "Cancelled."
        default:
            return nil
        }
    }

    private static func posixMessage(_ code: Int) -> String? {
        switch Int32(code) {
        case ENOENT: return "The file or folder no longer exists."
        case EACCES, EPERM: return "Sorty doesn't have permission to access this location."
        case ENOSPC: return "There isn't enough disk space."
        case EROFS: return "This disk is read-only."
        case EEXIST: return "An item with that name already exists."
        case ECONNREFUSED: return "Couldn't reach the server. Make sure it's running and the address is correct."
        case ETIMEDOUT: return "The server took too long to respond. Make sure it's running and reachable."
        default: return nil
        }
    }

    /// Removes trailing "(SomeDomain error 123.)" from Foundation descriptions.
    static func stripCodeSuffix(_ text: String) -> String {
        let pattern = #"\s*\([A-Za-z0-9_.]+ error -?\d+\.?\)\s*$"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isGeneric(_ text: String) -> Bool {
        let normalized = stripCodeSuffix(text)
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
        return normalized == "the operation couldn't be completed."
            || normalized == "the operation couldn't be completed"
    }
}
