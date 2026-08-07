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
    ///
    /// `WINEDLLOVERRIDES` cannot express either of these: an environment
    /// variable is inherited by every child process, so a launcher's overrides
    /// silently become every game's overrides. Wine reads the variable before
    /// the registry, so registry entries are dead while it is set.
    enum DLLOverrideScope: Equatable, Sendable {
        /// `HKCU\Software\Wine\DllOverrides`: the prefix default, used by any
        /// process without an entry of its own. This is what a game launched by
        /// a launcher should fall back to.
        case bottle
        /// `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`: this executable
        /// only. Children do not inherit it.
        case program(String)

        var registryKey: String {
            switch self {
            case .bottle:
                #"HKCU\Software\Wine\DllOverrides"#
            case let .program(executable):
                // \\#( is a literal backslash followed by the interpolation:
                // \#( alone would be read as the interpolation and swallow the
                // path separator.
                #"HKCU\Software\Wine\AppDefaults\\#(executable)\DllOverrides"#
            }
        }
    }

    private static let dllOverrideLogger = Logger(
        subsystem: "com.isaacmarovitz.WhiskyKit", category: "dll-overrides"
    )

    /// Replaces the DLL overrides at each scope with the ones given, in a
    /// single registry import.
    ///
    /// One import, not one `reg` invocation per value: every `reg add` and
    /// `reg delete` is a whole wine process, and a launch that syncs a bottle
    /// scope plus a launcher and its helpers was spending twenty-odd sequential
    /// process launches before the program it was asked to start. A `.reg` file
    /// deletes each key and rewrites it, so nothing has to be read back first
    /// and stale values from a previous backend cannot survive.
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

    /// Renders a `.reg` document that leaves each key holding exactly
    /// `overrides` and nothing else.
    ///
    /// Each key is deleted and recreated rather than edited. `.reg` processes
    /// entries in order, so `[-Key]` followed by `[Key]` is a replace, which is
    /// both how stale values get pruned and why no read-back is needed.
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

    /// The launcher helper executables that must share `url`'s DLL overrides,
    /// or none when the executable is not a recognised launcher.
    ///
    /// Detection runs on the launched executable rather than the bottle's
    /// recorded launcher, so this is right even when launcher compatibility
    /// mode is off: the reason the helpers need the entry is how wine resolves
    /// `AppDefaults`, not whether the user opted into launcher fixes.
    static func helperExecutables(for url: URL) -> [String] {
        LauncherType.detect(from: url)?.helperExecutables ?? []
    }

    /// Parses a `WINEDLLOVERRIDES` string into DLL name to load-order pairs.
    ///
    /// Wine's registry accepts the same load-order syntax as the variable, so
    /// the values are written through unchanged. `dll=` (disabled) is kept: an
    /// empty value is how a DLL is disabled in both forms.
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
