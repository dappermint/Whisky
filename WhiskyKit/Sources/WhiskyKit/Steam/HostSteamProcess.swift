//
//  HostSteamProcess.swift
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
import os.log

/// Errors thrown while starting or stopping the macOS Steam client.
public enum HostSteamProcessError: LocalizedError, Equatable {
    /// The downloaded client is not where it should be.
    case clientMissing
    /// The client would not stop within the time allowed.
    case didNotQuit

    public var errorDescription: String? {
        switch self {
        case .clientMissing:
            String(localized: "steam.process.error.clientMissing")
        case .didNotQuit:
            String(localized: "steam.process.error.didNotQuit")
        }
    }
}

/// Starts and stops the macOS Steam client on Whisky's terms.
///
/// Whisky has to be what starts Steam, for two reasons that both come from the
/// client rather than from choice. It only looks for compatibility tools in
/// directories named by `STEAM_EXTRA_COMPAT_TOOLS_PATHS`, never in its own
/// `compatibilitytools.d`. And its interface only accepts changes when it was
/// started with `-cef-enable-debugging`; the marker file that turns that on
/// elsewhere does nothing on macOS.
///
/// The binary launched is the downloaded client inside the data directory, not
/// `/Applications/Steam.app`. That one is a bootstrapper which re-execs the
/// real client, and neither an environment nor an argument list survives the
/// hop.
public enum HostSteamProcess {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier, category: "HostSteamProcess"
    )

    /// The argument that makes the client's interface accept changes.
    static let debuggingArgument = "-cef-enable-debugging"

    /// The downloaded client's executable, or `nil` when Steam is not
    /// installed.
    public static func clientBinary(steamRoot: URL = HostSteam.defaultRoot) -> URL? {
        let binary = steamRoot
            .appending(path: "Steam.AppBundle")
            .appending(path: "Steam")
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: "steam_osx")
        return FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false))
            ? binary
            : nil
    }

    /// Whether a client is running, whoever started it.
    public static func isRunning() -> Bool {
        !runningProcessIdentifiers().isEmpty
    }

    /// Whether the running client was started in a way Whisky can drive.
    ///
    /// A client the user opened from the Dock is running without the debugging
    /// argument, so its interface cannot be reached and its compatibility tools
    /// were never scanned. Whisky has to offer to restart it rather than
    /// silently doing nothing.
    public static func isRunningUnderWhisky() async -> Bool {
        guard isRunning() else { return false }
        return await SteamDevTools.isListening()
    }

    /// What the client has to be started with.
    ///
    /// - Parameter compatToolsDirectory: The directory holding Whisky's
    ///   compatibility tool, or `nil` to start without one.
    public static func environment(compatToolsDirectory: URL?) -> [String: String] {
        guard let compatToolsDirectory else { return [:] }
        return ["STEAM_EXTRA_COMPAT_TOOLS_PATHS":
            compatToolsDirectory.path(percentEncoded: false)]
    }

    /// Starts the client.
    ///
    /// - Parameters:
    ///   - steamRoot: The macOS Steam data directory.
    ///   - compatTools: Whether to point the client at Whisky's compatibility
    ///     tool.
    ///   - debugging: Whether to let Whisky reach the client's interface.
    /// - Throws: ``HostSteamProcessError/clientMissing`` when Steam is not
    ///   installed.
    public static func launch(
        steamRoot: URL = HostSteam.defaultRoot,
        compatTools: Bool = true,
        debugging: Bool = true
    ) throws {
        guard let binary = clientBinary(steamRoot: steamRoot) else {
            throw HostSteamProcessError.clientMissing
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = debugging ? [debuggingArgument] : []
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment(
                compatToolsDirectory: compatTools
                    ? SteamCompatTool.toolsDirectory(steamRoot: steamRoot)
                    : nil
            )
        ) { _, new in new }
        // The client detaches on its own and outlives this, so nothing here
        // waits on it or reads its output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        logger.notice("Started the macOS Steam client")
    }

    /// Asks the client to quit, and waits for it to go.
    ///
    /// - Parameter timeout: How long to wait before giving up.
    /// - Throws: ``HostSteamProcessError/didNotQuit`` if it is still running
    ///   when the time is up.
    public static func quit(timeout: TimeInterval = 30) async throws {
        guard isRunning() else { return }

        for pid in runningProcessIdentifiers() {
            kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw HostSteamProcessError.didNotQuit
    }

    /// The pids of any running client.
    ///
    /// Matched on the executable path rather than the process name, because
    /// `steam_osx` is also the bootstrapper's name and killing that one leaves
    /// the client running.
    static func runningProcessIdentifiers() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let listing = String(bytes: data, encoding: .utf8)
        else { return [] }
        process.waitUntilExit()

        return parseProcessIdentifiers(from: listing)
    }

    /// Reads pids out of a `ps` listing, keeping only the downloaded client.
    ///
    /// Separate from running `ps` so the matching can be tested, which matters
    /// because the wrong match here kills the wrong process.
    static func parseProcessIdentifiers(from listing: String) -> [pid_t] {
        listing.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex ..< separator])
            else { return nil }

            let command = trimmed[trimmed.index(after: separator)...]
            guard command.contains("Steam.AppBundle/Steam/Contents/MacOS/steam_osx") else {
                return nil
            }
            return pid
        }
    }
}
