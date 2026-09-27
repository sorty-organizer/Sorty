//
//  NamingPreset.swift
//  Sorty
//
//  Naming Preset Model
//

import Foundation

public struct NamingPreset: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var instructions: String
    public var dateCreated: Date
    public let isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, instructions: String, dateCreated: Date = Date(), isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.dateCreated = dateCreated
        self.isBuiltIn = isBuiltIn
    }
}
