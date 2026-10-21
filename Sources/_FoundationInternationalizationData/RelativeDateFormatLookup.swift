//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT

// Reads the tables in RelativeDateFormatData.swift, which stay `internal` to this module so they compile into
// read-only data. The generator (utils/build-relative-date-format-data) resolves inheritance, width fallback
// and plural fallback, so lookups here only walk the locale chain.

// MARK: - Public types

/// A unit of relative date formatting.
package enum RelativeDateUnit: UInt8, Sendable {
    case year, month, week, day, hour, minute, second
}

/// The width of the patterns: `wide` ("in 2 days"), `short` ("in 2 days" or "in 2d"), `narrow`.
package enum RelativeDateWidth: UInt8, Sendable {
    case wide, short, narrow
}

/// A string in the tables.
package struct RelativeDateString: Sendable {
    let index: Int

    /// The empty string, which is string 0.
    package static var empty: RelativeDateString { RelativeDateString(index: 0) }

    package var isEmpty: Bool { utf8Count == 0 }

    package var utf8Count: Int {
        Int(RelativeDateFormatData.stringOffsets[index + 1]) - Int(RelativeDateFormatData.stringOffsets[index])
    }

    /// The string's UTF-8 bytes, in the string pool.
    package var utf8: Span<UInt8> {
        @_lifetime(immortal)
        get {
            let start = Int(RelativeDateFormatData.stringOffsets[index])
            // The pool is a string literal, so its bytes live as long as the program.
            let pool = UnsafeBufferPointer(start: RelativeDateFormatData.stringPool.utf8Start, count: RelativeDateFormatData.stringPool.utf8CodeUnitCount)
            let span = Span(_unsafeElements: pool).extracting(start ..< start + utf8Count)
            return _overrideLifetime(span, borrowing: ())
        }
    }

    /// The UTF-8 byte at `offset`.
    package subscript(utf8 offset: Int) -> UInt8 {
        RelativeDateFormatData.stringPool.utf8Start[Int(RelativeDateFormatData.stringOffsets[index]) + offset]
    }

    /// Appends the UTF-8 bytes from `offset` on.
    package func append(to output: inout OutputSpan<UInt8>, from offset: Int = 0) {
        let bytes = utf8
        for i in offset ..< bytes.count {
            output.append(bytes[i])
        }
    }

    /// Compares the bytes with `other`, as `strcmp` orders ASCII identifiers.
    fileprivate func compare(_ other: Span<UInt8>) -> Int {
        let bytes = utf8
        for i in 0 ..< min(bytes.count, other.count) {
            if bytes[i] != other[i] { return bytes[i] < other[i] ? -1 : 1 }
        }
        return bytes.count - other.count
    }

    package var string: String {
        String(unsafeUninitializedCapacity: utf8Count) { buffer in
            var output = OutputSpan(buffer: buffer, initializedCount: 0)
            append(to: &output)
            return output.finalize(for: buffer)
        }
    }
}

/// A pattern such as "in {0} days", split at `{0}`.
package struct RelativeDatePatternParts: Sendable {
    package let prefix: RelativeDateString
    package let suffix: RelativeDateString
    /// Whether the pattern has `{0}`. A pattern without it is the whole output.
    package let hasPlaceholder: Bool

    package init(prefix: RelativeDateString, suffix: RelativeDateString, hasPlaceholder: Bool) {
        self.prefix = prefix
        self.suffix = suffix
        self.hasPlaceholder = hasPlaceholder
    }
}

/// The patterns and names of one unit in one width, read from the tables once.
package struct RelativeDateUnitPatterns: Sendable {
    /// The past and future patterns, by plural category in the order of `PluralCategory`.
    let past: [RelativeDatePatternParts]
    let future: [RelativeDatePatternParts]
    /// The names for offsets -2 through 2; nil where the locale has none.
    let names: [RelativeDateString?]

    init(forms: Int) {
        func patterns(_ set: UInt16) -> [RelativeDatePatternParts] {
            // Six patterns per set, in the order of `PluralCategory`.
            (0 ..< 6).map { category in
                let pattern = Int(RelativeDateFormatData.patternSets[Int(set) * 6 + category])
                return RelativeDatePatternParts(
                    prefix: RelativeDateString(index: Int(RelativeDateFormatData.patternPrefix[pattern])),
                    suffix: RelativeDateString(index: Int(RelativeDateFormatData.patternSuffix[pattern])),
                    hasPlaceholder: RelativeDateFormatData.patternHasPlaceholder[pattern])
            }
        }
        past = patterns(RelativeDateFormatData.unitFormsPast[forms])
        future = patterns(RelativeDateFormatData.unitFormsFuture[forms])
        // Five names per set, for -2 through 2.
        let nameSet = Int(RelativeDateFormatData.unitFormsNames[forms])
        names = (0 ..< 5).map { offset in
            let name = RelativeDateString(index: Int(RelativeDateFormatData.nameSets[nameSet * 5 + offset]))
            return name.isEmpty ? nil : name
        }
    }

    /// The pattern for a value in the past or the future with the plural category `category`.
    package func pattern(future isFuture: Bool, category: PluralCategory) -> RelativeDatePatternParts {
        let index = switch category {
        case .zero: 0
        case .one: 1
        case .two: 2
        case .few: 3
        case .many: 4
        case .other: 5
        }
        return isFuture ? future[index] : past[index]
    }

    /// The name for `offset`, such as "yesterday" for -1, or nil if the locale has none.
    package func name(offset: Int) -> RelativeDateString? {
        guard offset >= -2 && offset <= 2 else { return nil }
        return names[offset + 2]
    }
}

/// The numbering system and grouping that integers use for a locale identifier.
package struct RelativeDateNumberFormat: Sendable {
    /// The ten digits, one after the other. `digitRange(_:)` gives each digit's bytes.
    package let digits: RelativeDateString
    /// The UTF-8 offset of each digit in `digits`, and the end of the last one.
    package let digitOffsets: InlineArray<11, UInt8>
    package let prefix: RelativeDateString
    package let suffix: RelativeDateString
    package let groupSeparator: RelativeDateString
    /// The size of the group next to the decimal separator, 0 for no grouping.
    package let primaryGrouping: Int
    package let secondaryGrouping: Int
    /// The fewest digits a number needs, counted from its first group separator, before it's grouped.
    package let minimumGroupingDigits: Int
}

// MARK: - Locale lookup

/// The data of a locale identifier: the locales of its lookup chain that have entries, nearest first.
package struct RelativeDateFormatLocale: Sendable {
    /// Indexes into `locales`.
    let chain: [Int]

    /// Resolves an identifier such as `en_GB` or `sr-Latn@calendar=gregorian` like the ICU path: keywords are
    /// ignored, then the lookup follows locale aliases and parent locales, else drops the last subtag, until
    /// root. Where the identifier's language has no data, it continues with the fallback locale chosen when
    /// the data was built.
    package init(identifier: String) {
        let chain = Self.chain(Self.baseName(identifier))
        if chain.count == 1, chain[0] != Int(RelativeDateFormatData.fallbackLocale) {
            self.chain = Self.chain(RelativeDateString(index: Int(RelativeDateFormatData.localeID[Int(RelativeDateFormatData.fallbackLocale)])).string)
        } else {
            self.chain = chain
        }
    }

    /// The forms of `unit` in `width`.
    package func patterns(_ unit: RelativeDateUnit, _ width: RelativeDateWidth) -> RelativeDateUnitPatterns {
        for locale in chain {
            for slot in Int(RelativeDateFormatData.localeSlotStart[locale]) ..< Int(RelativeDateFormatData.localeSlotEnd[locale]) {
                if RelativeDateFormatData.slotUnit[slot] == unit.rawValue && RelativeDateFormatData.slotWidth[slot] == width.rawValue {
                    return RelativeDateUnitPatterns(forms: Int(RelativeDateFormatData.slotForms[slot]))
                }
            }
        }
        // Root has every unit and width.
        preconditionFailure("no relative date data for \(unit) \(width)")
    }

    /// The numbers entry: the first in the chain that has one. Root has one.
    var numbers: RelativeDateNumbers {
        for locale in chain where RelativeDateFormatData.localeHasNumbers[locale] {
            return RelativeDateNumbers(index: Int(RelativeDateFormatData.localeNumbers[locale]))
        }
        preconditionFailure("no relative date number data")
    }

    // MARK: Identifiers

    /// The identifier without keywords, with `_` separators, a lowercase language, a title-case script, and
    /// an uppercase region. An empty identifier is root.
    static func baseName(_ identifier: String) -> String {
        var base = PluralRules.normalizedIdentifier(identifier)
        // A BCP 47 extension such as `-u-nu-arab` starts with a single-character subtag; it isn't part of the
        // base name.
        let subtags = base.split(separator: "_", omittingEmptySubsequences: false)
        if let singleton = subtags.dropFirst().firstIndex(where: { $0.utf8.count == 1 }) {
            base = subtags[..<singleton].joined(separator: "_")
        }
        return base.isEmpty ? "root" : base
    }

    /// The entries on the lookup chain of `baseName`, ending with root.
    static func chain(_ baseName: String) -> [Int] {
        var result: [Int] = []
        var current = baseName
        while true {
            if let index = search(current) { result.append(index) }
            if current == "root" { return result }
            if let redirect = redirect(current) {
                current = redirect
            } else if let underscore = current.utf8.lastIndex(of: UInt8(ascii: "_")) {
                current = String(current[..<underscore])
            } else {
                current = "root"
            }
        }
    }

    /// The first locale on the lookup chain of `baseName` that has an entry, without the fallback.
    static func firstLocale(_ baseName: String) -> Int {
        chain(baseName)[0]
    }

    static func search(_ identifier: String) -> Int? {
        binarySearch(identifier, count: RelativeDateFormatData.localeID.count) { RelativeDateFormatData.localeID[$0] }
    }

    static func redirect(_ identifier: String) -> String? {
        binarySearch(identifier, count: RelativeDateFormatData.redirectFrom.count) { RelativeDateFormatData.redirectFrom[$0] }
            .map { RelativeDateString(index: Int(RelativeDateFormatData.redirectTo[$0])).string }
    }

    /// The locale of the country fallback for `region`, or nil if it isn't a known region.
    static func regionLocale(_ region: Substring) -> String? {
        binarySearch(String(region), count: RelativeDateFormatData.regionLocaleRegion.count) { RelativeDateFormatData.regionLocaleRegion[$0] }
            .map { RelativeDateString(index: Int(RelativeDateFormatData.regionLocaleLocale[$0])).string }
    }

    static func numberingSystemDigits(_ name: String) -> RelativeDateString? {
        binarySearch(name, count: RelativeDateFormatData.numberingSystemID.count) { RelativeDateFormatData.numberingSystemID[$0] }
            .map { RelativeDateString(index: Int(RelativeDateFormatData.numberingSystemDigits[$0])) }
    }

    /// The index of `target` in a table of `count` entries sorted by the string `key` gives for each index.
    private static func binarySearch(_ target: String, count: Int, key: (Int) -> UInt16) -> Int? {
        var target = target
        target.makeContiguousUTF8()
        let span = target.utf8Span.span
        var low = 0
        var high = count - 1
        while low <= high {
            let middle = (low + high) / 2
            let order = RelativeDateString(index: Int(key(middle))).compare(span)
            if order == 0 { return middle }
            if order < 0 { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

// MARK: - Numbers

/// The subtags of a base name: language, script, region, and whether there is more (a variant).
private struct Subtags {
    var language: Substring
    var script: Substring?
    var region: Substring?
    var rest: Substring?

    init(_ baseName: String) {
        var parts = baseName.split(separator: "_", maxSplits: 3, omittingEmptySubsequences: false)[...]
        language = parts.removeFirst()
        if let next = parts.first, next.count == 4 {
            script = next
            parts.removeFirst()
        }
        if let next = parts.first, next.count == 2 && next.allSatisfy(\.isLetter) || next.count == 3 && next.allSatisfy(\.isNumber) {
            region = next
            parts.removeFirst()
        }
        if !parts.isEmpty {
            rest = baseName[parts.first!.startIndex...]
        }
    }

    var languageAndScript: String {
        script.map { "\(language)_\($0)" } ?? String(language)
    }
}

/// The value of keyword `name`, lowercased, in an identifier such as `en_US@numbers=arab;rg=gbzzzz`, or of
/// its BCP 47 key in a Unicode extension such as `en-US-u-nu-arab` (`nu` for `numbers`, `rg` for `rg`).
private func keyword(_ name: String, in identifier: String) -> String? {
    let utf8 = identifier.utf8
    if let at = utf8.firstIndex(of: UInt8(ascii: "@")) {
        for item in identifier[identifier.index(after: at)...].split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name { return parts[1].lowercased() }
        }
        return nil
    }
    // A Unicode extension holds keywords too: `-u-` then keys of two characters, each followed by its values.
    let bcp47Key = name == "numbers" ? "nu" : name
    let subtags = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.lowercased() }
    guard let u = subtags.firstIndex(of: "u") else { return nil }
    var index = u + 1
    while index < subtags.count, subtags[index].utf8.count != 1 {
        if subtags[index] == bcp47Key, index + 1 < subtags.count, subtags[index + 1].utf8.count > 2 {
            return subtags[index + 1]
        }
        index += 1
    }
    return nil
}

extension RelativeDateNumberFormat {
    /// The decimal number format of an identifier, as the ICU path sets it up. Returns nil where the
    /// numbering system is algorithmic (such as `roman`) or unknown, which need other rules.
    package init?(identifier: String) {
        let baseName = RelativeDateFormatLocale.baseName(identifier)
        let subtags = Subtags(baseName)
        let numbersKeyword = keyword("numbers", in: identifier)
        let rgKeyword = keyword("rg", in: identifier)

        // The numbering system. Default, native, traditional and finance resolve on the language, script and
        // region, where the region comes from a valid `rg` keyword, else the identifier.
        let system: String
        if let numbersKeyword, !["default", "native", "traditional", "finance"].contains(numbersKeyword) {
            system = numbersKeyword
        } else {
            var region = subtags.region.map(String.init)
            if let rgKeyword, rgKeyword.utf8.count >= 3, rgKeyword.utf8.count <= 6, rgKeyword.utf8.prefix(2).allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }) {
                let rgRegion = rgKeyword.prefix(2).uppercased()
                if Self.isRegion(rgRegion) { region = rgRegion }
            }
            let adjusted = region.map { "\(subtags.languageAndScript)_\($0)" } ?? baseName
            let numbers = RelativeDateFormatLocale(identifier: adjusted).numbers
            let name = switch numbersKeyword {
            case "native": RelativeDateFormatData.numbersNativeSystem[numbers.index]
            case "traditional": RelativeDateFormatData.numbersTraditionalSystem[numbers.index]
            case "finance": RelativeDateFormatData.numbersFinanceSystem[numbers.index]
            default: RelativeDateFormatData.numbersDefaultSystem[numbers.index]
            }
            system = RelativeDateString(index: Int(name)).string
        }
        guard let digits = RelativeDateFormatLocale.numberingSystemDigits(system) else { return nil }
        var offsets: InlineArray<11, UInt8> = .init(repeating: 0)
        var digit = 0
        var position = 0
        while digit < 10 {
            let lead = digits[utf8: position]
            position += lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
            digit += 1
            offsets[digit] = UInt8(position)
        }
        self.digits = digits
        self.digitOffsets = offsets

        // The group separator and pattern come from the country fallback; the minimum grouping digits come
        // from the identifier itself.
        let symbolsLocale = RelativeDateFormatLocale(identifier: Self.countryFallback(baseName: baseName, subtags: subtags, rgKeyword: rgKeyword))
        let numbers = symbolsLocale.numbers
        // The run starts with latn, which serves the systems without their own row.
        var format = Int(RelativeDateFormatData.numbersFormatStart[numbers.index])
        var systemName = system
        systemName.makeContiguousUTF8()
        for row in Int(RelativeDateFormatData.numbersFormatStart[numbers.index]) ..< Int(RelativeDateFormatData.numbersFormatEnd[numbers.index]) {
            if RelativeDateString(index: Int(RelativeDateFormatData.numberFormatSystem[row])).compare(systemName.utf8Span.span) == 0 {
                format = row
                break
            }
        }
        prefix = RelativeDateString(index: Int(RelativeDateFormatData.numberFormatPrefix[format]))
        suffix = RelativeDateString(index: Int(RelativeDateFormatData.numberFormatSuffix[format]))
        groupSeparator = RelativeDateString(index: Int(RelativeDateFormatData.numberFormatGroupSeparator[format]))
        primaryGrouping = Int(RelativeDateFormatData.numberFormatPrimaryGrouping[format])
        secondaryGrouping = Int(RelativeDateFormatData.numberFormatSecondaryGrouping[format])
        minimumGroupingDigits = Int(RelativeDateFormatData.numbersMinimumGroupingDigits[RelativeDateFormatLocale(identifier: baseName).numbers.index])
    }

    /// The UTF-8 bytes of `digit`, 0 through 9, as a range of `digits`.
    package func digitRange(_ digit: Int) -> Range<Int> {
        Int(digitOffsets[digit]) ..< Int(digitOffsets[digit + 1])
    }

    private static func isRegion(_ region: String) -> Bool {
        RelativeDateFormatLocale.regionLocale(Substring(region)) != nil
    }

    /// The identifier whose number symbols and patterns the ICU path reads for `baseName`: with an `rg`
    /// keyword, the identifier with that region; then, where the identifier has a region but no data of its
    /// own for it, the likely language of the region with that region, such as `en_US` for `ja_US`.
    private static func countryFallback(baseName: String, subtags: Subtags, rgKeyword: String?) -> String {
        var subtags = subtags
        var baseName = baseName
        // This takes the first two letters of any `rg` value, without checking the region.
        if let rgKeyword, rgKeyword.utf8.count >= 2, rgKeyword.utf8.prefix(2).allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }) {
            let region = rgKeyword.prefix(2).uppercased()
            subtags.region = Substring(region)
            baseName = subtags.languageAndScript + "_" + region + (subtags.rest.map { "_\($0)" } ?? "")
            subtags = Subtags(baseName)
        }
        guard let region = subtags.region else { return baseName }
        // The first locale with data or an entry on the chain, and its region.
        let found = RelativeDateFormatLocale.firstLocale(baseName)
        let foundName = RelativeDateString(index: Int(RelativeDateFormatData.localeID[found])).string
        if Subtags(foundName).region == region || RelativeDateFormatLocale.redirect(baseName) != nil {
            return baseName
        }
        return regionLocale(region, subtags: subtags)
    }

    private static func regionLocale(_ region: Substring, subtags: Subtags) -> String {
        // The likely subtags give English for an unknown region.
        let target = RelativeDateFormatLocale.regionLocale(region) ?? "en_\(region)"
        return target + (subtags.rest.map { "_\($0)" } ?? "")
    }
}

// MARK: - Table rows

/// A row of the numbers columns.
struct RelativeDateNumbers {
    let index: Int
}

#endif // FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT
