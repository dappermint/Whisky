//
//  RuntimeTLSTests.swift
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

/// A runtime's unix library directory, with only the two files that matter.
private struct UnixFixture {
    let folder: URL

    init(gnutls: Bool, libiconv: Data?) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "tls_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if gnutls {
            try Data("gnutls".utf8).write(to: folder.appending(path: "libgnutls.30.dylib"))
        }
        if let libiconv {
            try libiconv.write(to: folder.appending(path: "libiconv.2.dylib"))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A thin arm64 dylib carrying nothing but a symbol table, which is all the
/// check reads.
private enum MachOFixture {
    static func dylib(exporting exports: [String], importing imports: [String] = []) -> Data {
        var strings = Data([0])
        var symbols: [(offset: UInt32, kind: UInt8)] = []
        // N_SECT | N_EXT is a definition this image provides; N_UNDF | N_EXT is
        // one it asks another image for, under exactly the same name.
        for (names, kind) in [(exports, UInt8(0x0F)), (imports, UInt8(0x01))] {
            for name in names {
                symbols.append((UInt32(strings.count), kind))
                strings.append(contentsOf: Array((name + "\u{0}").utf8))
            }
        }

        let commandSize = 24
        let symbolOffset = 32 + commandSize
        let stringOffset = symbolOffset + symbols.count * 16

        var data = Data()
        for value: UInt32 in [
            0xFEED_FACF, 0x0100_000C, 0, 6, 1, UInt32(commandSize), 0, 0,
            2, UInt32(commandSize), UInt32(symbolOffset), UInt32(symbols.count),
            UInt32(stringOffset), UInt32(strings.count)
        ] {
            data.append(littleEndian: value)
        }

        for symbol in symbols {
            data.append(littleEndian: symbol.offset)
            data.append(contentsOf: [symbol.kind, 1, 0, 0])
            data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        }
        data.append(strings)
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}

@Suite("Runtime TLS")
struct RuntimeTLSTests {
    private func status(gnutls: Bool = true, libiconv: Data?) throws -> RuntimeTLS.Status {
        let fixture = try UnixFixture(gnutls: gnutls, libiconv: libiconv)
        defer { fixture.remove() }
        return RuntimeTLS.status(unixFolder: fixture.folder)
    }

    @Test("GNU libiconv serves GnuTLS' dependencies")
    func gnuLibiconvIsAvailable() throws {
        let gnu = MachOFixture.dylib(exporting: ["_libiconv_open", "_libiconv", "_iconv"])
        #expect(try status(libiconv: gnu) == .available)
    }

    /// The whole point: Apple's copy under the GNU name, which is what the
    /// arm64 runtime shipped and what left every HTTPS call answering
    /// `SEC_E_SECPKG_NOT_FOUND`.
    @Test("Apple's libiconv under the GNU name is named as the cause")
    func appleLibiconvIsCaught() throws {
        let apple = MachOFixture.dylib(exporting: ["_iconv", "_iconv_open", "_iconv_close"])
        #expect(try status(libiconv: apple) == .libiconvIsApples)
    }

    /// A library that calls `libiconv` mentions the name too. Only a definition
    /// counts.
    @Test("Asking for the symbol is not the same as exporting it")
    func anImportIsNotAnExport() throws {
        let consumer = MachOFixture.dylib(exporting: ["_iconv"], importing: ["_libiconv"])
        #expect(try status(libiconv: consumer) == .libiconvIsApples)
    }

    @Test("A runtime that bundles no GnuTLS is not judged")
    func noBundledGnuTLS() throws {
        #expect(try status(gnutls: false, libiconv: MachOFixture.dylib(exporting: ["_iconv"])) == .unknown)
    }

    @Test("A missing or unreadable libiconv is not evidence of anything")
    func nothingToRead() throws {
        #expect(try status(libiconv: nil) == .unknown)
        #expect(try status(libiconv: Data("not a mach-o".utf8)) == .unknown)
    }

    @Test("A runtime with no unix directory has nothing to check")
    func noUnixDirectory() {
        #expect(RuntimeTLS.unixFolder(forRuntime: "whisky-no-such-runtime-0.0.0") == nil)
        #expect(RuntimeTLS.status(forRuntime: "whisky-no-such-runtime-0.0.0") == .unknown)
    }

    @Test("Every status says something a person can act on")
    func statusesReadPlainly() {
        for status: RuntimeTLS.Status in [.available, .libiconvIsApples, .unknown] {
            #expect(!status.summary.isEmpty)
        }
    }
}
