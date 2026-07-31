//
//  SteamAppManifest.swift
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

/// A parsed Steam application manifest (`appmanifest_<appid>.acf`).
///
/// Steam stores application metadata in ACF/VDF format files alongside
/// installed games. This type parses those files fully via ``VDFParser``,
/// and also provides the legacy fast-path helpers for extracting App IDs
/// from manifest text and `steam_appid.txt` files.
///
/// ## ACF Format
///
/// Valve's ACF (App Cache File) format uses `"key"\t\t"value"` pairs:
/// ```
/// "AppState"
/// {
///     "appid"     "1245620"
///     "name"      "Elden Ring"
/// }
/// ```
public struct SteamAppManifest: Equatable, Sendable {
    /// The Steam App ID.
    public let appId: Int
    /// The display name of the app.
    public let name: String
    /// The install directory name, relative to `<library>/steamapps/common/`.
    public let installDir: String
    /// Steam's install-state bitmask. Bit 4 means fully installed.
    public let stateFlags: Int
    /// The installed build number, when present.
    public let buildID: Int?
    /// The size on disk in bytes, when present.
    public let sizeOnDisk: Int64?

    /// Whether Steam considers the app fully installed (not downloading,
    /// updating, or partially removed).
    public var isFullyInstalled: Bool {
        stateFlags & 4 != 0
    }

    /// Parses a manifest file.
    ///
    /// - Parameter url: The URL to an `appmanifest_*.acf` file.
    /// - Returns: `nil` if the file can't be read, isn't valid VDF, or lacks
    ///   the required `appid`, `name`, or `installdir` fields.
    public init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? VDFParser.parse(text),
              let appState = root["appstate"]?.objectValue,
              let appId = appState["appid"]?.intValue,
              let name = appState["name"]?.stringValue,
              let installDir = appState["installdir"]?.stringValue
        else { return nil }

        self.appId = appId
        self.name = name
        self.installDir = installDir
        self.stateFlags = appState["stateflags"]?.intValue ?? 0
        self.buildID = appState["buildid"]?.intValue
        self.sizeOnDisk = appState["sizeondisk"]?.stringValue.flatMap(Int64.init)
    }

    /// Parses a Steam App ID from ACF/VDF format text.
    ///
    /// Looks for a `"appid"` key followed by its value in Valve's
    /// key-value format. Handles varying amounts of whitespace and
    /// tab indentation.
    ///
    /// - Parameter text: The raw text content of an ACF/VDF file.
    /// - Returns: The parsed App ID, or `nil` if not found.
    public static func parseAppId(from text: String) -> Int? {
        // Match "appid" followed by whitespace and a quoted integer value.
        // ACF format: "key"<whitespace>"value"
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Check if this line contains the appid key
            guard trimmed.lowercased().contains("\"appid\"") else { continue }

            // Extract the value: find all quoted strings on this line
            var quotedValues: [String] = []
            var inQuote = false
            var current = ""
            for char in trimmed {
                if char == "\"" {
                    if inQuote {
                        quotedValues.append(current)
                        current = ""
                    }
                    inQuote.toggle()
                } else if inQuote {
                    current.append(char)
                }
            }

            // The second quoted string is the value
            guard quotedValues.count >= 2 else { continue }
            return Int(quotedValues[1])
        }
        return nil
    }

    /// Searches a Wine bottle for a Steam App ID by scanning manifest files.
    ///
    /// - Parameter bottleURL: The root URL of the Wine bottle.
    /// - Returns: The first App ID found, or `nil` if none found.
    @available(*, deprecated, message: "Use SteamLibrary.enumerate(bottleURL:) instead")
    public static func findAppId(in bottleURL: URL) -> Int? {
        SteamLibrary.enumerate(bottleURL: bottleURL).first?.appId
    }

    /// Searches for a Steam App ID near a specific executable.
    ///
    /// Checks for `steam_appid.txt` in the executable's directory and
    /// up to three parent directories. The file should contain a plain
    /// integer App ID.
    ///
    /// - Parameter exeURL: The URL to the game executable.
    /// - Returns: The parsed App ID, or `nil` if not found.
    public static func findAppIdForProgram(at exeURL: URL) -> Int? {
        let fileManager = FileManager.default
        var directory = exeURL.deletingLastPathComponent()

        // Check exe directory and up to 3 parent directories
        for _ in 0 ..< 4 {
            let appIdFile = directory.appending(path: "steam_appid.txt")
            let filePath = appIdFile.path(percentEncoded: false)

            if fileManager.fileExists(atPath: filePath),
               let text = try? String(contentsOf: appIdFile, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let appId = Int(trimmed) {
                    return appId
                }
            }

            directory = directory.deletingLastPathComponent()
        }

        return nil
    }
}
