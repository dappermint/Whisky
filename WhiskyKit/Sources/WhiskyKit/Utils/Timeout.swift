//
//  Timeout.swift
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

/// Thrown when an operation was still running when its deadline passed.
public struct TimedOutError: LocalizedError, Equatable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public var errorDescription: String? {
        String(localized: "error.timedOut \(Int(seconds.rounded()))")
    }
}

/// Runs `operation`, giving up on it once `timeout` has passed.
///
/// A Wine command normally answers in seconds, but anything reading the prefix
/// queues behind whatever else holds it. A `wineboot` that wedges partway
/// through installing `wine.inf` never lets go, and a caller with no deadline
/// waits for that forever.
///
/// Losing the race cancels `operation`, which for a Wine call tears down the
/// stream and terminates the process it was waiting on.
///
/// - Parameters:
///   - timeout: How long `operation` is given.
///   - operation: The work to run.
/// - Returns: What `operation` returned, if it finished in time.
/// - Throws: ``TimedOutError`` if it did not, or whatever `operation` threw.
public func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let seconds = Double(timeout.components.seconds)
        + Double(timeout.components.attoseconds) / 1e18

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOutError(seconds: seconds)
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimedOutError(seconds: seconds)
        }
        return result
    }
}
