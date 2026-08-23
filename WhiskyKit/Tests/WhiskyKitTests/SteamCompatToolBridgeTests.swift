//
//  SteamCompatToolBridgeTests.swift
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

@Suite("SteamCompatTool Bridge Tests")
struct SteamCompatToolBridgeTests {
    private func makeSteamRoot(withLibrary: Bool) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "bridge_\(UUID().uuidString)")
        let macOS = root.appending(path: "Steam.AppBundle").appending(path: "Steam")
            .appending(path: "Contents").appending(path: "MacOS")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        if withLibrary { try Data().write(to: macOS.appending(path: "steamclient.dylib")) }
        return root
    }

    /// The bridge opens `$STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib`,
    /// so the value has to name the directory the library is in, which on
    /// macOS is inside the app bundle rather than the Steam data root.
    @Test("The library directory is the one holding the dylib")
    func findsTheLibraryDirectory() throws {
        let root = try makeSteamRoot(withLibrary: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try #require(SteamCompatTool.clientLibraryDirectory(steamRoot: root))

        #expect(directory.lastPathComponent == "MacOS")
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "steamclient.dylib").path(percentEncoded: false)
        ))
    }

    @Test("A Steam without the library yields nothing rather than a bad path")
    func reportsAMissingLibrary() throws {
        let root = try makeSteamRoot(withLibrary: false)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamCompatTool.clientLibraryDirectory(steamRoot: root) == nil)
    }

    /// Steam sets this itself, to the install root, which is the right answer
    /// on Linux and the wrong one here. Ours has to win.
    @Test("The value Steam sets is replaced")
    func replacesTheValueSteamSets() throws {
        let root = try makeSteamRoot(withLibrary: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try #require(SteamCompatTool.clientLibraryDirectory(steamRoot: root))

        let passed = SteamCompatTool.passthroughEnvironment(
            from: ["STEAM_COMPAT_CLIENT_INSTALL_PATH": "/somewhere/else", "SteamAppId": "480"],
            clientLibrary: directory
        )

        #expect(passed["STEAM_COMPAT_CLIENT_INSTALL_PATH"] == directory.path(percentEncoded: false))
        #expect(passed["SteamAppId"] == "480")
    }

    /// Pointing the bridge at a library that is not there would only turn a
    /// missing Steam into a confusing dlopen failure, so leave the key alone.
    @Test("Nothing is pointed at a library that is not there")
    func leavesTheKeyAloneWithoutALibrary() {
        let passed = SteamCompatTool.passthroughEnvironment(
            from: ["STEAM_COMPAT_CLIENT_INSTALL_PATH": "/somewhere/else"], clientLibrary: nil
        )

        #expect(passed["STEAM_COMPAT_CLIENT_INSTALL_PATH"] == "/somewhere/else")
    }

    @Test("Variables that are not Steam's are still dropped")
    func stillDropsUnrelatedVariables() {
        let passed = SteamCompatTool.passthroughEnvironment(
            from: ["PATH": "/usr/bin", "SteamAppId": "480"], clientLibrary: nil
        )

        #expect(passed["PATH"] == nil)
        #expect(passed["SteamAppId"] == "480")
    }
}
