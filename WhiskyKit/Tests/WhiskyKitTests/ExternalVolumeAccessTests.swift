//
//  ExternalVolumeAccessTests.swift
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
@testable import WhiskyKit
import XCTest

final class ExternalVolumeAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "access_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritableDirectoryIsGranted() {
        XCTAssertEqual(ExternalVolumeAccess.requestAccess(to: directory), .granted)
    }

    func testProbeLeavesNothingBehind() throws {
        XCTAssertEqual(ExternalVolumeAccess.requestAccess(to: directory), .granted)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [], "the probe file must not survive the check")
    }

    func testUncreatedPathProbesItsNearestExistingParent() {
        // Bottle directories don't exist yet at creation time; access has to be
        // answerable from the parent rather than reported as unavailable.
        let notYetCreated = directory.appending(path: "a/b/c")
        XCTAssertEqual(ExternalVolumeAccess.requestAccess(to: notYetCreated), .granted)
    }

    func testUnwritableDirectoryIsDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        guard case .denied = ExternalVolumeAccess.requestAccess(to: directory) else {
            return XCTFail("a read-only directory must report denied")
        }
    }

    func testFileTargetIsNotADirectory() throws {
        let file = directory.appending(path: "regular.txt")
        try Data("x".utf8).write(to: file)
        guard case .failed = ExternalVolumeAccess.requestAccess(to: file) else {
            return XCTFail("a regular file is not a usable bottle location")
        }
    }

    func testTemporaryDirectoryIsClassifiedInternal() {
        XCTAssertEqual(ExternalVolumeAccess.volumeKind(of: directory), .internalDisk)
        XCTAssertFalse(ExternalVolumeAccess.VolumeKind.internalDisk.requiresConsent)
    }

    func testOnlyGatedVolumeKindsRequireConsent() {
        XCTAssertTrue(ExternalVolumeAccess.VolumeKind.removable.requiresConsent)
        XCTAssertTrue(ExternalVolumeAccess.VolumeKind.network.requiresConsent)
    }

    func testNilIfGrantedCollapsesTheHappyPath() {
        XCTAssertNil(ExternalVolumeAccess.Access.granted.nilIfGranted)
        XCTAssertEqual(
            ExternalVolumeAccess.Access.denied(.removable).nilIfGranted,
            .denied(.removable)
        )
    }

    func testPrivacySettingsDeepLinkIsValid() throws {
        let url = try XCTUnwrap(ExternalVolumeAccess.privacySettingsURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
    }
}
