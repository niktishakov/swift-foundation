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

// Stage 2 of the relative-date-format data pipeline: reads
// RelativeDateFormatData.json and writes RelativeDateFormatData.swift for the
// _FoundationInternationalizationData library.
//
// Reads four environment variables (set by the build-relative-date-format-data wrapper):
//   - INPUT        : path to RelativeDateFormatData.json
//   - OUTPUT_SWIFT : path where RelativeDateFormatData.swift is written
//   - LOCALES      : comma-separated locale list ("" = include all)
//   - FALLBACK     : locale whose data a lookup uses when the identifier's language has no data (default:
//     "root")
//
// With LOCALES, the data keeps each listed locale and every locale its lookup
// reaches (redirects, then the identifier without its last subtag), plus root
// and the fallback.
//
// The tables are `static let` constants on an enum, so the compiler places
// them in read-only data with no initializer at load time. Each table is one
// column of integers (a row is the same index in the columns of a group), and
// the strings are one string literal. Array literals of tuples or structs, and
// a 113,076-element byte array, made the compiler use about 10 GB for this file.

import Foundation

struct Options {
    let inputPath: String
    let outputSwiftPath: String
    let requestedLocales: [String]? // nil = include all locales
    let fallback: String
}

func readOptions() -> Options {
    let environment = ProcessInfo.processInfo.environment
    guard let inputPath = environment["INPUT"], !inputPath.isEmpty else { fatalError("INPUT environment variable not set") }
    guard let outputSwiftPath = environment["OUTPUT_SWIFT"], !outputSwiftPath.isEmpty else { fatalError("OUTPUT_SWIFT environment variable not set") }
    let locales = environment["LOCALES"] ?? ""
    return Options(
        inputPath: inputPath,
        outputSwiftPath: outputSwiftPath,
        requestedLocales: locales.isEmpty ? nil : locales.split(separator: ",").map { $0.replacingOccurrences(of: "-", with: "_") },
        fallback: environment["FALLBACK"] ?? "root")
}

// MARK: - Packing

/// Strings in one UTF-8 pool, each stored once. String 0 is the empty string, which also means "no name".
struct StringPool {
    var bytes: [UInt8] = []
    var offsets: [Int] = [0]
    var index: [String: Int] = [:]

    init() { _ = add("") }

    mutating func add(_ string: String) -> Int {
        if let existing = index[string] { return existing }
        bytes += Array(string.utf8)
        offsets.append(bytes.count)
        index[string] = offsets.count - 2
        return offsets.count - 2
    }
}

/// Unique rows of a table, in the order they were first added.
struct Table<Row: Hashable> {
    var rows: [Row] = []
    var index: [Row: Int] = [:]

    mutating func add(_ row: Row) -> Int {
        if let existing = index[row] { return existing }
        rows.append(row)
        index[row] = rows.count - 1
        return rows.count - 1
    }
}

struct PatternRow: Hashable { var prefix: Int; var suffix: Int; var hasPlaceholder: Bool }
struct PatternSetRow: Hashable { var patterns: [Int] } // one per category, in `relativeDatePluralCategories` order
struct NameSetRow: Hashable { var names: [Int] } // one per offset, in `relativeDateNamedOffsets` order
struct UnitFormsRow: Hashable { var past: Int; var future: Int; var names: Int }
struct SlotRow: Hashable { var unit: Int; var width: Int; var forms: Int }
struct NumberFormatRow: Hashable { var system: Int; var prefix: Int; var suffix: Int; var groupSeparator: Int; var primary: Int; var secondary: Int }
struct NumbersRow: Hashable { var defaultSystem: Int; var nativeSystem: Int; var traditionalSystem: Int; var financeSystem: Int; var minimumGrouping: Int; var formatStart: Int; var formatEnd: Int }
struct LocaleRow { var id: Int; var slotStart: Int; var slotEnd: Int; var numbers: Int? }

struct PackedData {
    var strings = StringPool()
    var patterns = Table<PatternRow>()
    var patternSets = Table<PatternSetRow>()
    var nameSets = Table<NameSetRow>()
    var unitForms = Table<UnitFormsRow>()
    var slots: [SlotRow] = []
    var numberFormats: [NumberFormatRow] = []
    var numbers = Table<NumbersRow>()
    var locales: [LocaleRow] = []
    var localeNames: [String] = []
    var redirects: [(from: Int, to: Int, fromName: String)] = []
    var numberingSystems: [(id: Int, digits: Int)] = []
    var regionLocales: [(region: Int, locale: Int, regionName: String)] = []
    var fallbackLocale = 0
}

func utf8Order(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

/// The next locale a lookup tries, as the run-time lookup does it.
func parent(of locale: String, redirects: [String: String]) -> String? {
    if locale == "root" { return nil }
    if let redirect = redirects[locale] { return redirect }
    if let underscore = locale.lastIndex(of: "_") { return String(locale[..<underscore]) }
    return "root"
}

func pack(_ data: RelativeDateFormatDataSchema, options: Options) throws -> (PackedData, keptLocales: [String]) {
    // Keep what a lookup of a requested locale reaches, plus root and the fallback.
    var kept = Set<String>()
    var keptRedirects = Set<String>()
    if let requested = options.requestedLocales {
        for locale in requested + ["root", options.fallback] {
            var current: String? = locale
            var seen = Set<String>()
            while let l = current, seen.insert(l).inserted {
                if data.locales[l] != nil { kept.insert(l) }
                if data.redirects[l] != nil { keptRedirects.insert(l) }
                current = parent(of: l, redirects: data.redirects)
            }
        }
    } else {
        kept = Set(data.locales.keys)
        keptRedirects = Set(data.redirects.keys)
    }
    guard kept.contains("root") else { throw PatternError(pattern: "", detail: "the data has no root") }

    // Regional locales without data of their own still get an entry, so a lookup knows that the region has
    // data.
    var regionalKept = Set<String>()
    let requestedChains: Set<String>? = options.requestedLocales.map { requested in
        var result = Set<String>()
        for locale in requested + [options.fallback] {
            var current: String? = locale
            while let l = current, result.insert(l).inserted { current = parent(of: l, redirects: data.redirects) }
        }
        return result
    }
    for locale in data.regionalLocales where data.locales[locale] == nil && requestedChains?.contains(locale) ?? true {
        regionalKept.insert(locale)
    }

    var packed = PackedData()
    func addPattern(_ text: String) throws -> Int {
        let compiled = try compilePattern(text)
        return packed.patterns.add(PatternRow(prefix: packed.strings.add(compiled.prefix), suffix: packed.strings.add(compiled.suffix), hasPlaceholder: compiled.hasPlaceholder))
    }
    func addPatternSet(_ patterns: [String: String]) throws -> Int {
        guard let other = patterns["other"] else { throw PatternError(pattern: "", detail: "no other pattern") }
        var row: [Int] = []
        for category in relativeDatePluralCategories {
            row.append(try addPattern(patterns[category] ?? other))
        }
        return packed.patternSets.add(PatternSetRow(patterns: row))
    }

    packed.localeNames = kept.union(regionalKept).sorted(by: utf8Order)
    for locale in packed.localeNames {
        let localeData = data.locales[locale] ?? RelativeDateFormatDataSchema.LocaleData(units: [:], numbers: nil)
        let slotStart = packed.slots.count
        for (unitIndex, unit) in relativeDateUnits.enumerated() {
            for (widthIndex, width) in relativeDateWidths.enumerated() {
                guard let forms = localeData.units[unit]?[width] else { continue }
                let names = NameSetRow(names: relativeDateNamedOffsets.map { packed.strings.add(forms.named[$0] ?? "") })
                let row = UnitFormsRow(past: try addPatternSet(forms.past), future: try addPatternSet(forms.future), names: packed.nameSets.add(names))
                packed.slots.append(SlotRow(unit: unitIndex, width: widthIndex, forms: packed.unitForms.add(row)))
            }
        }
        var numbersIndex: Int?
        if let numbers = localeData.numbers {
            // latn first; the others follow in name order.
            let systems = ["latn"] + numbers.formats.keys.filter { $0 != "latn" }.sorted(by: utf8Order)
            let formatRows = systems.map { system -> NumberFormatRow in
                let format = data.numberFormats[numbers.formats[system]!]
                return NumberFormatRow(system: packed.strings.add(system), prefix: packed.strings.add(format.prefix), suffix: packed.strings.add(format.suffix),
                                       groupSeparator: packed.strings.add(format.groupSeparator), primary: format.primaryGrouping, secondary: format.secondaryGrouping)
            }
            // Share an equal run of formats with an earlier locale.
            var formatStart = packed.numberFormats.count
            if let existing = (0 ... max(0, packed.numberFormats.count - formatRows.count)).first(where: { start in
                start + formatRows.count <= packed.numberFormats.count && Array(packed.numberFormats[start ..< start + formatRows.count]) == formatRows
            }) {
                formatStart = existing
            } else {
                packed.numberFormats += formatRows
            }
            numbersIndex = packed.numbers.add(NumbersRow(
                defaultSystem: packed.strings.add(numbers.defaultSystem),
                nativeSystem: packed.strings.add(numbers.nativeSystem),
                traditionalSystem: packed.strings.add(numbers.traditionalSystem),
                financeSystem: packed.strings.add(numbers.financeSystem),
                minimumGrouping: numbers.minimumGroupingDigits,
                formatStart: formatStart,
                formatEnd: formatStart + formatRows.count))
        }
        packed.locales.append(LocaleRow(id: packed.strings.add(locale), slotStart: slotStart, slotEnd: packed.slots.count, numbers: numbersIndex))
    }
    guard let root = locale(packed, "root"), root.numbers != nil, root.slotEnd - root.slotStart == relativeDateUnits.count * relativeDateWidths.count else {
        throw PatternError(pattern: "", detail: "root doesn't have every value")
    }

    for from in keptRedirects.sorted(by: utf8Order) {
        packed.redirects.append((packed.strings.add(from), packed.strings.add(data.redirects[from]!), from))
    }
    // Each region's country fallback.
    func dataLocale(_ identifier: String) -> String? {
        var current: String? = identifier
        while let l = current {
            if kept.contains(l) { return l }
            current = parent(of: l, redirects: data.redirects)
        }
        return nil
    }
    for region in data.regionLocales.keys.sorted(by: utf8Order) {
        let target = data.regionLocales[region]!
        // Keep every region, since the table also says which regions are valid.
        _ = dataLocale(target)
        packed.regionLocales.append((packed.strings.add(region), packed.strings.add(target), region))
    }
    for id in data.numberingSystems.keys.sorted(by: utf8Order) {
        packed.numberingSystems.append((packed.strings.add(id), packed.strings.add(data.numberingSystems[id]!)))
    }

    // The fallback is the first kept locale on its own lookup path.
    var current: String? = options.fallback
    while let l = current {
        if let index = packed.localeNames.firstIndex(of: l) {
            packed.fallbackLocale = index
            break
        }
        current = parent(of: l, redirects: data.redirects)
    }

    precondition(packed.strings.offsets.count <= Int(UInt16.max) && packed.patterns.rows.count <= Int(UInt16.max)
        && packed.patternSets.rows.count <= Int(UInt16.max) && packed.unitForms.rows.count <= Int(UInt16.max)
        && packed.slots.count <= Int(UInt16.max) && packed.numberFormats.count <= Int(UInt16.max), "tables too large for UInt16 indexes")
    return (packed, options.requestedLocales == nil ? [] : packed.localeNames)
}

func locale(_ packed: PackedData, _ name: String) -> LocaleRow? {
    packed.localeNames.firstIndex(of: name).map { packed.locales[$0] }
}

// MARK: - Rendering

/// The string pool as a Swift string literal: a multi-line literal whose lines end with `\`, so it has no
/// line breaks
/// of its own. Characters that are invisible or special in a literal are escaped.
func stringPoolLiteral(_ bytes: [UInt8]) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    precondition(Array(text.utf8) == bytes, "the string pool isn't valid UTF-8")
    var out = "\"\"\"\n"
    var lineBytes = 0
    for scalar in text.unicodeScalars {
        let piece: String
        switch scalar {
        case "\\": piece = "\\\\"
        case "\"": piece = "\\\""
        default:
            let category = scalar.properties.generalCategory
            let invisible: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate]
            if invisible.contains(category) || (category == .spaceSeparator && scalar != " ") {
                piece = "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                piece = String(scalar)
            }
        }
        out += piece
        lineBytes += piece.utf8.count
        // Break lines between characters; a space before the break would be easy to lose, so break after
        // other characters.
        if lineBytes >= 100 && scalar != " " && scalar.properties.generalCategory != .nonspacingMark {
            out += "\\\n"
            lineBytes = 0
        }
    }
    out += "\n\"\"\""
    return out
}

func renderSwift(_ packed: PackedData, data: RelativeDateFormatDataSchema, keptLocales: [String], fallback: String) -> String {
    var out = """
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
    // Generated by utils/build-relative-date-format-data — do not edit by hand.
    // CLDR version: \(data.cldrVersion)
    // Locales: \(keptLocales.isEmpty ? "all" : keptLocales.joined(separator: ","))
    // Fallback: \(fallback)
    //===----------------------------------------------------------------------===//

    #if FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT

    // Each table is one column of integers, and a row is the same index in the
    // columns of a group. Strings are indexes into the string pool.
    internal enum RelativeDateFormatData {
        // The locale (an index into the locale columns) a lookup uses when the identifier's language has no
        // data.
        internal static let fallbackLocale: UInt16 = \(packed.fallbackLocale)


    """
    func emit<T>(_ name: String, _ type: String, _ values: [T], _ comment: String) {
        out += "    // \(comment)\n"
        out += "    internal static let \(name): InlineArray<\(values.count), \(type)> = [\n"
        for chunk in stride(from: 0, to: values.count, by: 16) {
            out += "        " + values[chunk ..< min(chunk + 16, values.count)].map { "\($0)," }.joined(separator: " ") + "\n"
        }
        out += "    ]\n\n"
    }

    out += "    // String pool, UTF-8. String `i` is the bytes from `stringOffsets[i]` up to `stringOffsets[i + 1]`; string 0 is empty.\n"
    out += "    // A string literal, read through its pointer: it compiles fast and reading it doesn't copy it.\n"
    out += "    internal static let stringPool: StaticString = \(stringPoolLiteral(packed.strings.bytes))\n\n"
    emit("stringOffsets", "UInt32", packed.strings.offsets, "Where each string starts in `stringPool`, and where the last one ends.")

    let patterns = packed.patterns.rows
    emit("patternPrefix", "UInt16", patterns.map(\.prefix), "Patterns such as \"in {0} days\": the text before `{0}`,")
    emit("patternSuffix", "UInt16", patterns.map(\.suffix), "the text after it,")
    emit("patternHasPlaceholder", "Bool", patterns.map(\.hasPlaceholder), "and whether there is a `{0}`. Without one, the prefix is the whole output.")

    emit("patternSets", "UInt16", packed.patternSets.rows.flatMap(\.patterns), "Six patterns per set (indexes into the pattern columns), one per plural category: zero, one, two, few, many, other.")
    emit("nameSets", "UInt16", packed.nameSets.rows.flatMap(\.names), "Five names per set (strings, 0 for none), for the offsets -2, -1, 0, 1 and 2, such as \"yesterday\" for -1.")

    let forms = packed.unitForms.rows
    emit("unitFormsPast", "UInt16", forms.map(\.past), "The forms of one unit in one width: past patterns (a set index),")
    emit("unitFormsFuture", "UInt16", forms.map(\.future), "future patterns (a set index),")
    emit("unitFormsNames", "UInt16", forms.map(\.names), "and names (a name set index).")

    emit("slotUnit", "UInt8", packed.slots.map(\.unit), "The units and widths each locale sets: the unit (in `RelativeDateUnit` order),")
    emit("slotWidth", "UInt8", packed.slots.map(\.width), "the width (in `RelativeDateWidth` order),")
    emit("slotForms", "UInt16", packed.slots.map(\.forms), "and the forms (an index into the unit form columns).")

    let formats = packed.numberFormats
    emit("numberFormatSystem", "UInt16", formats.map(\.system), "The grouping of a numbering system: the system's name (a string), each locale's run starting with latn,")
    emit("numberFormatPrefix", "UInt16", formats.map(\.prefix), "the text before the digits,")
    emit("numberFormatSuffix", "UInt16", formats.map(\.suffix), "the text after them,")
    emit("numberFormatGroupSeparator", "UInt16", formats.map(\.groupSeparator), "the group separator,")
    emit("numberFormatPrimaryGrouping", "UInt8", formats.map(\.primary), "the size of the group next to the decimal separator (0 for no grouping),")
    emit("numberFormatSecondaryGrouping", "UInt8", formats.map(\.secondary), "and the size of the other groups.")

    let numbers = packed.numbers.rows
    emit("numbersDefaultSystem", "UInt16", numbers.map(\.defaultSystem), "A locale's numbers: the numbering systems (strings) for default,")
    emit("numbersNativeSystem", "UInt16", numbers.map(\.nativeSystem), "native,")
    emit("numbersTraditionalSystem", "UInt16", numbers.map(\.traditionalSystem), "traditional,")
    emit("numbersFinanceSystem", "UInt16", numbers.map(\.financeSystem), "and finance,")
    emit("numbersMinimumGroupingDigits", "UInt8", numbers.map(\.minimumGrouping), "the minimum grouping digits,")
    emit("numbersFormatStart", "UInt16", numbers.map(\.formatStart), "and the run of number format rows.")
    emit("numbersFormatEnd", "UInt16", numbers.map(\.formatEnd), "")

    let locales = packed.locales
    emit("localeID", "UInt16", locales.map(\.id), "Locales, sorted by identifier for binary search: the identifier (a string),")
    emit("localeSlotStart", "UInt16", locales.map(\.slotStart), "the run of slots it sets,")
    emit("localeSlotEnd", "UInt16", locales.map(\.slotEnd), "")
    emit("localeHasNumbers", "Bool", locales.map { $0.numbers != nil }, "whether it sets numbers,")
    emit("localeNumbers", "UInt16", locales.map { $0.numbers ?? 0 }, "and which (an index into the numbers columns).")

    emit("redirectFrom", "UInt16", packed.redirects.map(\.from), "Locale aliases and CLDR parent locales, sorted by source identifier: the source,")
    emit("redirectTo", "UInt16", packed.redirects.map(\.to), "and the next locale to try.")

    emit("regionLocaleRegion", "UInt16", packed.regionLocales.map(\.region), "Each region's country fallback, sorted by region: the region (also the regions an `rg` keyword can name),")
    emit("regionLocaleLocale", "UInt16", packed.regionLocales.map(\.locale), "and its locale.")

    emit("numberingSystemID", "UInt16", packed.numberingSystems.map(\.id), "Numeric numbering systems, sorted by name: the name,")
    emit("numberingSystemDigits", "UInt16", packed.numberingSystems.map(\.digits), "and the ten digits.")
    out.removeLast()
    out += "}\n\n#endif // FOUNDATION_RELATIVE_DATE_FORMAT_SWIFT\n"
    return out
}

@main
struct BuildRelativeDateFormatData {
    static func main() throws {
        let options = readOptions()
        let data = try JSONDecoder().decode(RelativeDateFormatDataSchema.self, from: Data(contentsOf: URL(fileURLWithPath: options.inputPath)))
        let (packed, keptLocales) = try pack(data, options: options)
        try renderSwift(packed, data: data, keptLocales: keptLocales, fallback: options.fallback)
            .write(toFile: options.outputSwiftPath, atomically: true, encoding: .utf8)
        print("  \(packed.locales.count) locales, \(packed.slots.count) slots, \(packed.unitForms.rows.count) unit forms, \(packed.patterns.rows.count) patterns, \(packed.strings.offsets.count - 1) strings (\(packed.strings.bytes.count) bytes), \(packed.redirects.count) redirects", to: &standardError)
    }
}
