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

// Stage 1 of the relative-date-format data pipeline: reads CLDR XML at
// CLDR_PATH and writes RelativeDateFormatData.json (to standard output), the
// input of utils/build-relative-date-format-data.
//
// From each locale in common/main it reads the relative forms of the units
// Foundation formats (`dates/fields/field`) and the parts of `numbers` that
// integer formatting needs. It resolves what the ICU-based formatter resolves when it loads the
// data, so the run-time code only looks values up:
//   - Each value is inherited on its own from the parent chain (CLDR parent
//     locales, else the identifier without its last subtag, then root).
//   - A missing narrow value uses the short one, and a missing short value the
//     wide one, as root's aliases say.
//   - A missing plural category uses `other`.
//   - Patterns are split at `{0}`, with the apostrophe quoting of the ICU-based formatter's
//     SimpleFormatter applied.
//   - Values marked draft="unconfirmed" or "provisional", and `alt` values,
//     are skipped: the ICU-based formatter's data leaves them out.
// A locale is written only if its resolved data differs from its parent's.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Constants

let inheritMarker = "\u{2191}\u{2191}\u{2191}"
let excludedDrafts: Set<String> = ["unconfirmed", "provisional"]

// MARK: - Errors

enum UpdateError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case unexpectedXML(String)
    case badPattern(String, String)

    var description: String {
        switch self {
        case .missingEnvironment(let name): return "\(name) environment variable not set"
        case .unexpectedXML(let detail): return "unexpected XML: \(detail)"
        case .badPattern(let pattern, let detail): return "can't use pattern \"\(pattern)\": \(detail)"
        }
    }
}

// MARK: - Reading XML

/// The values one locale file sets, by a key that names the value.
///
/// Keys: `unit|width|past|category` and `unit|width|future|category` for patterns, `unit|width|named|offset`
/// for
/// names, and `numbers|...` for numbers: `numbers|default`, `numbers|native`, `numbers|traditional`,
/// `numbers|finance`, `numbers|minimumGroupingDigits`, `numbers|group|<system>`, `numbers|decimal|<system>`.
typealias LocaleValues = [String: String]

extension XMLElement {
    /// The element's text, unless it inherits, is an alt value, or is a draft that the data leaves out.
    var usableValue: String? {
        guard attribute(forName: "alt") == nil else { return nil }
        if let draft = attribute(forName: "draft")?.stringValue, excludedDrafts.contains(draft) { return nil }
        guard let text = stringValue, text != inheritMarker else { return nil }
        return text
    }

    func attributeValue(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    func children(_ name: String) -> [XMLElement] { elements(forName: name) }
}

func parseLocale(_ url: URL) throws -> LocaleValues {
    let document = try XMLDocument(contentsOf: url)
    var values: LocaleValues = [:]

    // Relative forms.
    for case let field as XMLElement in try document.nodes(forXPath: "/ldml/dates/fields/field") {
        guard let type = field.attributeValue("type"), field.attributeValue("alt") == nil else { continue }
        let parts = type.split(separator: "-", maxSplits: 1).map(String.init)
        guard relativeDateUnits.contains(parts[0]) else { continue }
        let width: String
        switch parts.count == 1 ? "" : parts[1] {
        case "": width = "wide"
        case "short": width = "short"
        case "narrow": width = "narrow"
        default: continue
        }
        let unit = parts[0]
        for relative in field.children("relative") {
            guard let offset = relative.attributeValue("type"), relativeDateNamedOffsets.contains(offset), let text = relative.usableValue else { continue }
            values["\(unit)|\(width)|named|\(offset)"] = text
        }
        for relativeTime in field.children("relativeTime") {
            guard let direction = relativeTime.attributeValue("type"), direction == "past" || direction == "future" else { continue }
            for pattern in relativeTime.children("relativeTimePattern") {
                guard let category = pattern.attributeValue("count"), let text = pattern.usableValue else { continue }
                guard relativeDatePluralCategories.contains(category) else {
                    throw UpdateError.unexpectedXML("\(url.lastPathComponent): count \(category)")
                }
                values["\(unit)|\(width)|\(direction)|\(category)"] = text
            }
        }
    }

    // Numbers.
    func single(_ path: String, key: String) throws {
        for case let element as XMLElement in try document.nodes(forXPath: path) {
            if let text = element.usableValue { values[key] = text }
        }
    }
    try single("/ldml/numbers/defaultNumberingSystem", key: "numbers|default")
    try single("/ldml/numbers/otherNumberingSystems/native", key: "numbers|native")
    try single("/ldml/numbers/otherNumberingSystems/traditional", key: "numbers|traditional")
    try single("/ldml/numbers/otherNumberingSystems/finance", key: "numbers|finance")
    try single("/ldml/numbers/minimumGroupingDigits", key: "numbers|minimumGroupingDigits")
    for case let symbols as XMLElement in try document.nodes(forXPath: "/ldml/numbers/symbols") {
        guard let system = symbols.attributeValue("numberSystem"), symbols.attributeValue("alt") == nil else { continue }
        for group in symbols.children("group") {
            if let text = group.usableValue { values["numbers|group|\(system)"] = text }
        }
    }
    for case let formats as XMLElement in try document.nodes(forXPath: "/ldml/numbers/decimalFormats") {
        guard let system = formats.attributeValue("numberSystem"), formats.attributeValue("alt") == nil else { continue }
        for length in formats.children("decimalFormatLength") where length.attribute(forName: "type") == nil {
            for format in length.children("decimalFormat") where (format.attributeValue("type") ?? "standard") == "standard" {
                for pattern in format.children("pattern") where pattern.attribute(forName: "type") == nil {
                    if let text = pattern.usableValue { values["numbers|decimal|\(system)"] = text }
                }
            }
        }
    }
    return values
}

/// Checks that root's aliases make narrow fall back to short and short to wide for every unit, which the
/// resolution
/// below assumes.
func checkRootAliases(_ url: URL) throws {
    let document = try XMLDocument(contentsOf: url)
    for unit in relativeDateUnits {
        for (source, target) in [("\(unit)-short", unit), ("\(unit)-narrow", "\(unit)-short")] {
            let nodes = try document.nodes(forXPath: "/ldml/dates/fields/field[@type='\(source)']/alias")
            guard let alias = nodes.first as? XMLElement, alias.attributeValue("path") == "../field[@type='\(target)']" else {
                throw UpdateError.unexpectedXML("root.xml: \(source) doesn't alias \(target)")
            }
        }
    }
}

func loadParentLocales(_ url: URL) throws -> [String: String] {
    let document = try XMLDocument(contentsOf: url)
    var map: [String: String] = [:]
    // Only the block without a `component` applies to these values.
    for case let element as XMLElement in try document.nodes(forXPath: "//parentLocales[not(@component)]/parentLocale") {
        guard let parent = element.attributeValue("parent"), let locales = element.attributeValue("locales") else { continue }
        for child in locales.split(separator: " ") { map[String(child)] = parent }
    }
    return map
}

func loadNumberingSystems(_ url: URL) throws -> [String: String] {
    let document = try XMLDocument(contentsOf: url)
    var systems: [String: String] = [:]
    for case let element as XMLElement in try document.nodes(forXPath: "//numberingSystem[@type='numeric']") {
        guard let id = element.attributeValue("id"), let digits = element.attributeValue("digits") else { continue }
        guard digits.unicodeScalars.count == 10 else { throw UpdateError.unexpectedXML("numbering system \(id) has \(digits.unicodeScalars.count) digits") }
        systems[id] = digits
    }
    return systems
}

/// CLDR's likely subtags, such as `und_US` → `en_Latn_US` and `sr` → `sr_Cyrl_RS`.
func loadLikelySubtags(_ url: URL) throws -> [String: String] {
    let document = try XMLDocument(contentsOf: url)
    var result: [String: String] = [:]
    for case let element as XMLElement in try document.nodes(forXPath: "//likelySubtag") {
        guard let from = element.attributeValue("from"), let to = element.attributeValue("to") else { continue }
        result[from] = to
    }
    return result
}

// The ICU-based formatter uses these languages for a region whose likely language has no data, and English
// for the others.
let countryFallbackSubstitutes = ["pap_Latn_BQ": "nl", "pap_Latn_CW": "nl", "aa_Latn_DJ": "fr", "ht_Latn_HT": "fr", "bi_Latn_VU": "fr"]

/// The regions of `territoryInfo` and `territoryContainment`, such as `US` and `419`.
func loadRegions(_ url: URL) throws -> Set<String> {
    let document = try XMLDocument(contentsOf: url)
    var result = Set<String>()
    for path in ["//territoryInfo/territory", "//territoryContainment/group"] {
        for case let element as XMLElement in try document.nodes(forXPath: path) {
            if let type = element.attributeValue("type") { result.insert(type) }
        }
    }
    return result
}

/// The locale of each region's country fallback: the likely language and script of `und_<region>` (else of
/// `und`)
/// with the region, as the ICU-based formatter opens it, without the script where it's the language's likely
/// script (`sr_Cyrl_RS`
/// opens `sr_RS`).
func regionLocales(regions: Set<String>, likelySubtags: [String: String], languages: Set<String>) -> [String: String] {
    var result: [String: String] = [:]
    for region in regions {
        guard let likely = likelySubtags["und_\(region)"] ?? likelySubtags["und"] else { continue }
        let parts = likely.split(separator: "_").map(String.init)
        guard parts.count == 3 else { continue }
        var language = parts[0]
        let script = parts[1]
        if let substitute = countryFallbackSubstitutes["\(language)_\(script)_\(region)"] {
            language = substitute
        } else if !languages.contains(language) {
            language = "en"
        }
        let defaultScript = likelySubtags[language].map { String($0.split(separator: "_")[1]) }
        result[region] = defaultScript == script ? "\(language)_\(region)" : "\(language)_\(script)_\(region)"
    }
    return result
}

/// Whether the second subtag of `locale`, or the third after a script, is a region.
func hasRegion(_ locale: String) -> Bool {
    let parts = locale.split(separator: "_")
    var index = 1
    if index < parts.count && parts[index].count == 4 { index += 1 }
    guard index < parts.count else { return false }
    let subtag = parts[index]
    return subtag.count == 2 && subtag.allSatisfy(\.isLetter) || subtag.count == 3 && subtag.allSatisfy(\.isNumber)
}

func detectCLDRVersion(_ cldrURL: URL) throws -> String {
    let dtd = try String(contentsOf: cldrURL.appendingPathComponent("common/dtd/ldml.dtd"), encoding: .utf8)
    guard let range = dtd.range(of: #"cldrVersion CDATA #FIXED "[^"]+""#, options: .regularExpression) else {
        throw UpdateError.unexpectedXML("no cldrVersion in common/dtd/ldml.dtd")
    }
    return String(dtd[range].split(separator: "\"")[1])
}

// MARK: - Grouping

/// The literal prefix and suffix and the primary and secondary grouping sizes of a decimal pattern such as
/// `#,##,##0.###`, as the ICU-based formatter reads them. No group separator means no grouping.
func parseDecimalPattern(_ pattern: String) throws -> (prefix: String, suffix: String, primary: Int, secondary: Int) {
    let positive = pattern.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let numberCharacters: Set<Character> = ["#", "0", ",", ".", "@"]
    guard let numberStart = positive.firstIndex(where: numberCharacters.contains),
          let numberEnd = positive.lastIndex(where: numberCharacters.contains) else {
        throw UpdateError.badPattern(pattern, "no digits")
    }
    let prefix = positive[..<numberStart]
    let suffix = positive[positive.index(after: numberEnd)...]
    // Quotes and symbols such as % or ¤ in the affixes would need more affix handling; the data has none.
    for affix in [prefix, suffix] where affix.contains(where: { "'%‰¤-+*".contains($0) }) {
        throw UpdateError.badPattern(pattern, "special characters in an affix")
    }
    let integerPart = positive[numberStart ... numberEnd].prefix { $0 != "." }
    guard integerPart.allSatisfy({ "#0,@".contains($0) }) else {
        throw UpdateError.badPattern(pattern, "unexpected characters in the integer part")
    }
    let groups = integerPart.split(separator: ",", omittingEmptySubsequences: false)
    switch groups.count {
    case 1: return (String(prefix), String(suffix), 0, 0)
    case 2: return (String(prefix), String(suffix), groups[1].count, groups[1].count)
    default: return (String(prefix), String(suffix), groups[groups.count - 1].count, groups[groups.count - 2].count)
    }
}

// MARK: - Resolution

/// The distinct number formats seen so far, in the order they were first seen. Equal formats get the same
/// index.
final class NumberFormatTable {
    private(set) var formats: [RelativeDateFormatDataSchema.NumberFormat] = []
    private var indices: [RelativeDateFormatDataSchema.NumberFormat: Int] = [:]

    func index(of format: RelativeDateFormatDataSchema.NumberFormat) -> Int {
        if let index = indices[format] { return index }
        formats.append(format)
        indices[format] = formats.count - 1
        return formats.count - 1
    }
}

struct Resolver {
    let values: [String: LocaleValues]
    let parents: [String: String]
    let numberFormats = NumberFormatTable()

    func parent(of locale: String) -> String? {
        if locale == "root" { return nil }
        if let explicit = parents[locale] { return explicit }
        if let underscore = locale.lastIndex(of: "_") { return String(locale[..<underscore]) }
        return "root"
    }

    func chain(_ locale: String) -> [String] {
        var result: [String] = []
        var current: String? = locale
        while let l = current {
            result.append(l)
            current = parent(of: l)
        }
        return result
    }

    /// The value for `key` from the first locale in the chain that sets it.
    func value(_ chain: [String], _ key: String) -> String? {
        for locale in chain {
            if let value = values[locale]?[key] { return value }
        }
        return nil
    }

    /// The widths a value of `width` falls back to, from root's aliases.
    func widthChain(_ width: String) -> [String] {
        switch width {
        case "narrow": return ["narrow", "short", "wide"]
        case "short": return ["short", "wide"]
        default: return ["wide"]
        }
    }

    func unitForms(_ chain: [String], unit: String, width: String) throws -> RelativeDateFormatDataSchema.UnitForms {
        func pattern(_ direction: String, _ category: String) -> String? {
            for w in widthChain(width) {
                if let value = value(chain, "\(unit)|\(w)|\(direction)|\(category)") { return value }
            }
            return nil
        }
        func patterns(_ direction: String) throws -> [String: String] {
            guard let other = pattern(direction, "other") else {
                throw UpdateError.unexpectedXML("\(chain[0]) has no \(direction) `other` pattern for \(unit) \(width)")
            }
            // Check now that the build tool can compile every pattern.
            _ = try compilePattern(other)
            var result = ["other": other]
            for category in relativeDatePluralCategories where category != "other" {
                if let text = pattern(direction, category), text != other {
                    _ = try compilePattern(text)
                    result[category] = text
                }
            }
            return result
        }
        var named: [String: String] = [:]
        // Seconds have only the name for 0 ("now"); the ICU-based formatter uses no other second names.
        for offset in relativeDateNamedOffsets where unit != "second" || offset == "0" {
            for w in widthChain(width) {
                if let value = value(chain, "\(unit)|\(w)|named|\(offset)") {
                    named[offset] = value
                    break
                }
            }
        }
        return .init(past: try patterns("past"), future: try patterns("future"), named: named)
    }

    func numbers(_ chain: [String], numberingSystems: [String: String]) throws -> RelativeDateFormatDataSchema.Numbers {
        // UTS #35: native falls back to default, traditional to native, finance to default.
        let defaultSystem = value(chain, "numbers|default") ?? "latn"
        let nativeSystem = value(chain, "numbers|native") ?? defaultSystem
        let traditionalSystem = value(chain, "numbers|traditional") ?? nativeSystem
        let financeSystem = value(chain, "numbers|finance") ?? defaultSystem
        let minimumGroupingText = value(chain, "numbers|minimumGroupingDigits") ?? "1"
        guard let minimumGrouping = Int(minimumGroupingText) else {
            throw UpdateError.unexpectedXML("\(chain[0]) minimumGroupingDigits \(minimumGroupingText)")
        }

        // Each system with its own group separator or decimal pattern in the chain. Other systems use latn's.
        var systems: Set<String> = ["latn"]
        for locale in chain {
            for key in values[locale, default: [:]].keys where key.hasPrefix("numbers|group|") || key.hasPrefix("numbers|decimal|") {
                systems.insert(String(key.split(separator: "|")[2]))
            }
        }
        func format(_ system: String) throws -> RelativeDateFormatDataSchema.NumberFormat {
            let group = value(chain, "numbers|group|\(system)") ?? value(chain, "numbers|group|latn") ?? ","
            let pattern = value(chain, "numbers|decimal|\(system)") ?? value(chain, "numbers|decimal|latn") ?? "#,##0.###"
            let (prefix, suffix, primary, secondary) = try parseDecimalPattern(pattern)
            return .init(prefix: prefix, suffix: suffix, groupSeparator: group, primaryGrouping: primary, secondaryGrouping: secondary)
        }
        let latn = try format("latn")
        var formats = ["latn": numberFormats.index(of: latn)]
        for system in systems.sorted() where system != "latn" && numberingSystems[system] != nil {
            let systemFormat = try format(system)
            if systemFormat != latn { formats[system] = numberFormats.index(of: systemFormat) }
        }
        return .init(
            defaultSystem: defaultSystem,
            nativeSystem: nativeSystem,
            traditionalSystem: traditionalSystem,
            financeSystem: financeSystem,
            minimumGroupingDigits: minimumGrouping,
            formats: formats)
    }

    func resolve(_ locale: String, numberingSystems: [String: String]) throws -> RelativeDateFormatDataSchema.LocaleData {
        let chain = chain(locale)
        var units: [String: [String: RelativeDateFormatDataSchema.UnitForms]] = [:]
        for unit in relativeDateUnits {
            for width in relativeDateWidths {
                units[unit, default: [:]][width] = try unitForms(chain, unit: unit, width: width)
            }
        }
        return .init(units: units, numbers: try numbers(chain, numberingSystems: numberingSystems))
    }
}

// MARK: - Main

@main
struct UpdateRelativeDateFormatData {
    static func main() throws {
        guard let cldrPath = ProcessInfo.processInfo.environment["CLDR_PATH"] else {
            throw UpdateError.missingEnvironment("CLDR_PATH")
        }
        let cldrURL = URL(fileURLWithPath: cldrPath)
        let mainURL = cldrURL.appendingPathComponent("common/main")
        let supplementalURL = cldrURL.appendingPathComponent("common/supplemental")

        try checkRootAliases(mainURL.appendingPathComponent("root.xml"))
        let parents = try loadParentLocales(supplementalURL.appendingPathComponent("supplementalData.xml"))
        let numberingSystems = try loadNumberingSystems(supplementalURL.appendingPathComponent("numberingSystems.xml"))
        let likelySubtags = try loadLikelySubtags(supplementalURL.appendingPathComponent("likelySubtags.xml"))

        var values: [String: LocaleValues] = [:]
        let files = try FileManager.default.contentsOfDirectory(atPath: mainURL.path).filter { $0.hasSuffix(".xml") }.sorted()
        for file in files {
            let locale = String(file.dropLast(4))
            // Alias sources are aliases even where the XML has data, as in the ICU-based formatter.
            guard localeAliases[locale] == nil else { continue }
            values[locale] = try parseLocale(mainURL.appendingPathComponent(file))
        }

        let resolver = Resolver(values: values, parents: parents)
        var resolved: [String: RelativeDateFormatDataSchema.LocaleData] = [:]
        for locale in values.keys.sorted() {
            resolved[locale] = try resolver.resolve(locale, numberingSystems: numberingSystems)
        }
        // Keep only what differs from the parent, which a lookup finds by walking the parent chain.
        var locales: [String: RelativeDateFormatDataSchema.LocaleData] = [:]
        for (locale, data) in resolved {
            guard let parent = resolver.parent(of: locale) else {
                locales[locale] = data
                continue
            }
            let parentData = try resolved[parent] ?? resolver.resolve(parent, numberingSystems: numberingSystems)
            var sparse = RelativeDateFormatDataSchema.LocaleData(units: [:], numbers: data.numbers == parentData.numbers ? nil : data.numbers)
            for (unit, widths) in data.units {
                for (width, forms) in widths where parentData.units[unit]?[width] != forms {
                    sparse.units[unit, default: [:]][width] = forms
                }
            }
            if sparse.numbers != nil || !sparse.units.isEmpty { locales[locale] = sparse }
        }

        // Number the formats the data uses in the order of their JSON, so the output doesn't depend on the
        // order of resolution.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let usedFormats = Set(locales.values.flatMap { $0.numbers?.formats.values.map { $0 } ?? [] })
        let sortedFormats = try usedFormats.map { index in
            (index: index, key: String(decoding: try encoder.encode(resolver.numberFormats.formats[index]), as: UTF8.self))
        }.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        let newIndex = Dictionary(uniqueKeysWithValues: sortedFormats.enumerated().map { ($0.element.index, $0.offset) })
        for (locale, data) in locales {
            guard let numbers = data.numbers else { continue }
            locales[locale]?.numbers = .init(
                defaultSystem: numbers.defaultSystem,
                nativeSystem: numbers.nativeSystem,
                traditionalSystem: numbers.traditionalSystem,
                financeSystem: numbers.financeSystem,
                minimumGroupingDigits: numbers.minimumGroupingDigits,
                formats: numbers.formats.mapValues { newIndex[$0]! })
        }

        var redirects = localeAliases
        for (child, parent) in parents { redirects[child] = parent }

        let version = try detectCLDRVersion(cldrURL)
        let schema = RelativeDateFormatDataSchema(
            generatedFrom: "CLDR \(version)",
            cldrVersion: version,
            redirects: redirects,
            numberingSystems: numberingSystems,
            regionLocales: regionLocales(
                regions: try loadRegions(supplementalURL.appendingPathComponent("supplementalData.xml")),
                likelySubtags: likelySubtags,
                languages: Set(values.keys.filter { !$0.contains("_") })),
            regionalLocales: values.keys.filter(hasRegion).sorted(),
            numberFormats: sortedFormats.map { resolver.numberFormats.formats[$0.index] },
            locales: locales)
        var json = try encoder.encode(schema)
        json.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(json)
        print("  \(values.count) CLDR locales, \(locales.count) written, \(redirects.count) redirects, \(numberingSystems.count) numbering systems", to: &standardError)
    }
}
