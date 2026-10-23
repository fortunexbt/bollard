import Foundation

/// Caches launcher metadata, never action authority. Keys include the process generation.
package struct LaunchOwnershipCache {
  private var known = Set<Identity>()
  private var labels: [Identity: String] = [:]
  package init() {}
  package func current(in processes: [Int32: Proc]) -> [Int32: String] {
    Dictionary(
      uniqueKeysWithValues: labels.compactMap { id, label in
        processes[id.pid]?.identity == id ? (id.pid, label) : nil
      })
  }
  package mutating func update(
    roots: [Proc], processes: [Int32: Proc], lookup: () throws -> [Int32: String]
  ) rethrows -> [Int32: String] {
    let detached = Set(roots.filter { $0.parent == 1 }.map(\.identity))
    labels = labels.filter {
      detached.contains($0.key) && processes[$0.key.pid]?.identity == $0.key
    }
    known.formIntersection(detached)
    if !detached.isSubset(of: known) {
      let fetched = try lookup()
      labels = Dictionary(
        uniqueKeysWithValues: detached.compactMap { id in
          guard processes[id.pid]?.identity == id, let label = fetched[id.pid] else { return nil }
          return (id, label)
        })
      known = detached
    }
    return current(in: processes)
  }
}
