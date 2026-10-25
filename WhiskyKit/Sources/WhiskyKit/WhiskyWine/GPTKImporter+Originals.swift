//
//  GPTKImporter+Originals.swift
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

/// Bookkeeping for the backed-up Wine originals a deploy swaps out, keyed per
/// runtime so several runtimes can hold the payload at once.
extension GPTKImporter {
    /// The runtime version under `folder`, or `nil` if none is readable.
    static func runtimeVersionStamp(inLibraryFolder folder: URL) -> String? {
        let plist = folder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")
        guard let info = WhiskyWineInstaller.whiskyWineInfo(at: plist) else { return nil }
        return "\(info.version.major).\(info.version.minor).\(info.version.patch)"
    }

    /// The store key a runtime's backups live under. The default runtime has no
    /// identifier of its own, so it gets a reserved one.
    static func originalsKey(for runtime: String?) -> String {
        runtime ?? "default"
    }

    /// Where `key`'s backed-up Wine originals live.
    ///
    /// Keyed per runtime, not shared: several runtimes can hold the payload at
    /// once, and a single backup set means deploying into one destroys the
    /// originals of another, leaving nothing to restore.
    static func originalsFolder(inStore store: URL, key: String) -> URL {
        store.appending(path: "originals").appending(path: key)
    }

    static func originalsRecordURL(inStore store: URL, key: String) -> URL {
        originalsFolder(inStore: store, key: key).appending(path: "OriginalsVersion.plist")
    }

    static func originalsRecord(inStore store: URL, key: String) -> GPTKOriginalsRecord? {
        guard let data = try? Data(contentsOf: originalsRecordURL(inStore: store, key: key)) else { return nil }
        return try? PropertyListDecoder().decode(GPTKOriginalsRecord.self, from: data)
    }

    /// Moves a flat `originals/` set, written when the store only ever backed up
    /// one runtime, under the default runtime's key. Without this the backups of
    /// an already-deployed default runtime are orphaned and its real Wine DLLs
    /// can never be restored.
    static func migrateFlatOriginals(inStore store: URL) throws {
        let fileManager = FileManager.default
        let originals = store.appending(path: "originals")
        let flatRecord = originals.appending(path: "OriginalsVersion.plist")
        guard fileManager.fileExists(atPath: flatRecord.path(percentEncoded: false)) else { return }

        let destination = originalsFolder(inStore: store, key: originalsKey(for: nil))
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in try fileManager.contentsOfDirectory(atPath: originals.path(percentEncoded: false))
            where entry != destination.lastPathComponent {
            try fileManager.moveItem(at: originals.appending(path: entry), to: destination.appending(path: entry))
        }
        logger.info("Migrated flat GPTK originals under the default runtime's key")
    }

    /// Readies `key`'s originals folder for a deploy against `folder`, dropping
    /// backups left by a previous engine: restoring those would put that
    /// engine's DLLs into this one's tree. The stamp is written before the first
    /// backup so an interrupted deploy still leaves originals remove will
    /// recognise and restore.
    static func prepareOriginals(inStore store: URL, forLibraryFolder folder: URL, key: String) throws {
        let fileManager = FileManager.default
        let originals = originalsFolder(inStore: store, key: key)
        let runtimeStamp = runtimeVersionStamp(inLibraryFolder: folder)

        if originalsRecord(inStore: store, key: key)?.runtimeVersion != runtimeStamp {
            try? fileManager.removeItem(at: originals)
        }
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)

        guard let runtimeStamp else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(GPTKOriginalsRecord(runtimeVersion: runtimeStamp))
            .write(to: originalsRecordURL(inStore: store, key: key))
    }
}
