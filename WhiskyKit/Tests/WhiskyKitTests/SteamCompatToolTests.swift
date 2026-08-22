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

/// A throwaway Steam data directory and a stand-in for WhiskyCmd.
private struct Fixture {
    let steamRoot: URL
    let whiskyCmd: URL
    let tempRoot: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

private func makeFixture(withSteam: Bool = true) throws -> Fixture {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: "compattool_\(UUID().uuidString)")
    let steamRoot = tempRoot.appending(path: "Steam")
    if withSteam {
        try fileManager.createDirectory(
            at: steamRoot.appending(path: "steamapps"), withIntermediateDirectories: true
        )
    } else {
        try fileManager.createDirectory(at: steamRoot, withIntermediateDirectories: true)
    }

    let whiskyCmd = tempRoot.appending(path: "WhiskyCmd")
    try Data("#!/bin/bash\n".utf8).write(to: whiskyCmd)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: whiskyCmd.path(percentEncoded: false)
    )

    return Fixture(steamRoot: steamRoot, whiskyCmd: whiskyCmd, tempRoot: tempRoot)
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

@Suite("SteamCompatTool Install Tests")
struct SteamCompatToolInstallTests {
    @Test("Installing writes both manifests and an executable runner")
    func installsTheTool() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        #expect(SteamCompatTool.isInstalled(steamRoot: fixture.steamRoot) == false)
        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, steamRoot: fixture.steamRoot)
        #expect(SteamCompatTool.isInstalled(steamRoot: fixture.steamRoot))

        let directory = SteamCompatTool.toolDirectory(steamRoot: fixture.steamRoot)
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

        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, steamRoot: fixture.steamRoot)
        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, steamRoot: fixture.steamRoot)

        #expect(SteamCompatTool.isInstalled(steamRoot: fixture.steamRoot))
    }

    @Test("A missing Steam is refused rather than half-installed")
    func refusesWithoutSteam() throws {
        let fixture = try makeFixture(withSteam: false)
        defer { fixture.cleanUp() }

        #expect(throws: SteamCompatToolError.steamNotInstalled) {
            try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, steamRoot: fixture.steamRoot)
        }
    }

    @Test("A runner that is not there is refused rather than written into a manifest")
    func refusesAMissingRunner() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.tempRoot.appending(path: "NotHere")

        #expect(throws: SteamCompatToolError.runnerMissing(missing)) {
            try SteamCompatTool.install(whiskyCmd: missing, steamRoot: fixture.steamRoot)
        }
    }

    @Test("Removing takes only this tool, leaving anything beside it")
    func removeLeavesOtherTools() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.install(whiskyCmd: fixture.whiskyCmd, steamRoot: fixture.steamRoot)
        let neighbour = SteamCompatTool.toolsDirectory(steamRoot: fixture.steamRoot)
            .appending(path: "proton-of-some-kind")
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        try SteamCompatTool.remove(steamRoot: fixture.steamRoot)

        #expect(SteamCompatTool.isInstalled(steamRoot: fixture.steamRoot) == false)
        #expect(FileManager.default.fileExists(atPath: neighbour.path(percentEncoded: false)))
    }

    @Test("Removing something that is not there is not an error")
    func removeIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.remove(steamRoot: fixture.steamRoot)
    }

    /// The client scans what this names and nothing else, which is the whole
    /// reason Whisky has to be what starts Steam.
    @Test("The launch environment points the client at the tools directory")
    func launchEnvironmentNamesTheDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let environment = SteamCompatTool.launchEnvironment(steamRoot: fixture.steamRoot)
        let path = try #require(environment["STEAM_EXTRA_COMPAT_TOOLS_PATHS"])

        #expect(path.hasSuffix("compatibilitytools.d"))
    }
}
