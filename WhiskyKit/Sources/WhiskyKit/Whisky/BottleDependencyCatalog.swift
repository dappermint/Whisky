//
//  BottleDependencyCatalog.swift
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

extension DependencyDefinition {
    /// The default set of dependencies shown in the bottle configuration UI.
    ///
    /// Each entry maps a user-facing name to one or more winetricks verbs.
    /// The list covers the most commonly needed Windows components for
    /// games and applications running under Wine.
    public static let standardDependencies: [DependencyDefinition] = [
        DependencyDefinition(
            id: "vcruntime",
            displayName: "Visual C++ Runtime",
            description: "Required by most Windows games and applications",
            // 2022 is the redistributable Microsoft still ships, and it carries
            // the 2015-2019 runtimes with it, so it covers what vcrun2019 did.
            winetricksVerbs: ["vcrun2022"],
            category: .runtime,
            estimatedInstallMinutes: 2,
            equivalentVerbs: ["vcrun2019"],
            // Not probed by file: Wine ships builtin vcruntime140.dll and
            // msvcp140.dll, so every bottle has them from wineboot onward. The
            // redistributable's own version key is what actually separates the
            // two, and a game's bundled vcredist writes it as well.
            probeRegistry: [
                DependencyRegistryProbe(
                    key: #"HKLM\Software\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"#,
                    valueName: "Installed"
                )
            ]
        ),
        DependencyDefinition(
            id: "dotnet48",
            displayName: ".NET Framework 4.8",
            description: "Required by .NET applications and some game launchers",
            winetricksVerbs: ["dotnet48"],
            category: .runtime,
            estimatedInstallMinutes: 10
        ),
        DependencyDefinition(
            id: "directx",
            displayName: "DirectX Runtime",
            description: "DirectX 9/10/11 components for older games",
            winetricksVerbs: ["d3dx9", "d3dcompiler_47"],
            category: .directx,
            estimatedInstallMinutes: 3,
            // Wine ships builtin d3dx9_43.dll and d3dcompiler_47.dll too, and
            // its d3dcompiler is a partial reimplementation, so the file being
            // present says nothing about whether a title can compile HLSL at
            // runtime. The override winetricks sets is the honest signal.
            probeRegistry: [
                DependencyRegistryProbe(
                    key: #"HKCU\Software\Wine\DllOverrides"#,
                    valueName: "d3dcompiler_47"
                )
            ]
        ),
        DependencyDefinition(
            id: "directx_audio",
            displayName: "DirectX Audio",
            description: "XACT audio framework for games using DirectX audio",
            winetricksVerbs: ["xact"],
            category: .audio,
            estimatedInstallMinutes: 2
        ),
        DependencyDefinition(
            id: "corefonts",
            displayName: "Core Fonts",
            description: "Arial, Times New Roman, Verdana and the rest of the set Windows UIs assume",
            // Usually already satisfied: BottleFontBootstrap copies these out of
            // macOS at bottle creation, since macOS ships every one of them.
            // The verb is the fallback for bottles made before that, and for a
            // Mac missing a face.
            winetricksVerbs: ["corefonts"],
            category: .fonts,
            estimatedInstallMinutes: 2,
            probeFiles: [
                "windows/Fonts/Arial.ttf",
                "windows/Fonts/Verdana.ttf"
            ]
        ),
        DependencyDefinition(
            id: "sourcehansans",
            displayName: "CJK Fonts",
            description: "Source Han Sans, for Chinese, Japanese and Korean text",
            winetricksVerbs: ["sourcehansans"],
            category: .fonts,
            estimatedInstallMinutes: 5,
            probeFiles: ["windows/Fonts/sourcehansans.ttc"]
        )
    ]
}
