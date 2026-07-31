//
//  GPTKDiskImage.swift
//  Whisky
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
import WhiskyKit

/// Mounts Apple's GPTK disk images long enough to import their payload.
///
/// The user may hand us the outer Game Porting Toolkit image (which contains
/// the evaluation-environment image), the evaluation-environment image
/// itself, an already-mounted volume, or a bare folder. Everything resolves
/// to the `redist/lib` payload root, plus the list of mount points to detach
/// once the import completes.
enum GPTKDiskImage {
    /// A resolved payload location and the mounts holding it open.
    struct ResolvedPayload {
        let libRoot: URL
        let mounts: [URL]
    }

    enum DiskImageError: LocalizedError {
        case attachFailed(String)

        var errorDescription: String? {
            switch self {
            case let .attachFailed(detail):
                String(localized: "gptk.error.attachFailed") + " " + detail
            }
        }
    }

    /// Resolves `url` (image or folder) to a GPTK payload root, attaching
    /// images as needed. Callers must ``detach(_:)`` every returned mount.
    static func resolvePayload(at url: URL) throws -> ResolvedPayload {
        guard url.pathExtension.lowercased() == "dmg" else {
            guard let lib = GPTKImporter.locatePayload(under: url) else {
                throw GPTKImportError.payloadNotFound
            }
            return ResolvedPayload(libRoot: lib, mounts: [])
        }

        var mounts: [URL] = []
        do {
            let outer = try attach(url)
            mounts.append(outer)
            if let lib = GPTKImporter.locatePayload(under: outer) {
                return ResolvedPayload(libRoot: lib, mounts: mounts)
            }

            // The outer GPTK image carries the evaluation environment as a
            // nested image; attach the first one that yields a payload.
            let contents = try FileManager.default.contentsOfDirectory(
                at: outer, includingPropertiesForKeys: nil
            )
            for nested in contents where nested.pathExtension.lowercased() == "dmg" {
                let inner = try attach(nested)
                mounts.append(inner)
                if let lib = GPTKImporter.locatePayload(under: inner) {
                    return ResolvedPayload(libRoot: lib, mounts: mounts)
                }
            }
            throw GPTKImportError.payloadNotFound
        } catch {
            for mount in mounts.reversed() {
                detach(mount)
            }
            throw error
        }
    }

    /// Attaches a disk image read-only and returns its mount point.
    static func attach(_ image: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", "-readonly", "-nobrowse", "-plist", image.path(percentEncoded: false)
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw DiskImageError.attachFailed(image.lastPathComponent)
        }
        return URL(filePath: mountPoint)
    }

    /// Detaches a mount point; failures are ignored (the mount stays behind
    /// for the user, nothing is lost).
    static func detach(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path(percentEncoded: false)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
