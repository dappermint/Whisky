//
//  LogTail.swift
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

private let tailLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "LogTail")

/// Follows a Wine run log while it is still being written.
///
/// Polling rather than a dispatch source: the log is appended to by a process
/// tree Whisky does not own, over a path that can be replaced between runs, and
/// a 400ms read costs nothing next to what the game is doing. The same reason
/// the late-crash watcher polls.
public actor LogTail {
    /// The file being followed.
    public let url: URL

    private let pollInterval: Duration
    private let chunkLimit: Int
    private var offset: UInt64 = 0
    private var carry = ""
    private var stopped = false

    /// - Parameters:
    ///   - url: The log file. It does not have to exist yet.
    ///   - fromStart: Whether to yield what the file already holds before
    ///     following new writes. A debug session wants the whole run.
    ///   - pollInterval: How often to look for new bytes.
    ///   - chunkLimit: Most bytes read per poll, so a runaway `+relay` log
    ///     cannot pull hundreds of megabytes into memory in one pass.
    public init(
        url: URL,
        fromStart: Bool = true,
        pollInterval: Duration = .milliseconds(400),
        chunkLimit: Int = 512 * 1_024
    ) {
        self.url = url
        self.pollInterval = pollInterval
        self.chunkLimit = chunkLimit
        if !fromStart {
            offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
    }

    /// Lines appended to the file, batched per poll.
    ///
    /// The stream finishes when ``stop()`` is called or the consuming task is
    /// cancelled. A partial last line is held back until its newline arrives.
    public nonisolated func lines() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, await self.keepGoing() {
                    let batch = await self.readNewLines()
                    if !batch.isEmpty {
                        continuation.yield(batch)
                    }
                    try? await Task.sleep(for: self.pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the stream at the next poll.
    public func stop() {
        stopped = true
    }

    private func keepGoing() -> Bool { !stopped }

    private func readNewLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            // The file was replaced or truncated under us, which is what a new
            // run looks like. Start again from the top rather than reading into
            // the middle of a line.
            offset = 0
            carry = ""
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.read(upToCount: chunkLimit), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        guard let text = String(bytes: data, encoding: .utf8) else {
            tailLogger.debug("Skipping a chunk of \(data.count) bytes that is not valid UTF-8")
            return []
        }

        var pieces = (carry + text).components(separatedBy: "\n")
        carry = pieces.removeLast()
        return pieces
    }
}
