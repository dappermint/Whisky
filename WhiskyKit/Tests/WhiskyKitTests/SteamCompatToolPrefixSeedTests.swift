//
//  SteamCompatToolPrefixSeedTests.swift
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

@Suite("SteamCompatTool Prefix Seed Tests")
struct SteamCompatToolPrefixSeedTests {
    // MARK: - Fixtures

    private func makeBottle(userRegistry: String = "", withWindowsClient: Bool = false) throws -> URL {
        let fileManager = FileManager.default
        let bottle = fileManager.temporaryDirectory.appending(path: "prefix_\(UUID().uuidString)")
        let dosdevices = bottle.appending(path: "dosdevices")

        try fileManager.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: dosdevices.appending(path: "z:").path(percentEncoded: false),
            withDestinationPath: "/"
        )
        try userRegistry.write(
            to: bottle.appending(path: "user.reg"), atomically: true, encoding: .utf8
        )

        if withWindowsClient {
            let client = bottle.appending(path: "drive_c")
                .appending(path: "Program Files (x86)").appending(path: "Steam")
            try fileManager.createDirectory(at: client, withIntermediateDirectories: true)
            try Data().write(to: client.appending(path: "steam.exe"))
        }
        return bottle
    }

    private func makeSteamRoot(_ loginUsers: String) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "steam_\(UUID().uuidString)")
        let config = root.appending(path: "config")

        try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        try loginUsers.write(
            to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func names(_ values: [SteamCompatTool.PrefixValue]) -> [String] {
        values.map(\.name)
    }

    // MARK: - What a clean prefix is missing

    /// A bottle that has never had Steam in it answers none of the questions a
    /// game asks before it will talk to the client.
    @Test("A clean prefix is given everything")
    func seedsACleanPrefix() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }

        let values = SteamCompatTool.missingPrefixValues(bottleURL: bottle, accountID: 408_240_426)

        #expect(names(values).contains("SteamClientDll64"))
        #expect(names(values).contains("SteamClientDll"))
        #expect(names(values).contains("SteamPath"))
        #expect(names(values).contains("SteamExe"))
        #expect(names(values).contains("ActiveUser"))
        #expect(values.contains { $0.key.hasPrefix(#"HKEY_CLASSES_ROOT\steam"#) })
    }

    /// The Windows client owns these and writes better ones. Overwriting them
    /// on every launch would leave a bottle that runs both clients worse off
    /// than one that runs either.
    @Test("Values the Windows client already wrote are left alone")
    func leavesExistingValuesAlone() throws {
        let bottle = try makeBottle(userRegistry: """
        [Software\\\\Valve\\\\Steam] 1787393483
        "SteamExe"="c:/program files (x86)/steam/steam.exe"
        "SteamPath"="c:/program files (x86)/steam"

        [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1787480390
        "ActiveUser"=dword:1855412a
        "SteamClientDll64"="C:\\\\windows\\\\system32\\\\lsteamclient.dll"

        """)
        defer { try? FileManager.default.removeItem(at: bottle) }

        let values = SteamCompatTool.missingPrefixValues(bottleURL: bottle, accountID: 408_240_426)

        #expect(names(values).contains("SteamPath") == false)
        #expect(names(values).contains("SteamExe") == false)
        #expect(names(values).contains("ActiveUser") == false)
        #expect(names(values).contains("SteamClientDll64") == false)
    }

    /// A bottle that has had the Windows client installed points these at that
    /// client, and a game reading them talks to a client that is not running.
    @Test("A bridge pointed somewhere else is repointed")
    func repointsAStaleBridge() throws {
        let bottle = try makeBottle(userRegistry: """
        [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1787480390
        "SteamClientDll64"="C:\\\\Program Files (x86)\\\\Steam\\\\steamclient64.dll"

        """)
        defer { try? FileManager.default.removeItem(at: bottle) }

        let values = SteamCompatTool.missingPrefixValues(bottleURL: bottle, accountID: nil)
        let bridge = try #require(values.first { $0.name == "SteamClientDll64" })

        #expect(bridge.literal.contains("lsteamclient.dll"))
    }

    /// A bottle with its own client registers the scheme itself, and that
    /// client is the one that should answer it.
    @Test("The steam:// handler yields to a client in the bottle")
    func yieldsTheProtocolToTheBottleClient() throws {
        let bottle = try makeBottle(withWindowsClient: true)
        defer { try? FileManager.default.removeItem(at: bottle) }

        #expect(SteamCompatTool.protocolHandler(bottleURL: bottle).isEmpty)
    }

    /// Wine hands a scheme it does not know to `/usr/bin/open`, which is how a
    /// `steam://` URL opened inside the prefix reaches the macOS client.
    @Test("The steam:// handler points at Wine's URL forwarder")
    func pointsTheProtocolAtWinebrowser() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }

        let values = SteamCompatTool.protocolHandler(bottleURL: bottle)
        let command = try #require(values.first { $0.key.hasSuffix(#"shell\open\command"#) })

        #expect(command.name.isEmpty)
        #expect(command.literal.contains("winebrowser.exe"))
        #expect(values.contains { $0.name == "URL Protocol" })
    }

    // MARK: - The document

    @Test("A default value is written as @, and a key is not repeated")
    func rendersTheDocument() {
        let document = SteamCompatTool.registryDocument(for: [
            SteamCompatTool.PrefixValue(
                key: #"HKCU\Software\Valve\Steam"#,
                name: "SteamPath",
                literal: "\"c:/steam\""
            ),
            SteamCompatTool.PrefixValue(key: #"HKCR\steam"#, name: "", literal: "\"URL:steam\""),
            SteamCompatTool.PrefixValue(
                key: #"HKCU\Software\Valve\Steam"#,
                name: "SteamExe",
                literal: "\"c:/steam/steam.exe\""
            )
        ])

        #expect(document.hasPrefix("Windows Registry Editor Version 5.00"))
        #expect(document.contains("@=\"URL:steam\""))
        #expect(document.contains("\"SteamPath\"=\"c:/steam\""))
        #expect(document.components(separatedBy: #"[HKCU\Software\Valve\Steam]"#).count == 2)
        // Wine reads `.reg` with CRLF line endings, the way regedit writes them.
        #expect(document.contains("\r\n"))
    }

    @Test("Backslashes in a path survive the escaping")
    func escapesAPath() {
        #expect(SteamCompatTool.quoted(#"C:\windows\system32"#) == #""C:\\windows\\system32""#)
    }

    // MARK: - The account

    /// Checked against a real prefix: account 408240426 is what the client
    /// wrote as `dword:1855412a` for the ID below.
    @Test("The account id is the Steam ID less the individual base")
    func derivesTheAccountID() throws {
        let root = try makeSteamRoot("""
        "users"
        {
            "76561198368506154"
            {
                "AccountName"        "giadiko"
                "MostRecent"        "1"
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamCompatTool.steamAccountID(steamRoot: root) == 408_240_426)
    }

    /// Whoever the client would sign in as is the one a game should see, and an
    /// older client writes `AutoLogin` where a newer one writes `MostRecent`.
    @Test("The signed-in account wins over the others")
    func prefersTheSignedInAccount() throws {
        let root = try makeSteamRoot("""
        "users"
        {
            "76561197960265729"
            {
                "AccountName"        "someone-else"
            }
            "76561198368506154"
            {
                "AccountName"        "giadiko"
                "AutoLogin"        "1"
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamCompatTool.steamAccountID(steamRoot: root) == 408_240_426)
    }

    @Test("A Steam nobody has signed into yields nothing")
    func toleratesAnEmptyLoginList() throws {
        let root = try makeSteamRoot("\"users\"\n{\n}\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamCompatTool.steamAccountID(steamRoot: root) == nil)
        #expect(SteamCompatTool.steamAccountID(steamRoot: URL(filePath: "/nope")) == nil)
    }

    // MARK: - Library folders

    /// Steam names each folder's `steamapps/common` rather than the folder, so
    /// a `libraryfolders.vdf` built from them verbatim points two levels too
    /// deep and finds nothing.
    @Test("A library path is walked back up to its root")
    func walksLibraryPathsToTheirRoot() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }

        let folders = SteamCompatTool.libraryFolders(
            for: ["STEAM_COMPAT_LIBRARY_PATHS": "/Users/me/Games/steamapps/common"],
            bottleURL: bottle
        )

        #expect(folders == [#"Z:\Users\me\Games"#])
    }

    @Test("The client's own directory leads, and a folder is listed once")
    func dedupesLibraryFolders() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }

        let folders = SteamCompatTool.libraryFolders(
            for: [
                "STEAM_COMPAT_CLIENT_INSTALL_PATH": "/Users/me/Steam",
                "STEAM_COMPAT_LIBRARY_PATHS": "/Users/me/Steam/steamapps:/Users/me/Games/steamapps/common"
            ],
            bottleURL: bottle
        )

        #expect(folders == [#"Z:\Users\me\Steam"#, #"Z:\Users\me\Games"#])
    }

    /// The bottle's own client owns this file and keeps a real one.
    @Test("A bottle with its own client keeps its library file")
    func leavesTheBottleClientsLibraryAlone() throws {
        let bottle = try makeBottle(withWindowsClient: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let library = bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam").appending(path: "steamapps")
            .appending(path: "libraryfolders.vdf")

        SteamCompatTool.writeClientFiles(
            bottleURL: bottle, environment: ["STEAM_COMPAT_CLIENT_INSTALL_PATH": "/Users/me/Steam"]
        )

        #expect(FileManager.default.fileExists(atPath: library.path(percentEncoded: false)) == false)
    }

    @Test("A prefix without a client gets one written for it")
    func writesTheLibraryFile() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let library = bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam").appending(path: "steamapps")
            .appending(path: "libraryfolders.vdf")

        SteamCompatTool.writeClientFiles(
            bottleURL: bottle, environment: ["STEAM_COMPAT_CLIENT_INSTALL_PATH": "/Users/me/Steam"]
        )

        let document = try String(contentsOf: library, encoding: .utf8)
        #expect(document.contains("LibraryFolders"))
        #expect(document.contains(#"Z:\\Users\\me\\Steam"#))
    }
}
