import AppKit
import DevPortsCore
import ServiceManagement

if CommandLine.arguments.contains("--login-status") {
  print(
    SMAppService.mainApp.status == .enabled
      ? "enabled" : "not enabled (status \(SMAppService.mainApp.status.rawValue))")
} else if CommandLine.arguments.contains("--list") {
  do {
    let scan = try Scanner().scan()
    for w in scan.workloads {
      print(
        "\(w.name)\t\(w.kind.name)\t\(w.ports.map{String($0)}.joined(separator:","))\t\(memoryText(w.memory))\tPID \(w.root.pid)\t\(w.provenance)\t\(w.refusal ?? "Stop available")"
      )
    }
    print("\(scan.count) processes inspected in \(Int(scan.duration*1000))ms")
  } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
  }
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
