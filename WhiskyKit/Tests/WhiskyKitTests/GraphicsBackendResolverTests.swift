//
//  GraphicsBackendResolverTests.swift
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

import SemanticVersion
@testable import WhiskyKit
import XCTest

final class GraphicsBackendResolverTests: XCTestCase {
    // MARK: - Architecture

    /// D3DMetal and DXMT live only in the runtime's x86_64-windows tree, so a
    /// 32-bit program offered either one loads Wine's builtin d3d11 on wined3d
    /// and reports that DirectX 11 is missing. DXVK is the only backend with a
    /// 32-bit payload.
    func testResolvesDXVKForA32BitProgramEvenWithD3DMetal() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(
                runtimeInfo: runtime,
                d3dMetalInstalled: true,
                dxmtRuntimeNative: true,
                architecture: .x32
            ),
            .dxvk
        )
    }

    func testResolves64BitProgramsAsBefore() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(
                runtimeInfo: runtime, d3dMetalInstalled: true, architecture: .x64
            ),
            .d3dMetal
        )
    }

    /// The default exists for callers describing a bottle rather than a launch,
    /// which have no target to read.
    func testDefaultsToThe64BitAnswer() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(runtimeInfo: runtime, d3dMetalInstalled: true),
            GraphicsBackendResolver.resolve(
                runtimeInfo: runtime, d3dMetalInstalled: true, architecture: .x64
            )
        )
    }

    func testReadsTheArchitectureOfAnExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "backendarch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thirtyTwo = directory.appending(path: "x32.exe")
        let sixtyFour = directory.appending(path: "x64.exe")
        try PEBuilder.createMinimalPE32().write(to: thirtyTwo)
        try PEBuilder.createMinimalPE32Plus().write(to: sixtyFour)

        XCTAssertEqual(GraphicsBackendResolver.architecture(of: thirtyTwo), .x32)
        XCTAssertEqual(GraphicsBackendResolver.architecture(of: sixtyFour), .x64)
    }

    /// An unreadable file keeps the path it took before rather than being
    /// quietly demoted to DXVK.
    func testUnreadableExecutableIsTreatedAs64Bit() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "nothing_\(UUID().uuidString).exe")

        XCTAssertEqual(GraphicsBackendResolver.architecture(of: missing), .x64)
    }

    func testResolvesD3DMetalWhenPayloadInstalled() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(runtimeInfo: runtime, d3dMetalInstalled: true),
            .d3dMetal
        )
    }

    func testResolvesDXMTWhenNoD3DMetalButRuntimeBundlesIt() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(
                runtimeInfo: runtime, d3dMetalInstalled: false, dxmtRuntimeNative: true
            ),
            .dxmt
        )
    }

    /// The version record alone is not the gate the picker applies: a
    /// builtin-variant or missing DXMT payload fails at launch, so auto must
    /// not promise a backend the picker would refuse.
    func testResolvesDXVKWhenDXMTPayloadNotNative() {
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 1, 1), dxmtVersion: "0.80")

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(
                runtimeInfo: runtime, d3dMetalInstalled: false, dxmtRuntimeNative: false
            ),
            .dxvk
        )
    }

    func testResolvesDXVKWhenNoD3DMetalAndNoDXMT() {
        // Pre-3.1.0 runtimes bundle DXVK but not DXMT.
        let runtime = WhiskyWineVersion(version: SemanticVersion(3, 0, 0))

        XCTAssertEqual(
            GraphicsBackendResolver.resolve(runtimeInfo: runtime, d3dMetalInstalled: false),
            .dxvk
        )
    }

    func testResolvesDXVKWhenRuntimeRecordMissing() {
        XCTAssertEqual(
            GraphicsBackendResolver.resolve(runtimeInfo: nil, d3dMetalInstalled: false),
            .dxvk
        )
    }

    func testNeverResolvesToRecommended() {
        for installed in [true, false] {
            XCTAssertNotEqual(
                GraphicsBackendResolver.resolve(runtimeInfo: nil, d3dMetalInstalled: installed),
                .recommended
            )
        }
    }
}
