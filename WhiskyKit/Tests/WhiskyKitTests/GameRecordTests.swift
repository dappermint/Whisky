//
//  GameRecordTests.swift
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

@Suite("GameRecord Tests")
struct GameRecordTests {
    private func makeBottle() -> (url: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, { try? FileManager.default.removeItem(at: tempDir) })
    }

    @Test("A record persists across store instances")
    func persistsAcrossInstances() {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let id = GameRecordID.steam(appID: 1_144_200)
        GameRecordStore(bottleURL: bottle).update(id) { $0.favourite = true }

        let reread = GameRecordStore(bottleURL: bottle).record(for: id)
        #expect(reread?.favourite == true)
        #expect(reread?.hidden == false)
    }

    @Test("Update creates the record on first touch")
    func updateUpserts() {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let store = GameRecordStore(bottleURL: bottle)
        let id = GameRecordID(source: .pinned, externalID: "/drive_c/Games/foo/foo.exe")
        #expect(store.record(for: id) == nil)

        store.update(id) { $0.displayName = "Foo" }
        #expect(store.record(for: id)?.displayName == "Foo")
    }

    @Test("A launch stamp lands on the right record and only that one")
    func recordLaunchIsScoped() {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let store = GameRecordStore(bottleURL: bottle)
        let played = GameRecordID.steam(appID: 1)
        let untouched = GameRecordID.steam(appID: 2)
        store.update(untouched) { $0.favourite = true }

        let date = Date(timeIntervalSince1970: 1_755_000_000)
        store.recordLaunch(played, at: date)

        #expect(store.record(for: played)?.lastPlayedInWhisky == date)
        #expect(store.record(for: untouched)?.lastPlayedInWhisky == nil)
    }

    @Test("A missing store reads as empty, not as an error")
    func missingStoreReadsEmpty() {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let store = GameRecordStore(bottleURL: bottle)
        #expect(store.records().isEmpty)
        #expect(store.record(for: .steam(appID: 99)) == nil)
    }

    @Test("A corrupt store reads as empty and is replaced by the next write")
    func corruptStoreRecovers() throws {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        try Data("not a plist".utf8).write(to: GameRecordStore.storeURL(in: bottle))
        let store = GameRecordStore(bottleURL: bottle)
        #expect(store.records().isEmpty)

        store.update(.steam(appID: 7)) { $0.hidden = true }
        #expect(store.record(for: .steam(appID: 7))?.hidden == true)
    }

    @Test("A record with fields this build doesn't know still decodes")
    func unknownFieldsTolerated() throws {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>records</key><array><dict>
            <key>id</key><dict>
              <key>source</key><string>steam</string>
              <key>externalID</key><string>42</string>
            </dict>
            <key>favourite</key><true/>
            <key>artworkStyle</key><string>from-the-future</string>
          </dict></array>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: GameRecordStore.storeURL(in: bottle))

        let record = GameRecordStore(bottleURL: bottle).record(for: .steam(appID: 42))
        #expect(record?.favourite == true)
        #expect(record?.hidden == false)
    }

    @Test("Pin identity is the bottle-relative path, so it survives a move")
    func pinIdentitySurvivesMove() {
        let before = URL(fileURLWithPath: "/tmp/bottles/one")
        let after = URL(fileURLWithPath: "/somewhere/else/one")

        let original = GameRecordID.pin(
            at: before.appending(path: "drive_c/Games/foo/Launch.exe"), bottleURL: before
        )
        let moved = GameRecordID.pin(
            at: after.appending(path: "drive_c/Games/foo/Launch.exe"), bottleURL: after
        )

        #expect(original == moved)
        #expect(original.externalID == "/drive_c/Games/foo/Launch.exe")
    }

    @Test("A pin outside the bottle still gets a distinct identity")
    func pinOutsideBottleKeepsAbsolutePath() {
        let bottle = URL(fileURLWithPath: "/tmp/bottles/one")
        let outside = GameRecordID.pin(
            at: URL(fileURLWithPath: "/Users/someone/Games/foo.exe"), bottleURL: bottle
        )
        #expect(outside.externalID == "/Users/someone/Games/foo.exe")
    }

    @Test("An unchanged update writes nothing")
    func noOpUpdateWritesNothing() throws {
        let (bottle, cleanup) = makeBottle()
        defer { cleanup() }

        let store = GameRecordStore(bottleURL: bottle)
        let id = GameRecordID.steam(appID: 5)
        store.update(id) { $0.favourite = true }

        let url = GameRecordStore.storeURL(in: bottle)
        let stamped = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )[.modificationDate] as? Date

        store.update(id) { $0.favourite = true }
        let after = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )[.modificationDate] as? Date
        #expect(stamped == after)
    }
}
