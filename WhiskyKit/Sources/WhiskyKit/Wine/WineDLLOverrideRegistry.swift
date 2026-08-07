//
//  WineDLLOverrideRegistry.swift
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

public extension Wine {
    /// Where a set of DLL overrides lives in the prefix registry.
    enum DLLOverrideScope: Equatable, Sendable {
        /// The prefix default, used by any process without an entry of its own.
        case bottle
        /// This executable only. Children do not inherit it.
        case program(String)

        var registryKey: String {
            switch self {
            case .bottle:
                #"HKCU\Software\Wine\DllOverrides"#
            case let .program(executable):
                // \\#( is a literal backslash then the interpolation; \#( alone
                // would swallow the path separator.
                #"HKCU\Software\Wine\AppDefaults\\#(executable)\DllOverrides"#
            }
        }
    }

    private static let dllOverrideLogger = Logger(
        subsystem: "com.isaacmarovitz.WhiskyKit", category: "dll-overrides"
    )

    /// Replaces the DLL overrides at each scope, in one import.
    ///
    /// One import rather than a `reg` call per value: each of those is a whole
    /// wine process, and a launch syncing a bottle plus a launcher and its
    /// helpers spent twenty-odd of them before starting anything.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose prefix registry is written.
    ///   - scopes: Each scope and the `WINEDLLOVERRIDES`-syntax string it
    ///     should hold. An empty string clears that scope.
    @MainActor
    static func syncDLLOverrides(
        bottle: Bottle, scopes: [(scope: DLLOverrideScope, overrides: String)]
    ) async throws {
        let document = registryDocument(
            for: scopes.map { (key: $0.scope.registryKey, overrides: parseDLLOverrides($0.overrides)) }
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "whisky-dll-overrides-\(UUID().uuidString).reg")
        try document.write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        try await runWine(["regedit", url.path(percentEncoded: false)], bottle: bottle)
        dllOverrideLogger.debug("Synced DLL overrides for \(scopes.count) scope(s) in one import")
    }

    /// Renders a `.reg` leaving each key holding exactly `overrides`.
    ///
    /// `[-Key]` then `[Key]` is a replace, since `.reg` runs in order. That is
    /// what prunes stale values without reading the key back first.
    static func registryDocument(for scopes: [(key: String, overrides: [String: String])]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for scope in scopes {
            lines.append("[-\(scope.key)]")
            lines.append("")
            guard !scope.overrides.isEmpty else { continue }
            lines.append("[\(scope.key)]")
            for (dll, mode) in scope.overrides.sorted(by: { $0.key < $1.key }) {
                lines.append("\"\(dll)\"=\"\(mode)\"")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// The launcher helpers that must share `url`'s DLL overrides.
    ///
    /// Detected from the executable, not the bottle's recorded launcher: they
    /// need the entry because of how wine resolves `AppDefaults`, not because
    /// the user enabled launcher fixes.
    static func helperExecutables(for url: URL) -> [String] {
        LauncherType.detect(from: url)?.helperExecutables ?? []
    }

    /// Parses a `WINEDLLOVERRIDES` string into DLL name to load-order pairs.
    ///
    /// The registry takes the same syntax, so values pass through unchanged.
    /// `dll=` is kept: an empty value is how a DLL is disabled in both forms.
    static func parseDLLOverrides(_ overrides: String) -> [String: String] {
        var result: [String: String] = [:]
        for clause in overrides.split(separator: ";") {
            let parts = clause.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let dll = name.trimmingCharacters(in: .whitespaces)
            guard !dll.isEmpty else { continue }
            result[dll] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        return result
    }
}
