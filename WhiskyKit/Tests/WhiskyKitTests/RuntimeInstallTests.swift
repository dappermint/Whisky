//
//  RuntimeInstallTests.swift
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
import SemanticVersion
import Testing
@testable import WhiskyKit

@Suite("Runtime Install Tests")
struct RuntimeInstallTests {
    private let tempDir: URL

    init() throws {
        tempDir = try makeGPTKTempDir()
    }

    // MARK: - Identifiers

    @Test("An identifier carries the runtime's name and version")
    func identifierFromNameAndVersion() {
        let info = WhiskyWineVersion(version: SemanticVersion(4, 0, 0), name: "winecx-gptk")

        #expect(WhiskyWineInstaller.runtimeIdentifier(for: info) == "winecx-gptk-4.0.0")
    }

    @Test("An unnamed runtime still gets an identifier")
    func identifierWithoutName() {
        let info = WhiskyWineVersion(version: SemanticVersion(3, 1, 1))

        #expect(WhiskyWineInstaller.runtimeIdentifier(for: info) == "runtime-3.1.1")
    }

    /// The name comes out of an archive, so it reaches a path as untrusted text.
    @Test("A path-shaped name cannot escape the runtimes folder")
    func identifierRejectsTraversal() {
        let info = WhiskyWineVersion(version: SemanticVersion(1, 0, 0), name: "../../etc")
        let identifier = WhiskyWineInstaller.runtimeIdentifier(for: info)

        #expect(!identifier.contains("/"))
        #expect(WhiskyWineInstaller.isValidRuntimeIdentifier(identifier))
    }

    @Test("Versions install side by side rather than replacing each other")
    func identifiersAreVersioned() {
        let old = WhiskyWineVersion(version: SemanticVersion(4, 0, 0), name: "winecx-gptk")
        let new = WhiskyWineVersion(version: SemanticVersion(4, 1, 0), name: "winecx-gptk")

        #expect(WhiskyWineInstaller.runtimeIdentifier(for: old)
            != WhiskyWineInstaller.runtimeIdentifier(for: new))
    }

    // MARK: - Installing

    @Test("Installing unpacks the archive under its own identifier")
    func installRuntime() throws {
        let tarball = try makeRuntimeTarball(in: tempDir, name: "winecx-gptk", version: SemanticVersion(4, 0, 0))
        let runtimes = tempDir.appending(path: "Runtimes")

        let identifier = try WhiskyWineInstaller.installRuntime(tarball: tarball, intoRuntimesFolder: runtimes)

        #expect(identifier == "winecx-gptk-4.0.0")
        #expect(WhiskyWineInstaller.isRuntimePresent(
            inLibraryFolder: runtimes.appending(path: identifier)
        ))
    }

    @Test("An archive without a usable runtime is rejected")
    func installRejectsIncompleteArchive() throws {
        // makeLibrariesTarball writes a Libraries folder with no wine64 in it.
        let tarball = try makeLibrariesTarball(in: tempDir)
        let runtimes = tempDir.appending(path: "Runtimes")

        #expect(throws: WhiskyWineInstallError.runtimeIncomplete) {
            try WhiskyWineInstaller.installRuntime(tarball: tarball, intoRuntimesFolder: runtimes)
        }
        #expect(!FileManager.default.fileExists(atPath: runtimes.path(percentEncoded: false)))
    }

    @Test("A missing archive is rejected before anything is touched")
    func installRejectsMissingArchive() throws {
        let runtimes = tempDir.appending(path: "Runtimes")

        #expect(throws: WhiskyWineInstallError.tarballNotFound) {
            try WhiskyWineInstaller.installRuntime(
                tarball: tempDir.appending(path: "absent.tar.gz"), intoRuntimesFolder: runtimes
            )
        }
    }

    @Test("Reinstalling the same version replaces it in place")
    func reinstallReplaces() throws {
        let runtimes = tempDir.appending(path: "Runtimes")
        let version = SemanticVersion(1, 0, 0)
        let first = try makeRuntimeTarball(in: tempDir.appending(path: "a"), name: "rt", version: version)
        let second = try makeRuntimeTarball(in: tempDir.appending(path: "b"), name: "rt", version: version)

        let one = try WhiskyWineInstaller.installRuntime(tarball: first, intoRuntimesFolder: runtimes)
        let two = try WhiskyWineInstaller.installRuntime(tarball: second, intoRuntimesFolder: runtimes)

        #expect(one == two)
        let installed = try FileManager.default.contentsOfDirectory(
            atPath: runtimes.path(percentEncoded: false)
        )
        #expect(installed == [one])
    }

    // MARK: - Fixtures

    /// A `Libraries.tar.gz` shaped like the real runtime archive: a version
    /// plist and a `wine64`, which is what `isRuntimePresent` requires.
    private func makeRuntimeTarball(
        in directory: URL, name: String?, version: SemanticVersion
    ) throws -> URL {
        let fileManager = FileManager.default
        let source = directory.appending(path: "Libraries")
        let bin = source.appending(path: "Wine").appending(path: "bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("fake wine".utf8).write(to: bin.appending(path: "wine64"))

        var plist: [String: Any] = [
            "version": ["major": version.major, "minor": version.minor, "patch": version.patch]
        ]
        if let name {
            plist["name"] = name
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: source.appending(path: "WhiskyWineVersion").appendingPathExtension("plist"))

        let tarball = directory.appending(path: "Libraries.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = directory
        tar.arguments = ["-czf", tarball.path(percentEncoded: false), "Libraries"]
        try tar.run()
        tar.waitUntilExit()
        return tarball
    }
}
