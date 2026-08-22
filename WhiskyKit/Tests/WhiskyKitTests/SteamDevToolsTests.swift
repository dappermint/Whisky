//
//  SteamDevToolsTests.swift
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

@Suite("SteamDevTools Tests")
struct SteamDevToolsTests {
    /// A `/json` listing shaped like the client's, including the page with no
    /// endpoint that it always returns alongside the real ones.
    private let listing = Data("""
    [
      {"title": "Steam", "type": "page",
       "webSocketDebuggerUrl": "ws://localhost:8080/devtools/page/133E8915B3C1"},
      {"title": "SharedJSContext", "type": "page",
       "webSocketDebuggerUrl": "ws://localhost:8080/devtools/page/F717938CF1FB"},
      {"title": "Detached", "type": "page"}
    ]
    """.utf8)

    @Test("Reads the pages the client has open")
    func decodesTargets() {
        let targets = SteamDevTools.decodeTargets(from: listing)

        #expect(targets.map(\.title) == ["Steam", "SharedJSContext"])
    }

    @Test("A page with nothing to attach to is dropped")
    func dropsTargetsWithNoEndpoint() {
        let targets = SteamDevTools.decodeTargets(from: listing)

        #expect(targets.allSatisfy { $0.webSocketDebuggerURL != nil })
    }

    @Test("A listing that is not a listing yields nothing rather than throwing")
    func survivesGarbage() {
        #expect(SteamDevTools.decodeTargets(from: Data("not json".utf8)).isEmpty)
    }

    @Test("The shared context is the page carrying SteamClient")
    func findsTheSharedContext() throws {
        let targets = SteamDevTools.decodeTargets(from: listing)
        let shared = try #require(
            targets.first { $0.title == SteamDevToolsTarget.sharedContextTitle }
        )

        #expect(shared.webSocketDebuggerURL?.absoluteString.hasSuffix("F717938CF1FB") == true)
    }

    // MARK: - Replies

    @Test("Reads the id and result off a reply")
    func decodesAReply() throws {
        let frame = URLSessionWebSocketTask.Message.string(
            #"{"id": 7, "result": {"identifier": "1.2"}}"#
        )
        let reply = try #require(SteamDevTools.decodeReply(frame))

        #expect(reply.id == 7)
        #expect(reply.result["identifier"] as? String == "1.2")
        #expect(reply.error == nil)
    }

    @Test("Reads the message off a protocol error")
    func decodesAnError() throws {
        let frame = URLSessionWebSocketTask.Message.string(
            #"{"id": 7, "error": {"code": -32000, "message": "Not attached"}}"#
        )
        let reply = try #require(SteamDevTools.decodeReply(frame))

        #expect(reply.error == "Not attached")
    }

    /// The client talks constantly on the same socket, and none of it is
    /// addressed to us. An event has no id, which is how it gets skipped.
    @Test("An event carries no id, so it is not mistaken for a reply")
    func decodesAnEventWithoutAnId() throws {
        let frame = URLSessionWebSocketTask.Message.string(
            #"{"method": "Runtime.consoleAPICalled", "params": {"type": "log"}}"#
        )
        let reply = try #require(SteamDevTools.decodeReply(frame))

        #expect(reply.id == nil)
    }

    @Test("A frame that is not JSON is not a reply")
    func rejectsANonReplyFrame() {
        #expect(SteamDevTools.decodeReply(.string("<html>")) == nil)
    }

    // MARK: - Against a running client

    /// Does nothing unless a Steam client started with `-cef-enable-debugging`
    /// is up, because nothing else can answer. The decoding tests above prove
    /// the shapes; this one proves the conversation, on the machine of whoever
    /// has a client running.
    @Test("Attaches to a running client and evaluates in its shared context")
    func talksToARunningClient() async throws {
        guard await SteamDevTools.isListening() else { return }

        let devTools = SteamDevTools()
        try await devTools.connect()
        defer { Task { await devTools.disconnect() } }

        #expect(try await devTools.evaluate("1 + 1") == "2")
        #expect(try await devTools.evaluate("typeof SteamClient") == "\"object\"")

        let identifier = try await devTools.installPatch("window.__whiskyPatchProbe = 42;")
        #expect(identifier != nil)
        #expect(try await devTools.evaluate("window.__whiskyPatchProbe") == "42")

        if let identifier {
            try await devTools.removePatch(identifier: identifier)
        }
    }

    // MARK: - Errors

    @Test("Every failure says which one it is")
    func errorsAreDistinct() {
        let errors: [SteamDevToolsError] = [
            .notListening(port: 8_080),
            .noSharedContext,
            .evaluationFailed("TypeError"),
            .protocolFailure("closed")
        ]
        let descriptions = errors.compactMap(\.errorDescription)

        #expect(descriptions.count == errors.count)
        #expect(Set(descriptions).count == errors.count)
    }
}
