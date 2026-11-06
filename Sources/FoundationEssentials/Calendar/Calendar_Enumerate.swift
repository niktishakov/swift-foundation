//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if FOUNDATION_FRAMEWORK
// For Logger
internal import os
#endif

extension Range where Bound: Comparable {
    func extended(to other: Range<Bound>) -> Range<Bound> {
        Swift.min(self.lowerBound, other.lowerBound)..<Swift.max(self.upperBound, other.upperBound)
    }
}

extension DateInterval {
    /// In contrast to interval.contains(...), this creates a half-open range that does not contain start+duration.
    internal var range: Range<Date> {
        return start..<end
    }
}

extension Calendar {
    // MARK: - Logging
#if FOUNDATION_FRAMEWORK
    static fileprivate let log = Logger(subsystem: "com.apple.foundation", category: "calendar_enumeration")
#endif // FOUNDATION_FRAMEWORK

    func validRange(for component: Component) -> ClosedRange<Int> {
        if component == .weekdayOrdinal {
            return 1...7
        } else if (component == .year || component == .yearForWeekOfYear) && (identifier == .hebrew || identifier == .indian || identifier == .persian) {
            // Check for Hebrew, Indian, and Persian calendar special cases
            // Min year value of 1 allowed
            let max = maximumRange(of: component) ?? 0..<Int.max
            let min = minimumRange(of: component) ?? 0..<Int.max
            return ClosedRange(min.extended(to: max)).clamped(to: 1...Int.max-1)
        } else if component == .yearForWeekOfYear {
            // Use year instead
            let max = maximumRange(of: .year) ?? 0..<Int.max
            let min = minimumRange(of: .year) ?? 0..<Int.max
            return ClosedRange(min.extended(to: max))
        } else {
            let max = maximumRange(of: component) ?? 0..<Int.max
            let min = minimumRange(of: component) ?? 0..<Int.max
            return ClosedRange(min.extended(to: max))
        }
    }

    func value(_ value: Int, isValidFor component: Component) -> Bool {
        let range = validRange(for: component)
        return range.contains(value)
    }
}

extension DateComponents {
    fileprivate func _validate(for calendar: Calendar) -> Bool {
        var hasAtLeastOneFieldSet = false
        
        if let v = self.era {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .era) else { return false }
        }
        
        if let v = self.year {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .year) else { return false }
        }
        
        if let v = self.dayOfYear {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .dayOfYear) else { return false }
        }

        if let v = self.quarter {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .quarter) else { return false }
        }

        if let v = self.month {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .month) else { return false }
        }

        if let v = self.day {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .day) else { return false }
        }

        if let v = self.hour {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .hour) else { return false }
        }

        if let v = self.minute {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .minute) else { return false }
        }

        if let v = self.second {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .second) else { return false }
        }

        if let v = self.weekday {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .weekday) else { return false }
        }

        if let v = self.weekdayOrdinal {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .weekdayOrdinal) else { return false }
        }

        if let v = self.weekOfMonth {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .weekOfMonth) else { return false }
        }

        if let v = self.weekOfYear {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .weekOfYear) else { return false }
        }

        if let v = self.yearForWeekOfYear {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .yearForWeekOfYear) else { return false }
        }

        if let v = self.nanosecond {
            hasAtLeastOneFieldSet = true
            guard calendar.value(v, isValidFor: .nanosecond) else { return false }
        }

        if !hasAtLeastOneFieldSet && !(isLeapMonth ?? false) && !(isRepeatedDay ?? false) {
            return false
        }

        return true
    }
}

private func _handleCalendarResultNotFound(date: Date, calendar: Calendar, comps: DateComponents, direction: Calendar.SearchDirection, matchingPolicy: Calendar.MatchingPolicy, repeatedTimePolicy: Calendar.RepeatedTimePolicy) {
#if FOUNDATION_FRAMEWORK
    Calendar.log.debug("Unable to find Calendar enumeration result: \(date.timeIntervalSinceReferenceDate, privacy: .public) \(calendar, privacy: .public) \(comps, privacy: .public) \(direction.debugDescription, privacy: .public) \(matchingPolicy.debugDescription, privacy: .public) \(repeatedTimePolicy.debugDescription)")
#endif
}

extension Calendar {
    /// A `Sequence` of `Date`s which match the specified search criteria.
    struct DatesByMatching : Sendable, Sequence {
        typealias Element = Date
        
        let calendar: Calendar
        let start: Date
        let range: Range<Date>?
        let matchingComponents: DateComponents
        let matchingPolicy: Calendar.MatchingPolicy
        let repeatedTimePolicy: Calendar.RepeatedTimePolicy
        let direction: Calendar.SearchDirection
        
        init(calendar: Calendar, start: Date, range: Range<Date>?, matchingComponents: DateComponents, matchingPolicy: Calendar.MatchingPolicy = .nextTime, repeatedTimePolicy: Calendar.RepeatedTimePolicy = .first, direction: Calendar.SearchDirection = .forward) {
            self.calendar = calendar
            self.matchingComponents = matchingComponents
            self.matchingPolicy = matchingPolicy
            self.repeatedTimePolicy = repeatedTimePolicy
            self.direction = direction
            self.start = start
            self.range = range
        }

        struct Iterator: Sendable, IteratorProtocol {
            var searchingDate: Date
            
            let range: Range<Date>?
            let start: Date
            let calendar: Calendar
            let matchingComponents: DateComponents
            let matchingPolicy: Calendar.MatchingPolicy
            let repeatedTimePolicy: Calendar.RepeatedTimePolicy
            let direction: Calendar.SearchDirection
            
            // Calculated at init, checked on `next`
            var finished: Bool
            
            // Fast-path: skip the search when the calendar can answer directly.
            let usesFastPath: Bool

            internal init(_ calendar: Calendar, start: Date, range: Range<Date>?, matching matchingComponents: DateComponents, matchingPolicy: Calendar.MatchingPolicy, repeatedTimePolicy: Calendar.RepeatedTimePolicy, direction: Calendar.SearchDirection) {
                self.calendar = calendar
                
                self.range = range
                self.matchingComponents = matchingComponents
                self.matchingPolicy = matchingPolicy
                self.repeatedTimePolicy = repeatedTimePolicy
                self.direction = direction
                self.start = start
                
                // Start searching here
                searchingDate = start
                
                // If this fails we'll short circuit the next `next`
                let validates = matchingComponents._validate(for: calendar)
                finished = !validates

                self.usesFastPath = validates && matchingPolicy == .nextTime && repeatedTimePolicy == .first && calendar._supportsNextDateFastPath(for: matchingComponents._populatedComponentSet)
            }
            
            mutating func next() -> Element? {
                guard !finished else { return nil }
                guard let match = nextMatch(), range?.contains(match) ?? true else {
                    finished = true
                    return nil
                }
                searchingDate = match
                return match
            }

            private func nextMatch() -> Date? {
                if usesFastPath {
                    return calendar._calendarNextDate(after: searchingDate, matching: matchingComponents, direction: direction)
                }
                guard let (match, _) = calendar._nearestMatch(after: searchingDate, direction: direction, matching: matchingComponents, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy, originalStart: start) else {
                    _handleCalendarResultNotFound(date: start, calendar: calendar, comps: matchingComponents, direction: direction, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy)
                    return nil
                }
                return match
            }
        }
        
        public func makeIterator() -> Iterator {
            return Iterator(calendar, start: start, range: range, matching: matchingComponents, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy, direction: direction)
        }
    }
    
    /// A `Sequence` of `Date`s, calculated by iterative addition of `DateComponents`.
    struct DatesByAdding : Sendable, Sequence {
        typealias Element = Date
        
        let calendar: Calendar
        let start: Date
        let range: Range<Date>?
        let components: DateComponents
        let wrappingComponents: Bool
        
        /// If `components` is `nil`, the result is an empty `Sequence`.
        internal init(calendar: Calendar, start: Date, range: Range<Date>?, components: DateComponents, wrappingComponents: Bool) {
            self.calendar = calendar
            self.start = start
            self.range = range
            self.components = components
            self.wrappingComponents = wrappingComponents
        }
        
        struct Iterator: Sendable, IteratorProtocol {
            let calendar: Calendar
            let start: Date
            let range: Range<Date>?
            let components: DateComponents
            let wrappingComponents: Bool
            var finished = false
            var iteration = 1
            
            /// If `components` is `nil`, the result is an empty `Sequence`.
            init(calendar: Calendar, start: Date, range: Range<Date>?, components: DateComponents, wrappingComponents: Bool) {
                self.start = start
                self.calendar = calendar
                self.components = components
                self.range = range
                self.wrappingComponents = wrappingComponents
            }
            
            mutating func next() -> Element? {
                guard !finished else {
                    return nil
                }
                
                let scaled = components.scaled(by: iteration)
                let next = calendar.date(byAdding: scaled, to: start, wrappingComponents: wrappingComponents)
                guard let next else {
                    // We have finished
                    finished = true
                    return nil
                }
                
                if let range, !range.contains(next) {
                    // We are out of the range
                    finished = true
                    return nil
                }
                
                iteration += 1
                return next
            }
        }
        
        func makeIterator() -> Iterator {
            return Iterator(calendar: calendar, start: start, range: range, components: components, wrappingComponents: wrappingComponents)
        }
    }
}

/// Constants of the nested date search in `_nearestMatch`.
private enum NestedSearch {
    /// The Gregorian calendar repeats every 400 years, weekdays included (146,097 days is a whole number of weeks), so a date that isn't in 400 years never comes.
    static let years = 400
    /// The longest year, so that the window is never shorter than `years`.
    static let daysPerYear = 366
    /// How far a search looks before it gives up.
    static let span = TimeInterval(years * daysPerYear * Calendar._secondsInDay)
    /// How many pieces a search looks at before it gives up, so that components that never match, such as February 30, end it even where jumps can't skip pieces. 400 years have about 4,800 months and 146,000 days.
    static let budget = 50_000
    /// A moment just before a date, to name the piece or the window that ends there.
    static let justBefore: TimeInterval = 0.001
    /// To add the wanted nanosecond to a date.
    static let nanosecondsPerSecond: TimeInterval = 1_000_000_000
    /// Days 1–7 of a month are the first of their weekday, 8–14 the second, and so on.
    static let daysPerWeek = 7
}

extension Calendar {
    /// The nearest date after `bound` in `direction` that matches `comps`.
    ///
    /// Each unit that is set is searched only inside the piece of the larger unit that matched, so a match can't leave a month, a week or a day that an earlier unit chose. When a value is in a gap, such as a day after the end of a short month or an hour skipped by a daylight saving time change, the matching policy picks a date next to the gap. `NestedDateSearch` tells the steps from top to bottom.
    internal func _nearestMatch(after bound: Date, direction: SearchDirection, matching comps: DateComponents,
                                matchingPolicy: MatchingPolicy, repeatedTimePolicy: RepeatedTimePolicy, originalStart: Date,
                                before limit: Date? = nil, firstInEachPiece: Bool = true) -> (Date, Bool)? {
        var search = NestedDateSearch(calendar: self, bound: bound, direction: direction, comps: comps,
                                      matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy,
                                      originalStart: originalStart, limit: limit, firstInEachPiece: firstInEachPiece)
        return search.run()
    }

    /// The first match at or after `date` and before `limit`, counting every match in a piece, not only the first.
    internal func _firstMatch(from date: Date, matching comps: DateComponents, matchingPolicy: MatchingPolicy,
                              repeatedTimePolicy: RepeatedTimePolicy, originalStart: Date, before limit: Date?) -> (Date, Bool)? {
        _nearestMatch(after: date - NestedSearch.justBefore, direction: .forward, matching: comps,
                      matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy, originalStart: originalStart,
                      before: limit, firstInEachPiece: false)
    }

    internal func _enumerateDates(startingAfter start: Date,
                                  matching matchingComponents: DateComponents,
                                  matchingPolicy: MatchingPolicy,
                                  repeatedTimePolicy: RepeatedTimePolicy,
                                  direction: SearchDirection,
                                  using block: (_ result: Date?, _ exactMatch: Bool, _ stop: inout Bool) -> Void) {
        guard matchingComponents._validate(for: self) else {
            return
        }
        
        guard start.isValidForEnumeration else {
            return
        }

        var bound = start
        while true {
            var stop = false
            guard let (match, exact) = _nearestMatch(after: bound, direction: direction, matching: matchingComponents, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy, originalStart: start) else {
                _handleCalendarResultNotFound(date: start, calendar: self, comps: matchingComponents, direction: direction, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy)
                block(nil, false, &stop)
                return
            }
            block(match, exact, &stop)
            if stop { return }
            bound = match
        }
    }
}

/// A unit that a search walks through, with the components it checks.
private struct SearchLevel {
    let unit: Calendar.Component
    let checks: [Calendar.Component]
}

/// One search for the nearest date that matches some components.
///
/// The search goes through levels, from the largest unit that is set to the smallest. Each level walks the pieces of its unit inside the piece that the level above chose: the months of a year, the days of a month, the hours of a day. A piece that matches is searched one level deeper. The steps are in the order they run:
/// 1. `run` builds the window and starts at the top level.
/// 2. `search` handles one level inside a window: it prepares the level, then walks its pieces.
/// 3. `walk` steps from piece to piece, jumping where it can, and finds gaps between neighboring pieces.
/// 4. The helpers at the end answer small questions: does a piece match, is a value skipped, which date stands in for a gap.
private struct NestedDateSearch {
    let calendar: Calendar
    let bound: Date
    let backward: Bool
    let comps: DateComponents
    let matchingPolicy: Calendar.MatchingPolicy
    let repeatedTimePolicy: Calendar.RepeatedTimePolicy
    let originalStart: Date
    let limit: Date?
    let levels: [SearchLevel]
    /// Only the first match inside each piece of the largest unit that is set counts, so November and 9 o'clock match November 1 at 9:00 once a year. In the smallest unit a match is the start of the piece anyway.
    let firstOnlyIndex: Int?
    /// The nanosecond is added to the start of the smallest unit that is found.
    let nanosecond: TimeInterval
    var budget = NestedSearch.budget

    init(calendar: Calendar, bound: Date, direction: Calendar.SearchDirection, comps: DateComponents,
         matchingPolicy: Calendar.MatchingPolicy, repeatedTimePolicy: Calendar.RepeatedTimePolicy,
         originalStart: Date, limit: Date?, firstInEachPiece: Bool) {
        self.calendar = calendar
        self.bound = bound
        self.backward = direction == .backward
        self.comps = comps
        self.matchingPolicy = matchingPolicy
        self.repeatedTimePolicy = repeatedTimePolicy
        self.originalStart = originalStart
        self.limit = limit
        let levels = Self.levels(for: comps)
        self.levels = levels
        if firstInEachPiece, let largest = levels.firstIndex(where: { !$0.checks.isEmpty }), largest < levels.count - 1 {
            firstOnlyIndex = largest
        } else {
            firstOnlyIndex = nil
        }
        nanosecond = TimeInterval(comps.nanosecond ?? 0) / NestedSearch.nanosecondsPerSecond
    }

    /// The units a search walks through, from the largest to the smallest, with the components each one checks.
    static func levels(for comps: DateComponents) -> [SearchLevel] {
        let all: [(Calendar.Component, [Calendar.Component])] = [
            (.year, [.era, .year]),
            (.yearForWeekOfYear, [.yearForWeekOfYear]),
            (.quarter, [.quarter]),
            (.month, [.month]),
            (.weekOfYear, [.weekOfYear, .weekOfMonth]),
            (.day, [.day, .weekday, .weekdayOrdinal, .dayOfYear]),
            (.hour, [.hour]),
            (.minute, [.minute]),
            (.second, [.second]),
        ]
        // A value counted inside a larger unit needs that unit's level too, even when nothing is set there: a day of the month, a weekday ordinal and a week of the month are counted in their month, a minute in its hour, a second in its minute. A leap month is told apart month by month.
        let countedIn: [Calendar.Component: Calendar.Component] = [
            .day: .month, .weekdayOrdinal: .month, .weekOfMonth: .month, .minute: .hour, .second: .minute,
        ]
        var parents = Set(countedIn.compactMap { comps.value(for: $0.key) != nil ? $0.value : nil })
        if comps.isLeapMonth != nil {
            parents.insert(.month)
        }
        return all.compactMap { unit, checks in
            let set = checks.filter { comps.value(for: $0) != nil }
            return set.isEmpty && !parents.contains(unit) ? nil : SearchLevel(unit: unit, checks: set)
        }
    }

    // MARK: - 1. The whole search

    mutating func run() -> (Date, Bool)? {
        guard !levels.isEmpty else { return nil }
        // The day of the month fixes the weekday ordinal: days 1–7 are the first of their weekday, 8–14 the second, and so on.
        if let day = comps.day, let ordinal = comps.weekdayOrdinal, day > 0, ordinal > 0,
           (day - 1) / NestedSearch.daysPerWeek + 1 != ordinal {
            return nil
        }
        // The whole window: `span` from the bound in the search direction, cut by the limit.
        let window: DateInterval
        if backward {
            window = DateInterval(start: bound - NestedSearch.span, end: bound)
        } else {
            window = DateInterval(start: bound, end: max(bound, min(bound + NestedSearch.span, limit ?? .distantFuture)))
        }
        return search(window, 0)
    }

    // MARK: - 2. One level inside a window

    mutating func search(_ window: DateInterval, _ index: Int) -> (Date, Bool)? {
        // Below the smallest level the window itself is the match.
        guard index < levels.count else {
            return matchAtBottom(of: window, index)
        }
        let unit = levels[index].unit

        // Every hour has the same minutes and every minute the same seconds, so the piece is found directly.
        if unit == .minute || unit == .second, let wanted = comps.value(for: unit), let length = fixedLength(unit),
           let parent = calendar.dateInterval(of: levels[index - 1].unit, for: window.start) {
            let start = parent.start + Double(wanted) * length
            // The search can start inside the wanted minute or second.
            guard window.start < start + length, start < window.end else { return nil }
            return search(DateInterval(start: max(start, window.start), end: min(start + length, window.end)), index + 1)
        }

        let level = prepare(index, in: window)
        // A window whose values are all before or all after the wanted one can't match, unless a matching policy fills the gap.
        if let counting = level.countingValue, level.gapComponent == nil || matchingPolicy == .strict,
           counting < calendar.component(unit, from: window.start)
            || counting > calendar.component(unit, from: window.end - NestedSearch.justBefore) {
            return nil
        }
        return walk(level)
    }

    /// The match when every level has matched: the start of the smallest piece, plus the nanosecond.
    func matchAtBottom(of window: DateInterval, _ index: Int) -> (Date, Bool)? {
        // A piece that the bound cuts starts at the bound, not at the start of its unit.
        var start = window.start
        if !backward, window.start == bound {
            start = calendar.dateInterval(of: levels[index - 1].unit, for: bound)?.start ?? bound
        }
        let match = start + nanosecond
        return match < window.end && isBeyondBound(match) ? (match, true) : nil
    }

    /// What a level needs to know before it walks: which value can be in a gap, where it can jump, and the pieces just outside the window.
    struct Level {
        let index: Int
        let unit: Calendar.Component
        let checks: [Calendar.Component]
        let window: DateInterval
        /// The component whose value time can skip over: the single value of a time unit, a day number or a leap month.
        let gapComponent: Calendar.Component?
        /// The wanted value of `gapComponent`, with a leap month ordered right after the month it repeats.
        let wanted: Int?
        /// A day or week number in a window where it only grows.
        let countingValue: Int?
        /// The value the search can jump to.
        let jumpTarget: Int?
        /// The pieces just outside the window, so that a gap at its edge is found too.
        let edgeBefore: Neighbor?
        let edgeAfter: Neighbor?
    }

    typealias Neighbor = (piece: DateInterval, value: Int)

    func prepare(_ index: Int, in window: DateInterval) -> Level {
        let unit = levels[index].unit
        let checks = levels[index].checks

        // A value that time skips over makes sense only for the single value of a time unit, a day number or a leap month. A month number that a year doesn't have is searched for in other years.
        let gapComponent: Calendar.Component?
        if checks.count == 1, [.day, .hour, .minute, .second].contains(checks[0]) {
            gapComponent = checks[0]
        } else if checks == [.month], comps.isLeapMonth == true {
            gapComponent = .month
        } else {
            gapComponent = nil
        }
        let wanted: Int?
        if gapComponent == .month {
            wanted = comps.month.map { monthKey($0, isLeap: comps.isLeapMonth) }
        } else {
            wanted = gapComponent.flatMap { comps.value(for: $0) }
        }

        // Day numbers only grow inside one month, and week numbers inside one week-numbering year. When the window stays inside one of these, the search can jump straight to the wanted value, and once a piece is past it the rest of the window can't match.
        var countingValue: Int?
        if let value = comps.value(for: unit), let counter: Calendar.Component = unit == .day ? .month : unit == .weekOfYear ? .yearForWeekOfYear : nil,
           calendar.component(counter, from: window.start) == calendar.component(counter, from: window.end - NestedSearch.justBefore) {
            countingValue = value
        }
        // Months, hours, minutes and seconds wrap around, so the search can jump to them too.
        let jumpTarget = countingValue ?? (periods(unit) != nil && comps.isLeapMonth == nil ? comps.value(for: unit) : nil)

        // An hour skipped at midnight lies between the last hour of the day before and the first hour of the day.
        var edgeBefore: Neighbor?
        if gapComponent == .hour, calendar.dateInterval(of: .day, for: window.start)?.start == window.start {
            edgeBefore = neighbor(of: unit, at: window.start - NestedSearch.justBefore, gapComponent: gapComponent)
        }
        // A day after the end of a short month lies between its last day and the first day of the next month. It is replaced only in a month that is asked for, or when the search goes month by month at the top: inside a quarter or a year, a later month can have the day.
        var edgeAfter: Neighbor?
        if gapComponent == .day, index > 0, levels[index - 1].unit == .month, comps.month != nil || index == 1,
           calendar.dateInterval(of: .month, for: window.start)?.end == window.end {
            edgeAfter = neighbor(of: unit, at: window.end, gapComponent: gapComponent)
        }

        return Level(index: index, unit: unit, checks: checks, window: window, gapComponent: gapComponent, wanted: wanted,
                     countingValue: countingValue, jumpTarget: jumpTarget, edgeBefore: edgeBefore, edgeAfter: edgeAfter)
    }

    // MARK: - 3. Walking the pieces of a level

    mutating func walk(_ level: Level) -> (Date, Bool)? {
        let window = level.window
        var t = backward ? window.end - NestedSearch.justBefore : window.start
        var previous = backward ? level.edgeAfter : level.edgeBefore
        while backward ? t >= window.start : t < window.end {
            budget -= 1
            guard budget > 0, let current = piece(of: level, at: t) else { return nil }
            // A matching piece is searched one level deeper.
            if matches(current, level), !isOtherOccurrence(current, level), let found = searchInside(current, level) {
                return found
            }
            // The wanted value can be skipped between this piece and the one before.
            let neighbor: Neighbor? = level.gapComponent != nil ? (current, key(current.start, level)) : nil
            if let previous, let neighbor, let candidate = dateNearGap(previous, neighbor, level) {
                return (candidate, false)
            }
            previous = neighbor
            // Then on to the next piece, or straight to the wanted value.
            guard let next = nextStart(after: current, level) else { break }
            t = next.start
            if next.jumped {
                previous = nil
            }
        }
        // A gap at the edge of the window that the search reaches last.
        if let previous, let edge = backward ? level.edgeBefore : level.edgeAfter, let candidate = dateNearGap(previous, edge, level) {
            return (candidate, false)
        }
        return nil
    }

    /// The piece of the level's unit at `t`, cut by the window.
    func piece(of level: Level, at t: Date) -> DateInterval? {
        guard let interval = calendar.dateInterval(of: level.unit, for: t) else { return nil }
        return DateInterval(start: max(interval.start, level.window.start), end: min(interval.end, level.window.end))
    }

    /// The next level inside a matching piece. Searching forward, a piece that the bound doesn't cut gives its first match anyway.
    mutating func searchInside(_ current: DateInterval, _ level: Level) -> (Date, Bool)? {
        if level.index == firstOnlyIndex && (backward || current.start == bound) {
            return firstMatch(in: current, level.index)
        }
        return search(current, level.index + 1)
    }

    /// The first match of the whole piece around `current`, which a search backward finds too. The bound can cut the piece, so the match counts only when it is beyond the bound.
    func firstMatch(in current: DateInterval, _ index: Int) -> (Date, Bool)? {
        // When the bound itself matches, as a previous match of an enumeration does, the first match of its piece is not after it.
        if !backward, comps.nanosecond == nil, comps.isLeapMonth == nil,
           levels.allSatisfy({ $0.checks.allSatisfy { calendar.component($0, from: bound) == comps.value(for: $0) } }) {
            return nil
        }
        guard var whole = calendar.dateInterval(of: levels[index].unit, for: current.start) else { return nil }
        // A week is cut by its month when the month is searched too.
        if index > 0, let parent = calendar.dateInterval(of: levels[index - 1].unit, for: current.start) {
            whole = DateInterval(start: max(whole.start, parent.start), end: min(whole.end, parent.end))
        }
        // Searching forward, the other policy keeps the same occurrence of a repeated time as searching backward.
        let forwardPolicy: Calendar.RepeatedTimePolicy = backward ? (repeatedTimePolicy == .first ? .last : .first) : repeatedTimePolicy
        let end = min(whole.end, limit ?? whole.end)
        guard let first = calendar._firstMatch(from: whole.start, matching: comps, matchingPolicy: matchingPolicy,
                                               repeatedTimePolicy: forwardPolicy, originalStart: originalStart, before: end),
              isBeyondBound(first.0) else { return nil }
        return first
    }

    /// Where the next piece starts, or `nil` when the rest of the window can't match.
    ///
    /// The search jumps straight to the wanted value instead of stepping through every piece. A daylight saving time change, or a calendar with 13 months, can make the jump miss; then the check after the jump fails and the search keeps stepping, which also finds gaps.
    func nextStart(after current: DateInterval, _ level: Level) -> (start: Date, jumped: Bool)? {
        let unit = level.unit
        let window = level.window
        let t = backward ? current.start - NestedSearch.justBefore : current.end
        guard let wanted = level.jumpTarget, window.start <= t, t < window.end else { return (t, false) }
        let value = calendar.component(unit, from: t)
        let currentValue = calendar.component(unit, from: current.start)
        // Day and week numbers only grow in this window: once a piece is past the wanted value, the rest can't match.
        if level.countingValue != nil, backward ? currentValue < wanted : currentValue > wanted {
            return nil
        }
        let steps: Int
        if let period = periods(unit) {
            // Months, hours, minutes and seconds wrap around, so the distance is counted around the circle. Don't jump over a gap right after this piece: the step finds it.
            let skipsGap = backward
                ? isSkipped(wanted, between: value, and: currentValue, unit: unit)
                : isSkipped(wanted, between: currentValue, and: value, unit: unit)
            steps = skipsGap ? 0 : (backward ? value - wanted + period : wanted - value + period) % period
        } else {
            steps = backward ? value - wanted : wanted - value
        }
        guard steps > 0 else { return (t, false) }
        let delta = backward ? -steps : steps
        let jumped: Date? = if let length = fixedLength(unit) { t + Double(delta) * length } else { calendar.date(byAdding: unit, value: delta, to: t) }
        guard let jumped, window.start <= jumped, jumped < window.end, calendar.component(unit, from: jumped) == wanted else {
            return (t, false)
        }
        return (jumped, true)
    }

    // MARK: - 4. Small questions

    func isBeyondBound(_ date: Date) -> Bool {
        backward ? date < bound : date > bound
    }

    /// Whether every checked component of `date` has the wanted value.
    func fits(_ date: Date, _ level: Level) -> Bool {
        level.checks.allSatisfy { calendar.component($0, from: date) == comps.value(for: $0) }
    }

    func matches(_ piece: DateInterval, _ level: Level) -> Bool {
        guard fits(piece.start, level) else { return false }
        if level.unit == .month, let leap = comps.isLeapMonth {
            return calendar._dateComponents(.month, from: piece.start).isLeapMonth == leap
        }
        return true
    }

    /// When a time repeats, only one of its occurrences counts: `.first` is the one the search reaches first, `.last` the other one.
    func isOtherOccurrence(_ current: DateInterval, _ level: Level) -> Bool {
        let unit = level.unit
        guard unit == .hour || unit == .minute || unit == .second, !level.checks.isEmpty else { return false }
        let wantsLaterOccurrence = (repeatedTimePolicy == .first) == backward
        let neighborTime = wantsLaterOccurrence ? current.end : current.start - NestedSearch.justBefore
        // The neighbor is another piece of the unit, not the rest of this one cut by the bound.
        guard let own = calendar.dateInterval(of: unit, for: current.start),
              let neighbor = calendar.dateInterval(of: unit, for: neighborTime) else { return false }
        return neighbor.start != own.start && fits(neighbor.start, level)
    }

    /// Months are ordered with a leap month right after the month it repeats.
    func monthKey(_ month: Int, isLeap: Bool?) -> Int {
        month * 2 + (isLeap == true ? 1 : 0)
    }

    /// The value of a piece that a gap is looked for in.
    func key(_ date: Date, _ level: Level) -> Int {
        keyValue(date, unit: level.unit, gapComponent: level.gapComponent)
    }

    func keyValue(_ date: Date, unit: Calendar.Component, gapComponent: Calendar.Component?) -> Int {
        guard gapComponent == .month else { return calendar.component(gapComponent ?? unit, from: date) }
        let month = calendar._dateComponents(.month, from: date)
        return monthKey(month.month ?? 0, isLeap: month.isLeapMonth)
    }

    /// The piece of `unit` at `t` with its value, as a neighbor of the pieces of a window.
    func neighbor(of unit: Calendar.Component, at t: Date, gapComponent: Calendar.Component?) -> Neighbor? {
        calendar.dateInterval(of: unit, for: t).map { ($0, keyValue($0.start, unit: unit, gapComponent: gapComponent)) }
    }

    /// Whether `wanted` lies between two neighboring values. Hours wrap at midnight and days at the end of a month.
    func isSkipped(_ wanted: Int, between earlierValue: Int, and laterValue: Int, unit: Calendar.Component) -> Bool {
        if earlierValue < laterValue {
            return earlierValue < wanted && wanted < laterValue
        }
        return earlierValue > laterValue && (unit == .hour || unit == .day) && (earlierValue < wanted || wanted < laterValue)
    }

    /// The date next to a gap, when the wanted value is skipped between two neighboring pieces, given in the order the search reaches them.
    func dateNearGap(_ first: Neighbor, _ second: Neighbor, _ level: Level) -> Date? {
        guard matchingPolicy != .strict, let wanted = level.wanted else { return nil }
        let (earlier, later) = backward ? (second, first) : (first, second)
        guard isSkipped(wanted, between: earlier.value, and: later.value, unit: level.unit),
              let candidate = nearGap(before: earlier.piece, after: later.piece.start, level.unit),
              isBeyondBound(candidate) else { return nil }
        return candidate
    }

    /// The date next to a gap, picked by the matching policy. `before` is the piece before the gap in time, `after` is where time continues after it.
    func nearGap(before: DateInterval, after: Date, _ unit: Calendar.Component) -> Date? {
        switch matchingPolicy {
        case .nextTime:
            return after
        case .nextTimePreservingSmallerComponents:
            return calendar.dateInterval(of: unit, for: after).flatMap { withSmallerComponents($0.start, below: unit) }
        case .previousTimePreservingSmallerComponents:
            return withSmallerComponents(before.start, below: unit)
        default:
            return nil
        }
    }

    /// The time of day below `unit` for a date next to a gap: the components that are set, else the ones of the start date, and the nanosecond.
    func withSmallerComponents(_ date: Date, below unit: Calendar.Component) -> Date? {
        let units: [Calendar.Component] = [.day, .hour, .minute, .second]
        var result = date
        for u in units[(units.firstIndex(of: unit).map { $0 + 1 } ?? 0)...] {
            let value = comps.value(for: u) ?? calendar.component(u, from: originalStart)
            let current = calendar.component(u, from: result)
            guard let moved = calendar.date(byAdding: u, value: value - current, to: result) else { return nil }
            result = moved
        }
        return result + nanosecond
    }

    /// How many values a unit that the search can jump through has.
    func periods(_ unit: Calendar.Component) -> Int? {
        switch unit {
        case .month: 12
        case .hour: 24
        case .minute, .second: 60
        default: nil
        }
    }

    /// The length of a unit that is always the same, which a jump can add without asking the calendar.
    func fixedLength(_ unit: Calendar.Component) -> TimeInterval? {
        switch unit {
        case .hour: TimeInterval(Calendar._secondsInHour)
        case .minute: TimeInterval(Calendar._secondsInMinute)
        case .second: 1
        default: nil
        }
    }
}

extension Calendar.Component {
    package var nextHigherUnit: Self? {
        switch self {
        case .timeZone, .calendar:
            return nil // not really components
        case .era:
            return nil
        case .year, .yearForWeekOfYear:
            return .era
        case .weekOfYear:
            return .yearForWeekOfYear
        case .quarter, .isLeapMonth, .month, .dayOfYear:
            return .year
        case .day, .weekOfMonth, .weekdayOrdinal, .isRepeatedDay:
            return .month
        case .weekday:
            return .weekOfMonth
        case .hour:
            return .day
        case .minute:
            return .hour
        case .second:
            return .minute
        case .nanosecond:
            return .second
        }
    }
}

