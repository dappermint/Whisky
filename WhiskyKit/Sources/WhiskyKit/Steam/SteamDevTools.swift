//
//  SteamDevTools.swift
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

/// A page the macOS Steam client has open in its embedded Chromium.
public struct SteamDevToolsTarget: Decodable, Equatable, Sendable {
    /// The page title, which is how the interesting one is found.
    public let title: String
    /// The DevTools protocol endpoint for this page.
    public let webSocketDebuggerURL: URL?

    enum CodingKeys: String, CodingKey {
        case title
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }

    /// The page that owns `SteamClient`, the client's whole scripting surface.
    ///
    /// Every other page is a view. This one is the shared context they all talk
    /// through, and the only one worth attaching to.
    public static let sharedContextTitle = "SharedJSContext"
}

/// Errors thrown while talking to the Steam client's DevTools endpoint.
public enum SteamDevToolsError: LocalizedError, Equatable {
    /// Nothing is listening, so the client was not started with
    /// `-cef-enable-debugging`.
    case notListening(port: Int)
    /// The client is listening but has no shared context page yet, which it
    /// does not until its UI has loaded.
    case noSharedContext
    /// The evaluated JavaScript threw.
    case evaluationFailed(String)
    /// The socket closed or answered something unreadable.
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .notListening(port):
            String(localized: "steam.devtools.error.notListening \(port)")
        case .noSharedContext:
            String(localized: "steam.devtools.error.noSharedContext")
        case let .evaluationFailed(message):
            String(localized: "steam.devtools.error.evaluation \(message)")
        case let .protocolFailure(message):
            String(localized: "steam.devtools.error.protocol \(message)")
        }
    }
}

/// Talks to the macOS Steam client's UI over the Chrome DevTools Protocol.
///
/// The client's interface is a Chromium app, so its behaviour is decided in
/// JavaScript that can be read and replaced from outside. That is the whole
/// reason this exists: the macOS client refuses to launch a Windows game with
/// `AppError_29` and hides the compatibility settings behind a one-line
/// platform check, and both of those live in the frontend rather than in the
/// client binary.
///
/// The client only listens when it was started with `-cef-enable-debugging`.
/// The `.cef-enable-remote-debugging` marker file that works on other platforms
/// does nothing on macOS.
public actor SteamDevTools {
    /// The port Steam's DevTools endpoint uses.
    public static let defaultPort = 8_080

    private let port: Int
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var nextId = 1

    private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamDevTools")

    public init(port: Int = SteamDevTools.defaultPort, session: URLSession = .shared) {
        self.port = port
        self.session = session
    }

    // MARK: - Discovery

    /// Whether the client is listening, without opening a connection.
    public static func isListening(port: Int = defaultPort, session: URLSession = .shared) async -> Bool {
        guard let url = endpoint("json/version", port: port) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The client's DevTools HTTP endpoint for `path`.
    static func endpoint(_ path: String, port: Int) -> URL? {
        URL(string: "http://localhost:\(port)/\(path)")
    }

    /// The pages the client currently has open.
    public func targets() async throws -> [SteamDevToolsTarget] {
        guard let url = Self.endpoint("json", port: port) else {
            throw SteamDevToolsError.notListening(port: port)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request) else {
            throw SteamDevToolsError.notListening(port: port)
        }
        return Self.decodeTargets(from: data)
    }

    /// Parses a `/json` listing, dropping pages with no endpoint to attach to.
    ///
    /// Separate from the request so it can be tested without a client running.
    static func decodeTargets(from data: Data) -> [SteamDevToolsTarget] {
        let decoded = (try? JSONDecoder().decode([SteamDevToolsTarget].self, from: data)) ?? []
        return decoded.filter { $0.webSocketDebuggerURL != nil }
    }

    // MARK: - Connection

    /// Attaches to the shared context.
    ///
    /// - Throws: ``SteamDevToolsError/notListening(port:)`` when the client was
    ///   not started with the debugging flag, or
    ///   ``SteamDevToolsError/noSharedContext`` when its UI has not loaded yet.
    public func connect() async throws {
        guard socket == nil else { return }
        let targets = try await targets()
        guard let target = targets.first(where: { $0.title == SteamDevToolsTarget.sharedContextTitle }),
              let url = target.webSocketDebuggerURL
        else {
            throw SteamDevToolsError.noSharedContext
        }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socket = socket
        logger.notice("Attached to the Steam client's shared context")
    }

    /// Drops the connection, leaving anything already installed in place.
    public func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Scripting

    /// Runs an expression in the shared context and returns its value as JSON.
    ///
    /// - Parameter expression: JavaScript to evaluate. A promise is awaited.
    /// - Returns: The result encoded as JSON, `"null"` when it has no value.
    /// - Throws: ``SteamDevToolsError/evaluationFailed(_:)`` when the
    ///   expression throws.
    @discardableResult
    public func evaluate(_ expression: String) async throws -> String {
        let result = try await send("Runtime.evaluate", params: [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true
        ])

        if let details = result["exceptionDetails"] as? [String: Any] {
            let text = (details["exception"] as? [String: Any])?["description"] as? String
                ?? details["text"] as? String
                ?? "unknown"
            throw SteamDevToolsError.evaluationFailed(text)
        }

        guard let value = (result["result"] as? [String: Any])?["value"] else { return "null" }
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(bytes: data, encoding: .utf8)
        else { return "null" }
        return String(json.dropFirst().dropLast())
    }

    /// Installs a script that runs again every time the UI reloads, and runs it
    /// once now.
    ///
    /// Steam reloads its frontend on its own, when it updates, when the user
    /// changes a display setting, and when a page navigates. Evaluating alone
    /// would leave the patch gone after the first of those, so the script is
    /// also registered to run on every new document.
    ///
    /// - Parameter javaScript: The patch source.
    /// - Returns: The identifier the client gave the registration, for removal.
    @discardableResult
    public func installPatch(_ javaScript: String) async throws -> String? {
        let registration = try await send(
            "Page.addScriptToEvaluateOnNewDocument", params: ["source": javaScript]
        )
        try await evaluate(javaScript)
        return registration["identifier"] as? String
    }

    /// Removes a patch registration, leaving the running UI as it is until it
    /// next reloads.
    public func removePatch(identifier: String) async throws {
        _ = try await send("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
    }

    // MARK: - Protocol

    /// Sends one command and waits for the reply carrying its id.
    ///
    /// Events and replies to other commands arrive on the same socket and are
    /// skipped rather than treated as failures, because the client is chatty
    /// and none of them are addressed to us.
    private func send(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw SteamDevToolsError.protocolFailure("not connected") }

        let id = nextId
        nextId += 1
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(bytes: data, encoding: .utf8)
        else {
            throw SteamDevToolsError.protocolFailure("could not encode \(method)")
        }

        do {
            try await socket.send(.string(text))
        } catch {
            self.socket = nil
            throw SteamDevToolsError.protocolFailure(error.localizedDescription)
        }

        while true {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await socket.receive()
            } catch {
                self.socket = nil
                throw SteamDevToolsError.protocolFailure(error.localizedDescription)
            }

            guard let reply = Self.decodeReply(frame), reply.id == id else { continue }
            if let error = reply.error {
                throw SteamDevToolsError.protocolFailure(error)
            }
            return reply.result
        }
    }

    /// A decoded reply frame: the id it answers, its result, and its error.
    struct Reply {
        let id: Int?
        let result: [String: Any]
        let error: String?
    }

    /// Decodes one frame. Separate from the socket so it can be tested.
    static func decodeReply(_ frame: URLSessionWebSocketTask.Message) -> Reply? {
        let data: Data? = switch frame {
        case let .string(text): Data(text.utf8)
        case let .data(data): data
        @unknown default: nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let error = (object["error"] as? [String: Any])?["message"] as? String
        return Reply(
            id: object["id"] as? Int,
            result: object["result"] as? [String: Any] ?? [:],
            error: error
        )
    }
}
