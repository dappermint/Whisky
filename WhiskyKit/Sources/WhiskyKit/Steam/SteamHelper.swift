//
//  SteamHelper.swift
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

/// Stands in for the Steam client inside a bottle, for a game the macOS client
/// launched.
///
/// ``SteamCompatTool`` points the prefix at the bridge, which is what lets a
/// game reach the macOS client through the Steamworks API. Several of the
/// things a game asks first do not go through that API at all: a live process
/// id in `ActiveProcess\pid`, a window of class `vguiPopupWindow`, `SteamPath`
/// and `ValvePlatformMutex` in the environment, and an answer to Steam's DRM
/// start handshake. Nothing in a Whisky bottle provided any of them.
///
/// Proton answers all of it from its `steam.exe` stub, and the reason that
/// works is that the game is the stub's child. This is the same shape: the
/// helper is what Whisky runs, and the game is what the helper runs, so the
/// environment is inherited and the helper lives exactly as long as the
/// session does.
///
/// Built from `scripts/steam-helper` and shipped as a resource, so a prefix
/// keeps no trace of it.
public enum SteamHelper {
    /// The helper binary's name, without its extension.
    public static let executableName = "WhiskySteamHelper"

    /// The bundled helper, or `nil` if the resource is missing from this build.
    public static var executableURL: URL? {
        Bundle.module.url(forResource: executableName, withExtension: "exe")
    }

    /// The environment keys that mean Steam described this launch.
    ///
    /// Both are set by the client for a game it starts, and Proton's stub keys
    /// its own setup on `SteamGameId` for the same reason: a program Whisky
    /// launched on its own has no Steam session to stand in for.
    static let sessionKeys = ["SteamGameId", "SteamAppId"]

    /// Whether `environment` describes a game the Steam client launched.
    public static func isSteamSession(_ environment: [String: String]) -> Bool {
        sessionKeys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty && value != "0"
        }
    }

    /// The command that runs `program` under the helper, or `nil` when it
    /// should be run directly.
    ///
    /// The working directory is passed explicitly rather than inherited. Steam
    /// runs a game from its install root and not from wherever the executable
    /// sits inside it, and with the helper in between there is no longer one
    /// obvious directory to fall into.
    ///
    /// - Parameters:
    ///   - program: The game being run.
    ///   - args: The game's own arguments.
    ///   - workingDirectory: The directory the game should run in.
    ///   - environment: The environment the launch was described with.
    ///   - helperURL: The helper binary. Defaults to the bundled one.
    /// - Returns: The full command, helper first, or `nil` to run directly.
    public static func command(
        program: URL, args: [String], workingDirectory: URL,
        environment: [String: String], helperURL: URL? = executableURL
    ) -> [String]? {
        guard isSteamSession(environment), let helperURL else { return nil }
        // A helper that ran itself would take the presence mutex twice and wait
        // on nothing.
        guard program.lastPathComponent != helperURL.lastPathComponent else { return nil }

        return [
            helperURL.path(percentEncoded: false),
            "--workdir", workingDirectory.path(percentEncoded: false),
            "--exec", program.path(percentEncoded: false)
        ] + args
    }
}
