import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, operation: String) {
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        fail("\(operation): \(message)")
    }
}

guard CommandLine.arguments.count == 3,
      let password = ProcessInfo.processInfo.environment["P12_PASSWORD"], !password.isEmpty else {
    fail("Use setup-release-secrets to export a pinned signing identity.")
}
let fingerprint = CommandLine.arguments[1].uppercased()
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: destination.path) else {
    fail("Refusing to overwrite an existing identity export.")
}
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
var result: CFTypeRef?
check(SecItemCopyMatching(query as CFDictionary, &result), operation: "Finding signing identities")
guard let identities = result as? [SecIdentity] else { fail("No signing identities found.") }
var selected: SecIdentity?
for identity in identities {
    var certificate: SecCertificate?
    check(SecIdentityCopyCertificate(identity, &certificate), operation: "Reading the public certificate")
    guard let certificate else { fail("The identity has no certificate.") }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
    if digest == fingerprint { selected = identity; break }
}
guard let selected else { fail("The pinned signing identity was not found.") }
let passphrase = password as CFString
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(passphrase)
var exported: CFData?
let status = withExtendedLifetime(passphrase) {
    SecItemExport(selected, .formatPKCS12, [], &parameters, &exported)
}
check(status, operation: "Exporting the pinned identity")
guard let exported else { fail("Identity export returned no data.") }
do {
    try (exported as Data).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
} catch {
    fail("Writing the temporary encrypted identity failed: \(error.localizedDescription)")
}
