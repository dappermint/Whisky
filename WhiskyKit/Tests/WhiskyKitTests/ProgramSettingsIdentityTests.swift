//
//  ProgramSettingsIdentityTests.swift
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

@Suite("Program Settings Identity Tests")
struct ProgramSettingsIdentityTests {
    private func makeBottle() throws -> (bottle: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir.appending(path: "drive_c"), withIntermediateDirectories: true
        )
        return (tempDir, { try? FileManager.default.removeItem(at: tempDir) })
    }

    private func makeExe(at path: String, in bottleURL: URL) throws -> URL {
        let url = bottleURL.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: url)
        return url
    }

    @Test("Two programs named Launch.exe get separate settings")
    @MainActor func launchExeCollision() throws {
        let (bottleURL, cleanup) = try makeBottle()
        defer { cleanup() }
        let bottle = Bottle(bottleUrl: bottleURL, inFlight: false, isAvailable: true)

        let first = try makeExe(at: "drive_c/GameA/Launch.exe", in: bottleURL)
        let second = try makeExe(at: "drive_c/GameB/Launch.exe", in: bottleURL)

        let firstProgram = Program(url: first, bottle: bottle, peFile: nil)
        let secondProgram = Program(url: second, bottle: bottle, peFile: nil)

        #expect(firstProgram.settingsURL != secondProgram.settingsURL)
        #expect(firstProgram.settingsURL.lastPathComponent.hasPrefix("Launch-"))
        #expect(secondProgram.settingsURL.lastPathComponent.hasPrefix("Launch-"))
    }

    @Test("Identity is stable when the bottle moves")
    func stableAcrossBottleMoves() {
        let exeA = URL(fileURLWithPath: "/tmp/bottles/old/drive_c/Game/game.exe")
        let exeB = URL(fileURLWithPath: "/somewhere/else/new/drive_c/Game/game.exe")

        let identityA = Program.settingsIdentity(
            for: exeA, bottleURL: URL(fileURLWithPath: "/tmp/bottles/old")
        )
        let identityB = Program.settingsIdentity(
            for: exeB, bottleURL: URL(fileURLWithPath: "/somewhere/else/new")
        )

        #expect(identityA == identityB)
        #expect(identityA.hasPrefix("game-"))
    }

    @Test("Legacy filename-keyed settings migrate on first load")
    @MainActor func migratesLegacySettings() throws {
        let (bottleURL, cleanup) = try makeBottle()
        defer { cleanup() }
        let bottle = Bottle(bottleUrl: bottleURL, inFlight: false, isAvailable: true)
        let exe = try makeExe(at: "drive_c/Game/Launch.exe", in: bottleURL)

        // A legacy plist under the old filename-keyed path
        var legacySettings = ProgramSettings()
        legacySettings.arguments = "-windowed"
        let settingsFolder = bottleURL.appending(path: "Program Settings")
        try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
        let legacyURL = settingsFolder.appending(path: "Launch.exe").appendingPathExtension("plist")
        try legacySettings.encode(to: legacyURL)

        let program = Program(url: exe, bottle: bottle, peFile: nil)

        #expect(program.settings.arguments == "-windowed")
        // Copied, not moved: the legacy file survives for downgrades
        #expect(FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)))
        #expect(program.settingsURL != legacyURL)
    }

    @Test("Existing identity-keyed settings are never overwritten by legacy")
    @MainActor func identityWinsOverLegacy() throws {
        let (bottleURL, cleanup) = try makeBottle()
        defer { cleanup() }
        let bottle = Bottle(bottleUrl: bottleURL, inFlight: false, isAvailable: true)
        let exe = try makeExe(at: "drive_c/Game/Launch.exe", in: bottleURL)

        let settingsFolder = bottleURL.appending(path: "Program Settings")
        try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)

        var identitySettings = ProgramSettings()
        identitySettings.arguments = "-identity"
        let identityName = Program.settingsIdentity(for: exe, bottleURL: bottleURL)
        try identitySettings.encode(
            to: settingsFolder.appending(path: identityName).appendingPathExtension("plist")
        )

        var legacySettings = ProgramSettings()
        legacySettings.arguments = "-legacy"
        try legacySettings.encode(
            to: settingsFolder.appending(path: "Launch.exe").appendingPathExtension("plist")
        )

        let program = Program(url: exe, bottle: bottle, peFile: nil)

        #expect(program.settings.arguments == "-identity")
    }
}

extension ProgramSettingsIdentityTests {
    /// A Steam library is a place a game moves between. Keying on the absolute
    /// path left everything tuned for Ready or Not behind when the library
    /// moved to another drive.
    @Test func aGameKeepsItsIdentityAcrossASteamLibraryMove() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let before = URL(fileURLWithPath: "/Volumes/A/steamapps/common/Ready Or Not/ReadyOrNot.exe")
        let after = URL(fileURLWithPath: "/Users/me/Games/Win/steamapps/common/Ready Or Not/ReadyOrNot.exe")

        #expect(
            Program.settingsIdentity(for: before, bottleURL: bottle)
                == Program.settingsIdentity(for: after, bottleURL: bottle)
        )
    }

    @Test func twoGamesInOneLibraryStillDiffer() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let ron = URL(fileURLWithPath: "/L/steamapps/common/Ready Or Not/ReadyOrNot.exe")
        let hd2 = URL(fileURLWithPath: "/L/steamapps/common/Helldivers 2/bin/helldivers2.exe")

        #expect(
            Program.settingsIdentity(for: ron, bottleURL: bottle)
                != Program.settingsIdentity(for: hd2, bottleURL: bottle)
        )
    }

    /// The old spelling has to stay reachable, or the change orphans everything
    /// it was meant to stop orphaning.
    @Test func theOlderSpellingsAreStillReachable() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let exe = URL(fileURLWithPath: "/Volumes/A/steamapps/common/Ready Or Not/ReadyOrNot.exe")

        let superseded = Program.supersededIdentities(for: exe, bottleURL: bottle)
        let current = Program.settingsIdentity(for: exe, bottleURL: bottle)
        #expect(!superseded.isEmpty)
        #expect(!superseded.contains(current))
        #expect(Set(superseded).count == superseded.count)
    }

    /// The case that lost an evening: the game moved out of the bottle's own
    /// Steam library, so the settings it had there are keyed on a path the new
    /// location cannot produce.
    @Test func aGameThatLeftTheBottlesOwnLibraryFindsItsOldSettings() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let inBottle = bottle.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/common/Ready Or Not/ReadyOrNot.exe"
        )
        let moved = URL(fileURLWithPath: "/Volumes/A/steamapps/common/Ready Or Not/ReadyOrNot.exe")

        // Both spell the same identity now, and the one the in-bottle copy used
        // to have is still looked for.
        #expect(
            Program.settingsIdentity(for: inBottle, bottleURL: bottle)
                == Program.settingsIdentity(for: moved, bottleURL: bottle)
        )
        let previouslyInBottle = Program.supersededIdentities(for: inBottle, bottleURL: bottle)
        #expect(Program.supersededIdentities(for: moved, bottleURL: bottle).contains {
            previouslyInBottle.contains($0)
        })
    }

    @Test func aProgramInsideTheBottleHasNoSupersededName() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let exe = bottle.appending(path: "drive_c/windows/notepad.exe")

        #expect(Program.supersededIdentities(for: exe, bottleURL: bottle).isEmpty)
    }

    @Test func theKeyPathStartsAtTheLibrary() {
        let bottle = URL(fileURLWithPath: "/Bottles/One")
        let exe = URL(fileURLWithPath: "/Volumes/A/steamapps/common/Ready Or Not/ReadyOrNot.exe")

        #expect(
            Program.keyPath(for: exe, bottleURL: bottle)
                == "steamapps/common/Ready Or Not/ReadyOrNot.exe"
        )
    }

    /// Launching a game after its library moved wrote a default plist under the
    /// new name. Taking that one would discard the tuning under the old one.
    @Test func anEmptyPlistDoesNotShadowAConfiguredOne() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let empty = folder.appending(path: "empty.plist")
        let configured = folder.appending(path: "configured.plist")
        var settings = ProgramSettings()
        try settings.encode(to: empty)
        var overrides = settings.overrides ?? ProgramOverrides()
        overrides.graphicsBackend = .d3dMetal
        settings.overrides = overrides
        try settings.encode(to: configured)

        #expect(Program.richestSettings(among: [empty, configured]) == configured)
        #expect(Program.richestSettings(among: [empty]) == empty)
        #expect(Program.richestSettings(among: []) == nil)
    }
}
