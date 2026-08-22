//
//  HostSteam.swift
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

/// The Steam client installed on macOS itself, as opposed to the Windows client
/// inside a bottle.
///
/// It is here because it can download Windows depots that the bottle's client
/// would otherwise have to fetch through Wine's networking. Its console takes
/// `@sSteamCmdForcePlatformType windows` followed by `app_install <appid>`, and
/// both are needed: without the platform override the manifest is written and
/// nothing is downloaded. What it will not do is launch what it downloaded,
/// because it refuses a Windows launch config with `AppError_29`.
///
/// So the useful arrangement is a library folder both clients can see: the
/// macOS client fills it, and the bottle's client launches out of it. See
/// ``SharedSteamLibrary``.
public enum HostSteam {
    /// Where the macOS Steam client keeps its data.
    public static let defaultRoot = URL.homeDirectory
        .appending(path: "Library")
        .appending(path: "Application Support")
        .appending(path: "Steam")

    /// The macOS Steam data directory, or `nil` when Steam is not installed.
    ///
    /// This is the data directory rather than `Steam.app`, because it is the
    /// one that holds the library configuration.
    public static func installRoot(at root: URL = defaultRoot) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.appending(path: "steamapps").path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else { return nil }
        return root
    }

    /// Every library folder the macOS client is configured to use, the data
    /// directory itself first.
    ///
    /// Unlike the bottle's copy, these paths are already POSIX, so nothing has
    /// to be mapped through the prefix.
    ///
    /// - Parameter root: The macOS Steam data directory. Defaults to the
    ///   standard location.
    /// - Returns: Existing directories, de-duplicated, empty if Steam is not
    ///   installed.
    public static func libraryFolders(at root: URL = defaultRoot) -> [URL] {
        guard let steamRoot = installRoot(at: root) else { return [] }

        var folders = [steamRoot]
        var seen: Set<String> = [steamRoot.standardizedFileURL.path]

        for candidate in libraryFolderFiles(steamRoot: steamRoot) {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8),
                  let parsed = try? VDFParser.parse(text),
                  let entries = parsed["libraryfolders"]?.objectValue
            else { continue }

            for entry in entries.values {
                guard let path = entry.objectValue?["path"]?.stringValue, path.hasPrefix("/") else { continue }
                let url = URL(filePath: path).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard !seen.contains(url.path),
                      FileManager.default.fileExists(
                          atPath: url.path(percentEncoded: false), isDirectory: &isDirectory
                      ), isDirectory.boolValue
                else { continue }
                seen.insert(url.path)
                folders.append(url)
            }
        }

        return folders
    }

    /// The two places Steam keeps `libraryfolders.vdf`.
    ///
    /// Current clients treat `config/` as the authority and mirror it into
    /// `steamapps/`, older ones only ever wrote `steamapps/`. Reading both and
    /// taking the union costs nothing; writing has to keep whichever already
    /// exist in step, which is what ``SharedSteamLibrary`` does.
    static func libraryFolderFiles(steamRoot: URL) -> [URL] {
        [
            steamRoot.appending(path: "config").appending(path: "libraryfolders.vdf"),
            steamRoot.appending(path: "steamapps").appending(path: "libraryfolders.vdf")
        ]
    }
}
