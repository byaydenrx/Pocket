// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

// Ed25519 signing for update DMGs.
//   swift Tools/update-signing.swift keygen <private-key-file>   prints the public key
//   swift Tools/update-signing.swift sign <private-key-file> <file>   writes <file>.sig
//   swift Tools/update-signing.swift verify <public-key-base64> <file>
// Keep the private key out of the repository (default: ~/.config/pocket/update-signing.key).
import CryptoKit
import Foundation

let args = CommandLine.arguments
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
guard args.count >= 3 else { fail("usage: keygen <key> | sign <key> <file> | verify <pubkey> <file>") }

switch args[1] {
case "keygen":
    let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path) { fail("\(url.path) already exists; not overwriting it") }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 4 else { fail("usage: sign <key> <file>") }
    let keyText = (try? String(contentsOfFile: (args[2] as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
    guard let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("can't read the private key") }
    guard let data = FileManager.default.contents(atPath: args[3]) else { fail("can't read \(args[3])") }
    let signature = try key.signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[3] + ".sig"))
    print(args[3] + ".sig")
case "verify":
    guard args.count >= 4, let raw = Data(base64Encoded: args[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let data = FileManager.default.contents(atPath: args[3]),
          let sigText = try? String(contentsOfFile: args[3] + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("bad input") }
    print(key.isValidSignature(sig, for: data) ? "valid" : "INVALID")
    exit(key.isValidSignature(sig, for: data) ? 0 : 1)
default:
    fail("unknown command \(args[1])")
}
