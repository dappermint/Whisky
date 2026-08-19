//
//  DebugLogPane.swift
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

/// The live half of the Debug window: the run's log as it is written, filtered.
struct DebugLogPane: View {
    @ObservedObject var model: DebugSessionModel
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            logBody
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("debug.filter", selection: $model.filter) {
                Text("debug.filter.all").tag(DebugSessionModel.Filter.all)
                Text("debug.filter.problems").tag(DebugSessionModel.Filter.problems)
                Text("debug.filter.fixme").tag(DebugSessionModel.Filter.fixme)
                Text("debug.filter.trace").tag(DebugSessionModel.Filter.trace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            TextField("debug.search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Toggle("debug.follow", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Spacer()

            if model.isFollowing {
                Label("debug.streaming", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button("debug.clear") {
                model.clear()
            }
            .disabled(model.lines.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var logBody: some View {
        if model.lines.isEmpty {
            ContentUnavailableView(
                "debug.log.empty",
                systemImage: "text.alignleft",
                description: Text("debug.log.empty.description")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.visibleLines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line.severity))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.lines.count) {
                    guard autoScroll, let last = model.visibleLines.last else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for severity: DebugLogLine.Severity) -> Color {
        switch severity {
        case .err: .red
        case .warn: .orange
        case .fixme: .secondary
        case .trace: .secondary
        case .plain: .primary
        }
    }
}
