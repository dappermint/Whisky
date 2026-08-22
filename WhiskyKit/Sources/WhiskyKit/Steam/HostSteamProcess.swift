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

import AppKit
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

/// Starts and stops the macOS Steam client.
///
/// Starting it is only needed for the one thing Steam cannot be asked to do
/// afterwards: accept changes to its interface, which requires
/// `-cef-enable-debugging` at launch. The marker file that turns that on
/// elsewhere does nothing on macOS.
///
/// Finding compatibility tools is deliberately not a reason. A tool installed
/// in the directory ``SteamCompatTool/sharedToolsDirectory`` names is found
/// however Steam was started, so opening it from the Dock works and Whisky
/// stays out of the way.
///
/// The app bundle is opened rather than the binary inside it. Running the inner
/// executable directly skips LaunchServices, which gives Steam a second, generic
/// Dock icon beside the real one and leaves it not answering a normal quit.
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

    /// Where the client is installed, as an app rather than as a binary.
    public static let applicationURL = URL(filePath: "/Applications/Steam.app")

    /// Starts the client the way the Dock does.
    ///
    /// - Parameters:
    ///   - application: The Steam app bundle.
    ///   - debugging: Whether to let Whisky reach the client's interface
    ///     afterwards.
    /// - Throws: ``HostSteamProcessError/clientMissing`` when Steam is not
    ///   installed.
    public static func launch(
        application: URL = applicationURL, debugging: Bool = true
    ) async throws {
        guard FileManager.default.fileExists(atPath: application.path(percentEncoded: false)) else {
            throw HostSteamProcessError.clientMissing
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = debugging ? [debuggingArgument] : []
        configuration.activates = true

        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
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
