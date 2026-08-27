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

import CryptoKit
import Foundation

/// One compatibility tool per installed runtime, so the client's own
/// Compatibility picker is the switch between them, the way it switches
/// between Proton builds.
public extension SteamCompatTool {
    /// Architecture names the client reads out of a tool's identifier.
    ///
    /// Longest first, so `arm64` is gone before `arm` can take a bite out of it.
    private static let architectureTokens = [
        "aarch64", "x86_64", "arm64", "amd64", "i386", "x64", "arm"
    ]

    /// The identifier for the tool that runs on `runtime`.
    ///
    /// The default runtime keeps ``name`` exactly, because that string is what
    /// every existing `CompatToolMapping` in `config.vdf` points at and a
    /// change orphans them. Additional runtimes get a suffix, and a leading
    /// `whisky-` is dropped from it so the result reads as one name rather than
    /// saying Whisky twice.
    ///
    /// An architecture name is dropped from that suffix too. The client reads
    /// one out of the identifier and drops the tool before it reaches the
    /// picker, logging "Ignoring tool <id> as it's for a different target
    /// platform macos arm64" and nothing else. ``displayName(for:label:)`` is
    /// not searched, so the picker still says which runtime it is.
    ///
    /// The result still contains `proton`, which is not cosmetic: the client
    /// only installs the Windows save-path overrides when a case insensitive
    /// search for it hits this string.
    static func name(for runtime: String?) -> String {
        guard let runtime, !runtime.isEmpty else { return name }
        var suffix = runtime
        if suffix.hasPrefix("whisky-") { suffix.removeFirst("whisky-".count) }

        for token in architectureTokens {
            suffix = suffix.replacingOccurrences(of: token, with: "", options: [.caseInsensitive])
        }
        // Stripping a token leaves the separators that surrounded it.
        while suffix.contains("--") {
            suffix = suffix.replacingOccurrences(of: "--", with: "-")
        }
        suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))

        // A runtime named after nothing but its architecture still needs an
        // identifier, and it has to be the same one on every launch or every
        // mapping to it is orphaned.
        guard !suffix.isEmpty else { return "\(name)-\(digest(of: runtime))" }
        return "\(name)-\(suffix)"
    }

    /// A short stable digest, for the identifier of a runtime whose name says
    /// nothing but its architecture.
    private static func digest(of runtime: String) -> String {
        SHA256.hash(data: Data(runtime.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// What the client lists the tool for `runtime` as.
    ///
    /// A leading `whisky-` is dropped so the picker reads "Whisky arm64"
    /// rather than saying Whisky twice.
    static func displayName(for runtime: String?, label: String? = nil) -> String {
        guard let runtime, !runtime.isEmpty else { return displayName }
        var suffix = label ?? runtime
        if suffix.hasPrefix("whisky-") { suffix.removeFirst("whisky-".count) }
        return "\(displayName) \(suffix)"
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

        // Two runtimes of one lane would list under a single name, and the
        // picker is then a coin toss. The identifier already carries the
        // version, so it is what tells them apart.
        var counts: [String: Int] = [:]
        for entry in runtimes {
            counts[displayName(for: entry.runtime, label: entry.label), default: 0] += 1
        }

        for entry in runtimes {
            let ambiguous = counts[displayName(for: entry.runtime, label: entry.label), default: 0] > 1
            try install(
                whiskyCmd: whiskyCmd, runtime: entry.runtime,
                label: ambiguous ? entry.runtime : entry.label, at: root
            )
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
