import Foundation
import Security

enum Keychain {
    /// Reads a generic password item from the login keychain.
    static func readGenericPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Fallback path that shells out to /usr/bin/security. Useful when the
    /// unsigned dev binary can't pass the keychain ACL but the user's
    /// terminal already can.
    static func readViaSecurityCLI(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    static func read(service: String) -> Data? {
        // CLI first: /usr/bin/security reads this item without tripping the
        // per-app keychain ACL prompt that SecItemCopyMatching raises for a
        // freshly (ad-hoc) signed app — a prompt that blocks indefinitely
        // when the app runs unattended.
        readViaSecurityCLI(service: service) ?? readGenericPassword(service: service)
    }
}
