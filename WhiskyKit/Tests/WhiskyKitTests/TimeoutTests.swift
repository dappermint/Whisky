//
//  TimeoutTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("Timeout")
struct TimeoutTests {
    @Test("Work that finishes in time returns its own value")
    func returnsValue() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("Work that overruns throws rather than waiting on it")
    func throwsOnOverrun() async {
        await #expect(throws: TimedOutError.self) {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
    }

    @Test("The operation's own error is what surfaces, not the deadline")
    func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTimeout(.seconds(5)) { throw Boom() }
        }
    }

    /// The point of the deadline is that the work stops, not just that the
    /// caller stops waiting: a Wine call left running holds the prefix.
    @Test("Losing the race cancels the work")
    func cancelsOverrunningWork() async throws {
        let observed = Observed()

        _ = try? await withTimeout(.milliseconds(50)) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await observed.markCancelled()
            }
            return 0
        }

        // The cancellation lands on the losing child as the group tears down.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await observed.wasCancelled)
    }

    private actor Observed {
        var wasCancelled = false
        func markCancelled() { wasCancelled = true }
    }
}
