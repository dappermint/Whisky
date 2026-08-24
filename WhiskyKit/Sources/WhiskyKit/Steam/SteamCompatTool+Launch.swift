//
//  SteamCompatTool+Launch.swift
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

public extension SteamCompatTool {
    /// What Steam names as the app's install root.
    static let installPathKey = "STEAM_COMPAT_INSTALL_PATH"

    /// The directory a game Steam launched should run in.
    ///
    /// Steam runs a game from its install root, and games take that seriously.
    /// Helldivers 2 is started as `--bundle-dir data` with `data` beside the
    /// root while the executable itself sits in `bin`, so running it from the
    /// executable's own folder leaves it opening a path that is not there and
    /// showing a black window with no error.
    ///
    /// - Parameters:
    ///   - executable: The program being run.
    ///   - environment: What Steam described the session with.
    /// - Returns: The install root when Steam named one, the executable's own
    ///   folder otherwise.
    static func workingDirectory(
        for executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let install = environment[installPathKey], !install.isEmpty else {
            return executable.deletingLastPathComponent()
        }
        return URL(filePath: install)
    }

    /// Where the client keeps the bridge the game's `steam_api` loads.
    static let activeProcessKey = #"HKCU\Software\Valve\Steam\ActiveProcess"#

    /// The bridge, as a path inside the prefix.
    ///
    /// `lsteamclient.dll` is a builtin, so the file in `system32` is only what
    /// the loader matches on before loading the real one out of the runtime.
    static let bridgePath = #"C:\windows\system32\lsteamclient.dll"#
    static let bridgePath32 = #"C:\windows\syswow64\lsteamclient.dll"#

    /// Where a launch names the Wine debug channels it wants.
    ///
    /// `WINEDEBUG` cannot ride in through
    /// ``SteamCompatTool/passthroughEnvironment(from:clientLibrary:)``, which
    /// keeps only what Steam itself named, and the per-program debug preset is
    /// not reachable for a game whose executable lives outside the bottle. So a
    /// launch says what it wants under a name of ours.
    static let debugChannelsKey = "WHISKY_WINEDEBUG"

    /// The debug channels this launch asked for, or nothing.
    ///
    /// Lands at the `programUser` layer, which is above the `fixme-all` the
    /// base layer sets, so whatever is named here is what Wine gets.
    static func diagnosticEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let channels = environment[debugChannelsKey], !channels.isEmpty else { return [:] }
        return ["WINEDEBUG": channels]
    }

    /// Whether the prefix already names the bridge.
    ///
    /// `steam_api64.dll` reads `SteamClientDll64` out of `ActiveProcess`, loads
    /// whatever it names and asks it for `SteamClient020`. A bottle that has
    /// had the Windows client installed in it already has these, pointing at
    /// that install, and a game reading them then talks to a client that is not
    /// running. ``SteamCompatTool/seedPrefix(bottle:environment:steamRoot:)``
    /// is what repoints them.
    ///
    /// Read from the prefix's own `user.reg` rather than through Wine, because
    /// this runs on every launch and a Wine process to answer a question we can
    /// read off disk would be a second of nothing on the way to every game.
    static func bridgeIsInstalled(bottleURL: URL) -> Bool {
        guard let value = WineRegistryFile.readValue(
            bottleURL: bottleURL, key: activeProcessKey, valueName: "SteamClientDll64"
        )
        else { return false }

        return value.replacingOccurrences(of: #"\\"#, with: #"\"#)
            .caseInsensitiveCompare(bridgePath) == .orderedSame
    }
}
