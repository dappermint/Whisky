//
//  HostSteamProcessTests.swift
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

@Suite("HostSteamProcess Tests")
struct HostSteamProcessTests {
    /// A Steam data directory holding the downloaded client, which is the one
    /// that has to be launched. `/Applications/Steam.app` is a bootstrapper
    /// that re-execs this, and nothing passed to it survives the hop.
    private func makeSteamRoot(withClient: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "hoststeam_\(UUID().uuidString)")
        let macOS = root.appending(path: "Steam.AppBundle").appending(path: "Steam")
            .appending(path: "Contents").appending(path: "MacOS")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)

        if withClient {
            let binary = macOS.appending(path: "steam_osx")
            try Data("#!/bin/bash\n".utf8).write(to: binary)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false)
            )
        }
        return root
    }

    @Test("The client that gets launched is the downloaded one")
    func findsTheDownloadedClient() throws {
        let root = try makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = try #require(HostSteamProcess.clientBinary(steamRoot: root))

        #expect(binary.path(percentEncoded: false).contains("Steam.AppBundle"))
        #expect(binary.lastPathComponent == "steam_osx")
    }

    @Test("No client means nothing to launch, rather than a path that is not there")
    func reportsAMissingClient() throws {
        let root = try makeSteamRoot(withClient: false)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(HostSteamProcess.clientBinary(steamRoot: root) == nil)
        #expect(throws: HostSteamProcessError.clientMissing) {
            try HostSteamProcess.launch(steamRoot: root)
        }
    }

    /// The client never scans its own compatibilitytools.d on macOS. It scans
    /// what this names and nothing else.
    @Test("The compat tools directory is named in the environment")
    func namesTheToolsDirectory() throws {
        let directory = URL(filePath: "/Users/someone/Steam/compatibilitytools.d")

        let environment = HostSteamProcess.environment(compatToolsDirectory: directory)

        #expect(environment["STEAM_EXTRA_COMPAT_TOOLS_PATHS"] == directory.path())
    }

    @Test("Starting without compat tools names nothing")
    func namesNothingWithoutTools() {
        #expect(HostSteamProcess.environment(compatToolsDirectory: nil).isEmpty)
    }

    // MARK: - Finding the client

    /// Matching on the path rather than the name matters: `steam_osx` is also
    /// the bootstrapper's name, and killing that one leaves the client running.
    @Test("Only the downloaded client is matched, not the bootstrapper")
    func matchesTheDownloadedClientOnly() {
        let listing = """
          501 /Applications/Steam.app/Contents/MacOS/steam_osx
          822 /Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx
          913 /Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ipcserver
        """

        #expect(HostSteamProcess.parseProcessIdentifiers(from: listing) == [822])
    }

    @Test("A listing with no client yields nothing")
    func matchesNothingWhenNotRunning() {
        let listing = """
          501 /usr/bin/login
          822 /Applications/Whisky Preview.app/Contents/MacOS/Whisky Preview
        """

        #expect(HostSteamProcess.parseProcessIdentifiers(from: listing).isEmpty)
    }

    @Test("A line that is not a process is skipped rather than misread")
    func survivesAMalformedListing() {
        #expect(HostSteamProcess.parseProcessIdentifiers(from: "PID COMMAND\n\n   \n").isEmpty)
    }

    @Test("Quitting when nothing is running is not an error")
    func quitIsIdempotent() async throws {
        guard !HostSteamProcess.isRunning() else { return }

        try await HostSteamProcess.quit()
    }
}
