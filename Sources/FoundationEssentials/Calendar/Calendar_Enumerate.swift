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

                let match = usesFastPath ? calendar._calendarNextDate(after: searchingDate, matching: matchingComponents, direction: direction) : calendar._nearestMatch(after: searchingDate, direction: direction, matching: matchingComponents, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy, originalStart: start)?.0
                guard let match, range?.contains(match) ?? true else {
                    if match == nil && !usesFastPath {
                        _handleCalendarResultNotFound(date: start, calendar: calendar, comps: matchingComponents, direction: direction, matchingPolicy: matchingPolicy, repeatedTimePolicy: repeatedTimePolicy)
                    }
                    finished = true
                    return nil
                }
                searchingDate = match
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

extension Calendar {
    /// The units a search walks through, from the largest to the smallest, with the components each one checks.
    private func _searchLevels(for comps: DateComponents) -> [(Calendar.Component, [Calendar.Component])] {
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
        return all.compactMap { unit, checks in
            let set = checks.filter { comps.value(for: $0) != nil }
            // A day of the month, a weekday ordinal and a week of the month are counted inside their month, so the search goes month by month when one is set.
            let keepMonth = unit == .month && (comps.isLeapMonth != nil || comps.day != nil || comps.weekdayOrdinal != nil || comps.weekOfMonth != nil)
            // A minute is found directly inside its hour, and a second inside its minute.
            let keepParent = (unit == .hour && comps.minute != nil) || (unit == .minute && comps.second != nil)
            return set.isEmpty && !keepMonth && !keepParent ? nil : (unit, set)
        }
    }

    /// The nearest date after `bound` in `direction` that matches `comps`. Each unit that is set is searched only inside the piece of the larger unit that matched, so a match can't leave a month, a week or a day that an earlier unit chose. When a value is in a gap, such as a day after the end of a short month or an hour skipped by a daylight saving time change, the matching policy picks a date next to the gap.
    internal func _nearestMatch(after bound: Date, direction: SearchDirection, matching comps: DateComponents, matchingPolicy: MatchingPolicy, repeatedTimePolicy: RepeatedTimePolicy, originalStart: Date, before limit: Date? = nil, firstInEachPiece: Bool = true) -> (Date, Bool)? {
        let levels = _searchLevels(for: comps)
        guard !levels.isEmpty else { return nil }
        let backward = direction == .backward
        // Only the first match inside each piece of the largest unit that is set counts, so November and 9 o'clock match November 1 at 9:00 once a year. In the smallest unit a match is the start of the piece anyway.
        let firstOnlyIndex = firstInEachPiece ? levels.firstIndex { !$0.1.isEmpty }.flatMap { $0 < levels.count - 1 ? $0 : nil } : nil
        // The nanosecond is added to the start of the smallest unit that is found.
        let nanosecond = TimeInterval(comps.nanosecond ?? 0) / 1_000_000_000
        // How far a search looks before it gives up, and how many pieces it looks at, so that components that never match, such as February 30, end the search.
        let span: TimeInterval = 400 * 366 * 86400
        var budget = 50_000

        func isBeyondBound(_ date: Date) -> Bool {
            backward ? date < bound : date > bound
        }

        // The time of day below `unit` for a date next to a gap: the components that are set, else the ones of the start date, and the nanosecond.
        func withSmallerComponents(_ date: Date, below unit: Calendar.Component) -> Date? {
            let units: [Calendar.Component] = [.day, .hour, .minute, .second]
            var result = date
            for u in units[(units.firstIndex(of: unit).map { $0 + 1 } ?? 0)...] {
                let value = comps.value(for: u) ?? component(u, from: originalStart)
                let current = component(u, from: result)
                guard let moved = self.date(byAdding: u, value: value - current, to: result) else { return nil }
                result = moved
            }
            return result + nanosecond
        }

        // The first match of the whole piece around `current`, which a search backward finds too. The bound can cut the piece, so the match counts only when it is beyond the bound.
        func firstMatch(in current: DateInterval, _ index: Int) -> (Date, Bool)? {
            // When the bound itself matches, as a previous match of an enumeration does, the first match of its piece is not after it.
            if !backward, comps.nanosecond == nil, comps.isLeapMonth == nil, levels.allSatisfy({ $0.1.allSatisfy { component($0, from: bound) == comps.value(for: $0) } }) {
                return nil
            }
            guard var whole = dateInterval(of: levels[index].0, for: current.start) else { return nil }
            // A week is cut by its month when the month is searched too.
            if index > 0, let parent = dateInterval(of: levels[index - 1].0, for: current.start) {
                whole = DateInterval(start: max(whole.start, parent.start), end: min(whole.end, parent.end))
            }
            // Searching forward, the other policy keeps the same occurrence of a repeated time as searching backward.
            guard let first = _nearestMatch(after: whole.start - 0.001, direction: .forward, matching: comps, matchingPolicy: matchingPolicy, repeatedTimePolicy: backward ? (repeatedTimePolicy == .first ? .last : .first) : repeatedTimePolicy, originalStart: originalStart, before: min(whole.end, limit ?? whole.end), firstInEachPiece: false), isBeyondBound(first.0) else { return nil }
            return first
        }

        func search(_ window: DateInterval, _ index: Int) -> (Date, Bool)? {
            guard index < levels.count else {
                // A piece that the bound cuts starts at the bound, not at the start of its unit.
                let start = !backward && window.start == bound ? dateInterval(of: levels[index - 1].0, for: bound)?.start ?? bound : window.start
                let match = start + nanosecond
                return match < window.end && isBeyondBound(match) ? (match, true) : nil
            }
            let (unit, checks) = levels[index]

            // Every hour has the same minutes and every minute the same seconds, so the piece is found directly.
            if unit == .minute || unit == .second, let wanted = comps.value(for: unit), let length = fixedLength(unit), let parent = dateInterval(of: levels[index - 1].0, for: window.start) {
                let start = parent.start + Double(wanted) * length
                // The search can start inside the wanted minute or second.
                guard window.start < start + length, start < window.end else { return nil }
                return search(DateInterval(start: max(start, window.start), end: min(start + length, window.end)), index + 1)
            }

            func piece(at t: Date) -> DateInterval? {
                guard let interval = dateInterval(of: unit, for: t) else { return nil }
                return DateInterval(start: max(interval.start, window.start), end: min(interval.end, window.end))
            }
            func fits(_ date: Date) -> Bool {
                checks.allSatisfy { component($0, from: date) == comps.value(for: $0) }
            }
            func matches(_ piece: DateInterval) -> Bool {
                guard fits(piece.start) else { return false }
                if unit == .month, let leap = comps.isLeapMonth {
                    return _dateComponents(.month, from: piece.start).isLeapMonth == leap
                }
                return true
            }
            // A value that time skips over makes sense only for the single value of a time unit, a day number or a leap month. A month number that a year doesn't have is searched for in other years.
            let gapComponent: Calendar.Component? = checks.count == 1 && [.day, .hour, .minute, .second].contains(checks[0]) || (checks == [.month] && comps.isLeapMonth == true) ? checks[0] : nil
            // Months are ordered with a leap month right after the month it repeats.
            func monthKey(_ month: Int, isLeap: Bool?) -> Int {
                month * 2 + (isLeap == true ? 1 : 0)
            }
            func key(_ date: Date) -> Int {
                guard gapComponent == .month else { return component(gapComponent ?? unit, from: date) }
                let month = _dateComponents(.month, from: date)
                return monthKey(month.month ?? 0, isLeap: month.isLeapMonth)
            }
            // The date next to a gap, picked by the matching policy. `before` is the piece before the gap in time, `after` is where time continues after it.
            func nearGap(before: DateInterval, after: Date) -> Date? {
                switch matchingPolicy {
                case .nextTime:
                    return after
                case .nextTimePreservingSmallerComponents:
                    return dateInterval(of: unit, for: after).flatMap { withSmallerComponents($0.start, below: unit) }
                case .previousTimePreservingSmallerComponents:
                    return withSmallerComponents(before.start, below: unit)
                default:
                    return nil
                }
            }
            let wanted: Int? = gapComponent == .month ? comps.month.map { monthKey($0, isLeap: comps.isLeapMonth) } : gapComponent.flatMap { comps.value(for: $0) }
            // A missing day is replaced only in a month that is asked for, or when the search goes month by month at the top. Inside a quarter or a year, a later month can have the day.
            let wholeMonth = gapComponent == .day && index > 0 && levels[index - 1].0 == .month && (comps.month != nil || index == 1) && dateInterval(of: .month, for: window.start)?.end == window.end

            let isTimeUnit = unit == .hour || unit == .minute || unit == .second
            var t = backward ? window.end - 0.001 : window.start
            var previous: (piece: DateInterval, value: Int)?
            // A day can start after midnight when the clock skips it, so an hour is compared with the last hour of the day before too.
            let hourBefore = unit == .hour && gapComponent == .hour && dateInterval(of: .day, for: window.start)?.start == window.start ? dateInterval(of: .hour, for: window.start - 0.001) : nil
            if !backward, let hourBefore {
                previous = (hourBefore, key(hourBefore.start))
            }
            // Hours wrap at midnight.
            func isSkipped(_ wanted: Int, between earlierValue: Int, and laterValue: Int) -> Bool {
                earlierValue < laterValue ? earlierValue < wanted && wanted < laterValue : earlierValue > laterValue && unit == .hour && (earlierValue < wanted || wanted < laterValue)
            }
            while backward ? t >= window.start : t < window.end {
                budget -= 1
                guard budget > 0, let current = piece(at: t) else { return nil }
                if matches(current) {
                    // When a time repeats, only one of its occurrences counts: `.first` is the one the search reaches first, `.last` the other one.
                    var isSkippedRepeat = false
                    if isTimeUnit, !checks.isEmpty {
                        let neighborTime = (repeatedTimePolicy == .first) == backward ? current.end : current.start - 0.001
                        // The neighbor is another piece of the unit, not the rest of this one cut by the bound.
                        if let own = dateInterval(of: unit, for: current.start), let neighbor = dateInterval(of: unit, for: neighborTime), neighbor.start != own.start, fits(neighbor.start) {
                            isSkippedRepeat = true
                        }
                    }
                    // Searching forward, a piece that the bound doesn't cut gives its first match anyway.
                    if !isSkippedRepeat, let found = index == firstOnlyIndex && (backward || current.start == bound) ? firstMatch(in: current, index) : search(current, index + 1) {
                        return found
                    }
                }
                if matchingPolicy != .strict, gapComponent != nil, let wanted {
                    let value = key(current.start)
                    var gap: (before: DateInterval, after: Date)?
                    if let previous {
                        // The wanted value is skipped between two neighboring pieces.
                        let (earlier, later, earlierValue, laterValue) = backward ? (current, previous.piece, value, previous.value) : (previous.piece, current, previous.value, value)
                        if isSkipped(wanted, between: earlierValue, and: laterValue) {
                            gap = (earlier, later.start)
                        }
                    } else if backward, wholeMonth, value < wanted {
                        // The month ends before the wanted day.
                        gap = (current, window.end)
                    }
                    if gap == nil, backward, let hourBefore, current.start == window.start, isSkipped(wanted, between: key(hourBefore.start), and: value) {
                        gap = (hourBefore, current.start)
                    }
                    if let gap, let candidate = nearGap(before: gap.before, after: gap.after), isBeyondBound(candidate) {
                        return (candidate, false)
                    }
                }
                previous = gapComponent != nil ? (current, key(current.start)) : nil
                t = backward ? current.start - 0.001 : current.end
                // A month, an hour, a minute or a second can jump straight to the wanted value instead of stepping through every piece. A daylight saving time change can make the jump miss; then the search keeps stepping, which also finds gaps.
                if let period = periods(unit), comps.isLeapMonth == nil, let wanted = comps.value(for: unit), window.start <= t, t < window.end {
                    let value = component(unit, from: t)
                    let currentValue = component(unit, from: current.start)
                    // Don't jump over a gap right after this piece: the step finds it.
                    let skipsGap = backward ? isSkipped(wanted, between: value, and: currentValue) : isSkipped(wanted, between: currentValue, and: value)
                    let steps = backward ? (value - wanted + period) % period : (wanted - value + period) % period
                    if !skipsGap, steps > 0 {
                        let delta = backward ? -steps : steps
                        let jumped: Date? = if let length = fixedLength(unit) { t + Double(delta) * length } else { date(byAdding: unit, value: delta, to: t) }
                        if let jumped, window.start <= jumped, jumped < window.end, component(unit, from: jumped) == wanted {
                            t = jumped
                            previous = nil
                        }
                    }
                }
            }
            // Searching forward, the month can end before the wanted day.
            if !backward, matchingPolicy != .strict, wholeMonth, let wanted, let previous, previous.value < wanted, let candidate = nearGap(before: previous.piece, after: window.end), isBeyondBound(candidate) {
                return (candidate, false)
            }
            return nil
        }
        return search(backward ? DateInterval(start: bound - span, end: bound) : DateInterval(start: bound, end: max(bound, min(bound + span, limit ?? .distantFuture))), 0)
    }

    /// How many values a unit that the search can jump through has.
    private func periods(_ unit: Calendar.Component) -> Int? {
        switch unit {
        case .month: 12
        case .hour: 24
        case .minute, .second: 60
        default: nil
        }
    }

    /// The length of a unit that is always the same, which a jump can add without asking the calendar.
    private func fixedLength(_ unit: Calendar.Component) -> TimeInterval? {
        switch unit {
        case .hour: 3600
        case .minute: 60
        case .second: 1
        default: nil
        }
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

