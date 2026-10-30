// Local probe, not part of any PR: searches in 12 calendars and time zones with DST at midnight. Each result is written as soon as it is found.
import Testing
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if FOUNDATION_FRAMEWORK
@testable import Foundation
#else
@testable import FoundationInternationalization
@testable import FoundationEssentials
#endif

private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
}

private let identifiers: [Calendar.Identifier] = [.gregorian, .iso8601, .hebrew, .chinese, .islamicCivil, .islamicUmmAlQura, .persian, .japanese, .buddhist, .coptic, .ethiopicAmeteMihret, .indian]
private let zones = ["GMT", "America/Sao_Paulo", "America/Havana", "Asia/Beirut", "Asia/Tehran", "America/Santiago", "Europe/Paris", "Pacific/Apia", "Asia/Kolkata"]
private let templates: [[Calendar.Component]] = [[.month], [.day], [.month, .day], [.weekday], [.month, .weekday], [.weekdayOrdinal, .weekday], [.month, .weekdayOrdinal, .weekday], [.weekOfMonth, .weekday], [.month, .weekOfMonth], [.day, .hour], [.hour, .minute], [.month, .day, .hour]]

@Test func cal12Probe() throws {
    guard let path = ProcessInfo.processInfo.environment["CAL12_OUT"] else { return }
    let n = Int(ProcessInfo.processInfo.environment["CAL12_CASES"] ?? "") ?? 5000
    var rng = Rng(state: 20261029)
    struct Case: Sendable { let id: Calendar.Identifier; let zone: String; let start: Date; let fields: [Calendar.Component]; let wanted: [Calendar.Component: Int] }
    var all: [Case] = []
    for _ in 0..<n {
        let fields = templates[rng.int(0...templates.count - 1)]
        var wanted: [Calendar.Component: Int] = [:]
        for f in fields {
            switch f {
            case .month: wanted[f] = rng.int(1...12)
            case .day: wanted[f] = rng.int(1...30)
            case .weekday: wanted[f] = rng.int(1...7)
            case .weekdayOrdinal: wanted[f] = rng.int(1...4)
            case .weekOfMonth: wanted[f] = rng.int(1...4)
            case .hour: wanted[f] = rng.int(0...23)
            case .minute: wanted[f] = rng.int(0...59)
            default: break
            }
        }
        all.append(Case(id: identifiers[rng.int(0...identifiers.count - 1)], zone: zones[rng.int(0...zones.count - 1)], start: Date(timeIntervalSince1970: Double(rng.int(946_684_800...1_924_991_999))), fields: fields, wanted: wanted))
    }
    let out = fopen(path, "w")!, started = fopen(path + ".started", "w")!
    let lock = DispatchQueue(label: "probe")
    DispatchQueue.concurrentPerform(iterations: all.count) { i in
        let c = all[i]
        var cal = Calendar(identifier: c.id)
        cal.timeZone = TimeZone(identifier: c.zone)!
        var dc = DateComponents()
        for (f, v) in c.wanted { dc.setValue(v, for: f) }
        let desc = "\(c.id):" + c.fields.map { "\($0)=\(c.wanted[$0]!)" }.joined(separator: ",")
        for dir in [Calendar.SearchDirection.backward, .forward] {
            for (pn, p) in [("strict", Calendar.MatchingPolicy.strict), ("nextTime", .nextTime)] {
                let tag = "\(i)\t\(c.zone)\t\(Int(c.start.timeIntervalSince1970))\t\(desc)\t\(dir == .backward ? "back" : "fwd")\t\(pn)"
                lock.sync { fputs(tag + "\n", started); fflush(started) }
                var res = "nil", m = "-"
                if let r = cal.nextDate(after: c.start, matching: dc, matchingPolicy: p, direction: dir) {
                    res = String(Int(r.timeIntervalSince1970))
                    let actual = cal.dateComponents(Set(c.fields), from: r)
                    m = c.fields.allSatisfy { actual.value(for: $0) == c.wanted[$0] } ? "1" : "0"
                }
                lock.sync { fputs("\(tag)\t\(res)\t\(m)\n", out); fflush(out) }
            }
        }
    }
    fclose(out); fclose(started)
}
