//
//  SteamCompatToolOverlayTests.swift
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

@Suite("SteamCompatTool Overlay Tests")
struct SteamCompatToolOverlayTests {
    static let overlay = "/Steam/Contents/MacOS/gameoverlayrenderer.dylib"

    private func makeClientLibrary(withOverlay: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "overlay_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if withOverlay {
            try Data().write(to: directory.appending(path: SteamCompatTool.overlayLibraryName))
        }
        return directory
    }

    /// The client has a per-game overlay switch already. Adding a second one
    /// in Whisky would only give somebody two places to look when the answer
    /// surprises them.
    @Test("With nothing stated the client's own answer is followed")
    func followsTheClientByDefault() {
        #expect(SteamCompatTool.overlayEnvironment(
            from: ["STEAM_DYLD_INSERT_LIBRARIES": Self.overlay], clientLibrary: nil
        )["DYLD_INSERT_LIBRARIES"] == Self.overlay)
    }

    @Test("A launch can keep the overlay out")
    func honoursAnOptOut() {
        for value in ["0", "false", "NO"] {
            let environment = [
                "WHISKY_STEAM_OVERLAY": value, "STEAM_DYLD_INSERT_LIBRARIES": Self.overlay
            ]
            #expect(SteamCompatTool.overlayEnvironment(
                from: environment, clientLibrary: nil
            ).isEmpty)
        }
    }

    /// dyld drops `DYLD_INSERT_LIBRARIES` on the way into a protected process,
    /// so the client carries it under a name nothing strips and expects
    /// whatever it launched to put it back.
    @Test("Steam's own list is what gets handed to dyld")
    func usesTheListSteamSet() {
        let environment = [
            "WHISKY_STEAM_OVERLAY": "1",
            "STEAM_DYLD_INSERT_LIBRARIES": "/one.dylib:/two.dylib"
        ]

        #expect(SteamCompatTool.overlayEnvironment(
            from: environment, clientLibrary: nil
        )["DYLD_INSERT_LIBRARIES"] == "/one.dylib:/two.dylib")
    }

    /// An empty value is the client saying this game gets no overlay. Answering
    /// it with our own guess would be answering a question nobody asked.
    @Test("A client that cleared the list is taken at its word")
    func respectsAnEmptyList() throws {
        let directory = try makeClientLibrary(withOverlay: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SteamCompatTool.overlayEnvironment(
            from: ["WHISKY_STEAM_OVERLAY": "1", "STEAM_DYLD_INSERT_LIBRARIES": ""],
            clientLibrary: directory
        ).isEmpty)
    }

    /// A client that names nothing has not made a decision, it is a client
    /// this does not recognise, so reaching for our own copy needs asking for.
    @Test("Our own copy is only used when a launch asks for it")
    func fallsBackToTheClientLibrary() throws {
        let directory = try makeClientLibrary(withOverlay: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = directory.appending(path: SteamCompatTool.overlayLibraryName)

        #expect(SteamCompatTool.overlayEnvironment(
            from: ["WHISKY_STEAM_OVERLAY": "1"], clientLibrary: directory
        )["DYLD_INSERT_LIBRARIES"] == expected.path(percentEncoded: false))
        #expect(SteamCompatTool.overlayEnvironment(
            from: [:], clientLibrary: directory
        ).isEmpty)
    }

    /// Pointing dyld at a library that is not there turns a missing overlay
    /// into a game that will not start.
    @Test("A missing dylib is left alone rather than named")
    func refusesAPathThatIsNotThere() throws {
        let directory = try makeClientLibrary(withOverlay: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SteamCompatTool.overlayEnvironment(
            from: ["WHISKY_STEAM_OVERLAY": "1"], clientLibrary: directory
        ).isEmpty)
        #expect(SteamCompatTool.overlayEnvironment(
            from: ["WHISKY_STEAM_OVERLAY": "1"], clientLibrary: nil
        ).isEmpty)
    }
}
