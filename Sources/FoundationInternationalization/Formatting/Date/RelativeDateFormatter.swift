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

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

#if FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT

internal import _FoundationInternationalizationData

/// Formats the value of a relative date, such as "in 2 days" or "yesterday", in Swift, in place of `ICURelativeDateFormatter`, with the same output.
///
/// `formatter(for:)` returns nil for what this doesn't support, and the caller uses `ICURelativeDateFormatter`:
/// - `unitsStyle: .spellOut`, which needs rule-based number spelling.
/// - A `numbers` keyword that names an algorithmic numbering system such as `roman`, or an unknown one.
internal final class RelativeDateFormatter : Sendable {
    struct Signature : Hashable, Sendable {
        let localeIdentifier: String
        let width: Date.RelativeFormatStyle.UnitsStyle.Option
        let capitalizationContext: FormatStyleCapitalizationContext.Option
    }

    /// The patterns of each unit, in the order of `RelativeDateUnit`.
    let units: [RelativeDateUnitPatterns]
    let pluralRules: PluralRules
    let numberFormat: RelativeDateNumberFormat
    /// Whether to titlecase a lowercase first letter, for `beginningOfSentence`.
    let capitalizesFirstLetter: Bool
    let caseLanguage: CaseLanguage

    private static let cache = FormatterCache<Signature, RelativeDateFormatter?>()

    static func formatter(for style: Date.RelativeFormatStyle) -> RelativeDateFormatter? {
        let signature = Signature(localeIdentifier: style.locale.identifier, width: style.unitsStyle.option, capitalizationContext: style.capitalizationContext.option)
        return cache.formatter(for: signature) {
            RelativeDateFormatter(signature)
        }
    }

    private init?(_ signature: Signature) {
        let width: RelativeDateWidth
        switch signature.width {
        case .wide: width = .wide
        case .abbreviated: width = .short
        case .narrow: width = .narrow
        case .spellOut: return nil
        }
        guard let numberFormat = RelativeDateNumberFormat(identifier: signature.localeIdentifier) else {
            return nil
        }
        let locale = RelativeDateFormatLocale(identifier: signature.localeIdentifier)
        units = [RelativeDateUnit.year, .month, .week, .day, .hour, .minute, .second].map { locale.patterns($0, width) }
        pluralRules = PluralRules(localeIdentifier: signature.localeIdentifier, type: .cardinal)
        self.numberFormat = numberFormat
        // The other contexts leave relative dates as they are.
        capitalizesFirstLetter = signature.capitalizationContext == .beginningOfSentence
        caseLanguage = CaseLanguage(identifier: signature.localeIdentifier)
    }

    /// Formats `value` of `component`, which is one of `ICURelativeDateFormatter.sortedAllowedComponents`.
    func format(value: Int, component: Calendar.Component, presentation: Date.RelativeFormatStyle.Presentation) -> String? {
        let unit: RelativeDateUnit
        switch component {
        case .year: unit = .year
        case .month: unit = .month
        case .weekOfMonth: unit = .week
        case .day: unit = .day
        case .hour: unit = .hour
        case .minute: unit = .minute
        case .second: unit = .second
        default: return nil
        }
        let patterns = units[Int(unit.rawValue)]
        if presentation.option == .named, let name = patterns.name(offset: value) {
            // A name is a pattern without a number.
            return write(pattern: RelativeDatePatternParts(prefix: name, suffix: .empty, hasPlaceholder: false), magnitude: 0)
        }
        // The number is the magnitude; the sign picks the pattern. Zero is in the future: "in 0 seconds".
        let category = pluralRules.category(for: PluralOperands(value))
        return write(pattern: patterns.pattern(future: value >= 0, category: category), magnitude: UInt64(value.magnitude))
    }

    // MARK: - Writing

    /// Writes the pattern's prefix, the number (if the pattern has `{0}`), and the suffix, in one string.
    private func write(pattern: RelativeDatePatternParts, magnitude: UInt64) -> String {
        // The decimal digits of the magnitude, least significant first.
        var digits: InlineArray<20, UInt8> = .init(repeating: 0)
        var digitCount = 0
        var remaining = magnitude
        repeat {
            digits[digitCount] = UInt8(remaining % 10)
            remaining /= 10
            digitCount += 1
        } while remaining != 0

        var count = pattern.prefix.utf8Count
        if pattern.hasPlaceholder {
            count += numberFormat.prefix.utf8Count + numberFormat.suffix.utf8Count + pattern.suffix.utf8Count
            for position in 0 ..< digitCount {
                count += numberFormat.digitRange(Int(digits[position])).count
                if groupsBefore(position, digitCount: digitCount) {
                    count += numberFormat.groupSeparator.utf8Count
                }
            }
        }

        // Only a first code point that is a lowercase letter is titlecased. The text before the number is the only place it can be: digits aren't letters.
        var titlecase: (replaced: Int, bytes: [UInt8])?
        if capitalizesFirstLetter {
            let first = pattern.prefix.isEmpty && pattern.hasPlaceholder ? numberFormat.prefix : pattern.prefix
            titlecase = titlecasedStart(of: first)
            if let titlecase { count += titlecase.bytes.count - titlecase.replaced }
        }

        return String(unsafeUninitializedCapacity: count) { buffer in
            var output = OutputSpan(buffer: buffer, initializedCount: 0)
            if !pattern.prefix.isEmpty || !pattern.hasPlaceholder {
                Self.append(pattern.prefix, titlecase: &titlecase, to: &output)
            }
            if pattern.hasPlaceholder {
                if !numberFormat.prefix.isEmpty { Self.append(numberFormat.prefix, titlecase: &titlecase, to: &output) }
                for position in (0 ..< digitCount).reversed() {
                    for offset in numberFormat.digitRange(Int(digits[position])) {
                        output.append(numberFormat.digits[utf8: offset])
                    }
                    if groupsBefore(position, digitCount: digitCount) {
                        numberFormat.groupSeparator.append(to: &output)
                    }
                }
                numberFormat.suffix.append(to: &output)
                pattern.suffix.append(to: &output)
            }
            return output.finalize(for: buffer)
        }
    }

    /// Writes `string`, with the titlecased start in place of its first bytes if `titlecase` is set, and clears it.
    private static func append(_ string: RelativeDateString, titlecase: inout (replaced: Int, bytes: [UInt8])?, to output: inout OutputSpan<UInt8>) {
        guard let replacement = titlecase else {
            string.append(to: &output)
            return
        }
        titlecase = nil
        for byte in replacement.bytes { output.append(byte) }
        string.append(to: &output, from: replacement.replaced)
    }

    /// Whether a group separator goes between the digit at `position` (0 for the ones) and the next lower one.
    private func groupsBefore(_ position: Int, digitCount: Int) -> Bool {
        let primary = numberFormat.primaryGrouping
        guard primary > 0, position > 0 else { return false }
        // `position` is where the separator goes after: digit `position` is followed by one.
        let distance = position - primary
        return distance >= 0 && distance % max(numberFormat.secondaryGrouping, 1) == 0 && digitCount - primary >= numberFormat.minimumGroupingDigits
    }

    // MARK: - Capitalization

    /// How the locale's language changes titlecasing.
    enum CaseLanguage {
        /// Turkish and Azerbaijani: i becomes İ.
        case turkic
        /// Dutch: a starting ij becomes IJ.
        case dutch
        case other

        init(identifier: String) {
            let language = identifier.utf8.prefix { $0 != UInt8(ascii: "_") && $0 != UInt8(ascii: "-") && $0 != UInt8(ascii: "@") }
            if language.elementsEqual("tr".utf8) || language.elementsEqual("az".utf8) {
                self = .turkic
            } else if language.elementsEqual("nl".utf8) {
                self = .dutch
            } else {
                self = .other
            }
        }
    }

    /// The titlecase form of `string`'s first code point if it's a lowercase letter: how many UTF-8 bytes it replaces, and the replacement. Nil if it isn't lowercase.
    private func titlecasedStart(of string: RelativeDateString) -> (replaced: Int, bytes: [UInt8])? {
        guard !string.isEmpty else { return nil }
        let (scalar, length) = decodeScalar(string, at: 0)
        guard scalar.properties.generalCategory == .lowercaseLetter else { return nil }
        var replacement: String
        if caseLanguage == .turkic && scalar == "i" {
            replacement = "\u{130}"
        } else {
            replacement = scalar.properties.titlecaseMapping
        }
        var replaced = length
        // Dutch titlecasing also capitalizes the j of a starting ij (and í with j́).
        if caseLanguage == .dutch && replaced < string.utf8Count {
            let (next, nextLength) = decodeScalar(string, at: replaced)
            if (replacement == "I" || replacement == "\u{CD}") && next == "j" {
                replacement += "J"
                replaced += nextLength
            }
        }
        return (replaced, Array(replacement.utf8))
    }

    private func decodeScalar(_ string: RelativeDateString, at offset: Int) -> (Unicode.Scalar, Int) {
        let lead = string[utf8: offset]
        let length = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
        var value = length == 1 ? UInt32(lead) : UInt32(lead) & (0xFF >> (length + 1))
        for i in 1 ..< length {
            value = value << 6 | UInt32(string[utf8: offset + i] & 0x3F)
        }
        return (Unicode.Scalar(value) ?? "\u{FFFD}", length)
    }
}

#endif // FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT
