//
//  BottleData.swift
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
import SemanticVersion

/// Minimal BottleData for fallback encoding
private struct BottleDataMinimal: Codable {
    var paths: [URL]
}

// MARK: - BottleData

public struct BottleData: Codable {
    private enum CodingKeys: String, CodingKey {
        case fileVersion
        case paths
    }

    public static let containerDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library")
        .appending(path: "Containers")
        .appending(path: Bundle.whiskyBundleIdentifier)

    public static let bottleEntriesDir = containerDir
        .appending(path: "BottleVM")
        .appendingPathExtension("plist")

    public static let defaultBottleDir = containerDir
        .appending(path: "Bottles")

    static let currentVersion = SemanticVersion(1, 0, 0)

    private var fileVersion: SemanticVersion

    /// Non-nil when ``init()`` found an existing registry file it couldn't
    /// read and moved it aside instead of overwriting it, so the UI can tell
    /// the user where their old bottle list went. Never persisted.
    public private(set) var corruptRegistryBackupURL: URL?

    public var paths: [URL] = [] {
        didSet {
            encode()
        }
    }

    public init() {
        fileVersion = Self.currentVersion

        if !decode() {
            encode()
        }
    }

    private init(fileVersion: SemanticVersion, paths: [URL], corruptRegistryBackupURL: URL?) {
        self.fileVersion = fileVersion
        self.paths = paths
        self.corruptRegistryBackupURL = corruptRegistryBackupURL
    }

    @MainActor
    public mutating func loadBottles() -> [Bottle] {
        var bottles: [Bottle] = []

        for path in paths {
            let bottleMetadata = path
                .appending(path: "Metadata")
                .appendingPathExtension("plist")
                .path(percentEncoded: false)

            if FileManager.default.fileExists(atPath: bottleMetadata) {
                bottles.append(Bottle(bottleUrl: path, isAvailable: true))
            } else {
                bottles.append(Bottle(bottleUrl: path))
            }
        }

        return bottles
    }

    /// Appends a bottle path to the registry and verifies the entries file on
    /// disk actually contains it afterwards, so a failed save can't silently
    /// drop the bottle on the next launch (issue #61).
    ///
    /// - Returns: `true` when the path is durably persisted.
    public mutating func registerBottlePath(_ url: URL) -> Bool {
        if !paths.contains(url) {
            paths.append(url) // didSet persists via encode()
        }
        return Self.persistedPaths()?.contains(url) ?? false
    }

    /// Reads the bottle paths back from the entries file, accepting both the
    /// full and the minimal (fallback) encodings.
    private static func persistedPaths() -> [URL]? {
        guard let data = try? Data(contentsOf: bottleEntriesDir) else { return nil }
        let decoder = PropertyListDecoder()
        if let full = try? decoder.decode(BottleData.self, from: data) {
            return full.paths
        }
        if let minimal = try? decoder.decode(BottleDataMinimal.self, from: data) {
            return minimal.paths
        }
        return nil
    }

    @discardableResult
    private mutating func decode() -> Bool {
        let decoder = PropertyListDecoder()
        let data: Data
        do {
            data = try Data(contentsOf: Self.bottleEntriesDir)
        } catch {
            // Missing entries file: first run, start with an empty registry.
            Logger.wineKit.error("Failed to read BottleData: \(error)")
            return false
        }
        do {
            let decoded = try decoder.decode(BottleData.self, from: data)
            if decoded.fileVersion != Self.currentVersion {
                Logger.wineKit.warning(
                    "Invalid file version \(decoded.fileVersion), expected \(Self.currentVersion)"
                )
                // Keep the registered paths; init() re-encodes them in the
                // current format instead of discarding them.
                self = BottleData(
                    fileVersion: Self.currentVersion,
                    paths: decoded.paths,
                    corruptRegistryBackupURL: nil
                )
                return false
            }
            self = decoded
            return true
        } catch {
            Logger.wineKit.error("Failed to decode BottleData: \(error)")
        }
        // The full decode failed on an existing file. Salvage the paths-only
        // shape written by encodeFallback() before treating it as corrupt.
        if let minimal = try? decoder.decode(BottleDataMinimal.self, from: data) {
            Logger.wineKit.warning("Recovered \(minimal.paths.count) bottle path(s) from minimal registry")
            self = BottleData(
                fileVersion: Self.currentVersion,
                paths: minimal.paths,
                corruptRegistryBackupURL: nil
            )
            return false
        }
        // Truly unreadable: move the file aside so the fresh registry written
        // by init() doesn't destroy the user's bottle list (issue #61).
        self = BottleData(
            fileVersion: Self.currentVersion,
            paths: [],
            corruptRegistryBackupURL: Self.backUpCorruptRegistry()
        )
        return false
    }

    /// Moves an unreadable registry file aside, returning the backup location.
    private static func backUpCorruptRegistry() -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bottleEntriesDir.path(percentEncoded: false)) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = bottleEntriesDir.deletingPathExtension().lastPathComponent
        let backupURL = bottleEntriesDir
            .deletingLastPathComponent()
            .appending(path: "\(name).corrupt-\(formatter.string(from: Date())).plist")
        do {
            try fileManager.moveItem(at: bottleEntriesDir, to: backupURL)
            Logger.wineKit.warning("Moved unreadable bottle registry to \(backupURL.path)")
            return backupURL
        } catch {
            Logger.wineKit.error("Failed to back up unreadable bottle registry: \(error)")
            return nil
        }
    }

    @discardableResult
    private func encode() -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            try FileManager.default.createDirectory(at: Self.containerDir, withIntermediateDirectories: true)
            let data = try encoder.encode(self)
            try data.write(to: Self.bottleEntriesDir, options: .atomic)
            return true
        } catch {
            Logger.wineKit.error("Failed to encode BottleData: \(error)")
            // Try alternative encoding without version check
            return encodeFallback()
        }
    }

    private func encodeFallback() -> Bool {
        // Fallback: try to recover existing paths and save minimal data
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            try FileManager.default.createDirectory(at: Self.containerDir, withIntermediateDirectories: true)
            // Create a minimal BottleData with just the paths
            let fallbackData = BottleDataMinimal(paths: self.paths)
            let data = try encoder.encode(fallbackData)
            try data.write(to: Self.bottleEntriesDir, options: .atomic)
            return true
        } catch {
            Logger.wineKit.error("Failed to encode fallback BottleData: \(error)")
            return false
        }
    }
}
