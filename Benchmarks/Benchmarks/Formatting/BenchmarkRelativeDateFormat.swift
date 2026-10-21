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

import Benchmark
import func Benchmark.blackHole

#if os(macOS) && USE_PACKAGE
import FoundationEssentials
import FoundationInternationalization
#else
import Foundation
#endif

// Benchmarks for `Date.AnchoredRelativeFormatStyle`. The default build formats with ICU; pass
// `-Xswiftc -DFOUNDATION_RELATIVE_DATE_FORMAT_SWIFT` to format in Swift, and compare the runs.
func relativeDateFormatBenchmarks() {
    let scaling = Benchmark.Configuration(scalingFactor: .kilo)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    // 2021-06-15 12:00:00 GMT
    let anchor = Date(timeIntervalSinceReferenceDate: 645_451_200)

    // The style formats the anchor relative to its input, so the input is `value` units before the anchor.
    func input(_ component: Calendar.Component, _ value: Int) -> Date {
        calendar.date(byAdding: component, value: -value, to: anchor)!
    }

    func style(_ identifier: String, _ field: Date.RelativeFormatStyle.Field, presentation: Date.RelativeFormatStyle.Presentation = .numeric, capitalizationContext: FormatStyleCapitalizationContext = .unknown) -> Date.AnchoredRelativeFormatStyle {
        Date.AnchoredRelativeFormatStyle(anchor: anchor, allowedFields: [field], presentation: presentation, unitsStyle: .wide, locale: Locale(identifier: identifier), calendar: calendar, capitalizationContext: capitalizationContext)
    }

    let cases: [(name: String, style: Date.AnchoredRelativeFormatStyle, input: Date)] = [
        ("relative-date-format-en-numeric", style("en", .day), input(.day, 3)),
        ("relative-date-format-en-named", style("en", .day, presentation: .named), input(.day, -1)),
        ("relative-date-format-en-capitalized", style("en", .day, presentation: .named, capitalizationContext: .beginningOfSentence), input(.day, -1)),
        ("relative-date-format-ru-grouping", style("ru", .day), input(.day, 12345)),
        ("relative-date-format-hi-grouping", style("hi", .second), input(.second, 1234567)),
        ("relative-date-format-ar-dual", style("ar", .day), input(.day, 2)),
    ]

    for c in cases {
        Benchmark(c.name, configuration: scaling) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(c.style.format(c.input))
            }
        }
    }
}
