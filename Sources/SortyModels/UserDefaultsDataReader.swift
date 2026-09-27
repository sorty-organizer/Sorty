//
//  UserDefaultsDataReader.swift
//  SortyModels
//
//  Thin UserDefaults reader shared by persisted managers. Uses how code is
//  used: managers only ever read through it (writes go through UserDefaults
//  directly), so the wrapper only exposes reads. Lives here so model-layer
//  persistence does not depend on SortyCore.
//

import Foundation

/// UserDefaults supports concurrent reads. This wrapper makes that documented contract explicit
/// to Swift's Sendable checker without allowing background writes through the same reference.
public final class UserDefaultsDataReader: @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(_ userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    public func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: key)
    }

    public func string(forKey key: String) -> String? {
        userDefaults.string(forKey: key)
    }

    public func stringArray(forKey key: String) -> [String]? {
        userDefaults.stringArray(forKey: key)
    }
}
