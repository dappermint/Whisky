//
//  BottleWineConfig.swift
//  WhiskyKit
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

public enum WinVersion: String, CaseIterable, Codable, Sendable {
    case winXP = "winxp64"
    case win7
    case win8
    case win81
    case win10
    case win11

    public func pretty() -> String {
        switch self {
        case .winXP:
            "Windows XP"
        case .win7:
            "Windows 7"
        case .win8:
            "Windows 8"
        case .win81:
            "Windows 8.1"
        case .win10:
            "Windows 10"
        case .win11:
            "Windows 11"
        }
    }
}

public extension WinVersion {
    /// The build number Wine writes for this version.
    ///
    /// Read out of the shipped runtime with `winecfg -v <version>` rather than
    /// transcribed from documentation, so it is what a bottle actually gets.
    var defaultBuild: Int {
        switch self {
        case .winXP: 3_790
        case .win7: 7_601
        case .win8: 9_200
        case .win81: 9_600
        case .win10: 19_045
        case .win11: 22_000
        }
    }

    /// Build numbers that still name this version.
    ///
    /// A build outside the range makes the pair unnameable, and every reader
    /// then answers differently: a prefix on 6.1 carrying build 22100 told
    /// `winecfg -v` "vista", told Steam "Windows 7", and sat under a Whisky
    /// picker that said Windows 11.
    var buildRange: ClosedRange<Int> {
        switch self {
        case .winXP: 2_600 ... 3_790
        case .win7: 7_600 ... 7_602
        case .win8: 9_200 ... 9_200
        case .win81: 9_600 ... 9_600
        case .win10: 10_240 ... 19_999
        case .win11: 22_000 ... 99_999
        }
    }

    /// Whether this version can carry the given build number.
    func accepts(build: Int) -> Bool {
        buildRange.contains(build)
    }
}

public enum EnhancedSync: Codable, Equatable, Sendable {
    case none, esync, msync
}

public struct BottleWineConfig: Codable, Equatable {
    static let defaultWineVersion = SemanticVersion(7, 7, 0)
    var wineVersion: SemanticVersion = Self.defaultWineVersion
    var windowsVersion: WinVersion = .win10
    var enhancedSync: EnhancedSync = .msync
    var avxEnabled: Bool = false
    /// Which installed runtime this bottle runs on, by folder name under
    /// ``WhiskyWineInstaller/runtimesFolder``. `nil` is the default runtime,
    /// which is what every bottle written before runtime selection decodes to.
    var runtime: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wineVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .wineVersion) ?? Self
            .defaultWineVersion
        self.windowsVersion = container.decodeLenientIfPresent(WinVersion.self, forKey: .windowsVersion) ?? .win10
        self.enhancedSync = try container.decodeIfPresent(EnhancedSync.self, forKey: .enhancedSync) ?? .msync
        self.avxEnabled = try container.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        self.runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
    }
}
