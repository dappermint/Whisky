//
//  SteamAppManifestTests.swift
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

private func acf(
    appId: Int, name: String, installDir: String, stateFlags: Int, lastPlayed: Int = 1_760_000_000
) -> String {
    """
    "AppState"
    {
        "appid"        "\(appId)"
        "name"        "\(name)"
        "installdir"        "\(installDir)"
        "StateFlags"        "\(stateFlags)"
        "buildid"        "1785187029"
        "SizeOnDisk"        "541968407"
        "LastPlayed"        "\(lastPlayed)"
    }
    """
}

@Suite("SteamAppManifest Tests")
struct SteamAppManifestTests {
    @Test("Parses a full manifest file")
    func parsesFullManifest() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "appmanifest_4576510.acf")
        try Data(acf(
            appId: 4_576_510, name: "Casualties: Unknown Demo",
            installDir: "Casualties Unknown Demo", stateFlags: 4
        ).utf8).write(to: url)

        let manifest = try #require(SteamAppManifest(contentsOf: url))

        #expect(manifest.appId == 4_576_510)
        #expect(manifest.name == "Casualties: Unknown Demo")
        #expect(manifest.installDir == "Casualties Unknown Demo")
        #expect(manifest.stateFlags == 4)
        #expect(manifest.buildID == 1_785_187_029)
        #expect(manifest.sizeOnDisk == 541_968_407)
        #expect(manifest.isFullyInstalled)
        #expect(manifest.lastPlayed == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test("Steam's own last-played time is what the library shows for a game")
    func readsLastPlayed() throws {
        // Whisky records its own launches, but only from the build that started
        // doing so. Steam has been writing this all along, and writes it for
        // sessions started inside the client too.
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "appmanifest_1245620.acf")
        try Data(acf(
            appId: 1_245_620, name: "ELDEN RING", installDir: "ELDEN RING",
            stateFlags: 4, lastPlayed: 1_755_000_000
        ).utf8).write(to: url)

        let manifest = try #require(SteamAppManifest(contentsOf: url))

        #expect(manifest.lastPlayed == Date(timeIntervalSince1970: 1_755_000_000))
    }

    @Test("A game that has never been played has no time rather than 1970")
    func neverPlayedIsNil() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "appmanifest_440.acf")
        try Data(acf(
            appId: 440, name: "Team Fortress 2", installDir: "Team Fortress 2",
            stateFlags: 4, lastPlayed: 0
        ).utf8).write(to: url)

        let manifest = try #require(SteamAppManifest(contentsOf: url))

        #expect(manifest.lastPlayed == nil)
    }

    @Test("Downloading state is not fully installed")
    func downloadingNotInstalled() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "appmanifest_999.acf")
        try Data(acf(appId: 999, name: "Downloading", installDir: "dl", stateFlags: 2).utf8)
            .write(to: url)

        let manifest = try #require(SteamAppManifest(contentsOf: url))
        #expect(!manifest.isFullyInstalled)
    }

    @Test("Returns nil for missing required fields or garbage")
    func returnsNilForBadInput() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let noName = tempDir.appending(path: "noname.acf")
        try Data("\"AppState\" { \"appid\" \"1\" \"installdir\" \"x\" }".utf8).write(to: noName)
        #expect(SteamAppManifest(contentsOf: noName) == nil)

        let garbage = tempDir.appending(path: "garbage.acf")
        try Data("not vdf at all".utf8).write(to: garbage)
        #expect(SteamAppManifest(contentsOf: garbage) == nil)

        #expect(SteamAppManifest(contentsOf: tempDir.appending(path: "missing.acf")) == nil)
    }

    @Test("Legacy parseAppId fast path still works")
    func parseAppIdCompat() {
        let text = acf(appId: 1_245_620, name: "ELDEN RING", installDir: "ELDEN RING", stateFlags: 4)
        #expect(SteamAppManifest.parseAppId(from: text) == 1_245_620)
        #expect(SteamAppManifest.parseAppId(from: "no appid here") == nil)
    }

    @Test("findAppIdForProgram walks parent directories")
    func findsAppIdNearExe() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let exeDir = tempDir.appending(path: "game").appending(path: "bin")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data("4576510\n".utf8).write(to: tempDir.appending(path: "game").appending(path: "steam_appid.txt"))

        let found = SteamAppManifest.findAppIdForProgram(at: exeDir.appending(path: "game.exe"))
        #expect(found == 4_576_510)
    }
}
