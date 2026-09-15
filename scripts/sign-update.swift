// Prints the Ed25519 signature (base64) of a file, made with the private update key.
// Usage: swift scripts/sign-update.swift build/MacGlance-0.24.zip
import CryptoKit
import Foundation

let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macglance/update-signing-key")
let keyText = try String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: keyText)!)
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(try key.signature(for: data).base64EncodedString())
