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
/// separate questions.
///
/// Whether a game gets the overlay is the client's decision and not ours: it
/// has a per-game switch already, and it writes the answer into the
/// environment it hands the tool. So there is no Whisky setting for this, only
/// an override for a launch that disagrees.
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
    /// The override, for a launch that wants to decide this itself.
    ///
    /// Set it in the game's Steam launch options: `WHISKY_STEAM_OVERLAY=0 %command%`
    /// to keep the overlay out of a title it disagrees with, `=1` to inject the
    /// client's own copy even when the client named nothing.
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
        // Three states, not two: unset follows the client, which is the whole
        // point of not having a setting of our own for this.
        let forced = environment[overlayOptInKey].map { value in
            !["0", "false", "no"].contains(value.lowercased())
        }
        if forced == false { return [:] }

        // The client already has a per-game overlay switch and puts the answer
        // here. An empty value is that switch turned off, and overriding it
        // would be answering a question the user has already answered.
        if let libraries = environment[overlayLibrariesKey] {
            return libraries.isEmpty ? [:] : [dyldInsertKey: libraries]
        }

        // Only reached on a client that does not set the variable at all. That
        // is not a decision, it is a client we do not recognise, so this needs
        // asking for.
        guard forced == true, let directory else { return [:] }

        let library = directory.appending(path: overlayLibraryName)
        guard FileManager.default.fileExists(atPath: library.path(percentEncoded: false)) else {
            return [:]
        }
        return [dyldInsertKey: library.path(percentEncoded: false)]
    }
}
