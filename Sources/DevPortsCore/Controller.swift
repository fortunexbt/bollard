import Foundation

public enum Signal: String, Sendable, CaseIterable {
  case terminate = "Stop"
  case interrupt = "Interrupt"
  case kill = "Force Quit"
  var number: Int32 {
    switch self {
    case .terminate: return SIGTERM
    case .interrupt: return SIGINT
    case .kill: return SIGKILL
    }
  }
  /// How long to wait for the tree to exit before reporting what remains.
  public var grace: TimeInterval { self == .kill ? 1.5 : 4 }
}

public struct Outcome: Sendable {
  public var signalled: [Proc]
  public var remaining: [Proc]
  public var done: Bool { remaining.isEmpty }
}

public enum Controller {
  /// Signals every live process in the workload's kill set, then waits for them to exit.
  public static func stop(_ w: Workload, _ signal: Signal = .terminate) throws -> Outcome {
    let live = try Native.snapshot()
    let targets = try Policy.validate(w, live: live)
    if w.usesMinecraftController, signal != .kill {
      // The audited controller sends Minecraft's console stop, waits for the world save,
      // creates a backup, and cleans up its own helpers.
      guard let root = live[w.root.pid], LocalControllers.isMinecraftController(root) else {
        throw SafetyError("Controller changed since discovery.")
      }
      try Native.signal(root, SIGTERM)
      let remaining = wait(for: targets, upTo: 60)
      return Outcome(signalled: [root], remaining: remaining)
    }
    return try deliver(signal, to: targets)
  }
  /// Signals one process inside a workload, leaving the rest of the tree alone.
  public static func stop(_ p: Proc, in w: Workload, _ signal: Signal) throws -> Outcome {
    let live = try Native.snapshot()
    let targets = try Policy.validate(w, live: live)
    guard let target = targets.first(where: { $0.identity == p.identity }) else {
      throw SafetyError("Process \(p.pid) already exited.")
    }
    return try deliver(signal, to: [target])
  }
  public static func stopAll(_ workloads: [Workload], _ signal: Signal = .terminate) -> [Identity:
    Result<Outcome, SafetyError>]
  {
    var results: [Identity: Result<Outcome, SafetyError>] = [:]
    var pending: [Identity: [Proc]] = [:]
    for w in workloads where w.blocked == nil {
      do {
        let live = try Native.snapshot()
        let targets = try Policy.validate(w, live: live)
        results[w.id] = .success(Outcome(signalled: try send(signal, to: targets), remaining: []))
        pending[w.id] = targets
      } catch let error as SafetyError {
        results[w.id] = .failure(error)
      } catch {
        results[w.id] = .failure(SafetyError(error.localizedDescription))
      }
    }
    let remaining = wait(for: pending.values.flatMap { $0 }, upTo: signal.grace)
    for (id, targets) in pending {
      let left = remaining.filter { r in targets.contains { $0.identity == r.identity } }
      if case .success(var outcome) = results[id] {
        outcome.remaining = left
        results[id] = .success(outcome)
      }
    }
    return results
  }
  private static func deliver(_ signal: Signal, to targets: [Proc]) throws -> Outcome {
    let signalled = try send(signal, to: targets)
    return Outcome(signalled: signalled, remaining: wait(for: signalled, upTo: signal.grace))
  }
  /// Root first so supervisors learn about the shutdown before their children vanish.
  private static func send(_ signal: Signal, to targets: [Proc]) throws -> [Proc] {
    var signalled: [Proc] = []
    var failure: SafetyError?
    for p in targets {
      do {
        if p.suspended { try Native.signal(p, SIGCONT) }
        try Native.signal(p, signal.number)
        signalled.append(p)
      } catch let error as SafetyError {
        if !error.message.contains("already exited") { failure = failure ?? error }
      }
    }
    if let failure, signalled.isEmpty { throw failure }
    return signalled
  }
  /// Polls the process table until every process is gone or reaped, or the deadline passes.
  public static func wait(for procs: [Proc], upTo seconds: TimeInterval) -> [Proc] {
    let deadline = Date().addingTimeInterval(seconds)
    var remaining = procs
    while !remaining.isEmpty {
      let table = Dictionary(
        (try? Native.table())?.map { ($0.pid, $0) } ?? [], uniquingKeysWith: { a, _ in a })
      remaining = remaining.filter { p in
        guard let e = table[p.pid], e.start == p.identity.start else { return false }
        return e.status != 5
      }
      if remaining.isEmpty || Date() >= deadline { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return remaining
  }
  /// Removes a user launch agent from launchd so it stays stopped.
  public static func unloadLaunchAgent(_ label: String) throws {
    _ = try Native.output("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 10)
  }
  public static func brewStop(_ service: String) throws {
    let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    guard let brew else { throw SafetyError("Homebrew is not installed.") }
    _ = try Native.output(brew, ["services", "stop", service], timeout: 30)
  }
}
