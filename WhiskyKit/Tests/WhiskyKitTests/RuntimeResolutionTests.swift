//
//  RuntimeResolutionTests.swift
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

@Suite("Runtime Resolution Tests")
struct RuntimeResolutionTests {
    // MARK: - Folder resolution

    @Test("A nil runtime resolves to the default library folder")
    func nilRuntimeIsDefault() {
        #expect(WhiskyWineInstaller.libraryFolder(for: nil) == WhiskyWineInstaller.libraryFolder)
        #expect(WhiskyWineInstaller.binFolder(for: nil) == WhiskyWineInstaller.binFolder)
    }

    @Test("A named runtime resolves under the runtimes folder")
    func namedRuntime() {
        let resolved = WhiskyWineInstaller.libraryFolder(for: "winecx-gptk-4.0.0")

        #expect(resolved == WhiskyWineInstaller.runtimesFolder.appending(path: "winecx-gptk-4.0.0"))
        #expect(WhiskyWineInstaller.binFolder(for: "winecx-gptk-4.0.0") ==
            resolved.appending(path: "Wine").appending(path: "bin"))
    }

    /// `install()` deletes the whole `Libraries` folder before untarring, so a
    /// runtimes folder nested inside it would be destroyed by every engine
    /// update — the same trap that moved the GPTK store out.
    @Test("The runtimes folder survives an engine update")
    func runtimesFolderIsNotInsideLibraries() {
        let libraries = WhiskyWineInstaller.libraryFolder.path(percentEncoded: false)
        let runtimes = WhiskyWineInstaller.runtimesFolder.path(percentEncoded: false)

        #expect(!runtimes.hasPrefix(libraries + "/"))
        #expect(runtimes != libraries)
    }

    // MARK: - Identifier validation

    @Test("Plain folder names are valid identifiers")
    func validIdentifiers() {
        for identifier in ["Wine", "winecx-gptk-4.0.0", "runtime_1", "a"] {
            #expect(WhiskyWineInstaller.isValidRuntimeIdentifier(identifier), "\(identifier) should be valid")
        }
    }

    /// Bottle metadata is a user-editable plist, so an identifier arrives as
    /// untrusted text and `appending(path:)` would resolve `..` right out of
    /// the runtimes folder.
    @Test("Path-shaped identifiers are rejected")
    func invalidIdentifiers() {
        for identifier in ["", "..", ".", ".hidden", "../../etc", "a/b", "/absolute", "nul\0byte"] {
            #expect(!WhiskyWineInstaller.isValidRuntimeIdentifier(identifier), "\(identifier) should be rejected")
        }
    }

    @Test("A rejected identifier falls back to the default runtime")
    func traversalFallsBackToDefault() {
        for identifier in ["../../../etc", "..", ""] {
            #expect(WhiskyWineInstaller.libraryFolder(for: identifier) == WhiskyWineInstaller.libraryFolder)
        }
    }

    // MARK: - Bottle metadata

    @Test("Bottle config written before runtime selection decodes to nil")
    func legacyConfigDecodesToNil() throws {
        let plist: [String: Any] = [
            "wineVersion": ["major": 8, "minor": 0, "patch": 1, "preRelease": "", "build": ""],
            "windowsVersion": "win10",
            "enhancedSync": ["msync": [:]],
            "avxEnabled": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let config = try PropertyListDecoder().decode(BottleWineConfig.self, from: data)

        #expect(config.runtime == nil)
    }

    @Test("A selected runtime round-trips through the bottle config")
    func runtimeRoundTrips() throws {
        var config = BottleWineConfig()
        config.runtime = "winecx-gptk-4.0.0"

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let decoded = try PropertyListDecoder().decode(BottleWineConfig.self, from: encoder.encode(config))

        #expect(decoded.runtime == "winecx-gptk-4.0.0")
        #expect(decoded == config)
    }

    /// Bottles on the default runtime must not gain a key, so their plists stay
    /// byte-identical and a downgrade to a Whisky without runtime selection
    /// reads them unchanged.
    @Test("A nil runtime writes no key")
    func nilRuntimeIsOmittedFromThePlist() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(BottleWineConfig())

        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        #expect(plist?["runtime"] == nil)
    }
}
