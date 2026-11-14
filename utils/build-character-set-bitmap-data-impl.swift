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

// Packs the bitmap data of the built-in character sets.
//
// The generated CFUniCharBitmapData.inc.h stores each plane of a character set as 8192 bytes: 256 pages of 32 bytes, one bit per character. Most pages are equal to another page, so this tool stores each distinct page once in `__CFUniCharBitmapPages`, and writes each plane as the 256 indexes of its pages in that table. The rest of the header stays the same.
//
// Reads two environment variables (set by the build-character-set-bitmap-data wrapper):
//   - INPUT  : path to the generated CFUniCharBitmapData.inc.h
//   - OUTPUT : path where the packed CFUniCharBitmapData.inc.h is written

import Foundation

let pageByteCount = 32
let pagesPerPlane = 256

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func pack(_ input: String) -> String {
    if input.contains("__CFUniCharBitmapPages") {
        fail("the input is already packed")
    }

    let planePrefix = "static uint8_t const __CFUniChar"
    let planeSuffix = "[] = {"
    var pages: [[UInt8]] = []
    var pageIndexes: [[UInt8]: Int] = [:]
    var planeCount = 0
    var output = ""

    var lines = input.split(separator: "\n", omittingEmptySubsequences: false)[...]
    // The last element is empty when the input ends with a newline.
    if lines.last == "" {
        lines.removeLast()
    }
    while let line = lines.popFirst() {
        guard line.hasPrefix(planePrefix), line.hasSuffix(planeSuffix) else {
            if line.hasPrefix("\t0x") {
                fail("found bytes outside a plane: \(line.prefix(40))")
            }
            // The tables of plane pointers now point to page indexes.
            output += line
                .replacingOccurrences(of: "static uint8_t const * const __CFUniChar", with: "static uint16_t const * const __CFUniChar")
                .replacingOccurrences(of: "(uint8_t const * const)", with: "(uint16_t const * const)") + "\n"
            continue
        }

        let name = line.dropFirst("static uint8_t const ".count).dropLast(planeSuffix.count)
        var data: [UInt8] = []
        while let dataLine = lines.popFirst(), dataLine != "};" {
            for field in dataLine.split(separator: ",") {
                let field = field.trimmingCharacters(in: .whitespaces)
                if field.isEmpty {
                    continue
                }
                guard field.hasPrefix("0x"), let byte = UInt8(field.dropFirst(2), radix: 16) else {
                    fail("unexpected value '\(field)' in \(name)")
                }
                data.append(byte)
            }
        }
        if data.count != pageByteCount * pagesPerPlane {
            fail("\(name) has \(data.count) bytes, expected \(pageByteCount * pagesPerPlane)")
        }

        output += "static uint16_t const \(name)[] = {\n"
        for lineStart in stride(from: 0, to: data.count, by: pageByteCount * 16) {
            let indexes = stride(from: lineStart, to: lineStart + pageByteCount * 16, by: pageByteCount).map { start in
                let page = Array(data[start..<start + pageByteCount])
                if let index = pageIndexes[page] {
                    return index
                }
                pages.append(page)
                pageIndexes[page] = pages.count - 1
                return pages.count - 1
            }
            output += "\t" + indexes.map { "\($0)," }.joined(separator: " ") + "\n"
        }
        output += "};\n"
        planeCount += 1
    }

    if planeCount == 0 {
        fail("the input has no planes")
    }
    if pages.count > Int(UInt16.max) + 1 {
        fail("\(pages.count) distinct pages do not fit a 16-bit index")
    }
    if output.components(separatedBy: "(uint16_t const * const)&").count - 1 != planeCount {
        fail("the tables of plane pointers do not list each of the \(planeCount) planes once")
    }

    output += "\n// Each plane has \(pagesPerPlane) pages of \(pageByteCount) bytes. Equal pages are stored once here; a plane lists the index of each of its pages.\n"
    output += "static uint8_t const __CFUniCharBitmapPages[] = {\n"
    for page in pages {
        output += "\t" + page.map { String(format: "0x%02X,", $0) }.joined(separator: " ") + "\n"
    }
    output += "};\n"

    let before = planeCount * pagesPerPlane * pageByteCount
    let after = pages.count * pageByteCount + planeCount * pagesPerPlane * MemoryLayout<UInt16>.size
    print("Packed \(planeCount) planes into \(pages.count) pages: \(before) bytes -> \(after) bytes")
    return output
}

@main
struct BuildCharacterSetBitmapData {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["INPUT"], let outputPath = environment["OUTPUT"] else {
            fail("INPUT and OUTPUT must be set")
        }
        do {
            let input = try String(contentsOf: URL(fileURLWithPath: inputPath), encoding: .utf8)
            try pack(input).write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        } catch {
            fail("\(error)")
        }
    }
}
