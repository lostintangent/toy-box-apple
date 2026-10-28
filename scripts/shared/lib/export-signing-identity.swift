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

guard CommandLine.arguments.count == 4,
      let password = ProcessInfo.processInfo.environment["P12_PASSWORD"], !password.isEmpty else {
    fail("Use a release-secret setup command to export a pinned signing identity.")
}
let fingerprint = CommandLine.arguments[1].uppercased()
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let chainDestination = URL(fileURLWithPath: CommandLine.arguments[3])
guard !FileManager.default.fileExists(atPath: destination.path),
      !FileManager.default.fileExists(atPath: chainDestination.path) else {
    fail("Refusing to overwrite an existing signing export.")
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
var selectedCertificate: SecCertificate?
for identity in identities {
    var certificate: SecCertificate?
    check(SecIdentityCopyCertificate(identity, &certificate), operation: "Reading the public certificate")
    guard let certificate else { fail("The identity has no certificate.") }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
    if digest == fingerprint {
        selected = identity
        selectedCertificate = certificate
        break
    }
}
guard let selected, let selectedCertificate else { fail("The selected signing identity was not found.") }
var trust: SecTrust?
guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else {
    fail("The system could not create its code-signing trust policy.")
}
check(SecTrustCreateWithCertificates(selectedCertificate, policy, &trust),
      operation: "Creating the signing certificate trust")
guard let trust else { fail("The signing certificate has no trust chain.") }
check(SecTrustSetNetworkFetchAllowed(trust, true), operation: "Allowing issuer-chain retrieval")
var trustError: CFError?
guard SecTrustEvaluateWithError(trust, &trustError) else {
    fail("The signing certificate trust chain is invalid: \(trustError.map { CFErrorCopyDescription($0) as String } ?? "unknown error")")
}
guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      certificates.count > 1 else { fail("No issuing certificate was found for the selected identity.") }
let issuerChain = certificates.dropFirst().map { certificate in
    let data = SecCertificateCopyData(certificate) as Data
    return "-----BEGIN CERTIFICATE-----\n"
        + data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        + "\n-----END CERTIFICATE-----\n"
}.joined()
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
    try issuerChain.write(to: chainDestination, atomically: true, encoding: .utf8)
} catch {
    fail("Writing the temporary signing exports failed: \(error.localizedDescription)")
}
