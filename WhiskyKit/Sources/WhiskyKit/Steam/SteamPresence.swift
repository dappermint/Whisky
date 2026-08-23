//
//  SteamPresence.swift
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

/// Makes Steam look present inside a bottle for the length of a session.
///
/// ``SteamCompatTool`` points the prefix at the bridge, which is what lets a
/// game reach the macOS client, and a game that first asks whether Steam is
/// *running* never gets that far. That question is answered by a live process
/// id in `ActiveProcess\pid` and by a window of class `vguiPopupWindow`,
/// neither of which goes through the Steamworks API and neither of which
/// anything in a Whisky bottle provided. Proton answers both from its
/// `steam.exe` stub, which its games are children of.
///
/// The helper is built from `scripts/steam-presence` and shipped as a resource.
/// It runs out of the bundle rather than being installed into the bottle, so a
/// prefix keeps no trace of it.
public enum SteamPresence {
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamPresence")

    /// The helper binary's name, without its extension.
    public static let executableName = "WhiskySteamPresence"

    /// The bundled helper, or `nil` if the resource is missing from this build.
    public static var executableURL: URL? {
        Bundle.module.url(forResource: executableName, withExtension: "exe")
    }

    /// The environment keys that mean Steam described this launch.
    ///
    /// Both are set by the client for a game it starts, and Proton's stub keys
    /// its own setup on `SteamGameId` for the same reason: a program Whisky
    /// launched on its own has no Steam session to look present for.
    static let sessionKeys = ["SteamGameId", "SteamAppId"]

    /// Whether `environment` describes a game the Steam client launched.
    public static func isSteamSession(_ environment: [String: String]) -> Bool {
        sessionKeys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty && value != "0"
        }
    }

    /// The arguments that run the helper in a bottle.
    static func launchArguments(executableURL: URL) -> [String] {
        ["start", "/unix", executableURL.path(percentEncoded: false)]
    }

    /// Starts the helper for `bottle` when `environment` names a Steam session.
    ///
    /// Safe to call on every launch: the helper holds a named mutex and a
    /// second copy exits immediately, and the one that stays rewrites the
    /// process id, so a stale one left by an earlier session is replaced.
    /// Failures are logged rather than thrown, because a game that does not
    /// check for Steam must not be stopped by a helper that could not start.
    @MainActor
    public static func start(for bottle: Bottle, environment: [String: String]) {
        guard isSteamSession(environment) else { return }

        guard let executableURL else {
            logger.error("The Steam presence helper is missing from this build")
            return
        }

        do {
            let output = try Wine.runWineProcess(
                name: "\(executableName).exe",
                args: launchArguments(executableURL: executableURL),
                bottle: bottle
            )
            // `start /unix` returns once the helper is running, so this drains a
            // stream that is already finishing rather than the helper's own life.
            Task { for await _ in output {} }
        } catch {
            logger.error(
                "Could not start the Steam presence helper: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
