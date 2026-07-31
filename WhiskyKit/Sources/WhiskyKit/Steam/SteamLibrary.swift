//
//  SteamLibrary.swift
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

/// A fully installed Steam game discovered inside a Wine bottle.
public struct SteamGame: Identifiable, Equatable, Sendable {
    public var id: Int { appId }
    /// The Steam App ID.
    public let appId: Int
    /// The display name from the manifest.
    public let name: String
    /// The resolved absolute URL of the game's install directory.
    public let installURL: URL
    /// The full parsed manifest.
    public let manifest: SteamAppManifest
}

/// Discovers a Windows Steam installation inside a Wine bottle and
/// enumerates its installed games across all configured library folders.
public enum SteamLibrary {
    /// Candidate Steam install locations under `drive_c`.
    private static let installCandidates = [
        "Program Files (x86)/Steam",
        "Program Files/Steam"
    ]

    /// Locates the Steam installation inside a bottle.
    ///
    /// - Parameter bottleURL: The root URL of the Wine bottle.
    /// - Returns: The Steam root directory (the one containing `steam.exe`),
    ///   or `nil` if no install is found.
    public static func detectInstall(bottleURL: URL) -> URL? {
        for candidate in installCandidates {
            let root = bottleURL.appending(path: "drive_c").appending(path: candidate)
            let steamExe = root.appending(path: "steam.exe")
            if FileManager.default.fileExists(atPath: steamExe.path(percentEncoded: false)) {
                return root
            }
        }
        return nil
    }

    /// Enumerates fully installed games across every Steam library in the bottle.
    ///
    /// Reads `libraryfolders.vdf` for configured library locations (mapping
    /// Windows paths through the prefix), scans each library's
    /// `steamapps/appmanifest_*.acf`, keeps fully installed games whose
    /// install directory actually exists, and de-duplicates by App ID.
    ///
    /// - Parameter bottleURL: The root URL of the Wine bottle.
    /// - Returns: Installed games sorted by name, empty if Steam isn't installed.
    public static func enumerate(bottleURL: URL) -> [SteamGame] {
        guard let steamRoot = detectInstall(bottleURL: bottleURL) else { return [] }

        var byAppId: [Int: SteamGame] = [:]
        for library in libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL) {
            for game in games(inLibrary: library) where byAppId[game.appId] == nil {
                byAppId[game.appId] = game
            }
        }

        return byAppId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The Steam root plus every existing library folder referenced by
    /// `libraryfolders.vdf` (checked in its current `config/` home and its
    /// legacy `steamapps/` location).
    static func libraryRoots(steamRoot: URL, bottleURL: URL) -> [URL] {
        var roots = [steamRoot]
        var seen: Set<String> = [steamRoot.standardizedFileURL.path]

        let vdfCandidates = [
            steamRoot.appending(path: "config").appending(path: "libraryfolders.vdf"),
            steamRoot.appending(path: "steamapps").appending(path: "libraryfolders.vdf")
        ]

        for vdfURL in vdfCandidates {
            guard let text = try? String(contentsOf: vdfURL, encoding: .utf8),
                  let root = try? VDFParser.parse(text),
                  let folders = root["libraryfolders"]?.objectValue
            else { continue }

            for value in folders.values {
                guard let windowsPath = value.objectValue?["path"]?.stringValue,
                      let mapped = mapWindowsPath(windowsPath, bottleURL: bottleURL)
                else { continue }

                let standardized = mapped.standardizedFileURL.path
                var isDirectory: ObjCBool = false
                if !seen.contains(standardized),
                   FileManager.default.fileExists(
                       atPath: mapped.path(percentEncoded: false),
                       isDirectory: &isDirectory
                   ),
                   isDirectory.boolValue {
                    seen.insert(standardized)
                    roots.append(mapped)
                }
            }
        }

        return roots
    }

    /// Maps a Windows path from a VDF file (`D:\\SteamLibrary`) to its
    /// location inside the prefix: `drive_c` for the C drive, the
    /// `dosdevices/<letter>:` symlink for everything else.
    static func mapWindowsPath(_ windowsPath: String, bottleURL: URL) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2 else { return nil }

        let driveLetter = normalized.prefix(1).lowercased()
        guard normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":",
              driveLetter.first?.isLetter == true
        else { return nil }

        let rest = String(normalized.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let base: URL = if driveLetter == "c" {
            bottleURL.appending(path: "drive_c")
        } else {
            bottleURL.appending(path: "dosdevices").appending(path: "\(driveLetter):")
        }

        return rest.isEmpty ? base : base.appending(path: rest)
    }

    /// Fully installed games in one library root whose install directory exists.
    private static func games(inLibrary library: URL) -> [SteamGame] {
        let steamApps = library.appending(path: "steamapps")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: steamApps.path(percentEncoded: false)
        )
        else { return [] }

        var found: [SteamGame] = []
        for filename in contents where filename.hasPrefix("appmanifest_") && filename.hasSuffix(".acf") {
            guard let manifest = SteamAppManifest(contentsOf: steamApps.appending(path: filename)),
                  manifest.isFullyInstalled
            else { continue }

            let installURL = steamApps.appending(path: "common").appending(path: manifest.installDir)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: installURL.path(percentEncoded: false), isDirectory: &isDirectory
            ), isDirectory.boolValue
            else { continue }

            found.append(SteamGame(
                appId: manifest.appId,
                name: manifest.name,
                installURL: installURL,
                manifest: manifest
            ))
        }
        return found
    }

    /// Lowercased executable names at the install root and one directory
    /// deep. Used to match a game's processes in the bottle's task list.
    public static func executableNames(under installURL: URL) -> Set<String> {
        let fileManager = FileManager.default
        var names: Set<String> = []
        var subdirectories: [URL] = []

        let top = (try? fileManager.contentsOfDirectory(
            at: installURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in top {
            if item.pathExtension.lowercased() == "exe" {
                names.insert(item.lastPathComponent.lowercased())
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subdirectories.append(item)
            }
        }
        for directory in subdirectories {
            let items = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for item in items where item.pathExtension.lowercased() == "exe" {
                names.insert(item.lastPathComponent.lowercased())
            }
        }
        return names
    }
}
