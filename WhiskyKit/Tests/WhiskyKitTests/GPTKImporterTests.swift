//
//  GPTKImporterTests.swift
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

/// Builds a fake PE: 0x40 bytes of stub, then either winebuild's marker
/// (Apple's forwarders and Wine's builtins carry it) or filler (a native PE).
private func fakePE(builtin: Bool) -> Data {
    var data = Data(count: 0x40)
    data.append(builtin ? Data("Wine builtin DLL".utf8) : Data(count: 16))
    data.append(Data(count: 16))
    return data
}

/// Assembles Apple's `redist/lib` payload layout under `libRoot`.
private func makePayload(
    at libRoot: URL,
    version: String? = "4.0b2",
    builtinForwarders: Bool = true,
    omitting: Set<String> = [],
    unixEntriesAsFiles: Bool = false
) throws {
    let fileManager = FileManager.default
    let peDir = libRoot.appending(path: "wine").appending(path: "x86_64-windows")
    let unixDir = libRoot.appending(path: "wine").appending(path: "x86_64-unix")
    let external = libRoot.appending(path: "external")
    try fileManager.createDirectory(at: peDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: external, withIntermediateDirectories: true)

    for name in GPTKImporter.forwarderDLLNames where !omitting.contains(name) {
        try fakePE(builtin: builtinForwarders).write(to: peDir.appending(path: name))
    }

    if !omitting.contains("libd3dshared.dylib") {
        try Data("fake dylib".utf8).write(to: external.appending(path: "libd3dshared.dylib"))
    }

    if !omitting.contains("D3DMetal.framework") {
        let resources = external.appending(path: "D3DMetal.framework")
            .appending(path: "Versions").appending(path: "A").appending(path: "Resources")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        if let version {
            let plist: [String: Any] = ["CFBundleShortVersionString": version]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: resources.appending(path: "Info.plist"))
        }
    }

    for name in GPTKImporter.unixLibraryNames where !omitting.contains(name) {
        let entry = unixDir.appending(path: name)
        if unixEntriesAsFiles {
            try Data("resolved copy".utf8).write(to: entry)
        } else {
            try fileManager.createSymbolicLink(
                atPath: entry.path(percentEncoded: false),
                withDestinationPath: GPTKImporter.unixLinkDestination
            )
        }
    }
}

/// Assembles a minimal Wine runtime tree with builtin-marked d3d DLLs.
private func makeRuntime(at libraryFolder: URL) throws {
    let fileManager = FileManager.default
    let wineLib = libraryFolder.appending(path: "Wine").appending(path: "lib")
    let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
    let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
    try fileManager.createDirectory(at: peDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
    for name in ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"] {
        var wineBuiltin = fakePE(builtin: true)
        wineBuiltin.append(Data("wine original".utf8))
        try wineBuiltin.write(to: peDir.appending(path: name))
    }
}

@Suite("GPTKImporter Tests")
struct GPTKImporterTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "gptk_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - Locating

    @Test("Locates the payload from volume root, redist folder, and lib folder")
    func locateFromAllShapes() throws {
        let volume = tempDir.appending(path: "volume")
        let lib = volume.appending(path: "redist").appending(path: "lib")
        try makePayload(at: lib)

        #expect(GPTKImporter.locatePayload(under: volume) == lib)
        #expect(GPTKImporter.locatePayload(under: volume.appending(path: "redist")) == lib)
        #expect(GPTKImporter.locatePayload(under: lib) == lib)
    }

    @Test("Locate returns nil when nothing payload-shaped exists")
    func locateNothing() throws {
        #expect(GPTKImporter.locatePayload(under: tempDir) == nil)
    }

    // MARK: - Validation

    @Test("Validates a complete payload and reads its version")
    func validateComplete() throws {
        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib)

        let payload = try GPTKImporter.validatePayload(at: lib)

        #expect(payload.version == "4.0b2")
        #expect(payload.libRoot == lib)
    }

    @Test("Missing forwarders are reported by name")
    func validateMissingForwarder() throws {
        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib, omitting: ["d3d12.dll"])

        #expect(throws: GPTKImportError.payloadIncomplete(missing: ["wine/x86_64-windows/d3d12.dll"])) {
            try GPTKImporter.validatePayload(at: lib)
        }
    }

    @Test("A native-marked forwarder is rejected")
    func validateNativeForwarder() throws {
        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib, builtinForwarders: false)

        #expect(throws: GPTKImportError.forwarderNotBuiltin("d3d10.dll")) {
            try GPTKImporter.validatePayload(at: lib)
        }
    }

    @Test("A missing framework is reported")
    func validateMissingFramework() throws {
        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib, omitting: ["D3DMetal.framework"])

        #expect(throws: GPTKImportError.payloadIncomplete(missing: ["external/D3DMetal.framework"])) {
            try GPTKImporter.validatePayload(at: lib)
        }
    }

    @Test("An unreadable framework version is rejected")
    func validateUnreadableVersion() throws {
        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib, version: nil)

        #expect(throws: GPTKImportError.versionUnreadable) {
            try GPTKImporter.validatePayload(at: lib)
        }
    }

    // MARK: - Import

    @Test("Import copies the payload, normalizes symlinks, and records the version")
    func importPayload() throws {
        let lib = tempDir.appending(path: "lib")
        let store = tempDir.appending(path: "store")
        try makePayload(at: lib)
        let payload = try GPTKImporter.validatePayload(at: lib)

        let record = try GPTKImporter.importPayload(payload, intoStore: store)

        #expect(record.gptkVersion == "4.0b2")
        #expect(GPTKImporter.storedRecord(inStore: store)?.gptkVersion == "4.0b2")

        let link = store.appending(path: "lib").appending(path: "wine")
            .appending(path: "x86_64-unix").appending(path: "dxgi.so")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination == GPTKImporter.unixLinkDestination)
    }

    @Test("Import rebuilds unix entries as symlinks even when the source resolved them into files")
    func importNormalizesResolvedUnixEntries() throws {
        let lib = tempDir.appending(path: "lib")
        let store = tempDir.appending(path: "store")
        try makePayload(at: lib, unixEntriesAsFiles: true)
        let payload = try GPTKImporter.validatePayload(at: lib)

        try GPTKImporter.importPayload(payload, intoStore: store)

        let link = store.appending(path: "lib").appending(path: "wine")
            .appending(path: "x86_64-unix").appending(path: "d3d11.so")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination == GPTKImporter.unixLinkDestination)
    }

    @Test("Stored record is nil without a store or with a gutted payload")
    func storedRecordAbsent() throws {
        let store = tempDir.appending(path: "store")
        #expect(GPTKImporter.storedRecord(inStore: store) == nil)

        let lib = tempDir.appending(path: "lib")
        try makePayload(at: lib)
        let payload = try GPTKImporter.validatePayload(at: lib)
        try GPTKImporter.importPayload(payload, intoStore: store)
        try FileManager.default.removeItem(
            at: store.appending(path: "lib").appending(path: "external")
        )

        #expect(GPTKImporter.storedRecord(inStore: store) == nil)
    }

    // MARK: - Deployment

    private func importedStore() throws -> URL {
        let lib = tempDir.appending(path: "payload")
        let store = tempDir.appending(path: "store")
        try makePayload(at: lib)
        let payload = try GPTKImporter.validatePayload(at: lib)
        try GPTKImporter.importPayload(payload, intoStore: store)
        return store
    }

    @Test("Deploy backs up Wine's originals and places the payload")
    func deploy() throws {
        let store = try importedStore()
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        let backupData = try Data(contentsOf: backup)
        #expect(backupData.suffix(13) == Data("wine original".utf8))

        let wineLib = runtime.appending(path: "Wine").appending(path: "lib")
        let deployed = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: "dxgi.dll")
        #expect(FileManager.default.fileExists(atPath: deployed.path(percentEncoded: false)))
        #expect(GPTKImporter.isDeployed(inLibraryFolder: runtime))

        let link = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
            .appending(path: "d3d12.so")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination == GPTKImporter.unixLinkDestination)
    }

    @Test("Redeploying never overwrites the backed-up originals")
    func redeployKeepsOriginals() throws {
        let store = try importedStore()
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        let backupData = try Data(contentsOf: backup)
        #expect(backupData.suffix(13) == Data("wine original".utf8))
    }

    @Test("Deploying from an empty store fails")
    func deployEmptyStore() throws {
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        #expect(throws: GPTKImportError.storeEmpty) {
            try GPTKImporter.deploy(
                fromStore: tempDir.appending(path: "missing"), intoLibraryFolder: runtime
            )
        }
    }

    @Test("Remove restores the originals and clears the payload")
    func removeRestores() throws {
        let store = try importedStore()
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        let wineLib = runtime.appending(path: "Wine").appending(path: "lib")
        let restored = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: "d3d11.dll")
        let restoredData = try Data(contentsOf: restored)
        #expect(restoredData.suffix(13) == Data("wine original".utf8))
        #expect(!GPTKImporter.isDeployed(inLibraryFolder: runtime))

        let external = wineLib.appending(path: "external")
        #expect(!FileManager.default.fileExists(atPath: external.path(percentEncoded: false)))
    }

    // MARK: - Runtime capability flag

    @Test("gptkCapable decodes when present and stays nil when absent")
    func gptkCapableDecoding() throws {
        let capable = WhiskyWineVersion(
            version: .init(4, 0, 0), gptkCapable: true
        )
        let encoder = PropertyListEncoder()
        let decoded = try PropertyListDecoder().decode(
            WhiskyWineVersion.self, from: encoder.encode(capable)
        )
        #expect(decoded.gptkCapable == true)

        let legacy = WhiskyWineVersion(version: .init(3, 1, 1))
        let decodedLegacy = try PropertyListDecoder().decode(
            WhiskyWineVersion.self, from: encoder.encode(legacy)
        )
        #expect(decodedLegacy.gptkCapable == nil)
    }
}
