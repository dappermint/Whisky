//
//  DebugSessionModel.swift
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
import os.log
import SwiftUI
import WhiskyKit

/// One line of a Wine log, classified by the class Wine stamped on it.
struct DebugLogLine: Identifiable, Hashable {
    enum Severity: String, CaseIterable {
        case err, warn, fixme, trace, plain
    }

    let id: Int
    let text: String
    let severity: Severity
    let channel: String?

    /// Wine writes `00e4:err:ntoskrnl:ZwLoadDriver failed`, so the class and the
    /// channel are the second and third colon-separated fields. Anything that
    /// does not match that shape is the program's own stdout and stays plain.
    init(id: Int, text: String) {
        self.id = id
        self.text = text

        let fields = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let severity = Severity(rawValue: String(fields[1])) else {
            self.severity = .plain
            self.channel = nil
            return
        }
        self.severity = severity
        self.channel = String(fields[2])
    }
}

/// The state behind the Debug window: what to launch, with which channels, and
/// the log it produced.
@MainActor
final class DebugSessionModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, problems, fixme, trace
        var id: String { rawValue }
    }

    /// Lines kept in memory. A `+relay` run writes millions, and nobody scrolls
    /// back through more than this by hand.
    private static let lineLimit = 5_000

    @Published var bottle: Bottle?
    @Published var program: Program?
    @Published var channels: Set<String> = ["err", "seh"]
    @Published var extraChannels = ""
    @Published var filter: Filter = .all
    @Published var search = ""
    @Published private(set) var lines: [DebugLogLine] = []
    @Published private(set) var isFollowing = false
    @Published private(set) var followedLog: URL?
    @Published private(set) var status: String?

    private var tail: LogTail?
    private var followTask: Task<Void, Never>?
    private var nextLineID = 0
    private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "DebugSession")

    /// The `WINEDEBUG` value the current picks add up to.
    var winedebugValue: String {
        WineDebugChannel.winedebugValue(channels: channels, extra: extraChannels)
    }

    var visibleLines: [DebugLogLine] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return lines.filter { line in
            guard passesFilter(line) else { return false }
            guard !needle.isEmpty else { return true }
            return line.text.lowercased().contains(needle)
        }
    }

    private func passesFilter(_ line: DebugLogLine) -> Bool {
        switch filter {
        case .all: true
        case .problems: line.severity == .err || line.severity == .warn
        case .fixme: line.severity == .fixme
        case .trace: line.severity == .trace
        }
    }

    /// Launches the selected program through the one launch door, with the
    /// picked channels as a one-off environment, and follows its log live.
    ///
    /// Attached, so the program is this process's child rather than
    /// wineserver's. Handed to wineserver it gets a console of its own and
    /// writes nothing this window could read: the log fills with Wine's session
    /// coming up and never with the program. The call lasts as long as the
    /// program does, so the log arrives through ``follow(_:)`` at the start
    /// rather than as a return value at the end.
    func launch() async {
        guard let program else { return }
        let programName = program.name

        clear()
        status = String(localized: "debug.status.launching")

        let result = await program.launchWithUserMode(
            useTerminal: false,
            debugEnvironment: ["WINEDEBUG": winedebugValue],
            keepAttached: true,
            onLogFile: { [weak self] logURL in
                self?.status = String(localized: "debug.status.running \(programName)")
                self?.follow(logURL)
            }
        )

        switch result {
        case .launchedSuccessfully, .launchedInTerminal:
            status = String(localized: "debug.status.finished \(programName)")
        case let .launchFailed(_, errorDescription):
            status = errorDescription
        }
        // The program is gone, so the file has stopped growing. Read what it
        // wrote on the way out before letting go of it, then say so instead of
        // leaving the streaming light on over a log nothing is writing.
        if let tail {
            await append(tail.drain())
        }
        stopFollowing()
    }

    /// Follows a log file, replacing whatever was being followed before.
    func follow(_ url: URL) {
        stopFollowing()

        let tail = LogTail(url: url)
        self.tail = tail
        followedLog = url
        isFollowing = true

        followTask = Task { [weak self] in
            for await batch in tail.lines() {
                guard let self else { return }
                await self.append(batch)
            }
            await self?.markStopped()
        }
    }

    /// The newest log Whisky has written, which is the run to watch when the
    /// game was started from the library rather than from here.
    func followLatestLog() {
        let folder = Wine.logsFolder
        let newest = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "log" }
        .max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (left ?? .distantPast) < (right ?? .distantPast)
        }

        guard let newest else {
            status = String(localized: "debug.status.noLogs")
            return
        }
        clear()
        status = newest.lastPathComponent
        follow(newest)
    }

    func stopFollowing() {
        followTask?.cancel()
        followTask = nil
        let closing = tail
        tail = nil
        isFollowing = false
        Task { await closing?.stop() }
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
    }

    private func append(_ batch: [String]) {
        for text in batch {
            lines.append(DebugLogLine(id: nextLineID, text: text))
            nextLineID += 1
        }
        if lines.count > Self.lineLimit {
            lines.removeFirst(lines.count - Self.lineLimit)
        }
    }

    private func markStopped() {
        isFollowing = false
    }
}
