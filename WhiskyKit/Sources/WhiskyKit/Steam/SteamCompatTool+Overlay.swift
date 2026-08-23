//
//  SteamCompatTool+Overlay.swift
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

/// The macOS Steam overlay, in a Wine process.
///
/// The received answer is that the overlay cannot work here, because the macOS
/// client injects a dylib into a native process and a Windows game is not one.
/// The game is not, but the process running it is: `wine` is a Mach-O binary
/// that presents through a `CAMetalLayer`, which is exactly what the overlay
/// hooks.
///
/// Measured against `gameoverlayrenderer.dylib` from client build 1787097529,
/// injected into a Wine process running a D3D11 swapchain through DXVK:
///
/// ```
/// GameID = 1144200, AppID = 1144200, OverlayGameID = 1144200, Executable: wine
/// One-time initialization: pid 13049 for game 1144200
/// Hooking _MTLCommandBuffer::presentDrawable: for MTLCommandBuffer
/// Hooking AGXG17GFamilyCommandBuffer::commit for MTLCommandBuffer
/// ```
///
/// So it loads, reads the app id Steam already put in our environment, and
/// installs its presentation hooks. What it does with them once a game is
/// really running, and whether input reaches it through `winemac.drv`, are
/// separate questions, which is why this is a switch and not a default.
public extension SteamCompatTool {
    /// Where Steam names the overlay's library.
    ///
    /// Not `DYLD_INSERT_LIBRARIES` directly: dyld drops that on the way into a
    /// protected process, so the client carries it under a name nothing strips
    /// and expects whatever it launched to put it back. A compatibility tool is
    /// the thing that was launched.
    static let overlayLibrariesKey = "STEAM_DYLD_INSERT_LIBRARIES"
    /// What dyld reads.
    static let dyldInsertKey = "DYLD_INSERT_LIBRARIES"
    /// The switch, since none of this is proven past the hooks.
    ///
    /// Set it in the game's Steam launch options: `WHISKY_STEAM_OVERLAY=1 %command%`.
    static let overlayOptInKey = "WHISKY_STEAM_OVERLAY"

    /// The overlay's own library, as the client names it.
    static let overlayLibraryName = "gameoverlayrenderer.dylib"

    /// The environment that puts the overlay in the game's process, or nothing.
    ///
    /// - Parameters:
    ///   - environment: What Steam described the session with.
    ///   - clientLibrary: The directory the client's own dylibs sit in.
    /// - Returns: The variables to merge into the launch, empty when this
    ///   launch did not ask for the overlay.
    static func overlayEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        clientLibrary directory: URL? = clientLibraryDirectory()
    ) -> [String: String] {
        guard let optIn = environment[overlayOptInKey],
              ["1", "true", "yes"].contains(optIn.lowercased())
        else { return [:] }

        // Steam's own value wins whenever the client set one, empty included:
        // an empty value is the client saying this game gets no overlay, and
        // overriding that would be answering a question nobody asked us.
        if let libraries = environment[overlayLibrariesKey] {
            return libraries.isEmpty ? [:] : [dyldInsertKey: libraries]
        }

        // Only reached on a client that does not set the variable at all, where
        // the alternative is the switch silently doing nothing.
        guard let directory else { return [:] }

        let library = directory.appending(path: overlayLibraryName)
        guard FileManager.default.fileExists(atPath: library.path(percentEncoded: false)) else {
            return [:]
        }
        return [dyldInsertKey: library.path(percentEncoded: false)]
    }
}
