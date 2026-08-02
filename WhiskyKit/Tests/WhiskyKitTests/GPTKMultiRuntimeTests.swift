//
//  GPTKMultiRuntimeTests.swift
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

/// Deployment into more than one runtime at a time. A single shared `originals/`
/// made this impossible: whichever runtime deployed last owned the only backup
/// set, and the others could never be restored.
@Suite("GPTK Multi-Runtime Tests")
struct GPTKMultiRuntimeTests {
    private let tempDir: URL

    init() throws {
        tempDir = try makeGPTKTempDir()
    }

    @Test("Deploying into a second runtime keeps the first one's originals")
    func originalsAreKeptPerRuntime() throws {
        let store = try makeImportedStore(in: tempDir)
        let (alpha, beta) = try makeTwoRuntimes()

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: alpha, originalsKey: "alpha")
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: beta, originalsKey: "beta")

        // Both backup sets survive, each stamped with its own runtime version.
        #expect(GPTKImporter.originalsRecord(inStore: store, key: "alpha")?.runtimeVersion == "1.0.0")
        #expect(GPTKImporter.originalsRecord(inStore: store, key: "beta")?.runtimeVersion == "2.0.0")
    }

    @Test("Removing from one runtime restores that runtime's own DLLs")
    func removeRestoresTheRightOriginals() throws {
        let store = try makeImportedStore(in: tempDir)
        let (alpha, beta) = try makeTwoRuntimes()

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: alpha, originalsKey: "alpha")
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: beta, originalsKey: "beta")
        try GPTKImporter.remove(fromLibraryFolder: alpha, usingStore: store, originalsKey: "alpha")

        #expect(marker(in: alpha) == "alpha wine")
        // Beta keeps Apple's forwarder, and its backups are still there to
        // restore later.
        #expect(marker(in: beta) == nil)
        #expect(GPTKImporter.originalsRecord(inStore: store, key: "beta") != nil)

        try GPTKImporter.remove(fromLibraryFolder: beta, usingStore: store, originalsKey: "beta")
        #expect(marker(in: beta) == "beta wine")
    }

    @Test("Each runtime reports its own deployment state")
    func deploymentStateIsPerRuntime() throws {
        let store = try makeImportedStore(in: tempDir)
        let (alpha, beta) = try makeTwoRuntimes()

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: alpha, originalsKey: "alpha")

        #expect(GPTKImporter.isDeployed(inLibraryFolder: alpha))
        #expect(!GPTKImporter.isDeployed(inLibraryFolder: beta))
    }

    // MARK: - Migration

    /// The store shipped with a flat `originals/`. Left alone, an already
    /// deployed default runtime would have its backups orphaned and its real
    /// Wine DLLs lost.
    @Test("A flat originals folder migrates under the default runtime's key")
    func flatOriginalsMigrate() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime, marker: "default wine")
        try writeRuntimeVersion(at: runtime, 1, 0, 0)

        try makeFlatOriginals(inStore: store, from: runtime, version: "1.0.0")

        try GPTKImporter.migrateFlatOriginals(inStore: store)

        let key = GPTKImporter.originalsKey(for: nil)
        #expect(GPTKImporter.originalsRecord(inStore: store, key: key)?.runtimeVersion == "1.0.0")
        #expect(FileManager.default.fileExists(
            atPath: GPTKImporter.originalsFolder(inStore: store, key: key)
                .appending(path: "d3d11.dll").path(percentEncoded: false)
        ))
        // The flat record is gone, so migration does not run twice.
        #expect(!FileManager.default.fileExists(
            atPath: store.appending(path: "originals")
                .appending(path: "OriginalsVersion.plist").path(percentEncoded: false)
        ))
    }

    @Test("Migrating a migrated store changes nothing")
    func migrationIsIdempotent() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime, marker: "default wine")
        try writeRuntimeVersion(at: runtime, 1, 0, 0)
        try makeFlatOriginals(inStore: store, from: runtime, version: "1.0.0")

        try GPTKImporter.migrateFlatOriginals(inStore: store)
        try GPTKImporter.migrateFlatOriginals(inStore: store)

        let key = GPTKImporter.originalsKey(for: nil)
        #expect(GPTKImporter.originalsRecord(inStore: store, key: key)?.runtimeVersion == "1.0.0")
    }

    /// The migration reaches a deployed default runtime through `remove`, which
    /// is the path that would otherwise lose its DLLs.
    @Test("A store deployed before the split still restores its originals")
    func migratedStoreStillRestores() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime, marker: "default wine")
        try writeRuntimeVersion(at: runtime, 1, 0, 0)
        try makeFlatOriginals(inStore: store, from: runtime, version: "1.0.0")
        try deployForwardersOnly(fromStore: store, into: runtime)

        try GPTKImporter.remove(
            fromLibraryFolder: runtime, usingStore: store, originalsKey: GPTKImporter.originalsKey(for: nil)
        )

        #expect(marker(in: runtime) == "default wine")
    }

    // MARK: - Fixtures

    private func makeTwoRuntimes() throws -> (URL, URL) {
        let alpha = tempDir.appending(path: "alpha")
        let beta = tempDir.appending(path: "beta")
        try makeRuntime(at: alpha, marker: "alpha wine")
        try writeRuntimeVersion(at: alpha, 1, 0, 0)
        try makeRuntime(at: beta, marker: "beta wine")
        try writeRuntimeVersion(at: beta, 2, 0, 0)
        return (alpha, beta)
    }

    /// Reads back the marker `makeRuntime` embeds, so a restored Wine DLL can be
    /// told apart from Apple's forwarder. `nil` means the file is not a marked
    /// Wine original.
    private func marker(in libraryFolder: URL) -> String? {
        let dll = libraryFolder.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows").appending(path: "d3d11.dll")
        // fakePE writes 0x40 of stub, 16 bytes of builtin marker and 16 of
        // padding, so makeRuntime's marker starts at 0x60.
        guard let data = try? Data(contentsOf: dll), data.count > 0x60,
              let trailer = String(bytes: data[0x60...], encoding: .utf8), !trailer.isEmpty
        else { return nil }
        return trailer
    }

    /// Recreates the pre-split store layout: backups directly under
    /// `originals/`, with the stamp beside them.
    private func makeFlatOriginals(inStore store: URL, from runtime: URL, version: String) throws {
        let fileManager = FileManager.default
        let originals = store.appending(path: "originals")
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)

        let peDir = runtime.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows")
        for name in GPTKImporter.forwarderDLLNames {
            let source = peDir.appending(path: name)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try fileManager.copyItem(at: source, to: originals.appending(path: name))
        }

        let plist: [String: Any] = ["runtimeVersion": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: originals.appending(path: "OriginalsVersion.plist"))
    }

    /// Swaps Apple's forwarders in without touching `originals/`, standing in
    /// for a deploy performed by the pre-split code.
    private func deployForwardersOnly(fromStore store: URL, into runtime: URL) throws {
        let fileManager = FileManager.default
        let peDir = runtime.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows")
        let storePE = store.appending(path: "lib").appending(path: "wine").appending(path: "x86_64-windows")
        for name in GPTKImporter.forwarderDLLNames {
            let target = peDir.appending(path: name)
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: storePE.appending(path: name), to: target)
        }
    }
}
