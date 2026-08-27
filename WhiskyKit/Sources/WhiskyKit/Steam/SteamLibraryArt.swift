//
//  SteamLibraryArt.swift
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

import AppKit
import Foundation

/// The artwork the Steam client has already downloaded for a game.
///
/// An executable is a poor source for a game's icon: Ready or Not's is the
/// Epic Online Services bootstrapper and carries Epic's logo, and plenty of
/// shipping binaries carry no icon at all. Steam knows which game it is, and
/// keeps the art on disk, so for a launch that came from Steam this is the
/// better answer.
public enum SteamLibraryArt {
    /// How a piece of artwork wants to be drawn.
    public enum Artwork: Sendable {
        /// Key art with no transparency, which fills the tile edge to edge.
        case fill(NSImage)
        /// A mark with its own transparency, which sits on a plate.
        case inset(NSImage)

        public var image: NSImage {
            switch self {
            case let .fill(image), let .inset(image): image
            }
        }

        /// Whether the artwork covers the whole tile rather than sitting on it.
        public var isFill: Bool {
            if case .fill = self { return true }
            return false
        }
    }

    /// Where the client keeps what it has downloaded, one directory per App ID.
    static var libraryCache: URL {
        URL.applicationSupportDirectory
            .appending(path: "Steam/appcache/librarycache")
    }

    /// The best artwork the client holds for `appId`.
    ///
    /// The capsule first: it is the portrait key art, and its top square is
    /// what a person recognises at Dock size. A logo is usually a wordmark
    /// several times wider than it is tall, which plates into an unreadable
    /// strip, so it is only the fallback. Both beat the 32pt icon the client
    /// also caches, which cannot be scaled up to a tile.
    ///
    /// - Returns: `nil` when the client has downloaded nothing for this game,
    ///   which is normal for a title that has never been shown in the library.
    public static func artwork(forAppId appId: Int, in cache: URL? = nil) -> Artwork? {
        let root = (cache ?? libraryCache).appending(path: String(appId))
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return nil
        }

        if let capsule = file(named: "library_capsule.jpg", under: root),
           let image = squareFromTop(of: capsule) {
            return .fill(image)
        }
        if let logo = file(named: "logo.png", under: root), let image = NSImage(contentsOf: logo) {
            return .inset(image)
        }
        return nil
    }

    /// Finds `name` in the App ID's directory or any of the content-addressed
    /// subdirectories the client shards art into.
    static func file(named name: String, under root: URL) -> URL? {
        let direct = root.appending(path: name)
        if FileManager.default.fileExists(atPath: direct.path(percentEncoded: false)) {
            return direct
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for folder in contents {
            let candidate = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    /// Crops the top square out of portrait key art, which is where the title
    /// and the subject sit; the lower half is usually background.
    static func squareFromTop(of url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url),
              let rep = source.representations.first
        else { return nil }

        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        guard width > 0, height > 0 else { return nil }
        guard height > width else { return source }

        let cropped = NSImage(size: NSSize(width: width, height: width))
        cropped.lockFocus()
        source.draw(
            in: NSRect(x: 0, y: 0, width: width, height: width),
            from: NSRect(x: 0, y: height - width, width: width, height: width),
            operation: .copy,
            fraction: 1
        )
        cropped.unlockFocus()
        return cropped
    }
}
