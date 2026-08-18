//
//  GameRecord.swift
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

/// The persisted identity of one library entry, stable across reloads.
///
/// `externalID` is whatever the source itself uses to name the game: a Steam
/// App ID, or a pin's bottle-relative executable path. Bottle-relative rather
/// than absolute for the same reason program settings are keyed that way: the
/// identity survives the bottle being moved.
public struct GameRecordID: Hashable, Sendable, Codable {
    public let source: LibrarySourceID
    public let externalID: String

    public init(source: LibrarySourceID, externalID: String) {
        self.source = source
        self.externalID = externalID
    }

    public static func steam(appID: Int) -> GameRecordID {
        GameRecordID(source: .steam, externalID: String(appID))
    }

    public static func pin(at url: URL, bottleURL: URL) -> GameRecordID {
        GameRecordID(source: .pinned, externalID: bottleRelativePath(of: url, bottleURL: bottleURL))
    }

    /// The path a pinned executable is identified by. Falls back to the
    /// absolute path for a URL outside the bottle, which still identifies it,
    /// just without surviving a move.
    static func bottleRelativePath(of url: URL, bottleURL: URL) -> String {
        let bottlePath = bottleURL.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        return fullPath.hasPrefix(bottlePath)
            ? String(fullPath.dropFirst(bottlePath.count))
            : fullPath
    }
}

/// What the library remembers about one game beyond what its source can
/// re-derive from disk.
///
/// A ``LibraryEntry`` is rebuilt from the prefix on every reload and can hold
/// nothing between passes; this is where anything user-shaped lives. Fields
/// default rather than fail on decode so a record written by a newer build
/// reads back instead of vanishing.
public struct GameRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GameRecordID
    /// A user-chosen name; `nil` means the source's own name is shown.
    public var displayName: String?
    public var favourite: Bool
    public var hidden: Bool
    /// The last time Whisky itself started this game. A source may know about
    /// launches from elsewhere (Steam's manifest does); that stays with the
    /// source, tagged by origin at projection time, so the sort can choose.
    public var lastPlayedInWhisky: Date?
    public var firstSeen: Date

    public init(id: GameRecordID, firstSeen: Date = Date()) {
        self.id = id
        self.displayName = nil
        self.favourite = false
        self.hidden = false
        self.lastPlayedInWhisky = nil
        self.firstSeen = firstSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(GameRecordID.self, forKey: .id)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.favourite = try container.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        self.lastPlayedInWhisky = try container.decodeIfPresent(Date.self, forKey: .lastPlayedInWhisky)
        self.firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
    }
}

/// The game records of one bottle, stored inside it.
///
/// Inside the bottle rather than in a global table so the records travel with
/// an exported or moved bottle, and so two bottles holding the same game keep
/// separate state, which is what the grid shows. Like ``GameRouting``, this is
/// a hand-readable plist and every read tolerates a missing or corrupt file: a
/// lost record costs a favourite flag, not a library.
public struct GameRecordStore: Sendable {
    /// The store inside a bottle: `{bottle}/Library.plist`.
    public static func storeURL(in bottleURL: URL) -> URL {
        bottleURL.appending(path: "Library").appendingPathExtension("plist")
    }

    private struct Contents: Codable {
        var records: [GameRecord] = []
    }

    private let url: URL

    public init(bottleURL: URL) {
        self.url = GameRecordStore.storeURL(in: bottleURL)
    }

    /// Every record in the bottle, keyed by identity.
    public func records() -> [GameRecordID: GameRecord] {
        Dictionary(read().records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func record(for id: GameRecordID) -> GameRecord? {
        records()[id]
    }

    /// Applies a change to a record, creating it first if the game has never
    /// had one. The record only hits disk when the change actually changed
    /// something, so a reload that touches every record rewrites nothing.
    public func update(_ id: GameRecordID, _ mutate: (inout GameRecord) -> Void) {
        var all = records()
        var record = all[id] ?? GameRecord(id: id)
        let before = all[id]
        mutate(&record)
        guard record != before else { return }
        all[id] = record
        write(Contents(records: all.values.sorted {
            ($0.id.source.rawValue, $0.id.externalID) < ($1.id.source.rawValue, $1.id.externalID)
        }))
    }

    /// Stamps a launch started by Whisky.
    public func recordLaunch(_ id: GameRecordID, at date: Date = Date()) {
        update(id) { $0.lastPlayedInWhisky = date }
    }

    private func read() -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        do {
            return try PropertyListDecoder().decode(Contents.self, from: data)
        } catch {
            Logger.wineKit.error("Failed to read game records: \(error.localizedDescription)")
            return Contents()
        }
    }

    private func write(_ contents: Contents) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(contents)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.wineKit.error("Failed to write game records: \(error.localizedDescription)")
        }
    }
}
