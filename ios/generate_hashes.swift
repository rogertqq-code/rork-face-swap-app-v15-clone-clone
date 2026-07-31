#!/usr/bin/env swift
//
//  generate_hashes.swift
//  ONE-TIME LOCAL GENERATOR FOR THE OFFLINE BETA GATE
//
//  SECURITY WARNING
//  - Run this locally before production using the provided valid_codes.txt file.
//  - The generated EmbeddedCodeHashes.swift contains ONLY Argon2id PHC hashes.
//  - After generation and verification, delete this script and valid_codes.txt from
//    any distributable/source-control copy. The app target must never ship plaintext
//    beta codes.
//  - The reusable owner/admin override code is hashed here as protected material and
//    is not added to the one-time beta-code list.
//
//  RUNNING THIS SCRIPT
//  This file imports SwiftArgon2. The app already declares that package dependency.
//  If `swift ios/generate_hashes.swift` cannot resolve the package on your machine,
//  copy this file into a tiny Swift Package executable target with:
//      .package(url: "https://github.com/mimiclone/argon2-swift.git", from: "1.0.4")
//  and product dependency:
//      .product(name: "SwiftArgon2", package: "argon2-swift")
//
//  Expected input path from the ios folder:
//      valid_codes.txt
//  Output path:
//      FaceSwapLiveApp/Gatekeeper/EmbeddedCodeHashes.swift
//

import CryptoKit
import Foundation
import Security
import SwiftArgon2

private enum GeneratorError: Error, CustomStringConvertible {
    case inputFileMissing(String)
    case invalidCode(line: Int, value: String)
    case wrongCodeCount(actual: Int)
    case duplicateCodes
    case randomFailure(OSStatus)
    case outputEncodingFailed

    var description: String {
        switch self {
        case .inputFileMissing(let path):
            return "Missing input file: \(path)"
        case .invalidCode(let line, let value):
            return "Invalid code at line \(line): \(value). Every code must be exactly six numeric digits."
        case .wrongCodeCount(let actual):
            return "Expected exactly 1,000 codes, found \(actual)."
        case .duplicateCodes:
            return "valid_codes.txt contains duplicate codes."
        case .randomFailure(let status):
            return "SecRandomCopyBytes failed with status \(status)."
        case .outputEncodingFailed:
            return "Could not build generated Swift output."
        }
    }
}

private struct GeneratedAccessMaterial {
    let betaHashes: [String]
    let masterOverrideHash: String
}

private let betaCodeCount: Int = 1_000
private let masterOverrideCode: String = "323207"
private let inputPath: String = CommandLine.arguments.dropFirst().first ?? "valid_codes.txt"
private let outputPath: String = CommandLine.arguments.dropFirst(2).first ?? "FaceSwapLiveApp/Gatekeeper/EmbeddedCodeHashes.swift"

private let argon2Params = Argon2Params(
    parallelism: 2,
    tagLength: 32,
    memorySize: 4_096,
    iterations: 3,
    variant: .argon2id
)

private func readCodes(from path: String) throws -> [String] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw GeneratorError.inputFileMissing(path)
    }

    let raw = try String(contentsOfFile: path, encoding: .utf8)
    let lines = raw
        .split(whereSeparator: \Character.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    for (zeroBasedIndex, code) in lines.enumerated() {
        let isSixDigits = code.count == 6 && code.allSatisfy(\.isNumber)
        guard isSixDigits else {
            throw GeneratorError.invalidCode(line: zeroBasedIndex + 1, value: code)
        }
    }

    guard lines.count == betaCodeCount else {
        throw GeneratorError.wrongCodeCount(actual: lines.count)
    }

    guard Set(lines).count == betaCodeCount else {
        throw GeneratorError.duplicateCodes
    }

    return lines
}

private func randomSalt(byteCount: Int = 16) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    guard status == errSecSuccess else {
        throw GeneratorError.randomFailure(status)
    }
    return Data(bytes)
}

private func computeArgon2idPHC(for code: String, using argon2: Argon2) async throws -> String {
    let password = Data(code.utf8)
    let salt = try randomSalt()
    return try await argon2.computeEncoded(password: password, salt: salt)
}

private func generateMaterial(from codes: [String]) async throws -> GeneratedAccessMaterial {
    let argon2 = try Argon2(params: argon2Params)
    var hashes: [String] = []
    hashes.reserveCapacity(codes.count)

    for (index, code) in codes.enumerated() {
        let hash = try await computeArgon2idPHC(for: code, using: argon2)
        hashes.append(hash)
        if (index + 1) % 50 == 0 {
            print("Hashed \(index + 1)/\(codes.count) beta codes")
        }
    }

    let masterHash = try await computeArgon2idPHC(for: masterOverrideCode, using: argon2)
    return GeneratedAccessMaterial(betaHashes: hashes, masterOverrideHash: masterHash)
}

private func swiftStringLiteral(_ value: String) -> String {
    String(reflecting: value)
}

private func buildOutput(material: GeneratedAccessMaterial) throws -> String {
    guard material.betaHashes.count == betaCodeCount else {
        throw GeneratorError.wrongCodeCount(actual: material.betaHashes.count)
    }

    let betaBody = material.betaHashes
        .map { "        \(swiftStringLiteral($0))," }
        .joined(separator: "\n")

    return """
    import Foundation

    /// Auto-generated offline access material. Do not edit by hand.
    ///
    /// This file contains only Argon2id PHC hashes derived from the authorized
    /// one-time beta codes plus a reusable protected owner/admin override hash.
    /// It contains no plaintext beta codes.
    nonisolated enum EmbeddedCodeHashes {
        static let expectedBetaCodeCount: Int = 1_000
        static let isPlaceholder: Bool = false

        /// Exactly 1,000 one-time beta access-code hashes, generated from valid_codes.txt.
        static let betaHashes: [String] = [
    \(betaBody)
        ]

        /// Protected reusable owner/admin override hash for the configured master code.
        /// This hash grants access without burning any beta-code slot.
        static let masterOverrideHash: String = \(swiftStringLiteral(material.masterOverrideHash))
    }
    """
}

private func writeOutput(_ content: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

@main
private enum GatekeeperHashGenerator {
    static func main() async {
        do {
            print("Reading exactly 1,000 beta codes from \(inputPath)")
            let codes = try readCodes(from: inputPath)
            print("Computing Argon2id hashes. This is intentionally memory-hard and may take several minutes.")
            let material = try await generateMaterial(from: codes)
            let output = try buildOutput(material: material)
            try writeOutput(output, to: outputPath)
            print("Generated \(outputPath)")
            print("IMPORTANT: verify the app builds, then delete generate_hashes.swift and valid_codes.txt from any production/source-control copy.")
        } catch {
            FileHandle.standardError.write(Data("Generation failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
