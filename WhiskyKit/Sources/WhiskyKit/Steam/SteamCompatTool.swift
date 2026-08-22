//
//  SteamCompatTool.swift
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

/// Errors thrown while installing Whisky as a Steam compatibility tool.
public enum SteamCompatToolError: LocalizedError, Equatable {
    /// The macOS Steam client is not installed.
    case steamNotInstalled
    /// The runner the tool manifest points at is missing.
    case runnerMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .steamNotInstalled:
            String(localized: "steam.compattool.error.noClient")
        case let .runnerMissing(url):
            String(localized: "steam.compattool.error.runnerMissing \(url.lastPathComponent)")
        }
    }
}

/// Whisky, presented to the macOS Steam client as a compatibility tool.
///
/// This is the shape Steam already knows how to drive: it picks a tool for a
/// title, runs the tool's command line with the game's executable appended, and
/// hands it a `STEAM_COMPAT_*` environment describing where the game lives and
/// where its prefix should go. The game then belongs to Steam the way a native
/// one does, which is what the overlay and the Steam API need and what a launch
/// started behind Steam's back can never have.
///
/// Two things sit between this and working, and neither is here:
///
/// - the client only scans directories named in `STEAM_EXTRA_COMPAT_TOOLS_PATHS`,
///   never `<steam>/compatibilitytools.d` on its own, so Whisky has to be the
///   thing that starts Steam
/// - the client decides at startup whether tools are usable at all, and that
///   decision is a string compare against `"linux"` in `CCompatManager`'s
///   constructor. Until that is dealt with the tool registers, is listed, and
///   is never called
public enum SteamCompatTool {
    /// The internal name Steam records in `config.vdf` mappings.
    public static let name = "whisky"
    /// The name shown in the client's tool list.
    public static let displayName = "Whisky"

    /// The directory the client scans, which it needs pointing at explicitly.
    public static func toolsDirectory(steamRoot: URL = HostSteam.defaultRoot) -> URL {
        steamRoot.appending(path: "compatibilitytools.d")
    }

    /// Where this tool's own files live.
    public static func toolDirectory(steamRoot: URL = HostSteam.defaultRoot) -> URL {
        toolsDirectory(steamRoot: steamRoot).appending(path: name)
    }

    /// The name of the runner inside the tool directory.
    static let runnerName = "whisky-run"

    // MARK: - Manifests

    /// The file that tells the client this directory holds a tool.
    ///
    /// `to_oslist` has to read exactly `macos`. The client rejects `osx`, and it
    /// rejects the key being absent, which was measured against three tools
    /// installed side by side that differed in nothing else.
    public static func compatibilityToolManifest() -> String {
        VDFWriter.serialize(["compatibilitytools": .object(["compat_tools": .object([
            name: .object([
                "install_path": .string("."),
                "display_name": .string(displayName),
                "from_oslist": .string("windows"),
                "to_oslist": .string("macos")
            ])
        ])])])
    }

    /// The file that tells the client how to invoke the tool.
    ///
    /// `waitforexitandrun` is the verb that makes Steam wait for the game
    /// rather than for the launcher, which is what keeps playtime and the
    /// "currently playing" state honest.
    public static func toolManifest() -> String {
        VDFWriter.serialize(["manifest": .object([
            "version": .string("2"),
            "commandline": .string("/\(runnerName) waitforexitandrun"),
            "compatmanager_layer_name": .string(name)
        ])])
    }

    /// The runner Steam executes, which forwards to Whisky's own launcher.
    ///
    /// Steam appends a verb and then the game's command line, and describes the
    /// rest through the environment. `STEAM_COMPAT_APP_ID` is the identity
    /// Whisky resolves a bottle and a GameDB profile from, so it is the one
    /// piece that has to survive; the executable path is passed through as
    /// given because Steam has already resolved it.
    ///
    /// The runner stays in the foreground for the whole session. Steam treats
    /// the process it spawned as the game, so returning early would end the
    /// session the moment the game started.
    static func runner(whiskyCmd: URL) -> String {
        """
        #!/bin/bash
        # Written by Whisky. Steam runs this as the compatibility tool for a
        # Windows title, with the verb first and the game's command line after.
        set -uo pipefail

        verb="${1:-run}"
        shift || true

        log="${TMPDIR:-/tmp}/whisky-compat-tool.log"
        { echo "=== $(date) verb=$verb appid=${STEAM_COMPAT_APP_ID:-none}"
          echo "    argv: $*"; } >> "$log"

        case "$verb" in
          getcompatpath|getnativepath)
            # Path translation questions, asked before a launch. Whisky exposes
            # the whole filesystem to the prefix, so a path is already itself.
            echo "$1"
            exit 0
            ;;
        esac

        exec \(shellQuoted(whiskyCmd.path(percentEncoded: false))) \\
             steam-compat-run "${STEAM_COMPAT_APP_ID:-0}" -- "$@"
        """
    }

    // MARK: - Installing

    /// Writes the tool into the client's tools directory.
    ///
    /// - Parameters:
    ///   - whiskyCmd: The `WhiskyCmd` binary the runner forwards to.
    ///   - steamRoot: The macOS Steam data directory.
    /// - Throws: ``SteamCompatToolError``.
    public static func install(
        whiskyCmd: URL, steamRoot: URL = HostSteam.defaultRoot
    ) throws {
        guard HostSteam.installRoot(at: steamRoot) != nil else {
            throw SteamCompatToolError.steamNotInstalled
        }
        guard FileManager.default.fileExists(atPath: whiskyCmd.path(percentEncoded: false)) else {
            throw SteamCompatToolError.runnerMissing(whiskyCmd)
        }

        let directory = toolDirectory(steamRoot: steamRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try compatibilityToolManifest().write(
            to: directory.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8
        )
        try toolManifest().write(
            to: directory.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8
        )

        let runnerURL = directory.appending(path: runnerName)
        try runner(whiskyCmd: whiskyCmd).write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: runnerURL.path(percentEncoded: false)
        )
    }

    /// Whether the tool is installed and its runner is executable.
    public static func isInstalled(steamRoot: URL = HostSteam.defaultRoot) -> Bool {
        let directory = toolDirectory(steamRoot: steamRoot)
        let runner = directory.appending(path: runnerName).path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: directory.appending(
            path: "compatibilitytool.vdf"
        ).path(percentEncoded: false))
            && FileManager.default.isExecutableFile(atPath: runner)
    }

    /// Removes the tool, leaving any other tool in the directory alone.
    public static func remove(steamRoot: URL = HostSteam.defaultRoot) throws {
        let directory = toolDirectory(steamRoot: steamRoot)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// The environment Steam has to be started with for the tool to be found.
    ///
    /// The client does not scan its own `compatibilitytools.d` on macOS. It
    /// scans what this variable names and nothing else, which is why Whisky has
    /// to be what starts Steam.
    public static func launchEnvironment(steamRoot: URL = HostSteam.defaultRoot) -> [String: String] {
        ["STEAM_EXTRA_COMPAT_TOOLS_PATHS": toolsDirectory(steamRoot: steamRoot)
            .path(percentEncoded: false)]
    }

    /// The variables a game needs kept from the environment Steam started the
    /// tool in.
    ///
    /// A game launched through a compatibility tool reaches the Steam API
    /// because Steam described the session in the environment before running
    /// the tool. Building a fresh environment for the game and dropping that
    /// would leave it unable to find the client it was launched by, which is
    /// the whole reason to be a compatibility tool rather than a launcher.
    ///
    /// Everything Steam names is passed through rather than a chosen subset,
    /// because the set has grown with every client and a variable missed here
    /// fails silently inside the game.
    public static func passthroughEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.filter { $0.key.lowercased().hasPrefix("steam") }
    }

    /// Wraps a value in single quotes for safe shell interpolation.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
