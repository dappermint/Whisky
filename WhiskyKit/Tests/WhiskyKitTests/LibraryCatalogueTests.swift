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

    @Test("Sources are registered in order, and pins win a name collision")
    func pinsWinCollisions() {
        #expect(LibraryCatalogue.sources.count >= 2)
        #expect(LibraryCatalogue.sources.first?.id == .pinned)
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
}
