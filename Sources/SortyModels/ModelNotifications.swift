//
//  ModelNotifications.swift
//  SortyModels
//
//  Cross-cutting notification names observed by model managers.
//  Lives here so managers can observe without depending on SortyCore.
//

import Foundation

extension Notification.Name {
    public static let organizationDidStart = Notification.Name("OrganizationDidStart")
    public static let organizationDidFinish = Notification.Name("OrganizationDidFinish")
    public static let organizationDidRevert = Notification.Name("OrganizationDidRevert")
    public static let forceQuitSorty = Notification.Name("ForceQuitSorty")

    /// Triggered when the user requests to delete all usage data
    public static let clearAllUsageData = Notification.Name("clearAllUsageData")
}
