//
//  SteamCompatTool+Runtimes.swift
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

/// One compatibility tool per installed runtime, so the client's own
/// Compatibility picker is the switch between them, the way it switches
/// between Proton builds.
public extension SteamCompatTool {
    /// The identifier for the tool that runs on `runtime`.
    ///
    /// The default runtime keeps ``name`` exactly, because that string is what
    /// every existing `CompatToolMapping` in `config.vdf` points at and a
    /// change orphans them. Additional runtimes get a suffix, and a leading
    /// `whisky-` is dropped from it so the result reads as one name rather than
    /// saying Whisky twice.
    ///
    /// Still contains `proton`, which is not cosmetic: the client only installs
    /// the Windows save-path overrides when a case insensitive search for it
    /// hits this string.
    static func name(for runtime: String?) -> String {
        guard let runtime, !runtime.isEmpty else { return name }
        var suffix = runtime
        if suffix.hasPrefix("whisky-") { suffix.removeFirst("whisky-".count) }
        return "\(name)-\(suffix)"
    }

    /// What the client lists the tool for `runtime` as.
    static func displayName(for runtime: String?, label: String? = nil) -> String {
        guard let runtime, !runtime.isEmpty else { return displayName }
        return "\(displayName) (\(label ?? runtime))"
    }

    /// Where the tool for `runtime` keeps its files.
    static func toolDirectory(for runtime: String?, at root: URL = sharedToolsDirectory) -> URL {
        root.appending(path: name(for: runtime))
    }

    /// One tool per installed runtime, so the client's own Compatibility picker
    /// is what chooses between them, the way it chooses between Proton builds.
    ///
    /// Tools for runtimes that are gone are removed. A stale one is worse than
    /// a missing one: the client keeps listing it, and a game still mapped to it
    /// fails at launch rather than falling back.
    ///
    /// - Parameters:
    ///   - whiskyCmd: The `WhiskyCmd` binary every runner forwards to.
    ///   - runtimes: Identifier and picker label for each runtime, `nil`
    ///     identifier being the default one.
    ///   - root: The directory the client scans.
    static func installAll(
        whiskyCmd: URL,
        runtimes: [(runtime: String?, label: String?)],
        at root: URL = sharedToolsDirectory
    ) throws {
        let wanted = Set(runtimes.map { name(for: $0.runtime) })
        for entry in runtimes {
            try install(whiskyCmd: whiskyCmd, runtime: entry.runtime, label: entry.label, at: root)
        }
        try pruneTools(keeping: wanted, at: root)
    }

    /// Removes tool directories we wrote for runtimes that no longer exist.
    ///
    /// Only directories whose name we would have generated and that carry our
    /// runner, so a tool somebody else installed alongside is never touched.
    static func pruneTools(keeping wanted: Set<String>, at root: URL) throws {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        for folder in contents {
            let identifier = folder.lastPathComponent
            guard identifier.hasPrefix("\(name)-"), !wanted.contains(identifier) else { continue }
            guard FileManager.default.fileExists(
                atPath: folder.appending(path: runnerName).path(percentEncoded: false)
            )
            else { continue }
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// The runtime a runner names on the command line, empty for the default.
    ///
    /// Written into a shell script, so it is quoted rather than interpolated
    /// bare: a runtime identifier reaches here from a folder name.
    static func runtimeArgument(_ runtime: String?) -> String {
        guard let runtime, !runtime.isEmpty else { return "" }
        return " --runtime \(shellQuoted(runtime))"
    }
}
