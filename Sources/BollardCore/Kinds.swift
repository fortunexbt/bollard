import Foundation

/// Names a workload from its program. A label only: an unrecognised program is still shown, under
/// its runtime or its own name.
package enum Kinds {
  private static func entries(
    _ names: [String], _ name: String, _ icon: String, web: Bool = false
  ) -> [(String, Kind)] {
    names.map { ($0, Kind(name: name, icon: icon, web: web)) }
  }
  static let table: [String: Kind] = Dictionary(
    [
      entries(["next", "next-server"], "Next.js", "globe", web: true),
      entries(["nuxt", "nuxi"], "Nuxt", "globe", web: true),
      entries(["remix", "remix-serve", "react-router"], "React Router", "globe", web: true),
      entries(["astro"], "Astro", "globe", web: true),
      entries(["svelte-kit", "@sveltejs/kit"], "SvelteKit", "globe", web: true),
      entries(["vite"], "Vite", "bolt", web: true),
      entries(
        ["webpack", "webpack-dev-server", "webpack-cli"], "Webpack", "shippingbox", web: true),
      entries(["parcel"], "Parcel", "shippingbox", web: true),
      entries(["storybook", "start-storybook"], "Storybook", "book", web: true),
      entries(["wrangler", "workerd", "miniflare"], "Wrangler", "cloud", web: true),
      entries(["vitest", "jest", "pytest", "playwright"], "Tests", "checkmark.circle"),
      entries(["tsc", "esbuild", "rollup", "swc", "turbo", "nx"], "Build", "hammer"),
      entries(["uvicorn"], "Uvicorn", "network", web: true),
      entries(["gunicorn"], "Gunicorn", "network", web: true),
      entries(["hypercorn"], "Hypercorn", "network", web: true),
      entries(["granian"], "Granian", "network", web: true),
      entries(["daphne"], "Daphne", "network", web: true),
      entries(["http.server"], "Python HTTP", "globe", web: true),
      entries(["flask"], "Flask", "network", web: true),
      entries(["fastapi"], "FastAPI", "network", web: true),
      entries(["django-admin"], "Django", "network", web: true),
      entries(["streamlit"], "Streamlit", "chart.bar", web: true),
      entries(["gradio"], "Gradio", "chart.bar", web: true),
      entries(
        ["jupyter", "jupyter-lab", "jupyter-notebook", "jupyterlab", "jupyter_server", "notebook"],
        "Jupyter", "book.closed", web: true),
      entries(["ipykernel_launcher", "ipykernel"], "Jupyter kernel", "book.closed"),
      entries(["rails", "puma", "unicorn"], "Rails", "network", web: true),
      entries(["artisan"], "Laravel", "network", web: true),
      entries(["ollama"], "Ollama", "sparkles"),
      entries(
        ["llama-server", "mlx_lm.server", "vllm", "lms", "text-generation-launcher"], "AI service",
        "sparkles", web: true),
      entries(["postgres"], "PostgreSQL", "cylinder.split.1x2"),
      entries(["redis-server", "valkey-server"], "Redis", "cylinder.split.1x2"),
      entries(["mysqld"], "MySQL", "cylinder.split.1x2"),
      entries(["mariadbd"], "MariaDB", "cylinder.split.1x2"),
      entries(["mongod"], "MongoDB", "cylinder.split.1x2"),
      entries(["clickhouse", "clickhouse-server"], "ClickHouse", "cylinder.split.1x2"),
      entries(["meilisearch"], "Meilisearch", "cylinder.split.1x2"),
      entries(["typesense", "typesense-server"], "Typesense", "cylinder.split.1x2"),
      entries(["memcached"], "Memcached", "cylinder.split.1x2"),
      entries(["etcd"], "etcd", "cylinder.split.1x2"),
      entries(["minio"], "MinIO", "cylinder.split.1x2", web: true),
      entries(["nats-server"], "NATS", "arrow.left.arrow.right"),
      entries(["nginx"], "Nginx", "globe", web: true),
      entries(["caddy"], "Caddy", "globe", web: true),
      entries(["httpd"], "Apache", "globe", web: true),
      entries(["traefik"], "Traefik", "globe", web: true),
      entries(["haproxy"], "HAProxy", "globe", web: true),
      entries(
        ["cloudflared", "ngrok", "tailscale", "bore", "frpc"], "Tunnel", "arrow.left.arrow.right"),
      entries(
        ["docker", "dockerd", "colima", "limactl", "podman", "containerd"], "Containers",
        "shippingbox"),
      entries(
        ["celery", "rq", "dramatiq", "huey", "sidekiq", "temporal"], "Worker", "gearshape.2"),
      entries(
        ["nodemon", "watchexec", "watchfiles", "chokidar", "fswatch", "entr", "watchman", "air"],
        "Watcher", "eye"),
      entries(
        ["pm2", "supervisord", "overmind", "foreman", "honcho", "process-compose"],
        "Process manager", "square.stack.3d.up"),
      entries(["runner.listener", "runner.worker"], "GitHub runner", "play.circle"),
      entries(
        ["chromedriver", "safaridriver", "geckodriver"], "Browser driver", "macwindow"),
      entries(["caffeinate"], "Keep awake", "cup.and.saucer"),
      entries(["tail"], "Log tail", "text.alignleft"),
    ].flatMap { $0 }, uniquingKeysWith: { first, _ in first })

  /// True when a dash- or slash-separated part of the name is `mcp` or carries it as an affix.
  static func mentionsMCP(_ name: String) -> Bool {
    name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains {
      $0 == "mcp" || $0.hasSuffix("mcp") || $0.hasPrefix("mcp")
    }
  }
  /// `ssh` that forwards ports or runs no remote command: a tunnel, not a terminal session.
  static func tunnel(_ p: Proc) -> Bool {
    p.base == "ssh"
      && p.args.dropFirst().contains {
        $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(where: { "NLRDfW".contains($0) })
      }
  }

  /// The kind of a recognised program, or nil.
  package static func known(_ program: Program, _ p: Proc) -> Kind? {
    let words = Set(program.words)
    if program.target == "manage", words.contains("runserver") {
      return Kind(name: "Django", icon: "network", web: true)
    }
    if program.runtime == "PHP", p.args.contains("-S") {
      return Kind(name: "PHP", icon: "network", web: true)
    }
    if program.runtime == "Java", words.contains("nogui") {
      return Kind(name: "Minecraft", icon: "cube")
    }
    if tunnel(p) { return Kind(name: "SSH tunnel", icon: "arrow.left.arrow.right") }
    let names = program.names
    for name in names { if let known = table[name] { return known } }
    if names.contains(where: mentionsMCP)
      || p.args.dropFirst().contains(where: { $0 == "--mcp" || $0 == "mcp" })
    {
      return Kind(name: "MCP server", icon: "puzzlepiece.extension")
    }
    if p.args.contains(where: { $0 == "--watch" || $0.hasPrefix("--watch=") }) {
      return Kind(name: "Watcher", icon: "eye")
    }
    return nil
  }
  /// The label for a program nothing above recognises: its runtime, or its own name.
  package static func fallback(_ program: Program, _ p: Proc) -> Kind {
    if let runtime = program.runtime {
      return Kind(name: runtime, icon: "chevron.left.forwardslash.chevron.right")
    }
    if Policy.shells.contains(program.target) {
      return Kind(name: "Shell script", icon: "terminal")
    }
    return Kind(name: p.comm, icon: "terminal")
  }
}
