//
//  SteamHelperTests.swift
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

@Suite("Steam Helper Tests")
struct SteamHelperTests {
    static let session = ["SteamGameId": "553850"]
    static let helper = URL(filePath: "/Whisky.app/Resources/WhiskySteamHelper.exe")
    static let game = URL(filePath: "/Games/Helldivers 2/bin/helldivers2.exe")
    static let installRoot = URL(filePath: "/Games/Helldivers 2")

    @Test("The helper ships with the build")
    func helperIsBundled() throws {
        let url = try #require(SteamHelper.executableURL)

        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(url.lastPathComponent == "WhiskySteamHelper.exe")
    }

    /// Whisky launches plenty of programs that have nothing to do with Steam,
    /// and putting all of them behind a helper that claims a prefix-wide mutex
    /// would be a side effect nobody asked for.
    @Test("A launch Steam did not describe runs unwrapped")
    func ignoresANonSteamLaunch() {
        #expect(SteamHelper.isSteamSession([:]) == false)
        #expect(SteamHelper.isSteamSession(["WINEPREFIX": "/tmp/bottle"]) == false)
        #expect(SteamHelper.command(
            program: Self.game, args: [], workingDirectory: Self.installRoot,
            environment: [:], helperURL: Self.helper
        ) == nil)
    }

    @Test("Either identity the client sets counts as a session")
    func recognisesASteamSession() {
        #expect(SteamHelper.isSteamSession(["SteamGameId": "553850"]))
        #expect(SteamHelper.isSteamSession(["SteamAppId": "553850"]))
    }

    /// Steam leaves these set to a placeholder for its own non-game children,
    /// and answering for one would point a game at the wrong process.
    @Test("A placeholder app id is not a session")
    func ignoresAPlaceholderAppID() {
        #expect(SteamHelper.isSteamSession(["SteamGameId": "0"]) == false)
        #expect(SteamHelper.isSteamSession(["SteamAppId": ""]) == false)
    }

    /// The whole reason the helper launches the game rather than running beside
    /// it: what it sets in the environment is what the game inherits, and the
    /// process Whisky waits on is the one that ends the session.
    @Test("A Steam launch runs the game under the helper")
    func wrapsASteamLaunch() throws {
        let command = try #require(SteamHelper.command(
            program: Self.game, args: ["--bundle-dir", "data", "--release"],
            workingDirectory: Self.installRoot, environment: Self.session, helperURL: Self.helper
        ))

        #expect(command == [
            Self.helper.path(percentEncoded: false),
            "--workdir", "/Games/Helldivers 2",
            "--exec", "/Games/Helldivers 2/bin/helldivers2.exe",
            "--bundle-dir", "data", "--release"
        ])
    }

    /// Steam runs a game from its install root and not from wherever the
    /// executable sits inside it, and with the helper in between there is no
    /// longer an obvious directory to fall into.
    @Test("The working directory is passed rather than inherited")
    func passesTheWorkingDirectory() throws {
        let command = try #require(SteamHelper.command(
            program: Self.game, args: [], workingDirectory: Self.installRoot,
            environment: Self.session, helperURL: Self.helper
        ))
        let index = try #require(command.firstIndex(of: "--workdir"))

        #expect(command[index + 1] == "/Games/Helldivers 2")
    }

    /// It would take the presence mutex twice and then wait on nothing.
    @Test("The helper is never wrapped in itself")
    func neverWrapsItself() {
        #expect(SteamHelper.command(
            program: Self.helper, args: [], workingDirectory: Self.installRoot,
            environment: Self.session, helperURL: Self.helper
        ) == nil)
    }

    /// A build without the resource should still launch games, just without the
    /// answers the helper would have held open.
    @Test("A build missing the helper runs the game directly")
    func toleratesAMissingHelper() {
        #expect(SteamHelper.command(
            program: Self.game, args: [], workingDirectory: Self.installRoot,
            environment: Self.session, helperURL: nil
        ) == nil)
    }

    @Test("An attached run names the command wine is given")
    func attachedRunNamesTheCommand() {
        let command = ["/helper.exe", "--exec", "/game.exe"]

        #expect(Wine.launchArguments(
            command: command, programName: "game.exe", programOverrides: nil, keepAttached: true
        ) == command)
        #expect(Wine.launchArguments(
            command: command, programName: "game.exe", programOverrides: nil, keepAttached: false
        ) == ["start", "/unix"] + command)
    }

    @Test("A virtual desktop run puts the whole command inside the desktop")
    func virtualDesktopWrapsTheCommand() {
        var overrides = ProgramOverrides()
        overrides.virtualDesktopEnabled = true
        overrides.resolutionPreset = .r1920x1080

        let arguments = Wine.launchArguments(
            command: ["/helper.exe", "--exec", "/game.exe"], programName: "my game.exe",
            programOverrides: overrides, keepAttached: true
        )

        #expect(arguments == [
            "explorer", "/desktop=my_game.exe,1920x1080", "/helper.exe", "--exec", "/game.exe"
        ])
    }
}
