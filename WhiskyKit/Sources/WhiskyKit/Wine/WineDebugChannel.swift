//
//  WineDebugChannel.swift
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

/// One Wine debug channel, with the question it answers.
///
/// ``WineDebugPreset`` covers the four cases the diagnosis flow asks for. This
/// is the other half: a person who already knows which calls they want to watch,
/// picking them for a single run.
public struct WineDebugChannel: Identifiable, Hashable, Sendable {
    /// The channel name as Wine spells it, without the `+`.
    public let name: String

    /// What turning it on shows you, in one line.
    public let summary: String

    public var id: String { name }

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    /// The channels worth a checkbox, in the order a debugging session tends to
    /// need them. Anything else goes in the free text field.
    public static let common: [WineDebugChannel] = [
        WineDebugChannel(name: "err", summary: "Errors only. On by default in every run."),
        WineDebugChannel(name: "seh", summary: "Exceptions as they are thrown, the first stop for a crash."),
        WineDebugChannel(name: "file", summary: "File and directory calls, including the ones that fail."),
        WineDebugChannel(name: "ntdll", summary: "The syscall layer under file, registry and process calls."),
        WineDebugChannel(name: "loaddll", summary: "Every DLL as it loads, native or builtin."),
        WineDebugChannel(name: "module", summary: "Module resolution, for a DLL that will not load."),
        WineDebugChannel(name: "reg", summary: "Registry reads and writes."),
        WineDebugChannel(name: "d3d", summary: "Direct3D calls. Loud, and slows the game down."),
        WineDebugChannel(name: "dxgi", summary: "Swapchain and adapter enumeration."),
        WineDebugChannel(name: "msync", summary: "The sync primitive layer, for hangs and deadlocks."),
        WineDebugChannel(name: "relay", summary: "Every call across the PE boundary. Enormous, use with a filter.")
    ]

    /// A free text entry is only trusted as far as it looks like Wine's own
    /// syntax: `+chan`, `-chan`, `class+chan`, `class-chan`, or a bare name.
    /// One sign at most, and never trailing.
    private static func isChannelToken(_ token: String) -> Bool {
        let isSign: (Character) -> Bool = { $0 == "+" || $0 == "-" }
        guard token.count(where: isSign) <= 1, let last = token.last, !isSign(last) else { return false }

        let parts = token.split(whereSeparator: isSign)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" }
        }
    }

    /// Composes the `WINEDEBUG` value for a set of picks.
    ///
    /// `fixme-all` stays on the end the way ``WineDebugPreset`` writes it: the
    /// fixme class is noise in a run you are already watching on purpose.
    ///
    /// - Parameters:
    ///   - channels: Channel names to enable, without the `+`.
    ///   - extra: Free text the user typed, comma separated. Tokens that are not
    ///     channel-shaped are dropped rather than passed to Wine.
    /// - Returns: A value for `WINEDEBUG`, never empty.
    public static func winedebugValue(channels: Set<String>, extra: String = "") -> String {
        var tokens = channels.sorted().map { "+\($0)" }

        for token in extra.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, isChannelToken(trimmed) else { continue }
            // `warn+ntdll` already says which class it wants; only a bare
            // channel name needs the `+` Wine would otherwise not see.
            let signed = trimmed.contains("+") || trimmed.contains("-")
            let normalized = signed ? trimmed : "+\(trimmed)"
            if !tokens.contains(normalized) {
                tokens.append(normalized)
            }
        }

        tokens.append("fixme-all")
        return tokens.joined(separator: ",")
    }
}
