//
//  SteamFrontendTests.swift
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

@Suite("SteamFrontend Script Tests")
struct SteamFrontendScriptTests {
    @Test("Both console commands go out, in order, with the folder")
    func installRunsBothCommands() {
        let script = SteamFrontendScript.installWindowsBuild(appId: 365_720, libraryFolder: 1)

        let override = try? #require(script.range(of: "@sSteamCmdForcePlatformType windows"))
        let install = try? #require(script.range(of: "app_install 365720 1"))
        #expect(override != nil)
        #expect(install != nil)
        if let override, let install {
            #expect(override.lowerBound < install.lowerBound, "the override has to precede the install")
        }
    }

    @Test("Clearing the override passes an empty string, not the word empty")
    func clearingTheOverrideIsAnEmptyString() {
        #expect(SteamFrontendScript.clearPlatformOverride().contains(#"@sSteamCmdForcePlatformType \"\""#))
    }

    /// The URL arrives slash-escaped, `whisky:\/\/launch`, because Foundation's
    /// JSON writer escapes forward slashes. That is a valid JavaScript string
    /// literal for the same URL, so these assertions are on the parts that
    /// carry meaning rather than on the exact spelling.
    @Test("A launch carries the App ID Whisky resolves everything else from")
    func launchCarriesTheAppId() {
        let script = SteamFrontendScript.launchThroughWhisky(appId: 553_850)

        #expect(script.contains("whisky:"))
        #expect(script.contains("launch?steam=553850"))
        #expect(!script.contains("&bottle="))
    }

    @Test("A named bottle rides along, percent encoded")
    func launchCarriesTheBottle() {
        let script = SteamFrontendScript.launchThroughWhisky(appId: 553_850, bottle: "Steam (winecx)")

        #expect(script.contains("bottle=Steam%20(winecx)"))
    }

    /// A tool or bottle name reaches a script from user input, so a quote in
    /// one must not be able to end the literal early.
    @Test("A quote in a name cannot escape the string literal")
    func escapesQuotesInNames() {
        let script = SteamFrontendScript.useCompatTool(#"evil", 1); alert("x"#, forAppId: 1)

        #expect(!script.contains(#"alert("x")"#))
        #expect(script.contains(#"\""#))
    }

    @Test("A backslash survives as a backslash")
    func escapesBackslashes() {
        let quoted = SteamFrontendScript.jsonString(#"C:\Games"#)

        #expect(quoted == #""C:\\Games""#)
    }

    @Test("Every script names the App ID it was built for")
    func scriptsCarryTheirAppId() {
        let scripts = [
            SteamFrontendScript.platforms(forAppId: 4_576_510),
            SteamFrontendScript.compatTool(forAppId: 4_576_510),
            SteamFrontendScript.availableCompatTools(forAppId: 4_576_510),
            SteamFrontendScript.useCompatTool("whisky", forAppId: 4_576_510)
        ]

        #expect(scripts.allSatisfy { $0.contains("4576510") })
    }
}

@Suite("SteamFrontend Live Tests")
struct SteamFrontendLiveTests {
    /// Does nothing unless a Steam client started with `-cef-enable-debugging`
    /// is up. It reads only, so it is safe to run against a real client, and it
    /// is the only thing that catches a script that is valid Swift and wrong
    /// JavaScript.
    @Test("Reads platforms and library folders from a running client")
    func readsFromARunningClient() async throws {
        guard await SteamDevTools.isListening() else { return }

        let frontend = SteamFrontend()
        try await frontend.connect()

        // Helldivers 2 has no macOS build; Factorio does.
        #expect(try await frontend.platforms(forAppId: 553_850) == ["windows"])
        #expect(try await frontend.isWindowsOnly(appId: 553_850))
        #expect(try await frontend.isWindowsOnly(appId: 427_520) == false)

        let folders = try await frontend.installFolders()
        #expect(!folders.isEmpty, "a logged-in client always has at least its own folder")
        #expect(folders.allSatisfy { $0.path.hasPrefix("/") })
    }
}

@Suite("SteamFrontend Decoding Tests")
struct SteamFrontendDecodingTests {
    /// The scripts return `JSON.stringify(...)`, so what arrives is a JSON
    /// string holding JSON.
    @Test("Reads a platform list out of its double encoding")
    func decodesPlatforms() throws {
        let arrived = #""[\"windows\",\"osx\",\"linux\"]""#

        #expect(try SteamFrontend.decodeStrings(from: arrived) == ["windows", "osx", "linux"])
    }

    @Test("A Windows-only title decodes to one platform")
    func decodesAWindowsOnlyTitle() throws {
        #expect(try SteamFrontend.decodeStrings(from: #""[\"windows\"]""#) == ["windows"])
    }

    @Test("Nothing readable decodes to nothing, rather than throwing")
    func survivesGarbage() throws {
        #expect(try SteamFrontend.decodeStrings(from: "null").isEmpty)
        #expect(try SteamFrontend.decodeStrings(from: "not json").isEmpty)
    }

    @Test("Unquoting returns the text a JSON string holds")
    func unquotesAValue() {
        #expect(SteamFrontend.unquote(#""hello""#) == "hello")
        #expect(SteamFrontend.unquote("42") == nil)
    }
}
