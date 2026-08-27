//
//  SteamCompatToolRuntimeTests.swift
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

private struct RuntimeFixture {
    let toolsRoot: URL
    let whiskyCmd: URL
    let tempRoot: URL

    func cleanUp() { try? FileManager.default.removeItem(at: tempRoot) }
}

private func makeRuntimeFixture() throws -> RuntimeFixture {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: "compatruntime_\(UUID().uuidString)")
    let toolsRoot = tempRoot.appending(path: "compatibilitytools.d")
    try fileManager.createDirectory(at: toolsRoot, withIntermediateDirectories: true)

    let whiskyCmd = tempRoot.appending(path: "WhiskyCmd")
    try Data("#!/bin/sh\n".utf8).write(to: whiskyCmd)
    return RuntimeFixture(toolsRoot: toolsRoot, whiskyCmd: whiskyCmd, tempRoot: tempRoot)
}

@Suite("Steam compatibility tool, one per runtime")
struct SteamCompatToolRuntimeTests {
    /// The default runtime has to keep the exact identifier every existing
    /// `CompatToolMapping` in `config.vdf` already points at.
    @Test func defaultRuntimeKeepsTheEstablishedIdentifier() {
        #expect(SteamCompatTool.name(for: nil) == "whisky-proton")
        #expect(SteamCompatTool.name(for: "") == "whisky-proton")
        #expect(SteamCompatTool.displayName(for: nil) == "Whisky")
    }

    /// The client only installs the Windows save-path overrides when a case
    /// insensitive search for `proton` hits the identifier, so every generated
    /// one has to keep it.
    @Test func everyIdentifierStillContainsProton() {
        for runtime in [nil, "", "whisky-arm64-5.0.0", "winecx-gptk-4.6.1", "odd_name"] {
            let name = SteamCompatTool.name(for: runtime)
            #expect(name.lowercased().contains("proton"), "\(name) would break cloud saves")
        }
    }

    @Test func aRuntimeIdentifierDoesNotSayWhiskyTwice() {
        #expect(SteamCompatTool.name(for: "whisky-arm64-5.0.0") == "whisky-proton-arm64-5.0.0")
        #expect(SteamCompatTool.name(for: "winecx-4.6.1") == "whisky-proton-winecx-4.6.1")
    }

    @Test func theLabelIsWhatThePickerShows() {
        #expect(SteamCompatTool.displayName(for: "whisky-arm64-5.0.0", label: "arm64 5.0.0")
            == "Whisky (arm64 5.0.0)")
        #expect(SteamCompatTool.displayName(for: "whisky-arm64-5.0.0") == "Whisky (whisky-arm64-5.0.0)")
    }

    /// A runner has to name its own runtime, or every tool launches the same one
    /// and the picker does nothing.
    @Test func onlyANamedRuntimeReachesTheRunner() throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.installAll(
            whiskyCmd: fixture.whiskyCmd,
            runtimes: [(nil, nil), ("whisky-arm64-5.0.0", "arm64 5.0.0")],
            at: fixture.toolsRoot
        )

        let base = try String(
            contentsOf: fixture.toolsRoot.appending(path: "whisky-proton/whisky-run"), encoding: .utf8
        )
        #expect(!base.contains("--runtime"))

        let arm = try String(
            contentsOf: fixture.toolsRoot.appending(path: "whisky-proton-arm64-5.0.0/whisky-run"),
            encoding: .utf8
        )
        #expect(arm.contains("--runtime 'whisky-arm64-5.0.0'"))
    }

    @Test func eachToolGetsItsOwnManifests() throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.installAll(
            whiskyCmd: fixture.whiskyCmd,
            runtimes: [(nil, nil), ("whisky-arm64-5.0.0", "arm64 5.0.0")],
            at: fixture.toolsRoot
        )

        for (folder, identifier) in [
            ("whisky-proton", "whisky-proton"),
            ("whisky-proton-arm64-5.0.0", "whisky-proton-arm64-5.0.0")
        ] {
            let directory = fixture.toolsRoot.appending(path: folder)
            for file in ["compatibilitytool.vdf", "toolmanifest.vdf", "whisky-run"] {
                #expect(FileManager.default.fileExists(
                    atPath: directory.appending(path: file).path(percentEncoded: false)
                ), "\(folder) is missing \(file)")
            }
            let manifest = try String(
                contentsOf: directory.appending(path: "toolmanifest.vdf"), encoding: .utf8
            )
            #expect(manifest.contains(identifier))
        }
    }

    /// A tool left behind for a runtime that is gone keeps being listed, and a
    /// game still mapped to it fails at launch rather than falling back.
    @Test func aToolForARemovedRuntimeIsPruned() throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.cleanUp() }

        try SteamCompatTool.installAll(
            whiskyCmd: fixture.whiskyCmd,
            runtimes: [(nil, nil), ("whisky-arm64-5.0.0", nil)],
            at: fixture.toolsRoot
        )
        try SteamCompatTool.installAll(
            whiskyCmd: fixture.whiskyCmd, runtimes: [(nil, nil)], at: fixture.toolsRoot
        )

        #expect(FileManager.default.fileExists(
            atPath: fixture.toolsRoot.appending(path: "whisky-proton").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.toolsRoot.appending(path: "whisky-proton-arm64-5.0.0")
                .path(percentEncoded: false)
        ))
    }

    /// A bottle written before runtime selection existed decodes to `nil`, and
    /// the default tool passes no runtime at all, so those two have to match or
    /// every existing bottle stops resolving.
    @Test func theDefaultRuntimeMatchesEitherSpelling() {
        #expect(SteamLauncher.runtime(nil, matches: nil))
        #expect(SteamLauncher.runtime(nil, matches: ""))
        #expect(SteamLauncher.runtime("", matches: nil))
        #expect(SteamLauncher.runtime("", matches: ""))
    }

    @Test func aRuntimeOnlyMatchesItself() {
        #expect(SteamLauncher.runtime("whisky-arm64-5.0.0", matches: "whisky-arm64-5.0.0"))
        #expect(!SteamLauncher.runtime("whisky-arm64-5.0.0", matches: nil))
        #expect(!SteamLauncher.runtime(nil, matches: "whisky-arm64-5.0.0"))
        #expect(!SteamLauncher.runtime("winecx-4.6.1", matches: "whisky-arm64-5.0.0"))
    }

    /// Pruning is allowed to remove what we wrote and nothing else.
    @Test func pruningLeavesSomebodyElsesToolAlone() throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.cleanUp() }

        let foreign = fixture.toolsRoot.appending(path: "whisky-proton-not-ours")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: foreign.appending(path: "toolmanifest.vdf"))

        try SteamCompatTool.installAll(
            whiskyCmd: fixture.whiskyCmd, runtimes: [(nil, nil)], at: fixture.toolsRoot
        )

        #expect(
            FileManager.default.fileExists(atPath: foreign.path(percentEncoded: false)),
            "a tool without our runner is not ours to delete"
        )
    }
}

@Suite("DXMT payload without a 32-bit lane")
struct DXMTNoThirtyTwoBitLaneTests {
    private static let trio = ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]
    private static let all = trio + ["winemetal.dll"]

    /// A PE whose DOS stub carries no builtin marker, which is what
    /// `isNativePE` looks for.
    private static func writeNativePE(at url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        try Data(bytes).write(to: url)
    }

    private struct Fixture {
        let payload: URL
        let prefix: URL
        let root: URL
    }

    private static func makePayload(x32: Bool) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "dxmt_\(UUID().uuidString)")
        let payload = root.appending(path: "DXMT")
        let x64 = payload.appending(path: "x64")
        try fileManager.createDirectory(at: x64, withIntermediateDirectories: true)
        for name in all {
            try writeNativePE(at: x64.appending(path: name))
        }
        if x32 {
            let folder = payload.appending(path: "x32")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in all {
                try writeNativePE(at: folder.appending(path: name))
            }
        }

        let prefix = root.appending(path: "prefix")
        let windows = prefix.appending(path: "drive_c").appending(path: "windows")
        try fileManager.createDirectory(
            at: windows.appending(path: "system32"), withIntermediateDirectories: true
        )
        // Present but empty, exactly as an arm64 prefix configured without i386.
        try fileManager.createDirectory(
            at: windows.appending(path: "syswow64"), withIntermediateDirectories: true
        )
        return Fixture(payload: payload, prefix: prefix, root: root)
    }

    /// An arm64 runtime ships no 32-bit payload, and the prefix still has an
    /// empty syswow64. Failing there would refuse a bottle whose 64-bit half is
    /// complete, which is the only half DXMT has.
    @Test func anEmptySyswow64DoesNotRequireA32BitPayload() throws {
        let fixture = try Self.makePayload(x32: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Wine.enableDXMT(payloadRoot: fixture.payload, prefixRoot: fixture.prefix)

        let system32 = fixture.prefix.appending(path: "drive_c/windows/system32")
        for name in Self.all {
            #expect(FileManager.default.fileExists(
                atPath: system32.appending(path: name).path(percentEncoded: false)
            ), "\(name) should have been deployed")
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.prefix.appending(path: "drive_c/windows/syswow64").path(percentEncoded: false)
        ).isEmpty, "nothing to deploy there, so nothing should have been")
    }

    /// A runtime that does ship one still deploys it.
    @Test func a32BitPayloadIsStillDeployedWhenPresent() throws {
        let fixture = try Self.makePayload(x32: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Wine.enableDXMT(payloadRoot: fixture.payload, prefixRoot: fixture.prefix)

        let syswow64 = fixture.prefix.appending(path: "drive_c/windows/syswow64")
        for name in Self.all {
            #expect(FileManager.default.fileExists(
                atPath: syswow64.appending(path: name).path(percentEncoded: false)
            ), "\(name) should have been deployed 32-bit")
        }
    }
}
