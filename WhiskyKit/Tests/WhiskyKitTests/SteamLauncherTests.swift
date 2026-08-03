//
//  SteamLauncherTests.swift
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

@Suite("SteamLauncher Routing Tests")
struct SteamLauncherTests {
    private let tempRoot: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "steamlaunch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    /// A bottle holding a Steam install with each of `appIds` fully installed.
    private func makeSteamBottle(_ label: String, appIds: [Int]) throws -> URL {
        let fileManager = FileManager.default
        let bottle = tempRoot.appending(path: "\(label)-\(UUID().uuidString)")
        let steamRoot = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let steamApps = steamRoot.appending(path: "steamapps")
        try fileManager.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try Data().write(to: steamRoot.appending(path: "steam.exe"))

        for appId in appIds {
            let installDir = "Game\(appId)"
            try fileManager.createDirectory(
                at: steamApps.appending(path: "common").appending(path: installDir),
                withIntermediateDirectories: true
            )
            let manifest = """
            "AppState"
            {
                "appid"        "\(appId)"
                "name"        "Game \(appId)"
                "installdir"        "\(installDir)"
                "StateFlags"        "4"
            }
            """
            try Data(manifest.utf8)
                .write(to: steamApps.appending(path: "appmanifest_\(appId).acf"))
        }
        return bottle
    }

    private func makeRouting() -> GameRouting {
        GameRouting(url: tempRoot.appending(path: "GameRouting-\(UUID().uuidString).plist"))
    }

    @Test("The remembered bottle wins over another that also has the game")
    @MainActor func routeWins() throws {
        let first = try Bottle(bottleUrl: makeSteamBottle("first", appIds: [1_245_620]))
        let second = try Bottle(bottleUrl: makeSteamBottle("second", appIds: [1_245_620]))
        let routing = makeRouting()
        routing.record(appId: 1_245_620, bottleURL: second.url)

        let resolved = try SteamLauncher.resolveBottle(
            appId: 1_245_620, in: [first, second], routing: routing
        )

        #expect(resolved.url == second.url)
    }

    @Test("A route to a bottle that lost the game falls through to one that has it")
    @MainActor func staleRouteFallsThrough() throws {
        let stale = try Bottle(bottleUrl: makeSteamBottle("stale", appIds: [4_576_510]))
        let real = try Bottle(bottleUrl: makeSteamBottle("real", appIds: [1_245_620]))
        let routing = makeRouting()
        routing.record(appId: 1_245_620, bottleURL: stale.url)

        let resolved = try SteamLauncher.resolveBottle(
            appId: 1_245_620, in: [stale, real], routing: routing
        )

        #expect(resolved.url == real.url)
    }

    @Test("A route to a bottle Whisky no longer knows falls through")
    @MainActor func routeToUnknownBottleFallsThrough() throws {
        let deleted = try makeSteamBottle("deleted", appIds: [1_245_620])
        let real = try Bottle(bottleUrl: makeSteamBottle("real", appIds: [1_245_620]))
        let routing = makeRouting()
        routing.record(appId: 1_245_620, bottleURL: deleted)

        let resolved = try SteamLauncher.resolveBottle(
            appId: 1_245_620, in: [real], routing: routing
        )

        #expect(resolved.url == real.url)
    }

    @Test("Without a route the first bottle holding the game wins")
    @MainActor func firstInstallWinsWithoutRoute() throws {
        let empty = try Bottle(bottleUrl: makeSteamBottle("empty", appIds: []))
        let holder = try Bottle(bottleUrl: makeSteamBottle("holder", appIds: [1_245_620]))

        let resolved = try SteamLauncher.resolveBottle(
            appId: 1_245_620, in: [empty, holder], routing: makeRouting()
        )

        #expect(resolved.url == holder.url)
    }

    @Test("No bottle with the game throws gameNotFound")
    @MainActor func noBottleThrows() throws {
        let bottle = try Bottle(bottleUrl: makeSteamBottle("other", appIds: [4_576_510]))
        let routing = makeRouting()
        routing.record(appId: 1_245_620, bottleURL: bottle.url)

        #expect(throws: SteamLaunchError.gameNotFound(appId: 1_245_620)) {
            try SteamLauncher.resolveBottle(appId: 1_245_620, in: [bottle], routing: routing)
        }
    }
}
