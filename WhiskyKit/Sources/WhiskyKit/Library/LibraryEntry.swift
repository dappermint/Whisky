//
//  LibraryEntry.swift
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

/// Where a library entry came from.
///
/// A raw-value type rather than an enum so a launcher can be added without
/// recompiling everything that switches over the existing ones.
public struct LibrarySourceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Programs the user pinned. The library shows these and not every
    /// executable found in a prefix: a Windows install is full of uninstallers,
    /// crash handlers and redistributables, and a library that lists them is a
    /// file browser rather than a library.
    public static let pinned = LibrarySourceID(rawValue: "pinned")
    /// Games installed through the Steam client inside a bottle.
    public static let steam = LibrarySourceID(rawValue: "steam")
}

/// One thing a person can launch, whatever put it there.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    /// How to start it. Sources that need their own launch path add a case;
    /// everything else in the library stays the same.
    public enum Launch: Hashable, Sendable {
        /// An executable inside the bottle, run directly.
        case program(URL)
        /// A Steam app, run through the client so Steam sees it as a launch.
        case steam(appID: Int)
    }

    public let id: String
    /// The identity this entry's persisted state lives under, in the bottle's
    /// ``GameRecordStore``.
    public let recordID: GameRecordID
    public let name: String
    /// The executable to read an icon out of, when there is one.
    public let iconURL: URL?
    /// Wide artwork for this entry, when the source has some on disk. Steam
    /// caches its own banners inside the bottle, so a Steam game shows the art
    /// its store page uses without anything being fetched.
    public let artworkURL: URL?
    public let bottleURL: URL
    public let source: LibrarySourceID
    public let launch: Launch
    /// Whether this entry is a storefront client rather than a game.
    ///
    /// A launcher is worth keeping in the library, since it is how you reach an
    /// account, a store and an update. It is not what somebody scanning the grid
    /// is looking for, so it is labelled and sorted below the games.
    public let launcher: LauncherType?
    /// Where the source says this game is installed, when it knows. What lets
    /// a pin and a store entry be recognised as the same game.
    public let installURL: URL?

    public var isLauncher: Bool { launcher != nil }

    /// The executable this entry runs directly, for entries that run one.
    public var programURL: URL? {
        if case let .program(url) = launch { url } else { nil }
    }

    public init(
        id: String,
        recordID: GameRecordID,
        name: String,
        iconURL: URL?,
        artworkURL: URL? = nil,
        bottleURL: URL,
        source: LibrarySourceID,
        launch: Launch,
        launcher: LauncherType? = nil,
        installURL: URL? = nil
    ) {
        self.id = id
        self.recordID = recordID
        self.name = name
        self.iconURL = iconURL
        self.artworkURL = artworkURL
        self.bottleURL = bottleURL
        self.source = source
        self.launch = launch
        self.launcher = launcher
        self.installURL = installURL
    }

    /// This entry wearing the name a pin gave the same game.
    ///
    /// Everything that makes the entry a store game stays: the identity, the
    /// launch route, the artwork. The name is the pin's because the person
    /// typed it, and the pin's executable backs up the icon for a store entry
    /// whose own icon was never cached.
    func named(after pin: LibraryEntry) -> LibraryEntry {
        LibraryEntry(
            id: id,
            recordID: recordID,
            name: pin.name,
            iconURL: iconURL ?? pin.iconURL,
            artworkURL: artworkURL,
            bottleURL: bottleURL,
            source: source,
            launch: launch,
            launcher: launcher,
            installURL: installURL
        )
    }
}

/// Somewhere library entries come from.
///
/// Deliberately takes a bottle URL and its settings rather than a ``Bottle``,
/// so a source can run off the main actor and be tested without building one.
public protocol LibrarySource {
    static var id: LibrarySourceID { get }
    static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry]
}

/// The pinned programs of a bottle.
public enum PinnedLibrarySource: LibrarySource {
    public static let id = LibrarySourceID.pinned

    public static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry] {
        settings.pins.compactMap { pin in
            guard let programURL = pin.url else { return nil }
            return LibraryEntry(
                id: "pinned:\(programURL.path(percentEncoded: false))",
                recordID: .pin(at: programURL, bottleURL: url),
                name: pin.name,
                iconURL: programURL,
                bottleURL: url,
                source: id,
                launch: .program(programURL),
                // The app's existing definition of a launcher, reused rather
                // than re-guessed: it is a pure string match, so this stays a
                // settings read with nothing touching disk.
                launcher: LauncherType.detect(from: programURL)
            )
        }
    }
}

/// The games a bottle's Steam client has installed.
public enum SteamLibrarySource: LibrarySource {
    public static let id = LibrarySourceID.steam

    public static func items(inBottleAt url: URL, settings _: BottleSettings) -> [LibraryEntry] {
        entries(inBottleAt: url)
    }

    /// Without the settings parameter, so a caller can run this off the main
    /// actor: enumerating Steam walks libraryfolders.vdf and every manifest in
    /// it, which is the one part of building the library that touches disk.
    public static func entries(inBottleAt url: URL) -> [LibraryEntry] {
        let steamRoot = SteamLibrary.detectInstall(bottleURL: url)
        return SteamLibrary.enumerate(bottleURL: url).map { game in
            LibraryEntry(
                // Scoped to the bottle, because the same game can be installed
                // in two of them and an id shared by two rows breaks the grid's
                // diffing rather than merely looking odd. A pin is already
                // scoped: its id carries the executable's full path.
                id: "steam:\(url.path(percentEncoded: false)):\(game.appId)",
                recordID: .steam(appID: game.appId),
                name: game.name,
                iconURL: steamRoot.flatMap { iconURL(appID: game.appId, steamRoot: $0) },
                artworkURL: steamRoot.flatMap { artworkURL(appID: game.appId, steamRoot: $0) },
                bottleURL: url,
                source: id,
                launch: .steam(appID: game.appId),
                installURL: game.installURL
            )
        }
    }

    /// The best art Steam already cached for `appID`.
    ///
    /// Steam has changed this layout more than once: a flat `<appid>_header.jpg`,
    /// then `<appid>/header.jpg`, and now `<appid>/<hash>/library_header.jpg`.
    /// Matching on the filename rather than the path survives all three, and the
    /// next one as long as the names hold.
    ///
    /// Landscape first because that is the shape of a card. A portrait capsule
    /// is the fallback and gets cropped, which still beats an empty card.
    public static func artworkURL(appID: Int, steamRoot: URL) -> URL? {
        let landscape = ["library_header.jpg", "header.jpg", "\(appID)_header.jpg"]
        let portrait = ["library_capsule.jpg", "library_600x900.jpg", "\(appID)_library_600x900.jpg"]
        let cached = cachedFiles(appID: appID, steamRoot: steamRoot)

        for name in landscape + portrait {
            if let match = cached.first(where: { $0.lastPathComponent == name }) {
                return match
            }
        }
        return nil
    }

    /// The small square icon Steam caches beside the art, if it left one.
    ///
    /// It sits directly in the app's folder rather than in one of the hashed
    /// subfolders, which is what separates it from the artwork.
    public static func iconURL(appID: Int, steamRoot: URL) -> URL? {
        let folder = steamRoot.appending(path: "appcache").appending(path: "librarycache")
            .appending(path: "\(appID)")
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        )
        return contents?.first { $0.pathExtension.lowercased() == "jpg" }
    }

    /// Every cached file for one app, from either layout.
    ///
    /// Both are always checked rather than one being a fallback for the other:
    /// an enumerator over a folder that does not exist yields nothing instead of
    /// failing, so "did the walk work" cannot decide which layout is in use.
    private static func cachedFiles(appID: Int, steamRoot: URL) -> [URL] {
        let cache = steamRoot.appending(path: "appcache").appending(path: "librarycache")
        let walked = FileManager.default.enumerator(
            at: cache.appending(path: "\(appID)"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        // The layout Steam used before it made a folder per app.
        let flat = ["\(appID)_header.jpg", "\(appID)_library_600x900.jpg"]
            .map { cache.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        return walked + flat
    }
}

/// Every source, merged.
public enum LibraryCatalogue {
    /// Registered sources, in the order their entries are produced. Adding a
    /// launcher is this line plus the type.
    public static let sources: [any LibrarySource.Type] = [
        PinnedLibrarySource.self,
        SteamLibrarySource.self
    ]

    /// Everything one bottle contributes to the library.
    public static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry] {
        merge(sources.map { $0.items(inBottleAt: url, settings: settings) })
    }

    /// Collapses a pin and a store entry that are the same game into one card.
    ///
    /// Sameness is identity, not the names matching: a pin whose executable
    /// lives inside a store game's install directory is that game. The card
    /// keeps the store entry's launch route and artwork and the pin's name,
    /// where matching on names silently traded both away, and a pin the names
    /// happened to collide with stayed hidden. A store game absorbs one pin;
    /// a second pin into the same install (an editor, a mod tool) is its own
    /// deliberate entry and stays. Exposed separately so a caller that
    /// gathered its groups from different actors can still merge them the
    /// same way.
    public static func merge(_ groups: [[LibraryEntry]]) -> [LibraryEntry] {
        let all = groups.flatMap { $0 }
        var absorbedPins = Set<String>()
        var pinFor: [String: LibraryEntry] = [:]

        for store in all where store.installURL != nil {
            guard let installURL = store.installURL,
                  let pin = all.first(where: { candidate in
                      candidate.source == .pinned
                          && candidate.bottleURL == store.bottleURL
                          && !absorbedPins.contains(candidate.id)
                          && candidate.programURL.map { isPath($0, under: installURL) } == true
                  })
            else { continue }
            absorbedPins.insert(pin.id)
            pinFor[store.id] = pin
        }

        return all.compactMap { item in
            if absorbedPins.contains(item.id) { return nil }
            if let pin = pinFor[item.id] { return item.named(after: pin) }
            return item
        }
    }

    /// Whether `url` points inside `root`, on path components rather than on
    /// string prefixes, so `…/Game` never claims `…/Game II`.
    static func isPath(_ url: URL, under root: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let rootPath = root.standardizedFileURL.pathComponents
        return path.count > rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
    }
}
