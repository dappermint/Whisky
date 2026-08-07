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

    /// Writes `overrides` to the registry at `scope`, removing any entries the
    /// scope previously held that are no longer wanted.
    ///
    /// The prune half matters because registry state persists where an
    /// environment variable did not: switching a bottle from DXVK to D3DMetal
    /// has to clear the `d3d9` entry DXVK's preset wrote, or it lingers.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose prefix registry is written.
    ///   - scope: Bottle default, or a single executable.
    ///   - overrides: A `WINEDLLOVERRIDES`-syntax string, for example
    ///     `d3d11=n,b;dxgi=n,b`. Empty clears the scope.
    @MainActor
    static func syncDLLOverrides(
        bottle: Bottle, scope: DLLOverrideScope, overrides: String
    ) async throws {
        let key = scope.registryKey
        let existing = await (try? queryDLLOverrides(bottle: bottle, key: key)) ?? [:]
        let plan = syncPlan(existing: existing, wanted: parseDLLOverrides(overrides))

        guard !plan.isEmpty else {
            dllOverrideLogger.debug("DLL overrides at \(key) already match, nothing to write")
            return
        }

        for (dll, mode) in plan.writes {
            try await addRegistryKey(bottle: bottle, key: key, name: dll, data: mode, type: .string)
        }
        for name in plan.deletes {
            try? await runWine(["reg", "delete", key, "-v", name, "-f"], bottle: bottle)
        }

        dllOverrideLogger.debug(
            "Synced \(plan.writes.count) DLL override(s) to \(key), pruned \(plan.deletes.count)"
        )
    }

    /// What ``syncDLLOverrides(bottle:scope:overrides:)`` has to do to turn
    /// `existing` into `wanted`.
    struct DLLOverrideSyncPlan: Equatable, Sendable {
        /// DLL name and load order to write, sorted by name.
        public let writes: [(dll: String, mode: String)]
        /// Value names to remove, sorted.
        public let deletes: [String]

        public var isEmpty: Bool { writes.isEmpty && deletes.isEmpty }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.deletes == rhs.deletes && lhs.writes.map(\.dll) == rhs.writes.map(\.dll)
                && lhs.writes.map(\.mode) == rhs.writes.map(\.mode)
        }
    }

    /// The minimal set of registry operations that turns `existing` into
    /// `wanted`.
    ///
    /// Every write is a wine process, and launches are frequent while the
    /// overrides rarely change between them, so anything already correct is
    /// left alone. Deletes are what an environment variable never needed:
    /// registry state persists, so switching a bottle from DXVK to D3DMetal has
    /// to clear the `d3d9` entry DXVK's preset wrote or it lingers forever.
    static func syncPlan(
        existing: [String: String], wanted: [String: String]
    ) -> DLLOverrideSyncPlan {
        DLLOverrideSyncPlan(
            writes: wanted.sorted { $0.key < $1.key }
                .filter { existing[$0.key] != $0.value }
                .map { (dll: $0.key, mode: $0.value) },
            deletes: existing.keys.filter { wanted[$0] == nil }.sorted()
        )
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

    /// The DLL overrides currently written under `key`, or an empty dictionary
    /// when the key does not exist.
    @MainActor
    static func queryDLLOverrides(bottle: Bottle, key: String) async throws -> [String: String] {
        try await parseRegistryQueryOutput(runWine(["reg", "query", key], bottle: bottle))
    }

    /// Parses `reg query` output into DLL name to load-order pairs.
    ///
    /// Lines look like `    d3d11    REG_SZ    n,b`: name, type, then the value,
    /// which is absent for a disabled override. The key's own header line
    /// carries no `REG_` type and is skipped, as is the blank line around it.
    static func parseRegistryQueryOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1].hasPrefix("REG_") else { continue }
            result[String(fields[0])] = fields.count > 2 ? String(fields[2]) : ""
        }
        return result
    }
}
