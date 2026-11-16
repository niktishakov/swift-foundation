// Temporary probe, not for the repository: prints a hash of everything the built-in scalar sets return,
// so two builds can be compared. Run with BITMAP_PROBE=1.

import Testing

#if canImport(FoundationEssentials)
@testable import FoundationEssentials
#else
@testable import Foundation
#endif

private struct FNV {
    var value: UInt64 = 0xcbf29ce484222325
    mutating func add(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x100000001b3
    }
    mutating func add(_ data: Data) {
        for byte in data { add(byte) }
    }
}

@Suite("BitmapProbe")
private struct BitmapProbe {
    static let enabled = true

    static let types: [(String, BuiltInUnicodeScalarSet.SetType)] = [
        ("control", .control), ("whitespace", .whitespace), ("whitespaceAndNewline", .whitespaceAndNewline),
        ("decimalDigit", .decimalDigit), ("letter", .letter), ("lowercaseLetter", .lowercaseLetter),
        ("uppercaseLetter", .uppercaseLetter), ("nonBase", .nonBase), ("canonicalDecomposable", .canonicalDecomposable),
        ("alphanumeric", .alphanumeric), ("punctuation", .punctuation), ("illegal", .illegal), ("titlecase", .titlecase),
        ("symbolAndOperator", .symbolAndOperator), ("newline", .newline),
        ("compatibilityDecomposable", .compatibilityDecomposable), ("hfsPlusDecomposable", .hfsPlusDecomposable),
        ("strongRightToLeft", .strongRightToLeft), ("hasNonSelfLowercase", .hasNonSelfLowercase),
        ("hasNonSelfUppercase", .hasNonSelfUppercase), ("hasNonSelfTitlecase", .hasNonSelfTitlecase),
        ("hasNonSelfCaseFolding", .hasNonSelfCaseFolding), ("hasNonSelfMirrorMapping", .hasNonSelfMirrorMapping),
        ("caseIgnorable", .caseIgnorable), ("graphemeExtend", .graphemeExtend),
        ("controlAndFormatter", .controlAndFormatter), ("decomposable", .decomposable),
    ]

    @Test(.enabled(if: enabled)) func builtInSets() {
        for (name, type) in Self.types {
            let set = BuiltInUnicodeScalarSet(type: type)

            var members = FNV()
            var count = 0
            for value in UInt32(0)...0x10FFFF {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let isMember = set.contains(scalar)
                members.add(isMember ? 1 : 0)
                if isMember { count += 1 }
            }
            print("PROBE \(name) contains \(String(members.value, radix: 16)) members=\(count) planes=\(set._numberOfPlanes)")

            for isInverted in [false, true] {
                var planes = FNV()
                var summary = ""
                for plane in 0...16 {
                    let result = set.bitmapResult(forPlane: plane, isInverted: isInverted)
                    let code: UInt8 = switch result { case .bitmapFilled: 1; case .bitmapEmpty: 2; case .bitmapAll: 3 }
                    let hasMember = set.hasMember(inPlane: UInt8(plane), isInverted: isInverted)
                    planes.add(code)
                    planes.add(hasMember ? 1 : 0)
                    planes.add(set.bitmap(forPlane: plane, isInverted: isInverted))
                    summary += "\(code)\(hasMember ? "y" : "n")"
                }
                var representation = FNV()
                let data = set.bitmapRepresentation(isInverted: isInverted)
                representation.add(data)
                print("PROBE \(name) inverted=\(isInverted) planes \(String(planes.value, radix: 16)) \(summary) representation \(String(representation.value, radix: 16)) bytes=\(data.count)")
            }
        }
    }

    @Test(.enabled(if: enabled)) func characterSets() {
        let sets: [(String, CharacterSet)] = [
            ("controlCharacters", .controlCharacters), ("whitespaces", .whitespaces), ("whitespacesAndNewlines", .whitespacesAndNewlines),
            ("decimalDigits", .decimalDigits), ("letters", .letters), ("lowercaseLetters", .lowercaseLetters),
            ("uppercaseLetters", .uppercaseLetters), ("nonBaseCharacters", .nonBaseCharacters), ("alphanumerics", .alphanumerics),
            ("decomposables", .decomposables), ("illegalCharacters", .illegalCharacters), ("punctuationCharacters", .punctuationCharacters),
            ("capitalizedLetters", .capitalizedLetters), ("symbols", .symbols), ("newlines", .newlines),
        ]
        for (name, set) in sets {
            var variants: [(String, CharacterSet)] = [("plain", set), ("inverted", set.inverted)]
            var mutated = set
            mutated.insert(charactersIn: "\u{1F600}"..."\u{1F64F}")
            mutated.remove(charactersIn: "a"..."f")
            variants.append(("mutated", mutated))
            variants.append(("unionDigits", set.union(.decimalDigits)))
            variants.append(("intersectLetters", set.intersection(.letters)))
            variants.append(("subtractLowercase", set.subtracting(.lowercaseLetters)))
            for (variant, value) in variants {
                var members = FNV()
                var count = 0
                for scalarValue in UInt32(0)...0x10FFFF {
                    guard let scalar = Unicode.Scalar(scalarValue) else { continue }
                    let isMember = value.contains(scalar)
                    members.add(isMember ? 1 : 0)
                    if isMember { count += 1 }
                }
                var representation = FNV()
                representation.add(value.bitmapRepresentation)
                var planes = ""
                for plane in UInt8(0)...16 { planes += value.hasMember(inPlane: plane) ? "y" : "n" }
                print("PROBE CharacterSet.\(name) \(variant) contains \(String(members.value, radix: 16)) members=\(count) representation \(String(representation.value, radix: 16)) planes \(planes) isEmpty=\(value.isEmpty)")
            }
        }
    }

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func scalar() -> Unicode.Scalar {
            // Mostly the BMP and plane 1, sometimes any plane.
            let limit: UInt32 = [0x80, 0x3000, 0x10000, 0x20000, 0x110000][below(5)]
            while true {
                if let scalar = Unicode.Scalar(UInt32(next() % UInt64(limit))) { return scalar }
            }
        }
    }

    static let predefined: [CharacterSet] = [
        .controlCharacters, .whitespaces, .whitespacesAndNewlines, .decimalDigits, .letters, .lowercaseLetters,
        .uppercaseLetters, .nonBaseCharacters, .alphanumerics, .decomposables, .illegalCharacters, .punctuationCharacters,
        .capitalizedLetters, .symbols, .newlines,
    ]

    static func randomSet(_ random: inout SplitMix64) -> CharacterSet {
        switch random.below(6) {
        case 0, 1, 2:
            return predefined[random.below(predefined.count)]
        case 3:
            return predefined[random.below(predefined.count)].inverted
        case 4:
            let a = random.scalar(), b = random.scalar()
            return CharacterSet(charactersIn: min(a, b)...max(a, b))
        default:
            var string = ""
            for _ in 0..<(1 + random.below(8)) { string.unicodeScalars.append(random.scalar()) }
            return CharacterSet(charactersIn: string)
        }
    }

    @Test(.enabled(if: enabled)) func randomOperations() {
        var sample: [Unicode.Scalar] = []
        var sampler = SplitMix64(state: 42)
        for _ in 0..<1500 { sample.append(sampler.scalar()) }
        for plane in UInt32(0)...16 {
            for low in [UInt32(0), 1, 0x1F, 0x20, 0x7F, 0x80, 0xFF, 0x100, 0xFFFD, 0xFFFF] {
                if let scalar = Unicode.Scalar(plane << 16 | low) { sample.append(scalar) }
            }
        }

        let sequences = Int(ProcessInfo.processInfo.environment["BITMAP_PROBE_SEQUENCES"] ?? "") ?? 3000
        for sequence in 0..<sequences {
            var random = SplitMix64(state: UInt64(sequence) &* 0x2545F4914F6CDD1D &+ 7)
            var set = Self.predefined[random.below(Self.predefined.count)]
            var log = ""
            for _ in 0..<(1 + random.below(6)) {
                let operation = random.below(9)
                log += "\(operation)"
                switch operation {
                case 0: set.formUnion(Self.randomSet(&random))
                case 1: set.formIntersection(Self.randomSet(&random))
                case 2: set.subtract(Self.randomSet(&random))
                case 3: set.formSymmetricDifference(Self.randomSet(&random))
                case 4: set.invert()
                case 5:
                    let a = random.scalar(), b = random.scalar()
                    set.insert(charactersIn: min(a, b)...max(a, b))
                case 6:
                    let a = random.scalar(), b = random.scalar()
                    set.remove(charactersIn: min(a, b)...max(a, b))
                case 7: set.insert(random.scalar())
                default: set.remove(random.scalar())
                }
            }
            var hash = FNV()
            for scalar in sample { hash.add(set.contains(scalar) ? 1 : 0) }
            for plane in UInt8(0)...16 { hash.add(set.hasMember(inPlane: plane) ? 1 : 0) }
            hash.add(set.isEmpty ? 1 : 0)
            let other = Self.randomSet(&random)
            hash.add(set.isSuperset(of: other) ? 1 : 0)
            hash.add(set.isSubset(of: other) ? 1 : 0)
            hash.add(set.isDisjoint(with: other) ? 1 : 0)
            hash.add(set == other.union(set).intersection(set) ? 1 : 0)
            hash.add(set.bitmapRepresentation)
            print("PROBE random \(sequence) ops=\(log) \(String(hash.value, radix: 16))")
        }
    }
}
