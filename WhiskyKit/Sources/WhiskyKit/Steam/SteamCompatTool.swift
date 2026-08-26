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
    /// The runner the tool manifest points at is missing.
    case runnerMissing(URL)
    /// The directory the client scans is not writable, which it is not until
    /// somebody with an administrator password says so.
    case directoryNotWritable(URL)

    public var errorDescription: String? {
        switch self {
        case let .runnerMissing(url):
            String(localized: "steam.compattool.error.runnerMissing \(url.lastPathComponent)")
        case .directoryNotWritable:
            String(localized: "steam.compattool.error.notWritable")
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
/// Where it goes matters more than it looks. The client never scans
/// `<steam>/compatibilitytools.d` on macOS, which is the directory every guide
/// names, but it does scan `/usr/local/share/steam/compatibilitytools.d`
/// unconditionally. A tool there is found however Steam was started, including
/// from the Dock, which is the difference between this working and Whisky
/// having to be what launches Steam.
///
/// The client also decides at startup whether tools are usable at all, and that
/// decision is a string compare in `CCompatManager`'s constructor. Until
/// ``SteamClientPatch`` has dealt with it the tool registers, is listed, and is
/// never called.
public enum SteamCompatTool {
    /// The internal name Steam records in `config.vdf` mappings.
    /// The identifier the client keys the tool by, which has to contain `proton`.
    ///
    /// The client only maps `WinSavedGames` and the rest of the Windows roots
    /// into `pfx/drive_c/users/steamuser` when a case insensitive substring
    /// search for `proton` hits this name. Miss it and every cloud file is
    /// skipped with "failed to resolve path", which reads like a server fault
    /// rather than a manifest one. The same test puts `STEAM_COMPAT_PROTON` in
    /// the game's environment, which is true of us in the sense it means: we
    /// answer the same contract.
    ///
    /// This is also the string the client writes into the per app mappings in
    /// `config.vdf`, so changing it orphans every game already set to run
    /// through us. `migrateMappings(in:from:)` is what carries them over.
    public static let name = "whisky-proton"

    /// The identifier used before the client's `proton` test was understood.
    public static let previousName = "whisky"
    /// The name shown in the client's tool list.
    public static let displayName = "Whisky"

    /// The one directory the macOS client scans on its own.
    ///
    /// Not `<steam>/compatibilitytools.d`, which is the obvious place and is
    /// never read. This path is compiled into the client alongside
    /// `/usr/share/steam/compatibilitytools.d`, and unlike the environment
    /// variable it needs nothing from whoever starts Steam.
    public static let sharedToolsDirectory = URL(filePath: "/usr/local/share/steam/compatibilitytools.d")

    /// The directory the client scans.
    public static func toolsDirectory(at root: URL = sharedToolsDirectory) -> URL { root }

    /// Where this tool's own files live.
    public static func toolDirectory(at root: URL = sharedToolsDirectory) -> URL {
        root.appending(path: name)
    }

    /// The name of the runner inside the tool directory.
    static let runnerName = "whisky-run"

    // MARK: - Manifests

    /// The file that tells the client this directory holds a tool.
    ///
    /// `to_oslist` has to read exactly `macos`. The client rejects `osx`, and it
    /// rejects the key being absent, which was measured against three tools
    /// installed side by side that differed in nothing else.
    public static func compatibilityToolManifest(
        for runtime: String? = nil, label: String? = nil
    ) -> String {
        VDFWriter.serialize(["compatibilitytools": .object(["compat_tools": .object([
            name(for: runtime): .object([
                "install_path": .string("."),
                "display_name": .string(displayName(for: runtime, label: label)),
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
    public static func toolManifest(for runtime: String? = nil) -> String {
        VDFWriter.serialize(["manifest": .object([
            "version": .string("2"),
            "commandline": .string("/\(runnerName) waitforexitandrun"),
            "compatmanager_layer_name": .string(name(for: runtime))
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
    static func runner(whiskyCmd: URL, runtime: String? = nil) -> String {
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

        case "${1:-}" in
          *iscriptevaluator.exe)
            # The client asks the tool to run a game's install script through
            # this, and then does not ship the binary: the legacycompat
            # directory it names is created empty on every macOS install. Wine
            # answers "failed to open", the client reads the nonzero exit as a
            # failed launch step and puts a sync warning in front of every game.
            # Nothing is skipped by answering here that was ever going to run.
            exit 0
            ;;
        esac

        exec \(shellQuoted(whiskyCmd.path(percentEncoded: false))) \\
             steam-compat-run "${STEAM_COMPAT_APP_ID:-0}"\(runtimeArgument(runtime)) -- "$@"
        """
    }

    // MARK: - Installing

    /// Writes the tool into the client's tools directory.
    ///
    /// - Parameters:
    ///   - whiskyCmd: The `WhiskyCmd` binary the runner forwards to.
    ///   - root: The directory the client scans.
    /// - Throws: ``SteamCompatToolError``.
    public static func install(
        whiskyCmd: URL, runtime: String? = nil, label: String? = nil, at root: URL = sharedToolsDirectory
    ) throws {
        guard FileManager.default.fileExists(atPath: whiskyCmd.path(percentEncoded: false)) else {
            throw SteamCompatToolError.runnerMissing(whiskyCmd)
        }
        guard isWritable(root) else { throw SteamCompatToolError.directoryNotWritable(root) }

        if runtime == nil { try removePreviousInstall(at: root) }

        let directory = toolDirectory(for: runtime, at: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try compatibilityToolManifest(for: runtime, label: label).write(
            to: directory.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8
        )
        try toolManifest(for: runtime).write(
            to: directory.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8
        )

        let runnerURL = directory.appending(path: runnerName)
        try runner(whiskyCmd: whiskyCmd, runtime: runtime).write(
            to: runnerURL, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: runnerURL.path(percentEncoded: false)
        )
    }

    /// Clears an install left under the identifier we used before.
    ///
    /// The directory is named after the identifier, so a rename leaves the old
    /// one in place and the client lists two tools that both claim to be us.
    static func removePreviousInstall(at root: URL) throws {
        let stale = root.appending(path: previousName)
        guard stale != toolDirectory(at: root),
              FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)),
              FileManager.default.fileExists(
                  atPath: stale.appending(path: runnerName).path(percentEncoded: false)
              )
        else { return }

        try FileManager.default.removeItem(at: stale)
    }

    /// Whether the directory the client scans exists and can be written to.
    ///
    /// It lives under `/usr/local`, which is root-owned until somebody makes it
    /// otherwise, so this is the thing to check before offering to install
    /// rather than a failure to explain afterwards.
    public static func isWritable(_ root: URL = sharedToolsDirectory) -> Bool {
        let path = root.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            return FileManager.default.isWritableFile(atPath: path)
        }
        let parent = root.deletingLastPathComponent().path(percentEncoded: false)
        return FileManager.default.isWritableFile(atPath: parent)
    }

    /// The command that makes the directory writable, which needs an
    /// administrator and so is the user's to run.
    public static func prepareCommand(for root: URL = sharedToolsDirectory) -> String {
        let path = root.path(percentEncoded: false)
        return "sudo mkdir -p \(path) && sudo chown -R \"$(whoami)\" \(path)"
    }

    /// Whether the tool is installed and its runner is executable.
    public static func isInstalled(at root: URL = sharedToolsDirectory) -> Bool {
        let directory = toolDirectory(at: root)
        let runner = directory.appending(path: runnerName).path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: directory.appending(
            path: "compatibilitytool.vdf"
        ).path(percentEncoded: false))
            && FileManager.default.isExecutableFile(atPath: runner)
    }

    /// Removes the tool, leaving any other tool in the directory alone.
    public static func remove(at root: URL = sharedToolsDirectory) throws {
        let directory = toolDirectory(at: root)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// Makes the bottle reachable at the path Steam expects a prefix to be.
    ///
    /// Steam allocates `compatdata/<appid>` per game and resolves cloud save
    /// paths inside `pfx` there. Whisky runs the game in its own bottle
    /// instead, because that is where the backend, the GameDB profile and the
    /// per-program overrides live, so Steam looks in an empty directory, finds
    /// no saves, and reports that it could not sync.
    ///
    /// Two links close the gap without moving anything. `pfx` points at the
    /// bottle, and `steamuser` points at the account the bottle actually uses,
    /// because Steam resolves save paths through a user of that name and Wine
    /// on macOS names it after the person logged in.
    ///
    /// - Parameters:
    ///   - bottleURL: The bottle the game runs in.
    ///   - compatDataPath: What Steam passed as `STEAM_COMPAT_DATA_PATH`.
    public static func linkPrefix(bottleURL: URL, compatDataPath: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: compatDataPath, withIntermediateDirectories: true)

        try replaceSymbolicLink(at: compatDataPath.appending(path: "pfx"), with: bottleURL)

        let users = bottleURL.appending(path: "drive_c").appending(path: "users")
        guard let account = bottleAccount(in: users) else { return }
        try replaceSymbolicLink(
            at: users.appending(path: steamUser), with: users.appending(path: account)
        )
    }

    /// The user Steam resolves a Windows save path through.
    static let steamUser = "steamuser"

    /// The account a bottle keeps its files under.
    ///
    /// Wine on macOS names it after whoever is logged in, and older prefixes
    /// use `crossover`. Backups and the shared account are not it.
    static func bottleAccount(in users: URL, preferring name: String = NSUserName()) -> String? {
        let fileManager = FileManager.default
        let candidates = [name, "crossover"]
        for candidate in candidates where fileManager.fileExists(
            atPath: users.appending(path: candidate).path(percentEncoded: false)
        ) {
            return candidate
        }
        return nil
    }

    /// Points a link at a target, replacing whatever was there.
    ///
    /// Checked without following, so a link left over from a bottle that has
    /// since moved is replaced rather than reported as already existing.
    static func replaceSymbolicLink(at link: URL, with target: URL) throws {
        let path = link.path(percentEncoded: false)
        let destination = target.path(percentEncoded: false)

        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            if existing == destination { return }
            try FileManager.default.removeItem(at: link)
        } else if (try? link.checkResourceIsReachable()) == true {
            // Something real is in the way. Steam made an empty directory here
            // and replacing that is the point; anything else is left alone.
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            guard contents.isEmpty else { return }
            try FileManager.default.removeItem(at: link)
        }

        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
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
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        clientLibrary directory: URL? = clientLibraryDirectory()
    ) -> [String: String] {
        var passed = environment.filter { $0.key.lowercased().hasPrefix("steam") }
        if let directory { passed[clientInstallPathKey] = directory.path(percentEncoded: false) }
        return passed
    }

    /// What the bridge reads to find the native client's library.
    static let clientInstallPathKey = "STEAM_COMPAT_CLIENT_INSTALL_PATH"

    /// The directory holding `steamclient.dylib`, or nil when it is not there.
    ///
    /// `lsteamclient` dlopens `$STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib`,
    /// so this has to be the directory the library actually sits in, not the
    /// Steam install root the variable names on Linux. macOS keeps it inside
    /// the app bundle the client downloads for itself, which is why the value
    /// Steam sets for us is the wrong one and gets replaced.
    public static func clientLibraryDirectory(
        steamRoot: URL = HostSteam.defaultRoot
    ) -> URL? {
        let directory = steamRoot
            .appending(path: "Steam.AppBundle")
            .appending(path: "Steam")
            .appending(path: "Contents")
            .appending(path: "MacOS")
        let library = directory.appending(path: "steamclient.dylib")

        guard FileManager.default.fileExists(atPath: library.path(percentEncoded: false)) else {
            return nil
        }
        return directory
    }

    /// Wraps a value in single quotes for safe shell interpolation.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
