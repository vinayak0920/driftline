// Signs a file with the private key in $DRIFTLINE_SIGNING_KEY and writes <file>.sig
// Usage: DRIFTLINE_SIGNING_KEY=... swift scripts/sign-update.swift build/Driftline.zip
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: sign-update.swift <file>\n".data(using: .utf8)!)
    exit(2)
}
guard let b64 = ProcessInfo.processInfo.environment["DRIFTLINE_SIGNING_KEY"],
      let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write("DRIFTLINE_SIGNING_KEY is missing or invalid\n".data(using: .utf8)!)
    exit(1)
}
let path = CommandLine.arguments[1]
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let signature = try key.signature(for: data)
guard key.publicKey.isValidSignature(signature, for: data) else { exit(1) }
try signature.write(to: URL(fileURLWithPath: path + ".sig"))
print("Signed \(path) → \(path).sig")
