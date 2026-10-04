import XCTest
@testable import SortyLib
@testable import SortyCore

final class SortyUninstallerTests: XCTestCase {
    private var temporaryHomes: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryHomes {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryHomes.removeAll()
        try super.tearDownWithError()
    }

    func testCleanupPathCandidatesIncludeKnownSortyStateLocations() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let paths = SortyUninstaller.cleanupPathCandidates(homeDirectory: home).map(\.path)

        XCTAssertTrue(paths.contains("/Users/test/Library/Application Support/Sorty"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Application Support/com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Application Support/com.sorty.app.ShipIt"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Caches/Sorty"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Caches/com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Caches/com.sorty.app.ShipIt"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Logs/Sorty"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Containers/com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Containers/com.sorty.app.SortyFinderSync"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Containers/com.sorty.toolbar-helper"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Group Containers/group.com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Application Scripts/group.com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Preferences/group.com.sorty.app.plist"))
        XCTAssertTrue(paths.contains("/Users/test/Library/HTTPStorages/com.sorty.app"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Saved Application State/com.sorty.app.savedState"))
        XCTAssertTrue(paths.contains("/Users/test/Library/LaunchAgents/com.sorty.app.background-agent.plist"))
        XCTAssertTrue(paths.contains("/Users/test/Library/LaunchAgents/com.sorty.app.plist"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Preferences/com.sorty.app.plist"))
        XCTAssertTrue(paths.contains("/Users/test/Library/Preferences/com.sorty.toolbar-helper.plist"))
    }

    func testDefaultsRequestKeyIsStableForDocumentation() {
        XCTAssertEqual(SortyUninstaller.requestDefaultsKey, "runUninstallerOnNextLaunch")
    }

    func testSkillHandoffRejectsCleanupLocationsIncludingSymlinks() throws {
        let fileManager = FileManager.default
        let safeDirectory = makeTemporaryHome(fileManager: fileManager)
        let safeSkill = safeDirectory.appendingPathComponent("sorty", isDirectory: true)
        try fileManager.createDirectory(at: safeSkill, withIntermediateDirectories: true)

        let temporaryCleanupDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("sorty-skill-handoff-\(UUID().uuidString)", isDirectory: true)
        temporaryHomes.append(temporaryCleanupDirectory)
        let unsafeSkill = temporaryCleanupDirectory.appendingPathComponent("sorty", isDirectory: true)
        try fileManager.createDirectory(at: unsafeSkill, withIntermediateDirectories: true)

        let cleanupAlias = safeDirectory.appendingPathComponent("cleanup-alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: cleanupAlias, withDestinationURL: temporaryCleanupDirectory)

        let cases: [(URL, Bool)] = [
            (safeSkill, true),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills/sorty"), true),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sorty/skills/sorty"), false),
            (unsafeSkill, false),
            (cleanupAlias.appendingPathComponent("sorty"), false),
            (Bundle.main.bundleURL, false)
        ]
        for (location, canPreserve) in cases {
            XCTAssertEqual(SortyUninstaller.canPreserveSkill(at: location), canPreserve, location.path)
        }
    }

    func testFilesystemCleanupRemovesSortyStateUnderHomeDirectory() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("SortyUninstallerTests-\(UUID().uuidString)", isDirectory: true)
        temporaryHomes.append(home)

        let pathsToCreate = [
            "Library/Application Support/Sorty",
            "Library/Application Support/com.sorty.app",
            "Library/Caches/Sorty",
            "Library/Caches/com.sorty.app",
            "Library/Logs/Sorty",
            "Library/Containers/com.sorty.app",
            "Library/Containers/com.sorty.app.SortyFinderSync",
            "Library/Group Containers/group.com.sorty.app",
            "Library/Services/Organize with Sorty.workflow",
            "Library/LaunchAgents",
            "Library/Preferences",
        ]

        for relativePath in pathsToCreate {
            try fileManager.createDirectory(
                at: home.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try createApplicationBundle(
            at: home.appendingPathComponent("Library/Services/Organize with Sorty.workflow"),
            bundleIdentifier: "com.sorty.workflow.organize",
            fileManager: fileManager
        )

        let filesToCreate = [
            "Library/LaunchAgents/com.sorty.app.background-agent.plist",
            "Library/LaunchAgents/com.sorty.app.plist",
            "Library/Preferences/com.sorty.app.plist",
            "Library/Group Containers/group.com.sorty.app/preferences.json",
            "Library/Group Containers/group.com.sorty.app/.com.apple.containermanagerd.metadata.plist",
        ]

        for relativePath in filesToCreate {
            fileManager.createFile(
                atPath: home.appendingPathComponent(relativePath).path,
                contents: Data("sorty".utf8)
            )
        }

        let result = SortyUninstaller.removeFilesystemState(
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent(
            "Library/Group Containers/group.com.sorty.app/.com.apple.containermanagerd.metadata.plist"
        ).path))
        XCTAssertFalse(fileManager.fileExists(atPath: home.appendingPathComponent(
            "Library/Group Containers/group.com.sorty.app/preferences.json"
        ).path))
        XCTAssertTrue(result.removed.contains(home.appendingPathComponent("Library/Application Support/Sorty").path))
        XCTAssertTrue(result.removed.contains(home.appendingPathComponent("Library/Preferences/com.sorty.app.plist").path))
        XCTAssertTrue(result.removed.contains(home.appendingPathComponent("Library/Services/Organize with Sorty.workflow").path))

        for path in result.removed {
            XCTAssertFalse(fileManager.fileExists(atPath: path), "Expected removed path to be gone: \(path)")
        }
    }

    func testContainerCleanupRetainsProtectedDirectoriesButRemovesSavedData() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager).resolvingSymlinksInPath()
        let directories = [
            home.appendingPathComponent("Library/Containers/com.sorty.app.SortyFinderSync/Data"),
            home.appendingPathComponent("Library/Group Containers/group.com.sorty.app/Widget"),
        ]
        let externalDirectory = home.appendingPathComponent("Documents")
        try fileManager.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalFile = externalDirectory.appendingPathComponent("keep.txt")
        try Data("user document".utf8).write(to: externalFile)

        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("saved data".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
            try fileManager.createSymbolicLink(
                at: directory.appendingPathComponent("Documents"),
                withDestinationURL: externalDirectory
            )
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone deny delete", directory.path]
            try chmod.run()
            chmod.waitUntilExit()
            XCTAssertEqual(chmod.terminationStatus, 0)
        }
        defer {
            for directory in directories {
                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["-N", directory.path]
                try? chmod.run()
                chmod.waitUntilExit()
            }
        }

        let result = SortyUninstaller.removeFilesystemState(homeDirectory: home, fileManager: fileManager)

        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        for directory in directories {
            XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
            XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: externalFile), Data("user document".utf8))

        // An undeletable saved file must still block uninstall, while other
        // files in the same container are cleaned up independently.
        let protectedFile = directories[0].appendingPathComponent("credentials.json")
        let removableFile = directories[0].appendingPathComponent("cache.json")
        try Data("protected data".utf8).write(to: protectedFile)
        try Data("cache".utf8).write(to: removableFile)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone deny delete", protectedFile.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        defer {
            let restore = Process()
            restore.executableURL = URL(fileURLWithPath: "/bin/chmod")
            restore.arguments = ["-N", protectedFile.path]
            try? restore.run()
            restore.waitUntilExit()
        }

        let blockedResult = SortyUninstaller.removeFilesystemState(homeDirectory: home, fileManager: fileManager)
        XCTAssertEqual(
            Set(blockedResult.failed.keys.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }),
            [protectedFile.resolvingSymlinksInPath().path]
        )
        XCTAssertTrue(fileManager.fileExists(atPath: protectedFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: removableFile.path))
    }

    func testCleanupPathCandidatesIncludeMatchingByHostAndDiagnosticFiles() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost", isDirectory: true)
        let diagnostics = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try fileManager.createDirectory(at: byHost, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnostics, withIntermediateDirectories: true)

        let matchingPreference = byHost.appendingPathComponent("com.sorty.app.1234.plist")
        let unrelatedPreference = byHost.appendingPathComponent("com.example.app.1234.plist")
        let matchingDiagnostic = diagnostics.appendingPathComponent("Sorty_2026-07-10.ips")
        fileManager.createFile(atPath: matchingPreference.path, contents: Data())
        fileManager.createFile(atPath: unrelatedPreference.path, contents: Data())
        fileManager.createFile(atPath: matchingDiagnostic.path, contents: Data())

        let paths = SortyUninstaller.cleanupPathCandidates(homeDirectory: home).map(\.path)

        XCTAssertTrue(paths.contains(matchingPreference.path))
        XCTAssertTrue(paths.contains(matchingDiagnostic.path))
        XCTAssertFalse(paths.contains(unrelatedPreference.path))
    }

    func testCleanupPathCandidatesOnlyIncludeOwnedQuickActionWorkflows() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let ownedWorkflow = home.appendingPathComponent(
            "Library/Services/Organize with Sorty.workflow",
            isDirectory: true
        )
        let unrelatedWorkflow = home.appendingPathComponent(
            "Library/Services/Watch with Sorty.workflow",
            isDirectory: true
        )
        try createApplicationBundle(
            at: ownedWorkflow,
            bundleIdentifier: "com.sorty.workflow.organize",
            fileManager: fileManager
        )
        try createApplicationBundle(
            at: unrelatedWorkflow,
            bundleIdentifier: "com.example.unrelated",
            fileManager: fileManager
        )

        let paths = SortyUninstaller.cleanupPathCandidates(homeDirectory: home).map(\.path)

        XCTAssertTrue(paths.contains(ownedWorkflow.path))
        XCTAssertFalse(paths.contains(unrelatedWorkflow.path))
    }

    func testTemporaryItemCandidatesOnlyIncludeSortyOwnedPrefixes() throws {
        let fileManager = FileManager.default
        let directory = makeTemporaryHome(fileManager: fileManager)
        let ownedItems = [
            directory.appendingPathComponent("sorty-codex-request.txt"),
            directory.appendingPathComponent("Sorty_Logs_2026.zip"),
            directory.appendingPathComponent("SortyNotificationIcon-123.png"),
        ]
        let unrelatedItem = directory.appendingPathComponent("sorting-notes.txt")
        for item in ownedItems + [unrelatedItem] {
            fileManager.createFile(atPath: item.path, contents: Data())
        }

        let candidates = SortyUninstaller.temporaryItemCandidates(
            temporaryDirectory: directory,
            fileManager: fileManager
        )

        XCTAssertEqual(
            Set(candidates.map { $0.resolvingSymlinksInPath().path }),
            Set(ownedItems.map { $0.resolvingSymlinksInPath().path })
        )
    }

    func testRemoveFilesystemStateDeletesDanglingOwnedSymlink() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let danglingSymlink = home.appendingPathComponent("Library/Caches/Sorty", isDirectory: true)
        try fileManager.createDirectory(at: danglingSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: danglingSymlink,
            withDestinationURL: home.appendingPathComponent("missing-target")
        )

        let result = SortyUninstaller.removeFilesystemState(
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertTrue(result.removed.contains(danglingSymlink.path))
        XCTAssertFalse(fileManager.fileExists(atPath: danglingSymlink.path))
        XCTAssertFalse((try? danglingSymlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    func testApplicationBundleCandidatesRequireSortyBundleIdentity() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let systemApplications = home.appendingPathComponent("System Applications", isDirectory: true)
        let currentApplication = home.appendingPathComponent("Downloads/Sorty's App.app", isDirectory: true)
        let stagedApplication = home.appendingPathComponent("Applications/Sorty's App.app", isDirectory: true)
        let unrecordedApplication = systemApplications.appendingPathComponent("Sorty's App.app", isDirectory: true)
        for application in [currentApplication, stagedApplication, unrecordedApplication] {
            try createApplicationBundle(
                at: application,
                bundleIdentifier: "com.sorty.app",
                fileManager: fileManager
            )
        }
        let candidates = SortyUninstaller.applicationBundleCandidates(
            currentApplicationURL: currentApplication,
            stagedApplicationURL: stagedApplication,
            fileManager: fileManager
        )

        XCTAssertEqual(
            Set(candidates.map(\.path)),
            Set([currentApplication, stagedApplication].map(\.path))
        )
        XCTAssertFalse(candidates.map(\.path).contains(unrecordedApplication.path))
    }

    func testApplicationBundleCandidatesRejectUnownedCurrentApplication() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let currentApplication = home.appendingPathComponent("Downloads/Sorty.app", isDirectory: true)
        try createApplicationBundle(
            at: currentApplication,
            bundleIdentifier: "com.example.unrelated",
            fileManager: fileManager
        )

        let candidates = SortyUninstaller.applicationBundleCandidates(
            currentApplicationURL: currentApplication,
            stagedApplicationURL: nil,
            fileManager: fileManager
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testApplicationBundleCandidatesRejectUnownedRecordedStagingPath() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let currentApplication = home.appendingPathComponent("Downloads/Sorty.app", isDirectory: true)
        let unrelatedApplication = home.appendingPathComponent("Applications/Sorty.app", isDirectory: true)
        try createApplicationBundle(
            at: currentApplication,
            bundleIdentifier: "com.sorty.app",
            fileManager: fileManager
        )
        try createApplicationBundle(
            at: unrelatedApplication,
            bundleIdentifier: "com.example.unrelated",
            fileManager: fileManager
        )

        let candidates = SortyUninstaller.applicationBundleCandidates(
            currentApplicationURL: currentApplication,
            stagedApplicationURL: unrelatedApplication,
            fileManager: fileManager
        )

        XCTAssertEqual(candidates.map(\.path), [currentApplication.path])
    }

    func testExternalRemovalCandidatesRequireExactOwnedAppMovedToTrash() throws {
        let fileManager = FileManager.default
        let home = makeTemporaryHome(fileManager: fileManager)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let trashedSorty = trash.appendingPathComponent("Sorty.app", isDirectory: true)
        let otherApp = trash.appendingPathComponent("Other.app", isDirectory: true)
        let movedElsewhere = home.appendingPathComponent("Desktop/Sorty.app", isDirectory: true)

        try createApplicationBundle(
            at: trashedSorty,
            bundleIdentifier: "com.sorty.app",
            fileManager: fileManager
        )
        try createApplicationBundle(
            at: otherApp,
            bundleIdentifier: "com.example.other",
            fileManager: fileManager
        )
        try createApplicationBundle(
            at: movedElsewhere,
            bundleIdentifier: "com.sorty.app",
            fileManager: fileManager
        )

        let movedElsewhereCandidates = SortyUninstaller.externalRemovalApplicationBundleCandidates(
            movedApplicationURL: movedElsewhere,
            homeDirectory: home,
            fileManager: fileManager
        )
        let movedToTrashCandidates = SortyUninstaller.externalRemovalApplicationBundleCandidates(
            movedApplicationURL: trashedSorty,
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertTrue(movedElsewhereCandidates.isEmpty)
        XCTAssertEqual(movedToTrashCandidates.map(\.path), [trashedSorty.path])
    }

    func testPostTerminationRemovalPassesPathsAsShellArguments() {
        let target = URL(fileURLWithPath: "/tmp/Sorty's $pecial App.app", isDirectory: true)
        let ready = URL(fileURLWithPath: "/tmp/sorty-uninstall-ready-test")

        let arguments = SortyUninstaller.postTerminationRemovalArguments(
            processIdentifier: 42,
            readyURL: ready,
            targetURLs: [target]
        )

        XCTAssertEqual(arguments[2], "sorty-uninstall-remove")
        XCTAssertEqual(arguments[3], "42")
        XCTAssertEqual(arguments[4], ready.path)
        XCTAssertEqual(arguments[5], target.path)
        XCTAssertTrue(arguments[1].contains("for TARGET in \"$@\""))
        XCTAssertTrue(arguments[1].contains("WAIT_COUNT"))
        XCTAssertTrue(arguments[1].contains("EXPECTED_START"))
        XCTAssertTrue(arguments[1].contains("ATTEMPT\" -lt 150"))
        XCTAssertFalse(arguments[1].contains(target.path))
    }

    func testPostTerminationRemovalRejectsUnsafeRootTargets() {
        let safeTarget = URL(fileURLWithPath: "/tmp/Sorty.app", isDirectory: true)

        let arguments = SortyUninstaller.postTerminationRemovalArguments(
            processIdentifier: 42,
            readyURL: URL(fileURLWithPath: "/tmp/sorty-uninstall-ready-test"),
            targetURLs: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Applications"), safeTarget]
        )

        XCTAssertEqual(Array(arguments.dropFirst(5)), [safeTarget.path])
    }

    func testPostTerminationRemovalDeletesTargetWithShellMetacharacters() throws {
        let fileManager = FileManager.default
        let directory = makeTemporaryHome(fileManager: fileManager)
        let target = directory.appendingPathComponent("Sorty's $pecial App.app", isDirectory: true)
        let ready = directory.appendingPathComponent("sorty-uninstall-ready-test")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("sorty".utf8).write(to: target.appendingPathComponent("payload"))
        try Data("ready".utf8).write(to: ready)

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.2"]
        try sleeper.run()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = SortyUninstaller.postTerminationRemovalArguments(
            processIdentifier: sleeper.processIdentifier,
            readyURL: ready,
            targetURLs: [target]
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        // Reap the child before waiting for the helper polling its PID.
        // An exited but unreaped child can still satisfy `kill -0`.
        sleeper.waitUntilExit()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Successful removal must not exhaust the retry budget")
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ready.path))
    }

    private func makeTemporaryHome(fileManager: FileManager) -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("SortyUninstallerTests-\(UUID().uuidString)", isDirectory: true)
        temporaryHomes.append(home)
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func createApplicationBundle(
        at applicationURL: URL,
        bundleIdentifier: String,
        fileManager: FileManager
    ) throws {
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
