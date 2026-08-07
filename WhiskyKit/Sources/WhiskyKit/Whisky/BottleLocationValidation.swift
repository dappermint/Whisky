//
//  BottleLocationValidation.swift
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

/// Pre-flight validation of a user-chosen bottle parent directory.
///
/// Run this *before* the bottle subdirectory is created and `wineboot`
/// initializes the prefix, so an unusable location surfaces a clear, actionable
/// error up front instead of a cryptic late Wine failure (issue #61).
///
/// Every check performs the operation it is checking rather than inferring it
/// from the filesystem type: whether the location can be written to, whether it
/// can do what a prefix needs (see ``Capability``), and whether the volume has
/// enough free space. Ownership is intentionally *not* checked — the prefix is a
/// freshly created subdirectory owned by the current user regardless of the
/// parent's owner, so the probes are the accurate predictor.
public enum BottleLocationValidation {
    /// The outcome of validating a prospective bottle location.
    public enum ValidationResult: Equatable, Sendable {
        /// The location is usable.
        case valid
        /// Neither the location nor its nearest existing parent can be written to.
        case notWritable(path: String)
        /// The volume cannot do something a Wine prefix requires.
        case missingCapability(Capability, path: String)
        /// The volume does not have enough free space to create a bottle.
        case insufficientSpace(availableBytes: Int64, requiredBytes: Int64)
    }

    /// An operation a Wine prefix performs on its own directory.
    ///
    /// Checked by performing it, not by inferring it from the filesystem type.
    /// exFAT supports all of these on macOS despite the format itself having no
    /// notion of symlinks or permission bits.
    public enum Capability: Equatable, Sendable {
        /// Creating a subdirectory that is then visible.
        case directory
        /// Symlinks: `dosdevices/c:` points at `../drive_c`, so a prefix without
        /// them has no drives at all.
        case symlink
        /// Colons in filenames, which every entry in `dosdevices` uses.
        case driveLetterName
        /// POSIX permission bits, which Wine sets across the prefix.
        case posixPermissions

        /// What to tell the user, naming the operation that failed.
        public func explanation(path: String) -> String {
            switch self {
            case .directory:
                String(localized: "\(path) refused to create a folder, so a bottle can't be set up there.")
            case .symlink:
                String(localized: "\(path) doesn't support symbolic links, which Wine needs to map its drives.")
            case .driveLetterName:
                String(localized: "\(path) doesn't allow colons in filenames, which Wine uses for drive letters.")
            case .posixPermissions:
                String(localized: "\(path) doesn't support file permissions, which Wine needs to set up a prefix.")
            }
        }
    }

    /// Minimum free space required to create a bottle. A bare prefix is well
    /// under 1 GiB; the floor leaves headroom and refuses near-full disks where
    /// prefix initialization would otherwise fail partway.
    public static let minimumFreeBytes: Int64 = 2 << 30 // 2 GiB

    /// Validates a prospective bottle parent directory.
    ///
    /// - Parameters:
    ///   - url: The parent directory the user chose (the bottle itself is a
    ///     not-yet-created subdirectory of this).
    ///   - minimumFreeBytes: The free-space floor to require. Injectable for tests.
    ///   - fileManager: The file manager to probe with. Injectable for tests.
    /// - Returns: ``ValidationResult/valid`` if the location is usable, otherwise
    ///   the specific reason it is not.
    public static func validate(
        at url: URL,
        minimumFreeBytes: Int64 = BottleLocationValidation.minimumFreeBytes,
        fileManager: FileManager = .default
    ) -> ValidationResult {
        let ancestor = nearestExistingDirectory(for: url, fileManager: fileManager)

        guard isWritable(ancestor, fileManager: fileManager) else {
            return .notWritable(path: url.path(percentEncoded: false))
        }

        if let missing = missingCapability(in: ancestor, fileManager: fileManager) {
            return .missingCapability(missing, path: url.path(percentEncoded: false))
        }

        // Skip the space check (fail open) if capacity can't be read, rather
        // than blocking creation over an unreadable volume.
        if let available = availableCapacity(at: ancestor), available < minimumFreeBytes {
            return .insufficientSpace(availableBytes: available, requiredBytes: minimumFreeBytes)
        }

        return .valid
    }

    /// Walks up from `url` to the first existing path, so writability and
    /// capacity can be probed even when the chosen path does not exist yet.
    ///
    /// The first existing path may be a regular file (a malformed location); the
    /// caller's write probe then fails and yields `.notWritable` rather than
    /// silently validating the file's parent.
    static func nearestExistingDirectory(for url: URL, fileManager: FileManager) -> URL {
        var candidate = url.resolvingSymlinksInPath()
        while !exists(candidate, fileManager: fileManager) {
            let parent = candidate.deletingLastPathComponent()
            // `deletingLastPathComponent()` on "/" returns "/"; stop at the root
            // rather than looping forever.
            if parent.path(percentEncoded: false) == candidate.path(percentEncoded: false) {
                break
            }
            candidate = parent
        }
        return candidate
    }

    /// `fileExists(atPath:)` with a trailing slash returns `false` for a regular
    /// file, and `deletingLastPathComponent()` introduces trailing slashes — so
    /// strip them before testing existence to detect file components correctly.
    private static func exists(_ url: URL, fileManager: FileManager) -> Bool {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return fileManager.fileExists(atPath: path)
    }

    /// Whether macOS gates this location behind Files and Folders consent, where an
    /// unwritable result most likely means a declined prompt rather than a bad folder.
    /// Whisky is not sandboxed, so choosing the folder in an open panel grants nothing.
    public static func isConsentGatedVolume(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
              let values = try? volume.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        else { return false }
        return values.volumeIsLocal == false || values.volumeIsInternal == false
    }

    /// Deep link to **Full Disk Access**, not Files and Folders.
    ///
    /// Files and Folders only lists apps that have already asked, and has no way to
    /// add one; Full Disk Access has a `+` button, so it is the only pane where a
    /// user can grant access to an app macOS never prompted for. That case is
    /// routine here: this build is ad-hoc signed, so its designated requirement is a
    /// bare cdhash and every update looks like a different app to TCC.
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    /// Performs each prefix operation in a scratch directory and reports the first
    /// one the location refuses, or `nil` if it can host a prefix.
    static func missingCapability(in directory: URL, fileManager: FileManager) -> Capability? {
        let root = directory.appending(path: ".whisky-capability-probe-\(UUID().uuidString)")
        guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: false)) != nil,
              fileManager.fileExists(atPath: root.path(percentEncoded: false))
        else { return .directory }
        defer { try? fileManager.removeItem(at: root) }

        let target = root.appending(path: "drive_c")
        guard (try? fileManager.createDirectory(at: target, withIntermediateDirectories: false)) != nil
        else { return .directory }

        let link = root.appending(path: "link")
        guard (try? fileManager.createSymbolicLink(at: link, withDestinationURL: target)) != nil,
              (try? fileManager.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))) != nil
        else { return .symlink }

        // Built by hand: a colon reads as a scheme separator to URL, and the
        // literal name is the point of the check.
        let driveLetter = root.path(percentEncoded: false) + "/c:"
        guard fileManager.createFile(atPath: driveLetter, contents: nil) else { return .driveLetterName }

        guard (try? fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: target.path(percentEncoded: false)
        )) != nil
        else { return .posixPermissions }

        return nil
    }

    /// Probes writability by creating and removing a unique temp file.
    ///
    /// `FileManager.isWritableFile(atPath:)` and the `isWritable` resource key
    /// are documented as unreliable on modern macOS, so an attempt-and-clean
    /// probe is used instead.
    private static func isWritable(_ directory: URL, fileManager: FileManager) -> Bool {
        let probe = directory.appendingPathComponent(".whisky-write-probe-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path(percentEncoded: false), contents: nil) else {
            return false
        }
        try? fileManager.removeItem(at: probe)
        return true
    }

    /// Reads available capacity, preferring the "important usage" figure (which
    /// counts purgeable space, so it errs optimistic and won't false-positive).
    private static func availableCapacity(at directory: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? directory.resourceValues(forKeys: keys) else { return nil }
        // Largest wins: the important-usage figure is an APFS facility that reads
        // absent or zero elsewhere, so alone it refuses a good exFAT drive.
        let candidates = [
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeAvailableCapacity.map(Int64.init)
        ].compactMap(\.self).filter { $0 > 0 }
        return candidates.max()
    }
}
