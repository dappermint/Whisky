//
//  LibraryCatalogueTests.swift
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

@Suite("Library Catalogue Tests")
struct LibraryCatalogueTests {
    private func bottle() -> (url: URL, settings: BottleSettings) {
        (URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle"), BottleSettings())
    }

    private func pin(_ name: String, _ path: String) -> PinnedProgram {
        PinnedProgram(name: name, url: URL(fileURLWithPath: path))
    }

    @Test("The library is the pins, not every executable in the prefix")
    func pinsBecomeItems() {
        var (url, settings) = bottle()
        settings.pins = [
            pin("Ready or Not", "/tmp/whisky-library-test/Bottle/drive_c/RoN/ReadyOrNot.exe"),
            pin("Skyrim", "/tmp/whisky-library-test/Bottle/drive_c/Skyrim/SkyrimSE.exe")
        ]

        let items = PinnedLibrarySource.items(inBottleAt: url, settings: settings)

        #expect(items.count == 2)
        #expect(items.map(\.name) == ["Ready or Not", "Skyrim"])
        #expect(items.allSatisfy { $0.source == .pinned })
        #expect(items.allSatisfy { $0.bottleURL == url })
    }

    @Test("A pin carries the executable to read an icon from")
    func pinsCarryAnIconSource() throws {
        var (url, settings) = bottle()
        settings.pins = [pin("Ready or Not", "/tmp/whisky-library-test/Bottle/drive_c/RoN/ReadyOrNot.exe")]

        let item = try #require(PinnedLibrarySource.items(inBottleAt: url, settings: settings).first)

        #expect(item.iconURL?.lastPathComponent == "ReadyOrNot.exe")
        #expect(item
            .launch == .program(URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle/drive_c/RoN/ReadyOrNot.exe")))
    }

    @Test("Identifiers are stable and unique per source")
    func identifiersAreStable() {
        var (url, settings) = bottle()
        settings.pins = [pin("Game", "/tmp/whisky-library-test/Bottle/drive_c/Game/game.exe")]

        let first = PinnedLibrarySource.items(inBottleAt: url, settings: settings)
        let second = PinnedLibrarySource.items(inBottleAt: url, settings: settings)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first[0].id.hasPrefix("pinned:"))
    }

    @Test("A bottle with no pins and no Steam contributes nothing")
    func emptyBottleIsEmpty() {
        let (url, settings) = bottle()

        #expect(LibraryCatalogue.items(inBottleAt: url, settings: settings).isEmpty)
    }

    @Test("A pin with no resolvable url is skipped rather than crashing the list")
    func brokenPinIsSkipped() {
        var (url, settings) = bottle()
        var broken = pin("Gone", "/tmp/whisky-library-test/Bottle/drive_c/gone.exe")
        broken.url = nil
        settings.pins = [broken, pin("Fine", "/tmp/whisky-library-test/Bottle/drive_c/fine.exe")]

        let items = PinnedLibrarySource.items(inBottleAt: url, settings: settings)

        #expect(items.map(\.name) == ["Fine"])
    }

    @Test("Sources are registered, pins first")
    func sourcesAreRegistered() {
        #expect(LibraryCatalogue.sources.count >= 2)
        #expect(LibraryCatalogue.sources.first?.id == .pinned)
    }

    private func steamEntry(
        appID: Int, name: String, bottle: URL, installDir: String
    ) -> LibraryEntry {
        let install = bottle.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/common/\(installDir)"
        )
        return LibraryEntry(
            id: "steam:\(bottle.path(percentEncoded: false)):\(appID)",
            recordID: .steam(appID: appID),
            name: name,
            iconURL: nil,
            artworkURL: install.appending(path: "header.jpg"),
            bottleURL: bottle,
            source: .steam,
            launch: .steam(appID: appID),
            installURL: install
        )
    }

    private func pinEntry(_ name: String, exe: String, bottle: URL) -> LibraryEntry {
        let url = bottle.appending(path: exe)
        return LibraryEntry(
            id: "pinned:\(url.path(percentEncoded: false))",
            recordID: .pin(at: url, bottleURL: bottle),
            name: name,
            iconURL: url,
            bottleURL: bottle,
            source: .pinned,
            launch: .program(url)
        )
    }

    @Test("A pin inside a Steam game's install is that game, once, with the pin's name")
    func pinInsideInstallMerges() throws {
        let bottle = URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle")
        let pin = pinEntry(
            "ready or not (dx11)",
            exe: "drive_c/Program Files (x86)/Steam/steamapps/common/Ready Or Not/ReadyOrNot.exe",
            bottle: bottle
        )
        let steam = steamEntry(appID: 1_144_200, name: "Ready Or Not", bottle: bottle, installDir: "Ready Or Not")

        let merged = LibraryCatalogue.merge([[pin], [steam]])

        let card = try #require(merged.first)
        #expect(merged.count == 1)
        // The store identity carries the launch route and the art; the name is
        // the one the person typed.
        #expect(card.recordID == .steam(appID: 1_144_200))
        #expect(card.launch == .steam(appID: 1_144_200))
        #expect(card.artworkURL != nil)
        #expect(card.name == "ready or not (dx11)")
    }

    @Test("Matching names alone no longer collapse a pin and a store entry")
    func nameCollisionAloneDoesNotMerge() {
        let bottle = URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle")
        // Same display name, but the pin points outside the install dir: two
        // different things the person can launch, so two cards.
        let pin = pinEntry("Ready Or Not", exe: "drive_c/Other/ReadyOrNot.exe", bottle: bottle)
        let steam = steamEntry(appID: 1_144_200, name: "Ready Or Not", bottle: bottle, installDir: "Ready Or Not")

        #expect(LibraryCatalogue.merge([[pin], [steam]]).count == 2)
    }

    @Test("A second pin into the same install stays its own entry")
    func secondPinIntoInstallStays() {
        let bottle = URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle")
        let game = pinEntry(
            "Ready or Not",
            exe: "drive_c/Program Files (x86)/Steam/steamapps/common/Ready Or Not/ReadyOrNot.exe",
            bottle: bottle
        )
        let editor = pinEntry(
            "RoN Mod Tools",
            exe: "drive_c/Program Files (x86)/Steam/steamapps/common/Ready Or Not/ModTools.exe",
            bottle: bottle
        )
        let steam = steamEntry(appID: 1_144_200, name: "Ready Or Not", bottle: bottle, installDir: "Ready Or Not")

        let merged = LibraryCatalogue.merge([[game, editor], [steam]])

        #expect(merged.count == 2)
        #expect(merged.contains { $0.name == "RoN Mod Tools" && $0.launch == .program(
            bottle.appending(
                path: "drive_c/Program Files (x86)/Steam/steamapps/common/Ready Or Not/ModTools.exe"
            )
        ) })
    }

    @Test("An install dir never claims its sibling with a longer name")
    func installDirMatchesWholeComponents() {
        let bottle = URL(fileURLWithPath: "/tmp/whisky-library-test/Bottle")
        let pin = pinEntry(
            "Game II",
            exe: "drive_c/Program Files (x86)/Steam/steamapps/common/Game II/game2.exe",
            bottle: bottle
        )
        let steam = steamEntry(appID: 1, name: "Game", bottle: bottle, installDir: "Game")

        #expect(LibraryCatalogue.merge([[pin], [steam]]).count == 2)
    }

    @Test("Steam artwork resolves the folder layout, then the flat one")
    func steamArtworkLayouts() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = root.appending(path: "appcache").appending(path: "librarycache")
        try FileManager.default.createDirectory(at: cache.appending(path: "12345"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamLibrarySource.artworkURL(appID: 12_345, steamRoot: root) == nil)

        // The portrait is a fallback: a card can crop it, and no art is worse.
        try Data().write(to: cache.appending(path: "12345").appending(path: "library_600x900.jpg"))
        #expect(SteamLibrarySource.artworkURL(appID: 12_345, steamRoot: root)?.lastPathComponent
            == "library_600x900.jpg")

        // The landscape banner is the shape a card actually wants, so it wins.
        try Data().write(to: cache.appending(path: "12345").appending(path: "header.jpg"))
        #expect(SteamLibrarySource.artworkURL(appID: 12_345, steamRoot: root)?.lastPathComponent == "header.jpg")

        // Steam used a flat name before it used a folder per app.
        try Data().write(to: cache.appending(path: "999_header.jpg"))
        #expect(SteamLibrarySource.artworkURL(appID: 999, steamRoot: root)?.lastPathComponent == "999_header.jpg")
    }

    @Test("An entry with no artwork says so rather than pointing at a missing file")
    func missingArtworkIsNil() {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)

        #expect(SteamLibrarySource.artworkURL(appID: 1, steamRoot: root) == nil)
    }

    @Test("A source id round-trips, so it can be persisted alongside a filter")
    func sourceIDCodes() throws {
        let encoded = try JSONEncoder().encode(LibrarySourceID.steam)
        let decoded = try JSONDecoder().decode(LibrarySourceID.self, from: encoded)

        #expect(decoded == .steam)
        #expect(decoded.rawValue == "steam")
    }

    @Test("The same Steam game in two bottles gets two ids, not one")
    func steamIDsAreScopedToTheirBottle() {
        // Two rows sharing an id inside one ForEach breaks the grid's diffing,
        // and duplicating a bottle to test a runtime is routine.
        let first = URL(fileURLWithPath: "/tmp/whisky-library-test/One")
        let second = URL(fileURLWithPath: "/tmp/whisky-library-test/Two")

        let ids = [first, second].map { "steam:\($0.path(percentEncoded: false)):440" }

        #expect(Set(ids).count == 2)
    }

    @Test("A pinned storefront client is marked as a launcher, a game is not")
    func pinsDetectLaunchers() throws {
        var (url, settings) = bottle()
        settings.pins = [
            pin("steam", "/tmp/whisky-library-test/Bottle/drive_c/Program Files (x86)/Steam/steam.exe"),
            pin("Ready or Not", "/tmp/whisky-library-test/Bottle/drive_c/RoN/ReadyOrNot.exe")
        ]

        let items = PinnedLibrarySource.items(inBottleAt: url, settings: settings)
        let client = try #require(items.first { $0.name == "steam" })
        let game = try #require(items.first { $0.name == "Ready or Not" })

        #expect(client.isLauncher)
        #expect(client.launcher == .steam)
        #expect(!game.isLauncher)
    }

    @Test("A game inside a Steam library is not mistaken for the client")
    func steamLibraryGamesAreNotLaunchers() throws {
        var (url, settings) = bottle()
        settings.pins = [
            pin(
                "Ready or Not",
                "/tmp/whisky-library-test/Bottle/drive_c/Program Files (x86)/Steam/"
                    + "steamapps/common/Ready Or Not/ReadyOrNot.exe"
            )
        ]

        let item = try #require(PinnedLibrarySource.items(inBottleAt: url, settings: settings).first)

        #expect(!item.isLauncher)
    }
}
