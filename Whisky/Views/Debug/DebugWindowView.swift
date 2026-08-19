//
//  DebugWindowView.swift
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

/// Launch a program with the channels you want and watch what it does.
///
/// A window rather than a tab so it can sit on a second display beside the game
/// it is watching, and so closing the library does not take the log with it.
struct DebugWindowView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @StateObject private var model = DebugSessionModel()
    @State private var programs: [Program] = []

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                launchBar
                Divider()
                channelBar
                Divider()
                DebugLogPane(model: model)
            }
            .frame(minHeight: 280)

            if let bottle = model.bottle {
                RunningProcessesView(bottle: bottle, windowTitle: "debug.window.title")
                    .frame(minHeight: 160)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("debug.window.title")
        .onAppear(perform: selectFirstBottle)
        .onChange(of: model.bottle) { loadPrograms() }
        .onDisappear { model.stopFollowing() }
    }

    private var launchBar: some View {
        HStack(spacing: 12) {
            Picker("debug.bottle", selection: $model.bottle) {
                Text("debug.bottle.none").tag(nil as Bottle?)
                ForEach(bottleVM.bottles) { bottle in
                    Text(bottle.settings.name).tag(bottle as Bottle?)
                }
            }
            .frame(maxWidth: 220)

            Picker("debug.program", selection: $model.program) {
                Text("debug.program.none").tag(nil as Program?)
                ForEach(programs) { program in
                    Text(program.name).tag(program as Program?)
                }
            }
            .frame(maxWidth: 260)

            Button("debug.launch") {
                Task { await model.launch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.program == nil)

            Button("debug.attach") {
                model.followLatestLog()
            }

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var channelBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(WineDebugChannel.common) { channel in
                    Toggle(channel.name, isOn: binding(for: channel))
                        .toggleStyle(.button)
                        .help(channel.summary)
                }
            }

            HStack(spacing: 8) {
                TextField("debug.channels.extra", text: $model.extraChannels)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Text(verbatim: "WINEDEBUG=\(model.winedebugValue)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func binding(for channel: WineDebugChannel) -> Binding<Bool> {
        Binding(
            get: { model.channels.contains(channel.name) },
            set: { isOn in
                if isOn {
                    model.channels.insert(channel.name)
                } else {
                    model.channels.remove(channel.name)
                }
            }
        )
    }

    private func selectFirstBottle() {
        guard model.bottle == nil else { return }
        model.bottle = bottleVM.bottles.first
        loadPrograms()
    }

    private func loadPrograms() {
        guard let bottle = model.bottle else {
            programs = []
            model.program = nil
            return
        }
        programs = bottle.programs
        model.program = nil
        Task {
            await bottle.updateInstalledPrograms()
            programs = bottle.programs
        }
    }
}
