import AppKit
import BollardCore
import SwiftUI

struct Sparkline: View {
  var samples: [Double]
  var body: some View {
    Canvas { context, size in
      guard samples.count > 1 else { return }
      let top = max(25, samples.max() ?? 0)
      var path = Path()
      for (i, v) in samples.enumerated() {
        let point = CGPoint(
          x: size.width * Double(i) / Double(samples.count - 1),
          y: size.height - (size.height - 1) * min(1, v / top))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      context.stroke(
        path, with: .style(.tint),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }
  }
}

/// Everything a right-click offers, and the detail view's overflow menu.
struct WorkloadMenu: View {
  var store: Store
  var w: Workload
  var body: some View {
    if w.blocked == nil {
      Button(w.section == .apps ? "Quit \(store.name(w))" : "Stop") { store.act(w, .terminate) }
      if w.section != .apps { Button("Interrupt (Ctrl-C)") { store.act(w, .interrupt) } }
      Button("Force Quit") { store.act(w, .kill) }
      if w.launchdLabel != nil {
        Button(w.brewService.map { "brew services stop \($0)" } ?? "Unload from launchd") {
          store.unload(w)
        }
      }
      if w.restartReason == nil { Button("Restart in Terminal") { store.restart(w) } }
      Divider()
    }
    ForEach(w.tcpPorts, id: \.self) { port in
      Button("Open localhost:\(String(port))") { store.open(port: port) }
    }
    if place {
      Menu("Open Project In") {
        Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.lead.cwd)) }
        ForEach(Launcher.editors, id: \.self) { name in
          Button(name) { Launcher.openIn(name, w.lead.cwd) }
        }
        Divider()
        ForEach(Launcher.agents, id: \.path) { agent in
          Button("\(agent.name) Here") { store.agentHere(agent.path, w) }
        }
      }
    }
    Divider()
    Button(store.pinned(w) ? "Unpin" : "Pin to Top") { store.togglePin(w) }
    Button("Rename…") { store.beginRename(w) }
    Divider()
    Button("Copy for Agent") {
      store.copy(
        Launcher.agentContext(w, displayName: store.name(w)),
        note: "Summary copied. Paste it into your agent.")
    }
    if !w.lead.command.isEmpty { Button("Copy Command") { store.copy(w.lead.command) } }
    if place { Button("Copy Directory") { store.copy(w.lead.cwd) } }
    if let url = w.url {
      Button("Copy URL") { store.copy(url.absoluteString) }
      Button("Copy curl") { store.copy("curl -i \(url.absoluteString)/") }
    }
    Button("Copy PID") { store.copy("\(w.root.pid)") }
    if !w.members.isEmpty {
      Button("Copy kill Command") {
        store.copy("kill \(w.members.map { "\($0.pid)" }.joined(separator: " "))")
      }
    }
  }
  private var place: Bool { !w.lead.cwd.isEmpty && w.lead.cwd != "/" && w.section != .system }
}

/// The expanded half of a row: what it is, where it listens, what it is made of, what to do.
struct Detail: View {
  @Bindable var store: Store
  var w: Workload
  @FocusState private var renameFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if store.renaming == w.id { rename }
      if !w.lead.command.isEmpty {
        Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(4)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
          .background(.fill.quaternary, in: .rect(cornerRadius: 7))
      }
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
        if !w.lead.cwd.isEmpty, w.lead.cwd != "/" {
          fact("Folder") {
            Button {
              NSWorkspace.shared.open(URL(fileURLWithPath: w.lead.cwd))
            } label: {
              Text(abbreviated(w.lead.cwd)).lineLimit(1).truncationMode(.head)
            }.buttonStyle(.link).help("Open \(w.lead.cwd) in Finder")
          }
        }
        fact("Started by") { Text(w.provenance) }
        ForEach(w.listeners, id: \.self) { l in
          fact(l.transport == .unix ? "Socket" : "Listens") {
            HStack(spacing: 5) {
              Text(l.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
              if l.transport != .unix {
                Text(l.wildcard ? "reachable from your network" : "this Mac only")
                  .foregroundStyle(l.wildcard ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
              }
            }
          }
        }
        if !w.members.isEmpty {
          fact("Uses") {
            HStack(spacing: 8) {
              Text("\(memoryText(w.memory)) · \(String(format: "%.0f%%", w.cpu)) CPU")
              Sparkline(samples: w.history.map(\.cpu)).frame(width: 60, height: 12)
                .accessibilityHidden(true)
            }
          }
        }
      }.font(.system(size: 11))
      ForEach(w.cautions + [w.blocked].compactMap { $0 }, id: \.self) { note in
        Label(note, systemImage: w.blocked == note ? "lock.fill" : "info.circle")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if w.members.count > 1 || !w.excluded.isEmpty { tree }
      if let message = store.messages[w.id] {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
      }
      actions
    }.padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
  }
  private func fact(_ name: String, @ViewBuilder _ value: () -> some View) -> some View {
    GridRow {
      Text(name).foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
      value().frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  /// The command as typed: the executable by name, not by the path it resolved to.
  private var command: String {
    let args = w.lead.args
    let name = args.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    return ([name] + args.dropFirst().map(shellQuote)).joined(separator: " ")
  }
  private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
  private var rename: some View {
    HStack {
      TextField("Display name", text: $store.renameText).textFieldStyle(.roundedBorder)
        .font(.system(size: 12)).focused($renameFocused).onSubmit { store.commitRename(w) }
        .accessibilityLabel("Display name")
      Button("Save") { store.commitRename(w) }.keyboardShortcut(.defaultAction)
      Button("Cancel") { store.renaming = nil }
    }.controlSize(.small).onAppear { renameFocused = true }
  }
  private var tree: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(w.members, id: \.identity) { p in
        HStack(spacing: 8) {
          Text(String(p.pid)).frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
          Text(Program(p).summary).lineLimit(1).truncationMode(.middle)
          if p.suspended { Text("suspended").foregroundStyle(.orange) }
          Spacer(minLength: 4)
          Text(memoryText(p.memory)).foregroundStyle(.tertiary)
          Menu {
            Button("Stop \(String(p.pid))") { store.act(p, in: w, .terminate) }
            Button("Force Quit \(String(p.pid))") { store.act(p, in: w, .kill) }
            Button("Copy Command") { store.copy(p.command) }
          } label: {
            Image(systemName: "ellipsis").frame(width: 16, height: 14).contentShape(.rect)
          }
          .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
          .foregroundStyle(.secondary).accessibilityLabel("Actions for process \(p.pid)")
          .disabled(w.blocked != nil)
        }.help(p.command)
      }
      ForEach(w.excluded, id: \.identity) { p in
        HStack(spacing: 8) {
          Text(String(p.pid)).frame(width: 44, alignment: .trailing)
          Text("\(p.base) · left running, \(Policy.protection(p) ?? "protected")").lineLimit(1)
        }.foregroundStyle(.tertiary)
      }
    }
    .font(.system(size: 11, design: .monospaced)).monospacedDigit().padding(.vertical, 6)
    .padding(.trailing, 8).background(.fill.quaternary, in: .rect(cornerRadius: 7))
  }
  private var actions: some View {
    HStack(spacing: 6) {
      if let url = w.url {
        Button("Open", systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
      }
      Menu {
        WorkloadMenu(store: store, w: w)
      } label: {
        Label("More", systemImage: "ellipsis")
      }.fixedSize()
      Spacer()
      if w.blocked == nil {
        let busy = store.acting.contains(w.id)
        if w.launchdLabel != nil {
          Button(w.brewService != nil ? "brew stop" : "Unload") { store.unload(w) }
            .help(w.cautions.first ?? "").disabled(busy)
        }
        if w.restartReason == nil { Button("Restart") { store.restart(w) }.disabled(busy) }
        Button("Force Quit") { store.act(w, .kill) }.disabled(busy).help("SIGKILL · ⌘⇧⌫")
        Button(w.section == .apps ? "Quit" : "Stop") { store.act(w, .terminate) }
          .buttonStyle(.borderedProminent).disabled(busy)
          .help("SIGTERM to \(w.members.count) process\(w.members.count == 1 ? "" : "es") · ⌘⌫")
      }
    }.controlSize(.small).labelStyle(.titleAndIcon)
  }
}
