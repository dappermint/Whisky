//
//  SteamCompatToolTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Testing
@testable import WhiskyKit

/// A throwaway stand-in for the directory the client scans, and for WhiskyCmd.
private struct Fixture {
    let toolsRoot: URL
    let whiskyCmd: URL
    let tempRoot: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

private func makeFixture(writable: Bool = true) throws -> Fixture {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: "compattool_\(UUID().uuidString)")
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    let toolsRoot = tempRoot.appending(path: "compatibilitytools.d")
    if writable {
        try fileManager.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
    } else {
        // A parent nobody can write to, which is what /usr/local looks like
        // until an administrator says otherwise.
        let locked = tempRoot.appending(path: "locked")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false)
        )
        return try Fixture(
            toolsRoot: locked.appending(path: "compatibilitytools.d"),
            whiskyCmd: makeCmd(in: tempRoot), tempRoot: tempRoot
        )
    }

    return try Fixture(toolsRoot: toolsRoot, whiskyCmd: makeCmd(in: tempRoot), tempRoot: tempRoot)
}

private func makeCmd(in directory: URL) throws -> URL {
    let whiskyCmd = directory.appending(path: "WhiskyCmd")
    try Data("#!/bin/bash\n".utf8).write(to: whiskyCmd)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: whiskyCmd.path(percentEncoded: false)
    )
    return whiskyCmd
}

@Suite("SteamCompatTool Manifest Tests")
struct SteamCompatToolManifestTests {
    /// Measured against three tools installed side by side that differed in
    /// nothing else: the client took `macos` and rejected both `osx` and the
    /// key being absent.
    @Test("The target platform is spelled the one way the client accepts")
    func targetsMacOSExactly() {
        let manifest = SteamCompatTool.compatibilityToolManifest()

        #expect(manifest.contains("\"to_oslist\"\t\t\"macos\""))
        #expect(!manifest.contains("osx"))
        #expect(manifest.contains("\"from_oslist\"\t\t\"windows\""))
    }

    @Test("The tool manifest is parseable by the parser Steam files use")
    func manifestsRoundTrip() throws {
        let tool = try VDFParser.parse(SteamCompatTool.toolManifest())
        let compatibility = try VDFParser.parse(SteamCompatTool.compatibilityToolManifest())

        let manifest = try #require(tool["manifest"]?.objectValue)
        #expect(manifest["version"]?.stringValue == "2")
        #expect(manifest["compatmanager_layer_name"]?.stringValue == "whisky")

        let tools = try #require(compatibility["compatibilitytools"]?.objectValue?["compat_tools"]?.objectValue)
        #expect(tools["whisky"] != nil)
    }

    /// Steam waits for the process it spawned and calls that the game, so the
    /// verb has to be the one that keeps the runner alive for the session.
    @Test("The command line uses the verb that waits for the game")
    func waitsForTheGame() {
        #expect(SteamCompatTool.toolManifest().contains("waitforexitandrun"))
    }

    @Test("The runner forwards the App ID, which is what Whisky resolves from")
    func runnerForwardsTheAppId() {
        let runner = SteamCompatTool.runner(whiskyCmd: URL(filePath: "/tmp/WhiskyCmd"))

        #expect(runner.contains("STEAM_COMPAT_APP_ID"))
        #expect(runner.contains("steam-compat-run"))
        #expect(runner.contains("exec "))
    }

    @Test("Path translation verbs answer without launching anything")
    func answersPathVerbsDirectly() {
        let runner = SteamCompatTool.runner(whiskyCmd: URL(filePath: "/tmp/WhiskyCmd"))

        #expect(runner.contains("getcompatpath|getnativepath"))
    }

    @Test("A path with a quote in it cannot break out of the runner")
    func quotesThePath() {
        let runner = SteamCompatTool.runner(whiskyCmd: URL(filePath: "/tmp/it's here/WhiskyCmd"))

        #expect(runner.contains(#"'/tmp/it'\''s here/WhiskyCmd'"#))
    }
}

@Suite("SteamCompatTool Environment Tests")
struct SteamCompatToolEnvironmentTests {
    /// A game reaches the Steam API because Steam described the session in the
    /// environment before running the tool. Dropping any of it leaves the game
    /// unable to find the client that launched it.
    @Test("Everything Steam named is kept")
    func keepsWhatSteamNamed() {
        let kept = SteamCompatTool.passthroughEnvironment(from: [
            "STEAM_COMPAT_APP_ID": "553850",
            "STEAM_COMPAT_DATA_PATH": "/tmp/compatdata/553850",
            "SteamAppId": "553850",
            "SteamGameId": "553850",
            "SteamOverlayGameId": "553850",
            "PATH": "/usr/bin",
            "HOME": "/Users/someone"
        ])

        #expect(kept.count == 5)
        #expect(kept["SteamAppId"] == "553850")
        #expect(kept["STEAM_COMPAT_DATA_PATH"] == "/tmp/compatdata/553850")
    }

    @Test("Nothing else rides along")
    func dropsEverythingElse() {
        let kept = SteamCompatTool.passthroughEnvironment(from: [
            "PATH": "/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"
        ])

        #expect(kept.isEmpty)
    }

    /// Valve spells these both ways in the same environment, so a
    /// case-sensitive filter would keep half of them.
    @Test("Both spellings survive")
    func matchesEitherCase() {
        let kept = SteamCompatTool.passthroughEnvironment(from: [
            "SteamAppId": "1", "STEAM_COMPAT_APP_ID": "1", "steam_lowercase": "1"
        ])

        #expect(kept.count == 3)
    }
}

@Suite("SteamCompatTool Install Tests")
struct SteamCompatToolInstallTests {
    @Test("Installing writes both manifests and an executable runner")
    func installsTheTool() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        #expect(SteamCompatTool.isInstalled(at: fixture.toolsRoot) == false)
        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, at: fixture.toolsRoot)
        #expect(SteamCompatTool.isInstalled(at: fixture.toolsRoot))

        let directory = SteamCompatTool.toolDirectory(at: fixture.toolsRoot)
        for file in ["compatibilitytool.vdf", "toolmanifest.vdf", "whisky-run"] {
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appending(path: file).path(percentEncoded: false)
                ),
                "\(file) is missing"
            )
        }
    }

    @Test("Installing twice leaves one working tool")
    func installIsRepeatable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, at: fixture.toolsRoot)
        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, at: fixture.toolsRoot)

        #expect(SteamCompatTool.isInstalled(at: fixture.toolsRoot))
    }

    /// The directory lives under /usr/local, which is root-owned until somebody
    /// changes that, so this is the common first failure rather than an edge.
    @Test("A directory nobody can write to is refused, with the command to fix it")
    func refusesAnUnwritableDirectory() throws {
        let fixture = try makeFixture(writable: false)
        defer { fixture.cleanUp() }

        #expect(SteamCompatTool.isWritable(fixture.toolsRoot) == false)
        #expect(throws: SteamCompatToolError.directoryNotWritable(fixture.toolsRoot)) {
            try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, at: fixture.toolsRoot)
        }
        #expect(SteamCompatTool.prepareCommand(for: fixture.toolsRoot).contains("sudo"))
    }

    /// Not `<steam>/compatibilitytools.d`, which is the obvious place and is
    /// the one the macOS client never reads.
    @Test("The default location is the one the client scans on its own")
    func defaultsToTheScannedDirectory() {
        #expect(
            SteamCompatTool.sharedToolsDirectory.path()
                == "/usr/local/share/steam/compatibilitytools.d"
        )
    }

    @Test("A runner that is not there is refused rather than written into a manifest")
    func refusesAMissingRunner() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.tempRoot.appending(path: "NotHere")

        #expect(throws: SteamCompatToolError.runnerMissing(missing)) {
            try SteamCompatTool.install(whiskyCmd: missing, at: fixture.toolsRoot)
        }
    }

    @Test("Removing takes only this tool, leaving anything beside it")
    func removeLeavesOtherTools() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, at: fixture.toolsRoot)
        let neighbour = SteamCompatTool.toolsDirectory(at: fixture.toolsRoot)
            .appending(path: "proton-of-some-kind")
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        try SteamCompatTool.remove(at: fixture.toolsRoot)

        #expect(SteamCompatTool.isInstalled(at: fixture.toolsRoot) == false)
        #expect(FileManager.default.fileExists(atPath: neighbour.path(percentEncoded: false)))
    }

    @Test("Removing something that is not there is not an error")
    func removeIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.remove(at: fixture.toolsRoot)
    }
}
