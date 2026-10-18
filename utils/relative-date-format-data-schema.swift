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

// Codable schema for RelativeDateFormatData.json, the intermediate form between
// CLDR (read by utils/update-relative-date-format-data) and the Swift tables
// (written by utils/build-relative-date-format-data). Both tools compile this
// file with their own impl.

import Foundation

/// A `TextOutputStream` over standard error, so the tools can use `print(_:to:)` for diagnostics.
internal struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
internal var standardError = StandardError()

/// The units Foundation formats, in the order of the tables.
internal let relativeDateUnits = ["year", "month", "week", "day", "hour", "minute", "second"]

/// The widths, in the order of the tables. CLDR calls them `""`, `-short` and `-narrow`.
internal let relativeDateWidths = ["wide", "short", "narrow"]

/// The plural categories, in the order of the tables.
internal let relativeDatePluralCategories = ["zero", "one", "two", "few", "many", "other"]

/// The offsets that have named forms, such as -1 for "yesterday", in the order of the tables.
internal let relativeDateNamedOffsets = ["-2", "-1", "0", "1", "2"]

internal struct RelativeDateFormatDataSchema: Codable {
    /// Where the data came from, such as "CLDR 48".
    let generatedFrom: String

    /// The CLDR version of the data.
    let cldrVersion: String

    /// Locale aliases and CLDR parent locales: the next locale a lookup tries. Other locales drop their last
    /// subtag, and
    /// single subtags go to root.
    let redirects: [String: String]

    /// The ten digits of each numeric numbering system, such as "0123456789" for `latn`.
    let numberingSystems: [String: String]

    /// For each region, the locale whose number symbols and patterns the ICU path uses for an identifier with
    /// that
    /// region when it has no data of its own for it, such as `ru_RU` for `RU` (its "country fallback"). From
    /// the
    /// likely subtags of `und_<region>`, without the script where it's the language's default. The keys are
    /// also the
    /// regions an `rg` keyword can name.
    let regionLocales: [String: String]

    /// The CLDR locales with a region, such as `ca_FR`. A lookup needs them to know whether an identifier's
    /// region
    /// has data, even where the data equals the parent's.
    let regionalLocales: [String]

    /// The distinct number formats. A locale's numbers name them by index.
    let numberFormats: [NumberFormat]

    /// For each locale, the values that differ from its parent's, with all inheritance resolved. A lookup
    /// walks the
    /// parent chain for each unit and width, and for the numbers, until a locale has them. Root has all of
    /// them.
    let locales: [String: LocaleData]

    internal struct LocaleData: Codable, Equatable {
        /// Unit (`relativeDateUnits`) to width (`relativeDateWidths`) to the forms of that unit.
        var units: [String: [String: UnitForms]]
        var numbers: Numbers?
    }

    /// The patterns and names of one unit in one width.
    internal struct UnitForms: Codable, Hashable {
        /// Plural category to the pattern for past values, such as "{0} days ago", in CLDR's syntax. `other`
        /// is always
        /// there; a missing category uses `other`.
        let past: [String: String]
        /// The same for future values, such as "in {0} days".
        let future: [String: String]
        /// Offset (`relativeDateNamedOffsets`) to a name such as "yesterday", where the locale has one.
        let named: [String: String]
    }

    internal struct Numbers: Codable, Hashable {
        /// The numbering systems for the `numbers` keyword values `default`, `native`, `traditional` and
        /// `finance`,
        /// with the fallbacks of UTS #35 applied.
        let defaultSystem: String
        let nativeSystem: String
        let traditionalSystem: String
        let financeSystem: String
        /// The fewest digits a number needs before it's grouped, counted from the first group separator.
        let minimumGroupingDigits: Int
        /// Numbering system to its grouping, an index into `numberFormats`. `latn` is always there and serves
        /// the others.
        let formats: [String: Int]
    }

    internal struct NumberFormat: Codable, Hashable {
        /// Literal text before and after the digits in the decimal pattern, usually empty.
        let prefix: String
        let suffix: String
        let groupSeparator: String
        /// The size of the group next to the decimal separator, 0 for no grouping.
        let primaryGrouping: Int
        /// The size of the other groups.
        let secondaryGrouping: Int
    }
}

// MARK: - Patterns

/// A pattern split at its `{0}`, with quoting applied.
internal struct CompiledPattern: Hashable {
    let prefix: String
    let suffix: String
    /// Whether the pattern has `{0}`. A pattern without it is the whole output.
    let hasPlaceholder: Bool
}

internal struct PatternError: Error, CustomStringConvertible {
    let pattern: String
    let detail: String
    var description: String { "can't use pattern \"\(pattern)\": \(detail)" }
}

/// Splits a relative time pattern at `{0}`, with the quoting rules of the ICU path's pattern formatter: `''`
/// is
/// an apostrophe, an apostrophe before `{` or `}` starts quoted text up to the next apostrophe, and any other
/// apostrophe is itself.
internal func compilePattern(_ pattern: String) throws -> CompiledPattern {
    let scalars = Array(pattern.unicodeScalars)
    var prefix = String.UnicodeScalarView()
    var suffix = String.UnicodeScalarView()
    var hasPlaceholder = false
    var inQuote = false
    var i = 0
    func append(_ scalar: Unicode.Scalar) {
        if hasPlaceholder { suffix.append(scalar) } else { prefix.append(scalar) }
    }
    while i < scalars.count {
        let c = scalars[i]
        i += 1
        if c == "'" {
            if i < scalars.count && scalars[i] == "'" {
                i += 1
                append("'")
            } else if inQuote {
                inQuote = false
            } else if i < scalars.count && (scalars[i] == "{" || scalars[i] == "}") {
                append(scalars[i])
                i += 1
                inQuote = true
            } else {
                append("'")
            }
        } else if !inQuote && c == "{" {
            guard i + 1 < scalars.count, scalars[i] == "0", scalars[i + 1] == "}" else {
                throw PatternError(pattern: pattern, detail: "only {0} is supported")
            }
            guard !hasPlaceholder else { throw PatternError(pattern: pattern, detail: "more than one {0}") }
            hasPlaceholder = true
            i += 2
        } else {
            append(c)
        }
    }
    return .init(prefix: String(prefix), suffix: String(suffix), hasPlaceholder: hasPlaceholder)
}
