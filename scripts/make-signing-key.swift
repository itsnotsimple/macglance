// Creates the Ed25519 key that signs updates. Run once: swift scripts/make-signing-key.swift
// The private half goes to ~/.config/macglance/update-signing-key (never into the repo);
// the printed public half goes into Updater.swift, so the app can check every download.
import CryptoKit
import Foundation

let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macglance")
let file = folder.appendingPathComponent("update-signing-key")
guard !FileManager.default.fileExists(atPath: file.path) else {
    print("A key already exists at \(file.path); not replacing it (old releases would stop verifying).")
    exit(1)
}
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: file, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)   // only you can read it
print("Private key saved to \(file.path)")
print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
