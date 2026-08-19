//
//  DebugChannelTests.swift
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

@Suite("Wine debug channel composition")
struct WineDebugChannelTests {
    @Test("No picks still silences fixme")
    func emptySelection() {
        #expect(WineDebugChannel.winedebugValue(channels: []) == "fixme-all")
    }

    @Test("Picked channels are sorted and prefixed")
    func picksCompose() {
        let value = WineDebugChannel.winedebugValue(channels: ["seh", "file"])
        #expect(value == "+file,+seh,fixme-all")
    }

    @Test("Free text keeps channel-shaped tokens and drops the rest")
    func freeTextIsFiltered() {
        let value = WineDebugChannel.winedebugValue(
            channels: ["file"],
            extra: "relay, -d3d, warn+ntdll, ../etc/passwd, rm -rf /, "
        )
        #expect(value == "+file,+relay,-d3d,warn+ntdll,fixme-all")
    }

    @Test("A channel picked twice is only written once")
    func duplicatesCollapse() {
        let value = WineDebugChannel.winedebugValue(channels: ["file"], extra: "file,+file")
        #expect(value == "+file,fixme-all")
    }
}

@Suite("Log tailing")
struct LogTailTests {
    @Test("Lines already in the file arrive, then lines appended after")
    func followsAppends() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).log")
        try "first\nsecond\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = LogTail(url: url, pollInterval: .milliseconds(20))
        var received: [String] = []

        let collector = Task {
            for await batch in tail.lines() {
                received.append(contentsOf: batch)
                if received.count >= 3 { break }
            }
            return received
        }

        // Give the first poll time to land before appending, so the append is a
        // genuine second read rather than part of the initial one.
        try await Task.sleep(for: .milliseconds(80))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("third\n".utf8))
        try handle.close()

        let lines = try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                collector.cancel()
                return []
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
        await tail.stop()

        #expect(lines == ["first", "second", "third"])
    }

    @Test("A line without its newline is held back until the newline arrives")
    func partialLineIsHeld() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).log")
        try "whole\npart".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = LogTail(url: url, pollInterval: .milliseconds(20))
        var received: [String] = []
        let collector = Task {
            for await batch in tail.lines() {
                received.append(contentsOf: batch)
                if received.count >= 2 { break }
            }
            return received
        }

        try await Task.sleep(for: .milliseconds(80))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\n".utf8))
        try handle.close()

        let lines = try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                collector.cancel()
                return []
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
        await tail.stop()

        #expect(lines == ["whole", "partial"])
    }

    @Test("Draining returns what landed after the last poll")
    func drainReturnsTheTail() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).log")
        try "first\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = LogTail(url: url, pollInterval: .seconds(60))
        // Nothing has polled yet, so everything in the file is still pending.
        #expect(await tail.drain() == ["first"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\nthird\n".utf8))
        try handle.close()

        #expect(await tail.drain() == ["second", "third"])
        #expect(await tail.drain().isEmpty)
    }
}
