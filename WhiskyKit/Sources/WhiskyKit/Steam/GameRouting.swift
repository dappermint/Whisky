//
//  GameRouting.swift
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

/// Remembers which bottle each Steam App ID was last launched from and when, so
/// a game can be launched by App ID alone (from the CLI, or later from a URL)
/// without asking which bottle every time, and so the library can sort by what
/// was actually played.
///
/// Deliberately a plain dictionary on disk rather than a database: the file is
/// hand-readable, a missing or corrupt entry only costs one prompt, and a wrong
/// entry is corrected by the next launch.
///
/// The launch date lives here rather than in a run log because a Steam game is
/// started by running `steam.exe -applaunch`, so its run log belongs to the
/// client, not the game. This is the only place that knows an App ID was played.
public struct GameRouting {
    /// The default store, alongside the bottle registry.
    public static var defaultURL: URL {
        BottleData.containerDir.appending(path: "GameRouting").appendingPathExtension("plist")
    }

    /// What is remembered about one App ID.
    public struct Route: Equatable, Sendable {
        public let bottleURL: URL
        /// When it was last launched, absent for routes written before launch
        /// times were recorded.
        public let lastLaunched: Date?
    }

    private enum Key {
        static let bottle = "bottle"
        static let lastLaunched = "lastLaunched"
    }

    private let url: URL

    /// Creates a routing store.
    ///
    /// - Parameter url: The plist to read and write. Defaults to ``defaultURL``.
    public init(url: URL = GameRouting.defaultURL) {
        self.url = url
    }

    /// The bottle a game was last launched from.
    public func bottleURL(forAppId appId: Int) -> URL? {
        entries()[String(appId)]?.bottleURL
    }

    /// When a game was last launched, if it has been since launch times were
    /// recorded.
    public func lastLaunched(forAppId appId: Int) -> Date? {
        entries()[String(appId)]?.lastLaunched
    }

    /// All known routes, keyed by App ID.
    public func routes() -> [Int: URL] {
        var result: [Int: URL] = [:]
        for (key, route) in entries() {
            if let appId = Int(key) {
                result[appId] = route.bottleURL
            }
        }
        return result
    }

    /// Every recorded launch time, keyed by App ID.
    ///
    /// Read in one pass because the library needs the whole set at once, and the
    /// store is a single plist: asking per game would re-read and re-parse it
    /// once per card.
    public func lastLaunches() -> [Int: Date] {
        var result: [Int: Date] = [:]
        for (key, route) in entries() {
            if let appId = Int(key), let date = route.lastLaunched {
                result[appId] = date
            }
        }
        return result
    }

    /// Records the bottle a game was launched from and when, replacing any
    /// previous route for that App ID (last launch wins).
    public func record(appId: Int, bottleURL: URL, at date: Date = Date()) {
        var current = entries()
        current[String(appId)] = Route(bottleURL: bottleURL, lastLaunched: date)
        write(current)
    }

    /// Forgets every route pointing at a bottle, e.g. when the bottle is
    /// deleted.
    ///
    /// Paths are compared through `standardizedFileURL`, the same way
    /// resolution matches a route against the bottle list, so exactly the
    /// routes that would have named this bottle are the ones removed. When
    /// nothing matches the store is left untouched (and never created).
    public func removeRoutes(toBottle bottleURL: URL) {
        let target = Self.storedPath(for: bottleURL)
        let current = entries()
        let remaining = current.filter { Self.storedPath(for: $0.value.bottleURL) != target }
        guard remaining.count != current.count else { return }
        write(remaining)
    }

    /// The path a bottle is stored and compared under.
    ///
    /// Trailing slashes are trimmed because `URL(fileURLWithPath:)` consults the
    /// filesystem and hands back a directory URL for a path that exists, whose
    /// `path(percentEncoded:)` keeps the slash. Without this a route written
    /// while the bottle existed no longer matches the same bottle once it has
    /// been deleted, which is exactly when the routes need pruning.
    private static func storedPath(for url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Reads the store, accepting both shapes it has had.
    ///
    /// Before launch times were recorded a value was the bottle path on its own.
    /// Those are read as a route with no date rather than migrated on read: a
    /// rewrite would have to invent a launch time, and the next real launch
    /// writes the new shape anyway.
    private func entries() -> [String: Route] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return [:] }

        var result: [String: Route] = [:]
        for (key, value) in dictionary {
            if let path = value as? String {
                result[key] = Route(bottleURL: URL(fileURLWithPath: path), lastLaunched: nil)
            } else if let fields = value as? [String: Any], let path = fields[Key.bottle] as? String {
                result[key] = Route(
                    bottleURL: URL(fileURLWithPath: path),
                    lastLaunched: fields[Key.lastLaunched] as? Date
                )
            }
        }
        return result
    }

    private func write(_ entries: [String: Route]) {
        var plist: [String: [String: Any]] = [:]
        for (key, route) in entries {
            var fields: [String: Any] = [Key.bottle: Self.storedPath(for: route.bottleURL)]
            fields[Key.lastLaunched] = route.lastLaunched
            plist[key] = fields
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.wineKit.error("Failed to write game routing: \(error.localizedDescription)")
        }
    }
}
