import AppKit
import BollardCore
import SwiftUI

/// Everything a right-click offers. Also reused by the detail buttons.
struct WorkloadMenu: View {
  @ObservedObject var store: Store
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
    ForEach(w.ports, id: \.self) { port in
      Button("Open localhost:\(String(port))") { store.open(port: port) }
    }
    if !w.root.cwd.isEmpty {
      Menu("Open project in") {
        Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.root.cwd)) }
        ForEach(Launcher.editors, id: \.self) { name in
          Button(name) { Launcher.openIn(name, w.root.cwd) }
        }
        Divider()
        ForEach(Launcher.agents, id: \.path) { agent in
          Button("\(agent.name) here") { store.agentHere(agent.path, w) }
        }
      }
    }
    Divider()
    Button(store.pinned(w) ? "Unpin" : "Pin to top") { store.togglePin(w) }
    Button("Rename…") { store.beginRename(w) }
    Divider()
    Button("Copy for agent") {
      store.copy(
        Launcher.agentContext(w, displayName: store.name(w)),
        note: "Summary copied. Paste it into your agent.")
    }
    if !w.root.command.isEmpty { Button("Copy command") { store.copy(w.root.command) } }
    if !w.root.cwd.isEmpty { Button("Copy directory") { store.copy(w.root.cwd) } }
    if !w.ports.isEmpty {
      Button("Copy URL") { store.copy("http://localhost:\(w.ports[0])") }
      Button("Copy curl") { store.copy("curl -i http://localhost:\(w.ports[0])/") }
    }
    Button("Copy PID") { store.copy("\(w.root.pid)") }
    if !w.members.isEmpty {
      Button("Copy kill command") {
        store.copy("kill \(w.members.map { "\($0.pid)" }.joined(separator: " "))")
      }
    }
  }
}

struct Detail: View {
  @ObservedObject var store: Store
  var w: Workload
  @FocusState private var renameFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      if store.renaming == w.id {
        HStack {
          TextField("Display name", text: $store.renameText).textFieldStyle(.roundedBorder).font(
            .system(size: 11)
          )
          .focused($renameFocused).onSubmit { store.commitRename(w) }.accessibilityLabel(
            "Display name")
          Button("Save") { store.commitRename(w) }.controlSize(.small).keyboardShortcut(
            .defaultAction)
          Button("Cancel") { store.renaming = nil }.controlSize(.small)
        }.onAppear { renameFocused = true }
      }
      HStack {
        Label(
          w.provenance, systemImage: w.orphan ? "exclamationmark.circle" : "arrow.turn.down.right")
        Spacer()
        Text("PID \(w.root.pid) · \(w.members.count) process\(w.members.count == 1 ? "" : "es")")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      if !w.root.cwd.isEmpty {
        HStack(spacing: 6) {
          Text(w.root.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled).lineLimit(2)
          if let branch = w.branch {
            Label(branch, systemImage: "arrow.triangle.branch").font(.system(size: 10))
              .foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      if !w.root.command.isEmpty {
        ScrollView(.horizontal) {
          Text(w.root.command).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            .padding(9)
        }.background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
      }
      ForEach(w.listeners, id: \.self) { l in
        HStack(spacing: 6) {
          Image(systemName: l.wildcard ? "antenna.radiowaves.left.and.right" : "lock")
            .foregroundStyle(l.wildcard ? .orange : .secondary)
          Text("\(l.address):\(String(l.port))").font(.system(size: 10, design: .monospaced))
          Text(l.wildcard ? "reachable from your network" : "local only").foregroundStyle(
            .secondary)
          if l.pid != w.root.pid { Text("· PID \(l.pid)").foregroundStyle(.tertiary) }
        }.font(.system(size: 10))
      }
      ForEach(w.cautions, id: \.self) { caution in
        Label(caution, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(
          .secondary)
      }
      if let blocked = w.blocked {
        Label(blocked, systemImage: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if !w.members.isEmpty { tree }
      buttons
      if let message = store.messages[w.id] {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
      }
    }.padding(.horizontal, 11).padding(.bottom, 9)
  }
  var tree: some View {
    DisclosureGroup("Process tree", isExpanded: $store.showTree) {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(w.members, id: \.identity) { p in
          HStack(spacing: 6) {
            Text("\(p.pid)").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
            Text(
              p.args.dropFirst().first.map { URL(fileURLWithPath: $0).lastPathComponent }.map {
                "\(p.base) \($0)"
              } ?? p.base
            ).lineLimit(1)
            if p.suspended { Text("suspended").foregroundStyle(.orange) }
            Spacer()
            Text(memoryText(p.memory)).foregroundStyle(.tertiary)
            Menu {
              Button("Stop \(p.pid)") { store.act(p, in: w, .terminate) }
              Button("Force Quit \(p.pid)") { store.act(p, in: w, .kill) }
              Button("Copy command") { store.copy(p.command) }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
            .accessibilityLabel("Actions for \(p.pid)")
          }.font(.system(size: 10, design: .monospaced)).help(p.command)
        }
        ForEach(w.excluded, id: \.identity) { p in
          HStack(spacing: 6) {
            Text("\(p.pid)").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
            Text(p.base).lineLimit(1)
            Text("left running · \(Policy.protection(p) ?? "protected")").foregroundStyle(.tertiary)
            Spacer()
          }.font(.system(size: 10, design: .monospaced))
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }.font(.system(size: 10)).foregroundStyle(.secondary)
  }
  var buttons: some View {
    HStack(spacing: 8) {
      if !w.ports.isEmpty, w.kind.web {
        Menu("Open") {
          ForEach(w.ports, id: \.self) { port in
            Button(":\(String(port))") { store.open(port: port) }
          }
        }.frame(width: 65)
      }
      if !w.root.cwd.isEmpty {
        Menu("Project") {
          Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.root.cwd)) }
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root.cwd)])
          }
          Divider()
          ForEach(Launcher.editors, id: \.self) { name in
            Button("Open in \(name)") { Launcher.openIn(name, w.root.cwd) }
          }
          Divider()
          ForEach(Launcher.agents, id: \.path) { agent in
            Button("\(agent.name) here") { store.agentHere(agent.path, w) }
          }
          Divider()
          Button("Copy for agent") {
            store.copy(
              Launcher.agentContext(w, displayName: store.name(w)),
              note: "Summary copied. Paste it into your agent.")
          }
        }.frame(width: 80)
      }
      Spacer()
      if store.acting.contains(w.id) { ProgressView().controlSize(.small) }
      if w.blocked == nil {
        if w.launchdLabel != nil {
          Button(w.brewService != nil ? "brew stop" : "Unload") { store.unload(w) }.help(
            w.cautions.first ?? "")
        }
        if w.section != .apps {
          Button("Restart") { store.restart(w) }.disabled(
            w.restartReason != nil || store.acting.contains(w.id)
          )
          .help(w.restartReason ?? "Stop, then rerun the command in Terminal")
        }
        Button(w.section == .apps ? "Quit" : "Stop") { store.act(w, .terminate) }
          .disabled(store.acting.contains(w.id)).help(
            "SIGTERM to \(w.members.count) processes · ⌘⌫")
        if store.lingering.contains(w.id) {
          Button("Force Quit") { store.act(w, .kill) }.tint(.red).buttonStyle(.borderedProminent)
            .disabled(store.acting.contains(w.id)).help("SIGKILL · ⌘⇧⌫")
        } else {
          Button("Force Quit") { store.act(w, .kill) }.disabled(store.acting.contains(w.id)).help(
            "SIGKILL · ⌘⇧⌫")
        }
      }
    }.controlSize(.small)
  }
}
