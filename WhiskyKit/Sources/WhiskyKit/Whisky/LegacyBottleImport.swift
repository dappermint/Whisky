//
//  LegacyBottleImport.swift
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

/// Discovery of bottles created by other Whisky builds so this build can import them.
///
/// Each build keys its bottle directory on its own bundle identifier, so it doesn't see
/// another build's bottles automatically. None of them are sandboxed, though, so the
/// containers can be read directly. Discovered bottles are referenced **in place** (no
/// copy) — the same way custom-path bottles already work — so importing is
/// non-destructive and the other build keeps working if it's still installed.
public enum LegacyBottleImport {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier,
        category: "LegacyBottleImport"
    )

    /// Bundle identifier of the archived original Whisky app.
    public static let legacyBundleIdentifier = "com.isaacmarovitz.Whisky"

    /// Bundle identifiers whose bottles this build can adopt, most recent lineage first:
    /// frankea's fork, then the archived original.
    public static let legacyBundleIdentifiers = ["com.franke.Whisky", legacyBundleIdentifier]

    /// `~/Library/Containers/com.isaacmarovitz.Whisky`.
    public static var legacyContainerDirectory: URL {
        containerDirectory(for: legacyBundleIdentifier)
    }

    /// Container directories for every identifier in ``legacyBundleIdentifiers``.
    public static var legacyContainerDirectories: [URL] {
        legacyBundleIdentifiers.map(containerDirectory(for:))
    }

    /// `~/Library/Containers/<bundleIdentifier>`.
    public static func containerDirectory(for bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Containers")
            .appending(path: bundleIdentifier)
    }

    /// Minimal decode of the original app's bottle registry. Same plist shape as
    /// ``BottleData`` — we only need the registered paths.
    private struct LegacyRegistry: Decodable {
        var paths: [URL]
    }

    /// Whether the original app's container exists at all. Used to decide whether the
    /// migration option is worth offering in the UI.
    public static func legacyContainerExists(at container: URL = legacyContainerDirectory) -> Bool {
        FileManager.default.fileExists(atPath: container.path(percentEncoded: false))
    }

    /// URLs of original-app bottles that are valid (contain a `Metadata.plist`) and are
    /// not already registered in `existingPaths`.
    ///
    /// Sources, in order: the original app's `BottleVM.plist` registry (which also covers
    /// bottles stored at custom paths outside the default Bottles directory), then a scan
    /// of the default `Bottles` directory as a fallback. Results are de-duplicated and
    /// sorted by directory name.
    ///
    /// - Parameters:
    ///   - legacyContainer: the original app's container directory (injectable for testing).
    ///   - existingPaths: bottle paths already registered in this fork, to avoid duplicates.
    public static func importableBottleURLs(
        legacyContainer: URL,
        existingPaths: [URL]
    ) -> [URL] {
        let existing = Set(existingPaths.map(\.standardizedFileURL))
        var candidates: [URL] = []

        // 1. The registry plist lists every bottle the original app knew about, including
        //    bottles stored at custom paths outside the Bottles directory.
        let registryURL = legacyContainer.appending(path: "BottleVM").appendingPathExtension("plist")
        if let data = try? Data(contentsOf: registryURL),
           let registry = try? PropertyListDecoder().decode(LegacyRegistry.self, from: data) {
            candidates.append(contentsOf: registry.paths)
        }

        // 2. Scan the default Bottles directory in case the registry is missing or stale.
        let bottlesDir = legacyContainer.appending(path: "Bottles")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: bottlesDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            candidates.append(contentsOf: entries)
        }

        var seen = Set<URL>()
        var result: [URL] = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard !existing.contains(standardized), seen.insert(standardized).inserted else { continue }
            guard isBottle(at: standardized) else { continue }
            result.append(standardized)
        }

        logger.info("Discovered \(result.count) importable legacy bottle(s)")
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// An importable original-app bottle, with the display name read from its settings.
    public struct DiscoveredBottle: Identifiable, Hashable, Sendable {
        /// The bottle's directory URL (also its identity).
        public let url: URL
        /// The bottle's display name, read from its settings (falls back to the directory name).
        public let name: String
        public var id: URL {
            url
        }
    }

    /// Like ``importableBottleURLs(legacyContainer:existingPaths:)`` but also reads each bottle's
    /// display name. Names are read **non-destructively** (see ``readOnlyName(at:)``) — discovery
    /// must never mutate the original app's bottles.
    public static func importableBottles(
        legacyContainer: URL,
        existingPaths: [URL]
    ) -> [DiscoveredBottle] {
        importableBottleURLs(legacyContainer: legacyContainer, existingPaths: existingPaths).map { url in
            DiscoveredBottle(url: url, name: readOnlyName(at: url) ?? url.lastPathComponent)
        }
    }

    /// ``importableBottleURLs(legacyContainer:existingPaths:)`` across several containers,
    /// de-duplicated. A bottle registered by two builds is offered once.
    public static func importableBottleURLs(
        legacyContainers: [URL] = legacyContainerDirectories,
        existingPaths: [URL]
    ) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for container in legacyContainers {
            for url in importableBottleURLs(legacyContainer: container, existingPaths: existingPaths)
                where seen.insert(url).inserted {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// ``importableBottles(legacyContainer:existingPaths:)`` across several containers.
    public static func importableBottles(
        legacyContainers: [URL] = legacyContainerDirectories,
        existingPaths: [URL]
    ) -> [DiscoveredBottle] {
        importableBottleURLs(legacyContainers: legacyContainers, existingPaths: existingPaths).map { url in
            DiscoveredBottle(url: url, name: readOnlyName(at: url) ?? url.lastPathComponent)
        }
    }

    /// Reads a bottle's display name from its `Metadata.plist` **without writing anything**.
    ///
    /// This decodes `BottleSettings` directly via `PropertyListDecoder` (whose `init(from:)` is
    /// pure). It deliberately does **not** use `BottleSettings.decode(from:)` or construct a
    /// `Bottle`: both of those rewrite the metadata file when the bottle's file/wine version
    /// differs from the current app's defaults — which a bottle from the original app almost
    /// always does — and that would silently mutate the user's original bottles just by opening
    /// the migration sheet. Returns `nil` if the metadata is missing or undecodable.
    private static func readOnlyName(at bottleURL: URL) -> String? {
        let metadata = bottleURL.appending(path: "Metadata").appendingPathExtension("plist")
        guard let data = try? Data(contentsOf: metadata),
              let settings = try? PropertyListDecoder().decode(BottleSettings.self, from: data)
        else { return nil }
        return settings.name
    }

    /// A directory is treated as a bottle when it contains a `Metadata.plist`, the marker
    /// ``Bottle`` and ``BottleData`` use to recognise a real bottle on disk.
    private static func isBottle(at url: URL) -> Bool {
        let metadata = url.appending(path: "Metadata").appendingPathExtension("plist")
        return FileManager.default.fileExists(atPath: metadata.path(percentEncoded: false))
    }
}
