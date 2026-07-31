//
//  SteamLibraryTests.swift
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

private func acf(appId: Int, name: String, installDir: String, stateFlags: Int) -> String {
    """
    "AppState"
    {
        "appid"        "\(appId)"
        "name"        "\(name)"
        "installdir"        "\(installDir)"
        "StateFlags"        "\(stateFlags)"
        "buildid"        "1785187029"
        "SizeOnDisk"        "541968407"
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

@Suite("SteamLibrary Tests")
struct SteamLibraryTests {
    /// Builds a fixture bottle: a default Steam install with one installed
    /// game, one downloading game, one manifest whose install dir is missing,
    /// plus a second library on D: (via dosdevices symlink) with another
    /// installed game and a duplicate of the first game's App ID.
    private func makeFixtureBottle() throws -> (bottle: URL, tempRoot: URL) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appending(path: "steamlib_\(UUID().uuidString)")
        let bottle = tempRoot.appending(path: "bottle")
        let steamRoot = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let steamApps = steamRoot.appending(path: "steamapps")

        try fileManager.createDirectory(
            at: steamApps.appending(path: "common").appending(path: "Casualties Unknown Demo"),
            withIntermediateDirectories: true
        )
        try Data().write(to: steamRoot.appending(path: "steam.exe"))

        try Data(acf(
            appId: 4_576_510, name: "Casualties: Unknown Demo",
            installDir: "Casualties Unknown Demo", stateFlags: 4
        ).utf8).write(to: steamApps.appending(path: "appmanifest_4576510.acf"))

        // Downloading: filtered by state
        try Data(acf(appId: 999, name: "Downloading Game", installDir: "dl", stateFlags: 2).utf8)
            .write(to: steamApps.appending(path: "appmanifest_999.acf"))

        // Claims installed but common dir is missing: filtered
        try Data(acf(appId: 777, name: "Ghost Game", installDir: "Ghost", stateFlags: 4).utf8)
            .write(to: steamApps.appending(path: "appmanifest_777.acf"))

        try makeSecondLibrary(tempRoot: tempRoot, bottle: bottle)

        let config = steamRoot.appending(path: "config")
        try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        let vdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
            }
            "1"
            {
                "path"        "D:\\\\"
            }
        }
        """
        try Data(vdf.utf8).write(to: config.appending(path: "libraryfolders.vdf"))

        return (bottle, tempRoot)
    }

    /// A second library on D: reached through the dosdevices symlink, holding
    /// another installed game plus a duplicate of the first library's App ID.
    private func makeSecondLibrary(tempRoot: URL, bottle: URL) throws {
        let fileManager = FileManager.default
        let secondLibrary = tempRoot.appending(path: "second-library")
        let secondApps = secondLibrary.appending(path: "steamapps")
        try fileManager.createDirectory(
            at: secondApps.appending(path: "common").appending(path: "ELDEN RING"),
            withIntermediateDirectories: true
        )
        try Data(acf(appId: 1_245_620, name: "ELDEN RING", installDir: "ELDEN RING", stateFlags: 4).utf8)
            .write(to: secondApps.appending(path: "appmanifest_1245620.acf"))

        try Data(acf(
            appId: 4_576_510, name: "Casualties Duplicate",
            installDir: "ELDEN RING", stateFlags: 4
        ).utf8).write(to: secondApps.appending(path: "appmanifest_dup.acf"))

        let dosDevices = bottle.appending(path: "dosdevices")
        try fileManager.createDirectory(at: dosDevices, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: dosDevices.appending(path: "d:"),
            withDestinationURL: secondLibrary
        )
    }

    @Test("Detects a Steam install")
    func detectsInstall() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let root = try #require(SteamLibrary.detectInstall(bottleURL: bottle))
        #expect(root.lastPathComponent == "Steam")
    }

    @Test("Returns nil for a bottle without Steam")
    func noSteamNoInstall() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir.appending(path: "drive_c"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(SteamLibrary.detectInstall(bottleURL: tempDir) == nil)
        #expect(SteamLibrary.enumerate(bottleURL: tempDir).isEmpty)
    }

    @Test("Enumerates installed games across libraries, filtered and sorted")
    func enumeratesAcrossLibraries() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let games = SteamLibrary.enumerate(bottleURL: bottle)

        #expect(games.map(\.appId) == [4_576_510, 1_245_620])
        #expect(games.map(\.name) == ["Casualties: Unknown Demo", "ELDEN RING"])
        // The duplicate App ID in the second library lost to the first discovery
        #expect(games[0].name != "Casualties Duplicate")
        // Downloading (999) and missing-install-dir (777) games are filtered
        #expect(!games.contains { $0.appId == 999 || $0.appId == 777 })
    }

    @Test("Collects executable names at root and one level deep")
    func collectsExecutableNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bin = tempDir.appending(path: "bin")
        let deep = tempDir.appending(path: "bin").appending(path: "too-deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        try Data().write(to: tempDir.appending(path: "Game.exe"))
        try Data().write(to: tempDir.appending(path: "readme.txt"))
        try Data().write(to: bin.appending(path: "Helper.EXE"))
        try Data().write(to: deep.appending(path: "ignored.exe"))

        let names = SteamLibrary.executableNames(under: tempDir)

        #expect(names == ["game.exe", "helper.exe"])
    }

    @Test("Maps Windows paths through the prefix")
    func mapsWindowsPaths() {
        let bottle = URL(fileURLWithPath: "/tmp/bottle")

        let cPath = SteamLibrary.mapWindowsPath(#"C:\Program Files (x86)\Steam"#, bottleURL: bottle)
        #expect(cPath?.path == "/tmp/bottle/drive_c/Program Files (x86)/Steam")

        let dPath = SteamLibrary.mapWindowsPath(#"D:\SteamLibrary"#, bottleURL: bottle)
        #expect(dPath?.path == "/tmp/bottle/dosdevices/d:/SteamLibrary")

        let driveOnly = SteamLibrary.mapWindowsPath(#"D:\"#, bottleURL: bottle)
        #expect(driveOnly?.path == "/tmp/bottle/dosdevices/d:")

        #expect(SteamLibrary.mapWindowsPath("not a path", bottleURL: bottle) == nil)
        #expect(SteamLibrary.mapWindowsPath("", bottleURL: bottle) == nil)
    }
}
