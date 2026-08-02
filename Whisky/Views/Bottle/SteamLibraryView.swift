//
//  SteamLibraryView.swift
//  Whisky
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

import SwiftUI
import WhiskyKit

struct SteamLibraryView: View {
    @ObservedObject var bottle: Bottle
    @StateObject private var orchestrator: SteamClientOrchestrator
    @State private var games: [SteamGame] = []
    @State private var loaded = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _orchestrator = StateObject(wrappedValue: SteamClientOrchestrator(bottle: bottle))
    }

    var body: some View {
        Form {
            if loaded, games.isEmpty {
                Text("steam.library.empty")
                    .foregroundStyle(.secondary)
            }
            ForEach(games) { game in
                gameRow(game)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("tab.steamLibrary")
        .task { await refresh() }
        .onDisappear { orchestrator.stop() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("steamLibrary.refresh")
            }
        }
        .alert(
            "steam.launch.failed",
            isPresented: Binding(
                get: { orchestrator.launchError != nil },
                set: { if !$0 { orchestrator.launchError = nil } }
            )
        ) {} message: {
            Text(orchestrator.launchError ?? "")
        }
    }

    @ViewBuilder
    private func gameRow(_ game: SteamGame) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(game.name)
                Text(verbatim: String(game.appId))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusView(for: game)
            if orchestrator.runningAppIds.contains(game.appId) {
                Button {
                    Task { await orchestrator.stop(game) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityIdentifier("steamLibrary.stop.\(game.appId)")
                .help("steam.button.stop")
            } else {
                Button {
                    Task { await orchestrator.launch(game) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(orchestrator.phases[game.appId] != nil)
                .accessibilityIdentifier("steamLibrary.play.\(game.appId)")
                .help("steam.button.play")
            }
        }
    }

    @ViewBuilder
    private func statusView(for game: SteamGame) -> some View {
        if orchestrator.runningAppIds.contains(game.appId) {
            Label("steam.status.running", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .imageScale(.small)
                .foregroundStyle(.green)
        } else {
            switch orchestrator.phases[game.appId] {
            case .startingClient:
                Text("steam.status.starting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .launching:
                ProgressView()
                    .controlSize(.small)
            case nil:
                if case .confirmedStall = orchestrator.downloadStatus {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .foregroundStyle(.orange)
                } else if case .downloading = orchestrator.downloadStatus {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refresh() async {
        let bottleURL = bottle.url
        games = await Task.detached { SteamLibrary.enumerate(bottleURL: bottleURL) }.value
        loaded = true
        orchestrator.startTracking(games: games)
    }
}
