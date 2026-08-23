//
//  SteamCompatTool+Prefix.swift
//  WhiskyKit
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

/// What the prefix has to hold before a game the macOS client launched starts.
///
/// The bridge is the part a game reaches through the Steamworks API.
/// ``SteamHelper`` is the part it reaches while it is starting. This is the
/// third part: the things a game reads straight out of the prefix, which no
/// process can answer because they have to be there already.
///
/// Everything here is written only when it is missing, which is what keeps a
/// bottle that also has the Windows client installed intact: that client owns
/// these values, writes better ones, and would be undone by a blind overwrite.
/// The bridge itself is the exception, because it has to point at us.
public extension SteamCompatTool {
    /// Where the prefix believes Steam is installed.
    ///
    /// The real client writes this path lowercased with forward slashes, so
    /// this does too. A game comparing it against something of its own then has
    /// the client's spelling to compare against rather than ours.
    static let steamPathValue = "c:/program files (x86)/steam"
    /// Where the prefix believes the client's executable is.
    static let steamExeValue = "c:/program files (x86)/steam/steam.exe"
    /// The key holding what a game reads to find the client.
    static let steamKey = #"HKCU\Software\Valve\Steam"#

    /// Seeds the prefix for a launch, in one registry import.
    ///
    /// - Parameters:
    ///   - bottle: The bottle the game runs in.
    ///   - environment: What Steam described the session with.
    ///   - steamRoot: The macOS client's data directory.
    @MainActor
    static func seedPrefix(
        bottle: Bottle,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        steamRoot: URL = HostSteam.defaultRoot
    ) async throws {
        writeClientFiles(bottleURL: bottle.url, environment: environment)

        let values = missingPrefixValues(
            bottleURL: bottle.url, accountID: steamAccountID(steamRoot: steamRoot)
        )
        guard !values.isEmpty else { return }

        try await importRegistry(document: registryDocument(for: values), bottle: bottle)
    }
}

extension SteamCompatTool {
    /// One value, as a `.reg` file writes it. An empty `name` is the key's
    /// default value.
    struct PrefixValue: Equatable, Sendable {
        let key: String
        let name: String
        let literal: String
    }

    // MARK: - Registry

    /// The values this launch has to add, leaving anything already set alone.
    ///
    /// `SteamClientDll` and `SteamClientDll64` are the exception: they have to
    /// name the bridge, whatever they named before. A bottle that has had the
    /// Windows client installed points them at that client, and a game reading
    /// them then talks to a client that is not running.
    static func missingPrefixValues(bottleURL: URL, accountID: UInt32?) -> [PrefixValue] {
        var values: [PrefixValue] = []

        if !bridgeIsInstalled(bottleURL: bottleURL) {
            values.append(PrefixValue(
                key: activeProcessKey, name: "SteamClientDll64", literal: quoted(bridgePath)
            ))
            values.append(PrefixValue(
                key: activeProcessKey, name: "SteamClientDll", literal: quoted(bridgePath32)
            ))
        }

        // `steam_api` prefers the registry and falls back to resolving
        // `steamclient64.dll` against `SteamPath`. A clean bottle gives it
        // nothing to fall back to.
        for (name, value) in [("SteamPath", steamPathValue), ("SteamExe", steamExeValue)]
            where WineRegistryFile.readValue(bottleURL: bottleURL, key: steamKey, valueName: name) == nil {
            values.append(PrefixValue(key: steamKey, name: name, literal: quoted(value)))
        }

        // The account id a game reads to decide somebody is signed in. Proton
        // does not write it either, so a title that checks fails the same way
        // there; the macOS client knows the answer, so there is no reason to.
        if let accountID, WineRegistryFile.readValue(
            bottleURL: bottleURL, key: activeProcessKey, valueName: "ActiveUser"
        ) == nil {
            values.append(PrefixValue(
                key: activeProcessKey, name: "ActiveUser",
                literal: String(format: "dword:%08x", accountID)
            ))
        }

        values.append(contentsOf: protocolHandler(bottleURL: bottleURL))
        return values
    }

    /// The `steam://` handler, pointed at Wine's own URL forwarder.
    ///
    /// A game or launcher that opens a `steam://` URL inside the prefix is
    /// asking the client to do something, and the client is on macOS.
    /// `winebrowser` hands a scheme it does not know to `/usr/bin/open`, which
    /// is how it gets there. Skipped when the bottle has its own Windows
    /// client, since that one registers the scheme and should answer it.
    static func protocolHandler(bottleURL: URL) -> [PrefixValue] {
        guard SteamLibrary.detectInstall(bottleURL: bottleURL) == nil else { return [] }

        let scheme = #"HKEY_CLASSES_ROOT\steam"#
        return [
            PrefixValue(key: scheme, name: "", literal: quoted("URL:steam protocol")),
            PrefixValue(key: scheme, name: "URL Protocol", literal: quoted("")),
            PrefixValue(
                key: #"HKEY_CLASSES_ROOT\steam\shell\open\command"#, name: "",
                literal: quoted(#""C:\windows\system32\winebrowser.exe" "%1""#)
            )
        ]
    }

    /// Renders values as a `.reg` document, grouped by key in the order given.
    static func registryDocument(for values: [PrefixValue]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var keys: [String] = []
        for value in values where !keys.contains(value.key) {
            keys.append(value.key)
        }

        for key in keys {
            lines.append("[\(key)]")
            for value in values where value.key == key {
                lines.append("\(value.name.isEmpty ? "@" : "\"\(value.name)\"")=\(value.literal)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    @MainActor
    static func importRegistry(document: String, bottle: Bottle) async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "whisky-steam-prefix-\(UUID().uuidString).reg")
        // Wine detects a Unicode `.reg` by its BOM alone, and `.utf16LittleEndian`
        // writes none, so the file parses as ANSI and imports nothing while
        // exiting 0.
        try ("\u{FEFF}" + document).write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        try await Wine.runWine(["reg", "import", url.path(percentEncoded: false)], bottle: bottle)
    }

    /// Escapes a string for a `.reg` value.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return "\"\(escaped)\""
    }

    // MARK: - The account

    /// The Steam account id of whoever the macOS client last signed in as.
    ///
    /// `ActiveUser` holds the 32-bit account id, and `loginusers.vdf` is keyed
    /// by the 64-bit ID, which is that id plus a constant describing the kind
    /// of account and the universe it belongs to.
    static func steamAccountID(steamRoot: URL = HostSteam.defaultRoot) -> UInt32? {
        let individualBase: UInt64 = 76_561_197_960_265_728
        let url = steamRoot.appending(path: "config").appending(path: "loginusers.vdf")

        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? VDFParser.parse(text),
              let users = parsed["users"]?.objectValue
        else { return nil }

        let signedIn = { (flag: String) in
            users.first { $0.value.objectValue?[flag]?.stringValue == "1" }
        }
        let chosen = signedIn("mostrecent") ?? signedIn("autologin")
            ?? users.sorted { $0.key < $1.key }.first

        guard let id = chosen.flatMap({ UInt64($0.key) }), id > individualBase else { return nil }
        return UInt32(truncatingIfNeeded: id - individualBase)
    }

    // MARK: - The client directory

    /// Puts the files a game expects to find beside the client into the prefix.
    ///
    /// Only `libraryfolders.vdf` matters in practice: a game that wants to know
    /// where its own depot went reads it, and Steam describes the folders in
    /// the environment rather than in anything the prefix can see. Skipped
    /// entirely when the bottle has a real Windows client, which owns the
    /// directory and keeps a better copy.
    static func writeClientFiles(bottleURL: URL, environment: [String: String]) {
        guard SteamLibrary.detectInstall(bottleURL: bottleURL) == nil else { return }

        let folders = libraryFolders(for: environment, bottleURL: bottleURL)
        guard !folders.isEmpty else { return }

        let fileManager = FileManager.default
        let root = bottleURL.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let steamapps = root.appending(path: "steamapps")

        try? fileManager.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: root.appending(path: "config"), withIntermediateDirectories: true
        )

        let document = VDFWriter.serialize(["LibraryFolders": .object(
            Dictionary(uniqueKeysWithValues: folders.enumerated().map { index, path in
                (String(index), VDFValue.object(["path": .string(path)]))
            })
        )])
        try? document.write(
            to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8
        )
    }

    /// The library folders Steam named, as Windows paths.
    ///
    /// `STEAM_COMPAT_LIBRARY_PATHS` names each folder's `steamapps/common`
    /// rather than the folder itself, which is what Proton reads too, so every
    /// entry is walked back up to the library root.
    static func libraryFolders(for environment: [String: String], bottleURL: URL) -> [String] {
        var roots: [URL] = []
        if let install = environment[clientInstallPathKey], !install.isEmpty {
            roots.append(URL(filePath: install))
        }
        for path in (environment["STEAM_COMPAT_LIBRARY_PATHS"] ?? "").split(separator: ":") {
            var folder = URL(filePath: String(path))
            while ["common", "steamapps"].contains(folder.lastPathComponent) {
                folder = folder.deletingLastPathComponent()
            }
            roots.append(folder)
        }

        var seen: Set<String> = []
        return roots.compactMap { SharedSteamLibrary.windowsPath(for: $0, bottleURL: bottleURL) }
            .filter { seen.insert($0).inserted }
    }
}
