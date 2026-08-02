//
//  SteamProcessWatch.swift
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

/// The polling half of Steam client orchestration: watches a bottle's process
/// list for executables to appear. The process-list source is injected so the
/// waiting and matching logic is testable without a live Wine bottle.
public struct SteamProcessWatch: Sendable {
    private let pollInterval: Duration
    private let runningImageNames: @Sendable () async -> Set<String>

    /// Creates a watch.
    ///
    /// - Parameters:
    ///   - pollInterval: How long to sleep between polls.
    ///   - runningImageNames: Source of the bottle's current lowercased
    ///     process image names (in production, tasklist.exe output).
    public init(
        pollInterval: Duration = .seconds(3),
        runningImageNames: @escaping @Sendable () async -> Set<String>
    ) {
        self.pollInterval = pollInterval
        self.runningImageNames = runningImageNames
    }

    /// Polls until any of `names` is running, up to `timeout`.
    ///
    /// Always checks at least once, so a zero timeout still observes the
    /// current state. An empty `names` set reports `true` immediately: there
    /// is nothing to wait for. Returns `false` on cancellation rather than
    /// running the timeout out, since `Task.sleep` throwing is swallowed here.
    public func waitForAny(of names: Set<String>, timeout: TimeInterval) async -> Bool {
        guard !names.isEmpty else { return true }

        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if await !runningImageNames().isDisjoint(with: names) {
                return true
            }
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return false }
        } while Date() < deadline
        return false
    }

    /// The keys whose executable-name sets intersect the running processes.
    ///
    /// Used to mark which games are currently running, keyed by App ID.
    public func runningKeys(byExecutables: [Int: Set<String>]) async -> Set<Int> {
        let running = await runningImageNames()
        return Set(byExecutables.filter { !$0.value.isDisjoint(with: running) }.keys)
    }
}
