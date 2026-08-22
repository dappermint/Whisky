//
//  SharedSteamLibraryTests.swift
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

/// A throwaway bottle and the macOS folder it can be pointed at.
private struct Fixture {
    let bottle: URL
    let library: URL
    let tempRoot: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

/// A bottle with Steam on `C:`, `z:` pointing at the root the way Wine sets
/// it up, and a macOS folder outside the bottle holding one installed game.
private func makeFixture(
    withSpecificDrive: Bool = false
) throws -> Fixture {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory
        .appending(path: "sharedsteam_\(UUID().uuidString)")
    let bottle = tempRoot.appending(path: "bottle")
    let steamRoot = bottle.appending(path: "drive_c")
        .appending(path: "Program Files (x86)").appending(path: "Steam")

    try fileManager.createDirectory(
        at: steamRoot.appending(path: "steamapps"), withIntermediateDirectories: true
    )
    try Data().write(to: steamRoot.appending(path: "steam.exe"))

    let dosDevices = bottle.appending(path: "dosdevices")
    try fileManager.createDirectory(at: dosDevices, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
        at: dosDevices.appending(path: "c:"), withDestinationURL: bottle.appending(path: "drive_c")
    )
    try fileManager.createSymbolicLink(
        at: dosDevices.appending(path: "z:"), withDestinationURL: URL(filePath: "/")
    )
    // A device mapping, which is not a drive and must be ignored.
    try fileManager.createSymbolicLink(
        at: dosDevices.appending(path: "d::"), withDestinationURL: URL(filePath: "/dev/null")
    )

    let library = tempRoot.appending(path: "SteamWindows")
    let libraryApps = library.appending(path: "steamapps")
    try fileManager.createDirectory(
        at: libraryApps.appending(path: "common").appending(path: "skyrim"),
        withIntermediateDirectories: true
    )
    try Data("""
    "AppState"
    {
        "appid"        "365720"
        "name"        "Skyrim Script Extender (SKSE)"
        "installdir"        "skyrim"
        "StateFlags"        "4"
    }
    """.utf8).write(to: libraryApps.appending(path: "appmanifest_365720.acf"))

    if withSpecificDrive {
        try fileManager.createSymbolicLink(
            at: dosDevices.appending(path: "g:"), withDestinationURL: library
        )
    }

    return Fixture(bottle: bottle, library: library, tempRoot: tempRoot)
}

@Suite("SharedSteamLibrary Path Tests")
struct SharedSteamLibraryPathTests {
    @Test("Maps a macOS folder onto the drive that reaches the root")
    func mapsThroughRootDrive() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        let path = try #require(SharedSteamLibrary.windowsPath(for: library, bottleURL: bottle))
        #expect(path.hasPrefix("Z:\\"))
        #expect(path.hasSuffix("\\SteamWindows"))
        #expect(!path.contains("/"))
    }

    @Test("A drive mounted deeper wins over the one at the root")
    func prefersTheMoreSpecificDrive() throws {
        let fixture = try makeFixture(withSpecificDrive: true)
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        let path = SharedSteamLibrary.windowsPath(for: library, bottleURL: bottle)
        #expect(path == "G:\\")
    }

    @Test("A folder no drive reaches has no Windows path")
    func unreachableFolderHasNoPath() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appending(path: "sharedsteam_\(UUID().uuidString)")
        let bottle = tempRoot.appending(path: "bottle")
        try fileManager.createDirectory(
            at: bottle.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: bottle.appending(path: "dosdevices").appending(path: "c:"),
            withDestinationURL: bottle.appending(path: "drive_c")
        )
        defer { try? fileManager.removeItem(at: tempRoot) }

        #expect(SharedSteamLibrary.windowsPath(for: URL(filePath: "/Users"), bottleURL: bottle) == nil)
    }

    @Test("A Windows path maps back to the folder it came from")
    func roundTripsThroughTheOtherMapper() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        let path = try #require(SharedSteamLibrary.windowsPath(for: library, bottleURL: bottle))
        let mapped = try #require(SteamLibrary.mapWindowsPath(path, bottleURL: bottle))
        #expect(mapped.resolvingSymlinksInPath() == library.resolvingSymlinksInPath())
    }
}

@Suite("SharedSteamLibrary Sharing Tests")
struct SharedSteamLibrarySharingTests {
    @Test("Sharing a folder puts its games in the bottle's library")
    func sharingSurfacesTheGames() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        #expect(SteamLibrary.enumerate(bottleURL: bottle).isEmpty)
        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        let games = SteamLibrary.enumerate(bottleURL: bottle)
        #expect(games.map(\.appId) == [365_720])
    }

    @Test("A shared folder is listed, a bottle's own library is not")
    func listsOnlyFoldersOutsideTheBottle() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        #expect(SharedSteamLibrary.shared(bottleURL: bottle).isEmpty)
        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)
        #expect(SharedSteamLibrary.shared(bottleURL: bottle) == [library.resolvingSymlinksInPath()])
    }

    @Test("Sharing the same folder twice is refused")
    func refusesADuplicate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)
        #expect(throws: SharedSteamLibraryError.alreadyShared(folder: library.resolvingSymlinksInPath())) {
            try SharedSteamLibrary.share(folder: library, bottleURL: bottle)
        }
    }

    @Test("Sharing the macOS client's own folder is refused")
    func refusesTheHostDataDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bottle = fixture.bottle

        #expect(throws: SharedSteamLibraryError.hostDataDirectory) {
            try SharedSteamLibrary.share(folder: HostSteam.defaultRoot, bottleURL: bottle)
        }
    }

    @Test("The macOS client's folder is still refused when named a different way")
    func refusesTheHostDataDirectoryByPath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bottle = fixture.bottle

        // What the CLI hands over: a URL built from a path string rather than
        // by appending components, which is not `==` to the one in HostSteam
        // even though both name the same directory.
        let byPath = URL(filePath: HostSteam.defaultRoot.path(percentEncoded: false) + "/")
        #expect(throws: SharedSteamLibraryError.hostDataDirectory) {
            try SharedSteamLibrary.share(folder: byPath, bottleURL: bottle)
        }
    }

    @Test("Sharing needs a Steam install in the bottle")
    func refusesABottleWithoutSteam() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)
        try FileManager.default.removeItem(
            at: bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
        )

        #expect(throws: SharedSteamLibraryError.steamNotInstalled) {
            try SharedSteamLibrary.share(folder: library, bottleURL: bottle)
        }
    }

    @Test("Unsharing takes the folder back out and leaves its games alone")
    func unsharingRemovesTheEntry() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)
        try SharedSteamLibrary.unshare(folder: library, bottleURL: bottle)

        #expect(SharedSteamLibrary.shared(bottleURL: bottle).isEmpty)
        #expect(SteamLibrary.enumerate(bottleURL: bottle).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: library.appending(path: "steamapps").appending(path: "appmanifest_365720.acf")
                .path(percentEncoded: false)
        ))
    }

    @Test("Unsharing a folder that was never shared is refused")
    func refusesUnsharingAStranger() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        #expect(throws: SharedSteamLibraryError.notShared(folder: library.resolvingSymlinksInPath())) {
            try SharedSteamLibrary.unshare(folder: library, bottleURL: bottle)
        }
    }

    @Test("Sharing keeps the content id the macOS client already wrote")
    func reusesAnExistingContentId() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        try Data("""
        "libraryfolder"
        {
            "contentid"        "2013937153799627505"
            "label"        ""
        }
        """.utf8).write(to: library.appending(path: "libraryfolder.vdf"))
        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        let vdf = bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam").appending(path: "steamapps")
            .appending(path: "libraryfolders.vdf")
        let text = try String(contentsOf: vdf, encoding: .utf8)
        #expect(text.contains("2013937153799627505"))
    }

    @Test("A folder with no marker gets one, so both clients agree on its id")
    func writesAMarkerWhenThereIsNone() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        let marker = library.appending(path: "libraryfolder.vdf")
        let parsed = try VDFParser.parse(String(contentsOf: marker, encoding: .utf8))
        let contentId = try #require(parsed["libraryfolder"]?.objectValue?["contentid"]?.stringValue)
        #expect(Int(contentId) != nil)
    }

    @Test("Both copies of libraryfolders.vdf are kept in step")
    func writesEveryConfigurationFileThatExists() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        let steamRoot = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let config = steamRoot.appending(path: "config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("\"libraryfolders\"\n{\n}\n".utf8)
            .write(to: config.appending(path: "libraryfolders.vdf"))
        try Data("\"libraryfolders\"\n{\n}\n".utf8)
            .write(to: steamRoot.appending(path: "steamapps").appending(path: "libraryfolders.vdf"))

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        for file in HostSteam.libraryFolderFiles(steamRoot: steamRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("SteamWindows"), "\(file.lastPathComponent) was not updated")
        }
    }

    @Test("An added entry never overwrites one already there")
    func picksAFreeIndex() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        let steamApps = bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam").appending(path: "steamapps")
        try Data("""
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
            }
        }
        """.utf8).write(to: steamApps.appending(path: "libraryfolders.vdf"))

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        let parsed = try VDFParser.parse(
            String(contentsOf: steamApps.appending(path: "libraryfolders.vdf"), encoding: .utf8)
        )
        let entries = try #require(parsed["libraryfolders"]?.objectValue)
        #expect(entries.count == 2)
        #expect(entries["0"]?.objectValue?["path"]?.stringValue == "C:\\Program Files (x86)\\Steam")
        #expect(entries["1"]?.objectValue?["path"]?.stringValue?.hasPrefix("Z:\\") == true)
    }

    @Test("A bottle whose Steam has no library configuration gets a usable one")
    func writesTheSteamRootWhenStartingFromNothing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let (bottle, library) = (fixture.bottle, fixture.library)

        try SharedSteamLibrary.share(folder: library, bottleURL: bottle)

        let steamApps = bottle.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam").appending(path: "steamapps")
        let parsed = try VDFParser.parse(
            String(contentsOf: steamApps.appending(path: "libraryfolders.vdf"), encoding: .utf8)
        )
        let entries = try #require(parsed["libraryfolders"]?.objectValue)
        #expect(entries["0"]?.objectValue?["path"]?.stringValue == "C:\\Program Files (x86)\\Steam")
        #expect(entries.count == 2)
    }
}
