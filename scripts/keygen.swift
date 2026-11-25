// Prints a new Ed25519 key pair for signing Driftline updates.
// Line 1: private key (keep secret: goes into the GitHub secret DRIFTLINE_SIGNING_KEY)
// Line 2: public key (goes into Info.plist as DriftlineUpdatePublicKey)
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
