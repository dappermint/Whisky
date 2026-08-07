//
//  ExternalVolumeAccess.swift
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

/// Whether Whisky may write to a location on a removable or network volume,
/// which macOS gates behind Files and Folders privacy consent.
///
/// Whisky is not sandboxed, so picking a folder in an `NSOpenPanel` grants
/// nothing — the consent prompt fires on the first real access, and a decline
/// makes every later access fail with `EPERM`.
public enum ExternalVolumeAccess {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier,
        category: "ExternalVolumeAccess"
    )

    public enum VolumeKind: Equatable, Sendable {
        case internalDisk
        case removable
        case network

        public var requiresConsent: Bool {
            self != .internalDisk
        }
    }

    public enum Access: Equatable, Sendable {
        case granted
        case denied(VolumeKind)
        case volumeUnavailable
        case failed(String)

        public var isGranted: Bool {
            self == .granted
        }

        public var nilIfGranted: Access? {
            isGranted ? nil : self
        }
    }

    public static func volumeKind(of url: URL) -> VolumeKind {
        do {
            guard let volume = try url.resourceValues(forKeys: [.volumeURLKey]).volume else {
                return .internalDisk
            }
            let values = try volume.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            if values.volumeIsLocal == false { return .network }
            return values.volumeIsInternal == true ? .internalDisk : .removable
        } catch {
            // An unreadable volume record is itself a denial symptom, so assume the
            // gated case rather than reporting a location as unrestricted.
            logger.warning("Could not classify volume for \(url.path, privacy: .public): \(error)")
            return .removable
        }
    }

    /// Probes write access, **triggering the macOS consent prompt when one is owed**.
    /// There is no status API for Files and Folders, so an actual write is the only
    /// way to ask. Blocks on the user while the prompt is up.
    public static func requestAccess(to url: URL, fileManager: FileManager = .default) -> Access {
        let kind = volumeKind(of: url)

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) {
            if kind.requiresConsent, !volumeIsMounted(for: url, fileManager: fileManager) {
                return .volumeUnavailable
            }
            guard let parent = existingAncestor(of: url, fileManager: fileManager) else {
                return .volumeUnavailable
            }
            return probeWrite(in: parent, kind: kind, fileManager: fileManager)
        }
        guard isDirectory.boolValue else {
            return .failed("Not a directory: \(url.path(percentEncoded: false))")
        }
        return probeWrite(in: url, kind: kind, fileManager: fileManager)
    }

    private static func probeWrite(in directory: URL, kind: VolumeKind, fileManager: FileManager) -> Access {
        let probe = directory.appending(path: ".whisky-access-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return .granted
        } catch {
            let nsError = error as NSError
            // Cocoa reports a TCC refusal as an ordinary write failure, so the volume
            // category is what distinguishes missing consent from a read-only disk.
            let isPermission = nsError.code == NSFileWriteNoPermissionError
                || nsError.underlyingErrors.contains { ($0 as NSError).code == Int(EPERM) }
            guard isPermission else { return .failed(error.localizedDescription) }
            return .denied(kind)
        }
    }

    private static func volumeIsMounted(for url: URL, fileManager: FileManager) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return true }
        return fileManager.fileExists(atPath: volume.path(percentEncoded: false))
    }

    private static func existingAncestor(of url: URL, fileManager: FileManager) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path(percentEncoded: false) != "/" {
            let parent = candidate.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: parent.path(percentEncoded: false), isDirectory: &isDirectory) {
                return isDirectory.boolValue ? parent : nil
            }
            candidate = parent
        }
        return nil
    }

    /// Nothing can re-present the prompt once answered, so Settings is the only recovery.
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )
}
