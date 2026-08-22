//
//  SharedSteamLibrary.swift
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

/// Errors thrown when sharing a macOS Steam library folder with a bottle.
public enum SharedSteamLibraryError: LocalizedError, Equatable {
    /// The bottle has no Steam installation to configure.
    case steamNotInstalled
    /// No drive in the bottle reaches the folder, so no Windows path exists
    /// for it.
    case unreachable(folder: URL)
    /// The folder is the macOS client's own data directory, which holds the
    /// macOS builds of native games.
    case hostDataDirectory
    /// The bottle's Steam already has the folder configured.
    case alreadyShared(folder: URL)
    /// The bottle's Steam does not have the folder configured.
    case notShared(folder: URL)

    public var errorDescription: String? {
        switch self {
        case .steamNotInstalled:
            String(localized: "steam.share.error.noClient")
        case let .unreachable(folder):
            String(localized: "steam.share.error.unreachable \(folder.lastPathComponent)")
        case .hostDataDirectory:
            String(localized: "steam.share.error.hostDataDirectory")
        case let .alreadyShared(folder):
            String(localized: "steam.share.error.alreadyShared \(folder.lastPathComponent)")
        case let .notShared(folder):
            String(localized: "steam.share.error.notShared \(folder.lastPathComponent)")
        }
    }
}

/// Puts a Steam library folder that lives on macOS into the bottle client's
/// `libraryfolders.vdf`, so both clients see one copy of the games.
///
/// The macOS client is the one that can fetch Windows depots (see
/// ``HostSteam``); the bottle's client is the one that can launch them. Sharing
/// a folder is what joins those two halves, and it needs nothing at run time:
/// Wine already exposes the whole filesystem through `dosdevices`, so the
/// folder simply has a Windows path as well as a POSIX one.
///
/// The macOS client's own data directory is deliberately refused. It holds the
/// macOS builds of native games, and a Windows client scanning those decides
/// they are the wrong build and queues a redownload over them.
public enum SharedSteamLibrary {
    // MARK: - Reading

    /// The Windows path of a folder as the bottle's Wine prefix sees it, for
    /// example `Z:\Users\me\Games`.
    ///
    /// The inverse of ``SteamLibrary/mapWindowsPath(_:bottleURL:)``. Every
    /// `dosdevices/<letter>:` symlink is a mount point; the one whose target is
    /// the longest prefix of the folder wins, so a dedicated `d:` beats the
    /// catch-all `z:` that points at the root.
    ///
    /// Symlinks are resolved on both sides before comparing, because a bottle
    /// reaches most of the disk through `dosdevices/z:` pointing at `/`, and
    /// `/var` and `/private/var` name the same directory through it.
    ///
    /// - Returns: `nil` when no drive in the bottle reaches the folder.
    public static func windowsPath(for folder: URL, bottleURL: URL) -> String? {
        let target = folder.resolvingSymlinksInPath().path
        let dosdevices = bottleURL.appending(path: "dosdevices")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: dosdevices.path(percentEncoded: false)
        )
        else { return nil }

        var best: (letter: Character, root: String)?
        for entry in entries {
            // Exactly "<letter>:". Entries like "d::" are device mappings, not
            // drives, and resolve to something like /dev/rdisk8s1.
            guard entry.count == 2, entry.hasSuffix(":"),
                  let letter = entry.first, letter.isLetter,
                  let root = resolvedDrive(entry, in: dosdevices),
                  target == root || target.hasPrefix(root == "/" ? "/" : root + "/")
            else { continue }

            if let current = best, current.root.count >= root.count { continue }
            best = (letter, root)
        }

        guard let best else { return nil }
        let rest = best.root == "/"
            ? String(target.dropFirst())
            : String(target.dropFirst(best.root.count).drop(while: { $0 == "/" }))
        return "\(best.letter.uppercased()):\\" + rest.replacingOccurrences(of: "/", with: "\\")
    }

    /// Library folders the bottle's Steam is configured to use that live
    /// outside the bottle, newest configuration last.
    ///
    /// A bottle's own `C:` libraries are not shared with anything, so they are
    /// left out.
    ///
    /// Returned paths are resolved back to where they really live, because a
    /// library on `Z:` maps to a path that runs through the bottle's
    /// `dosdevices` symlink and reads as nonsense to a person.
    public static func shared(bottleURL: URL) -> [URL] {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return [] }
        let bottlePath = identity(bottleURL) + "/"
        return SteamLibrary.libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL)
            .map { $0.resolvingSymlinksInPath() }
            .filter { !identity($0).hasPrefix(bottlePath) }
    }

    /// The one form two URLs for the same directory are compared in: symlinks
    /// resolved, percent encoding undone, no trailing slash.
    ///
    /// `URL` equality is not usable here. `URL(filePath:)` and
    /// `URL.homeDirectory.appending(path:)` produce values that differ in
    /// encoding and in whether they end in a slash while naming one directory,
    /// so comparing them directly quietly answers no.
    static func identity(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - Writing

    /// Adds a macOS library folder to the bottle client's configuration.
    ///
    /// Creates the folder's `steamapps` directory and its `libraryfolder.vdf`
    /// marker when they are missing, so a folder can be prepared here and added
    /// to the macOS client afterwards, or the other way round.
    ///
    /// - Throws: ``SharedSteamLibraryError``.
    public static func share(folder: URL, bottleURL: URL) throws {
        let folder = folder.resolvingSymlinksInPath()
        guard identity(folder) != identity(HostSteam.defaultRoot) else {
            throw SharedSteamLibraryError.hostDataDirectory
        }
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else {
            throw SharedSteamLibraryError.steamNotInstalled
        }
        guard let path = windowsPath(for: folder, bottleURL: bottleURL) else {
            throw SharedSteamLibraryError.unreachable(folder: folder)
        }
        guard !shared(bottleURL: bottleURL).map(identity).contains(identity(folder)) else {
            throw SharedSteamLibraryError.alreadyShared(folder: folder)
        }

        try FileManager.default.createDirectory(
            at: folder.appending(path: "steamapps"), withIntermediateDirectories: true
        )
        let contentId = try contentId(of: folder)

        try updateConfiguration(steamRoot: steamRoot, bottleURL: bottleURL) { entries in
            var entries = entries
            entries[String(nextIndex(in: entries))] = .object([
                "path": .string(path),
                "label": .string(""),
                "contentid": .string(contentId),
                "totalsize": .string("0"),
                "update_clean_bytes_tally": .string("0"),
                "time_last_update_verified": .string("0"),
                "apps": .object([:])
            ])
            return entries
        }
    }

    /// Removes a folder from the bottle client's configuration, leaving the
    /// folder and its games alone.
    ///
    /// - Throws: ``SharedSteamLibraryError``.
    public static func unshare(folder: URL, bottleURL: URL) throws {
        let folder = folder.resolvingSymlinksInPath()
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else {
            throw SharedSteamLibraryError.steamNotInstalled
        }
        guard shared(bottleURL: bottleURL).map(identity).contains(identity(folder)) else {
            throw SharedSteamLibraryError.notShared(folder: folder)
        }

        try updateConfiguration(steamRoot: steamRoot, bottleURL: bottleURL) { entries in
            entries.filter { _, value in
                guard let path = value.objectValue?["path"]?.stringValue,
                      let mapped = SteamLibrary.mapWindowsPath(path, bottleURL: bottleURL)
                else { return true }
                return identity(mapped) != identity(folder)
            }
        }
    }

    // MARK: - Configuration files

    /// Rewrites every `libraryfolders.vdf` the bottle's Steam already has,
    /// creating the `steamapps` one when it has none.
    ///
    /// Both copies are kept in step because Steam itself keeps them in step,
    /// and a client that reads the one Whisky did not write would not see the
    /// folder.
    private static func updateConfiguration(
        steamRoot: URL,
        bottleURL: URL,
        transform: ([String: VDFValue]) -> [String: VDFValue]
    ) throws {
        let candidates = HostSteam.libraryFolderFiles(steamRoot: steamRoot)
        let existing = candidates.filter {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        let targets = existing.isEmpty ? [candidates[1]] : existing

        for target in targets {
            var entries = readEntries(at: target)
            if entries.isEmpty, let rootPath = windowsPath(for: steamRoot, bottleURL: bottleURL) {
                entries["0"] = .object(["path": .string(rootPath), "label": .string("")])
            }

            let document: [String: VDFValue] = ["libraryfolders": .object(transform(entries))]
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try VDFWriter.serialize(document).write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private static func readEntries(at url: URL) -> [String: VDFValue] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? VDFParser.parse(text),
              let entries = parsed["libraryfolders"]?.objectValue
        else { return [:] }
        return entries
    }

    /// The lowest unused numeric index, so an entry never overwrites another.
    private static func nextIndex(in entries: [String: VDFValue]) -> Int {
        var index = 0
        while entries[String(index)] != nil {
            index += 1
        }
        return index
    }

    /// The folder's content id, from its `libraryfolder.vdf` marker.
    ///
    /// Steam writes that marker when it adds a drive and matches the id against
    /// the one in `libraryfolders.vdf` to recognise a folder that moved. When
    /// the marker is missing the folder was prepared outside Steam, so one is
    /// written here for both clients to agree on.
    private static func contentId(of folder: URL) throws -> String {
        let marker = folder.appending(path: "libraryfolder.vdf")
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let parsed = try? VDFParser.parse(text),
           let existing = parsed["libraryfolder"]?.objectValue?["contentid"]?.stringValue,
           !existing.isEmpty {
            return existing
        }

        let contentId = String(UInt64.random(in: 1 ... UInt64(Int64.max)))
        let document: [String: VDFValue] = ["libraryfolder": .object([
            "contentid": .string(contentId),
            "label": .string("")
        ])]
        try VDFWriter.serialize(document).write(to: marker, atomically: true, encoding: .utf8)
        return contentId
    }

    /// The absolute path a `dosdevices` drive symlink points at.
    private static func resolvedDrive(_ entry: String, in dosdevices: URL) -> String? {
        let link = dosdevices.appending(path: entry)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        else { return nil }

        let resolved = destination.hasPrefix("/")
            ? URL(filePath: destination)
            : URL(filePath: destination, relativeTo: dosdevices)
        return resolved.resolvingSymlinksInPath().path
    }
}
