import Foundation

/// What a process is actually running, with interpreters, package runners and rewritten process
/// titles looked through. Everything that classifies a process matches on these whole names, never
/// on substrings of the command line, so a project that happens to live in `~/invite-app` is not
/// mistaken for Vite.
public struct Program: Sendable, Equatable {
  /// Lowercased identity: a module, a package, a script's stem or the executable's name.
  public var target: String
  /// Language runtime hosting the target, when there is one.
  public var runtime: String?
  /// Positional arguments after the target, lowercased.
  public var words: [String] = []
  /// Short description for a row: `worker.py`, `-m http.server`, `next dev`.
  public var summary: String
  /// The script file it runs, when it runs one.
  public var script: String?
  /// The target names a program (an executable, module or package) rather than a loose script file.
  public var named = true
  /// An interpreter or shell with nothing to run: a prompt waiting for input.
  public var repl = false
  /// Exists only to start something else: `npm run`, `uv run`, `zsh -c`, `env`.
  public var wrapper = false

  static let runtimes: [(prefix: String, name: String)] = [
    ("python", "Python"), ("node", "Node.js"), ("bun", "Bun"), ("deno", "Deno"), ("ruby", "Ruby"),
    ("php", "PHP"), ("java", "Java"), ("perl", "Perl"), ("dotnet", ".NET"), ("elixir", "Elixir"),
    ("beam.smp", "Erlang"), ("rscript", "R"), ("lua", "Lua"),
  ]
  static let runners: Set<String> = [
    "npm", "pnpm", "yarn", "npx", "pnpx", "bunx", "uv", "uvx", "pipx", "poetry", "pipenv", "pdm",
    "hatch", "rye", "cargo", "go", "make", "just", "task", "mise", "doppler", "dotenvx", "env",
    "nice", "nohup", "time", "caffeinate", "stdbuf", "setsid",
  ]
  /// Subcommands of a runner that say "run the next word" and carry no meaning of their own.
  static let runnerNoise: Set<String> = ["run", "exec", "x", "dlx", "tool", "run-script", "--"]
  /// Node packages that only launch another script.
  static let launchers: Set<String> = [
    "tsx", "ts-node", "nodemon", "concurrently", "cross-env", "dotenv-cli", "npm", "pnpm", "yarn",
    "npx", "turbo",
  ]
  static let valueFlags: [String: Set<String>] = [
    "python": ["-W", "-X", "--check-hash-based-pycs"],
    "node": [
      "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
    ],
    "java": ["-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens"],
  ]

  /// Parsed once per process, when its record is created; see `Proc.program`.
  init(base: String, comm: String, args: [String]) {
    var args = args
    var exe = base
    // Node's process.title and setproctitle collapse the command line into argv[0].
    if let first = args.first, first.contains(" "),
      !first.hasPrefix("/") || (args.count == 1 && !FileManager.default.fileExists(atPath: first))
    {
      args =
        first.split(separator: " ").map(String.init) + args.dropFirst().filter { !$0.isEmpty }
      exe = Self.name(args.first ?? exe).lowercased()
      if exe.hasSuffix(":") { exe.removeLast() }
    }
    let rest = Array(args.dropFirst())
    let positional = rest.filter { !$0.hasPrefix("-") }
    target = exe
    summary = comm

    if Policy.shells.contains(exe) {
      if let flag = rest.firstIndex(where: {
        $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")
      }), flag + 1 < rest.count {
        wrapper = true
        summary = Self.shellSummary(rest[flag + 1])
      } else if let script = positional.first {
        adopt(script: script, after: positional.dropFirst())
      } else {
        repl = true
      }
    } else if let hosted = Self.runtimes.first(where: { exe.hasPrefix($0.prefix) }) {
      runtime = hosted.name
      parseRuntime(family: hosted.prefix, exe: exe, rest: rest)
    } else if Self.runners.contains(exe) {
      wrapper = true
      words = positional.drop { Self.runnerNoise.contains($0) }.map { $0.lowercased() }
      summary = ([exe] + rest.prefix(3)).joined(separator: " ")
    } else {
      words = positional.prefix(4).map { $0.lowercased() }
      summary = ([args.first.map(Self.name) ?? comm] + rest.prefix(3)).joined(separator: " ")
    }
    if summary.count > 60 { summary = String(summary.prefix(59)) + "…" }
  }

  private mutating func parseRuntime(family: String, exe: String, rest: [String]) {
    let skip = Self.valueFlags[family] ?? []
    var index = 0
    while index < rest.count {
      let a = rest[index]
      index += 1
      if family == "python", a == "-m", index < rest.count {
        target = rest[index].lowercased()
        summary = "-m \(rest[index])"
        words = rest[(index + 1)...].filter { !$0.hasPrefix("-") }.prefix(4).map { $0.lowercased() }
        return
      }
      if family == "java", a == "-jar", index < rest.count {
        adopt(script: rest[index], after: rest[(index + 1)...].filter { !$0.hasPrefix("-") })
        return
      }
      if ["-c", "-e", "--eval", "-p", "--print"].contains(a), family != "java" {
        summary = "\(exe) \(a)"
        return
      }
      if skip.contains(a) {
        index += 1
        continue
      }
      if a.hasPrefix("-") { continue }
      let after = rest[index...].filter { !$0.hasPrefix("-") }
      if ["bun", "deno"].contains(family), ["run", "x", "task"].contains(a) { continue }
      if family == "java" {
        target = a.lowercased()
        summary = a.split(separator: ".").last.map(String.init) ?? a
        words = after.prefix(4).map { $0.lowercased() }
        return
      }
      if ["bun", "deno"].contains(family), !a.contains("/"), !a.contains(".") {
        // `bun dev`: a package script, not a file.
        wrapper = true
        words = [a.lowercased()] + after.prefix(3).map { $0.lowercased() }
        summary = "\(exe) \(a)"
        return
      }
      adopt(script: a, after: after)
      return
    }
    repl = true
  }

  /// Targets a script file, or the package it belongs to when it sits inside node_modules.
  private mutating func adopt(script path: String, after: some Sequence<String>) {
    let following = Array(after.prefix(4))
    words = following.map { $0.lowercased() }
    script = path
    if let range = path.range(of: "/node_modules/", options: .backwards) {
      let inside = path[range.upperBound...].split(separator: "/").map(String.init)
      var package = inside.first ?? ""
      if package == ".bin", inside.count > 1 {
        package = inside[1]
      } else if package.hasPrefix("@"), inside.count > 1 {
        package += "/" + inside[1]
      }
      target = package.lowercased()
      wrapper = Self.launchers.contains(target)
      summary = ([package] + following.prefix(2)).joined(separator: " ")
      return
    }
    let file = Self.name(path)
    let stem =
      file.split(separator: ".").count > 1 ? String(file[..<file.lastIndex(of: ".")!]) : file
    target = stem.lowercased()
    named = stem == file
    wrapper = Self.launchers.contains(target)
    summary = wrapper ? ([file] + following.prefix(2)).joined(separator: " ") : file
  }

  static func name(_ path: String) -> String {
    let last = path.split(separator: "/").last.map(String.init) ?? path
    return last.hasPrefix("-") ? String(last.dropFirst()) : last
  }

  /// The command a `sh -c` runs, with the environment preamble agents put in front of it removed.
  package static func shellSummary(_ command: String) -> String {
    var text = command.replacingOccurrences(of: "'\"'\"'", with: "'")
    if let eval = text.range(of: "eval '") ?? text.range(of: "eval \"") {
      text = String(text[eval.upperBound...])
      for tail in ["' \\< /dev/null", "' < /dev/null", "\" < /dev/null"] {
        if let end = text.range(of: tail) { text = String(text[..<end.lowerBound]) }
      }
    }
    return text.split(whereSeparator: \.isNewline).first.map {
      $0.trimmingCharacters(in: .whitespaces)
    } ?? text
  }

  /// Names to look this program up by: its target, the words a wrapper passes on, and for scoped
  /// or versioned packages the bare name (`@playwright/mcp@1.2` gives `@playwright/mcp` and `mcp`).
  var names: [String] {
    var result: [String] = []
    for raw in [target] + (wrapper ? Array(words.prefix(2)) : []) {
      var name = raw
      if let at = name.lastIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
      result.append(name)
      if let slash = name.lastIndex(of: "/") {
        result.append(String(name[name.index(after: slash)...]))
      }
    }
    return result
  }
}
