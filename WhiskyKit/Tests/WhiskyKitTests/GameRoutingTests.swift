//
//  GameRoutingTests.swift
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

@Suite("GameRouting Tests")
struct GameRoutingTests {
    private func makeStore() -> (routing: GameRouting, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = tempDir.appending(path: "GameRouting.plist")
        return (GameRouting(url: url), { try? FileManager.default.removeItem(at: tempDir) })
    }

    @Test("Records and reads a route")
    func recordsRoute() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        let bottle = URL(fileURLWithPath: "/tmp/bottles/one")
        routing.record(appId: 4_576_510, bottleURL: bottle)

        #expect(routing.bottleURL(forAppId: 4_576_510) == bottle)
        #expect(routing.routes()[4_576_510] == bottle)
    }

    @Test("Last launch wins")
    func lastLaunchWins() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: "/tmp/bottles/one"))
        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: "/tmp/bottles/two"))

        #expect(routing.bottleURL(forAppId: 1)?.lastPathComponent == "two")
        #expect(routing.routes().count == 1)
    }

    @Test("Unknown App IDs and a missing store read as empty")
    func unknownReadsEmpty() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        #expect(routing.bottleURL(forAppId: 99) == nil)
        #expect(routing.routes().isEmpty)
    }

    @Test("Removes every route pointing at a bottle, keeping the rest")
    func removesRoutesToBottle() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        let doomed = URL(fileURLWithPath: "/tmp/bottles/doomed")
        routing.record(appId: 1, bottleURL: doomed)
        routing.record(appId: 2, bottleURL: URL(fileURLWithPath: "/tmp/bottles/kept"))
        routing.record(appId: 3, bottleURL: doomed)

        routing.removeRoutes(toBottle: doomed)

        #expect(routing.bottleURL(forAppId: 1) == nil)
        #expect(routing.bottleURL(forAppId: 3) == nil)
        #expect(routing.bottleURL(forAppId: 2)?.lastPathComponent == "kept")
        #expect(routing.routes().count == 1)
    }

    @Test("Bottle paths match the way resolution compares them")
    func removesRoutesByStandardizedPath() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: "/tmp/bottles/one"))
        routing.removeRoutes(toBottle: URL(fileURLWithPath: "/tmp/bottles/./one"))

        #expect(routing.bottleURL(forAppId: 1) == nil)
    }

    @Test("Pruning without a match never creates the store")
    func pruneWithoutMatchWritesNothing() {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appending(path: "GameRouting.plist")

        let routing = GameRouting(url: url)
        routing.removeRoutes(toBottle: URL(fileURLWithPath: "/tmp/bottles/none"))

        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("Keeps other routes when one changes")
    func keepsOtherRoutes() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: "/tmp/bottles/one"))
        routing.record(appId: 2, bottleURL: URL(fileURLWithPath: "/tmp/bottles/two"))
        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: "/tmp/bottles/three"))

        #expect(routing.routes().count == 2)
        #expect(routing.bottleURL(forAppId: 2)?.lastPathComponent == "two")
    }

    @Test("A launch records when it happened, which is what the library sorts on")
    func recordsLaunchTime() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        let when = Date(timeIntervalSince1970: 1_760_000_000)
        routing.record(appId: 1_245_620, bottleURL: URL(fileURLWithPath: "/tmp/bottles/one"), at: when)

        #expect(routing.lastLaunched(forAppId: 1_245_620) == when)
        #expect(routing.lastLaunches()[1_245_620] == when)
    }

    @Test("Relaunching moves the time forward")
    func lastLaunchTimeWins() {
        let (routing, cleanup) = makeStore()
        defer { cleanup() }

        let bottle = URL(fileURLWithPath: "/tmp/bottles/one")
        let earlier = Date(timeIntervalSince1970: 1_760_000_000)
        let later = Date(timeIntervalSince1970: 1_760_003_600)
        routing.record(appId: 1, bottleURL: bottle, at: earlier)
        routing.record(appId: 1, bottleURL: bottle, at: later)

        #expect(routing.lastLaunched(forAppId: 1) == later)
    }

    @Test("A store written before launch times reads as a route with no date")
    func readsTheLegacyShape() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "GameRouting.plist")
        let legacy = try PropertyListSerialization.data(
            fromPropertyList: ["440": "/tmp/bottles/one"], format: .xml, options: 0
        )
        try legacy.write(to: url)

        let routing = GameRouting(url: url)

        #expect(routing.bottleURL(forAppId: 440)?.lastPathComponent == "one")
        #expect(routing.lastLaunched(forAppId: 440) == nil)
        #expect(routing.lastLaunches().isEmpty)
    }

    @Test("Only launches that have a time are reported as having one")
    func launchesWithoutTimesAreOmitted() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "GameRouting.plist")
        let legacy = try PropertyListSerialization.data(
            fromPropertyList: ["440": "/tmp/bottles/one"], format: .xml, options: 0
        )
        try legacy.write(to: url)

        let routing = GameRouting(url: url)
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        routing.record(appId: 550, bottleURL: URL(fileURLWithPath: "/tmp/bottles/two"), at: when)

        #expect(routing.routes().count == 2)
        #expect(routing.lastLaunches() == [550: when])
    }

    @Test("A route matches its bottle whether or not the bottle still exists")
    func pathsMatchAfterTheBottleIsDeleted() throws {
        // `URL(fileURLWithPath:)` consults the filesystem and returns a
        // directory URL for a path that exists, whose path keeps a trailing
        // slash. Pruning happens after deletion, so the two must still match.
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bottle = tempDir.appending(path: "Bottle")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let routing = GameRouting(url: tempDir.appending(path: "GameRouting.plist"))
        routing.record(appId: 1, bottleURL: URL(fileURLWithPath: bottle.path(percentEncoded: false)))
        routing.record(appId: 2, bottleURL: URL(fileURLWithPath: bottle.path(percentEncoded: false)))

        try FileManager.default.removeItem(at: bottle)
        routing.removeRoutes(toBottle: bottle)

        #expect(routing.routes().isEmpty)
    }

    @Test("A corrupt store is treated as empty, not fatal")
    func corruptStoreIsEmpty() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "GameRouting.plist")
        try Data("this is not a plist".utf8).write(to: url)

        let routing = GameRouting(url: url)
        #expect(routing.routes().isEmpty)

        // and writing over it still works
        routing.record(appId: 5, bottleURL: URL(fileURLWithPath: "/tmp/bottles/five"))
        #expect(routing.bottleURL(forAppId: 5) != nil)
    }
}
