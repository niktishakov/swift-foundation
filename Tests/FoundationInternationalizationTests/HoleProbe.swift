// Local probe, not part of any PR: enumeration with every pair and triple of components, so that
// two versions can be compared. Writes to $HOLE_PROBE_OUT.
import Testing
#if FOUNDATION_FRAMEWORK
@testable import Foundation
#else
@testable import FoundationInternationalization
@testable import FoundationEssentials
#endif

@Test func holeProbe() throws {
    guard let path = ProcessInfo.processInfo.environment["HOLE_PROBE_OUT"] else { return }
    let values: [(Calendar.Component, Int)] = [(.quarter, 4), (.month, 11), (.weekOfYear, 46), (.weekOfMonth, 2), (.day, 12), (.weekdayOrdinal, 2), (.weekday, 5), (.hour, 9), (.minute, 45), (.second, 30)]
    var sets: [[Int]] = []
    for i in 0..<values.count { for j in (i + 1)..<values.count {
        sets.append([i, j])
        for k in (j + 1)..<values.count { sets.append([i, j, k]) }
    } }
    // 2026-10-29 09:30 Thu, 2026-11-12 11:15 Thu, 2026-12-20 18:00 Sun
    let starts = [1793266200.0, 1794482100, 1797789600].map { Date(timeIntervalSince1970: $0) }
    var lines: [String] = []
    for zone in ["GMT", "America/Los_Angeles"] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        for set in sets {
            var c = DateComponents()
            for i in set { c.setValue(values[i].1, for: values[i].0) }
            let name = set.map { "\(values[$0].0)" }.joined(separator: "+")
            for start in starts {
                for direction in [Calendar.SearchDirection.forward, .backward] {
                    var out: [String] = []
                    cal.enumerateDates(startingAfter: start, matching: c, matchingPolicy: .nextTime, direction: direction) { d, _, stop in
                        out.append(d.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"); if out.count == 4 || d == nil { stop = true }
                    }
                    lines.append("\(zone)\t\(name)\t\(Int(start.timeIntervalSince1970))\t\(direction == .forward ? "fwd" : "back")\t\(out.joined(separator: ","))")
                }
            }
        }
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}
