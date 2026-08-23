//
//  SteamPresenceTests.swift
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

@Suite("Steam Presence Tests")
struct SteamPresenceTests {
    @Test("The helper ships with the build")
    func helperIsBundled() throws {
        let url = try #require(SteamPresence.executableURL)

        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(url.lastPathComponent == "WhiskySteamPresence.exe")
    }

    /// Whisky launches plenty of programs that have nothing to do with Steam,
    /// and a helper that claims a prefix-wide mutex for all of them would be
    /// a side effect nobody asked for.
    @Test("A launch Steam did not describe starts no helper")
    func ignoresANonSteamLaunch() {
        #expect(SteamPresence.isSteamSession([:]) == false)
        #expect(SteamPresence.isSteamSession(["WINEPREFIX": "/tmp/bottle"]) == false)
    }

    @Test("Either identity the client sets counts as a session")
    func recognisesASteamSession() {
        #expect(SteamPresence.isSteamSession(["SteamGameId": "553850"]))
        #expect(SteamPresence.isSteamSession(["SteamAppId": "553850"]))
    }

    /// Steam leaves these set to a placeholder for its own non-game children,
    /// and answering for one would point a game at the wrong process.
    @Test("A placeholder app id is not a session")
    func ignoresAPlaceholderAppID() {
        #expect(SteamPresence.isSteamSession(["SteamGameId": "0"]) == false)
        #expect(SteamPresence.isSteamSession(["SteamAppId": ""]) == false)
    }

    @Test("The helper is started through the prefix, not as a host process")
    func runsInsideThePrefix() {
        let args = SteamPresence.launchArguments(executableURL: URL(filePath: "/tmp/Presence.exe"))

        #expect(args.prefix(2) == ["start", "/unix"])
        #expect(args.last == "/tmp/Presence.exe")
    }
}
