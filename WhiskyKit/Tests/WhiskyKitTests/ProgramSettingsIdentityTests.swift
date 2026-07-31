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
