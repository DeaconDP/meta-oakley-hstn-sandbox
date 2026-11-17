/*
 * OpenAIKey - where the OpenAI key for cloud reading comes from, and the settings model around it
 *
 * Lookup order:
 * 1. The Keychain: a key the user pasted in Settings. It wins, so a user can replace a key that
 *    was baked into a build without rebuilding.
 * 2. Info.plist `OpenAIAPIKey`, filled at build time from $(OPENAI_API_KEY) in
 *    Config/Secrets.xcconfig (gitignored; see Config/Base.xcconfig).
 * No key, an empty one, or an unexpanded "$(OPENAI_API_KEY)" (the xcconfig isn't wired) means
 * the cloud path is off and reading stays on the phone.
 *
 * The key is never logged or printed, and OpenAIClient only ever sends it to api.openai.com.
 * Keychain item: generic password, this device only, readable after first unlock (so a Siri
 * "Read this" from the lock screen after a reboot-and-unlock still works).
 */

import Foundation
import Observation
import Security

/// Somewhere a user-supplied key is kept. The Keychain in the app; an in-memory fake in tests.
protocol OpenAIKeyStore: Sendable {
  func readKey() -> String?
  /// False if it couldn't be saved.
  func saveKey(_ key: String) -> Bool
  func deleteKey()
}

enum OpenAIKey {
  static let infoPlistKey = "OpenAIAPIKey"

  /// The key to use: the stored one, then the bundled one. nil when neither is usable.
  static func resolve(store: any OpenAIKeyStore, infoDictionary: [String: Any]?) -> String? {
    if let stored = normalized(store.readKey()) { return stored }
    return bundled(infoDictionary: infoDictionary)
  }

  static func bundled(infoDictionary: [String: Any]?) -> String? {
    normalized(infoDictionary?[infoPlistKey] as? String)
  }

  /// Trims whitespace and newlines (a pasted key often carries one) and rejects placeholders.
  static func normalized(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    // An unexpanded build setting: Info.plist has the key but the xcconfig isn't applied.
    if trimmed.hasPrefix("$(") { return nil }
    return trimmed
  }
}

// MARK: - Keychain

struct KeychainKeyStore: OpenAIKeyStore {
  var service = "com.deaco.hstnbench.openai"
  var account = "api-key"

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func readKey() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func saveKey(_ key: String) -> Bool {
    let data = Data(key.utf8)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var add = baseQuery
    add.merge(update) { _, new in new }
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  func deleteKey() {
    SecItemDelete(baseQuery as CFDictionary)
  }
}

// MARK: - Settings model

/// What Settings shows and TextReader asks: is there a key, and should reading use the cloud.
@MainActor
@Observable
final class CloudReading {
  static let shared = CloudReading()

  /// A key the user pasted is in the Keychain (so Settings offers Remove).
  private(set) var hasStoredKey = false
  /// Some key is usable, stored or bundled.
  private(set) var hasKey = false

  @ObservationIgnored private let store: any OpenAIKeyStore
  @ObservationIgnored private let infoDictionary: [String: Any]?
  @ObservationIgnored private let preferences: A11yPreferences
  /// Read once and after every change, so a Read doesn't touch the Keychain.
  @ObservationIgnored private var key: String?

  init(
    store: any OpenAIKeyStore = KeychainKeyStore(), infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
    preferences: A11yPreferences = .shared
  ) {
    self.store = store
    self.infoDictionary = infoDictionary
    self.preferences = preferences
    reload()
  }

  /// Cloud reading is on: a key, the user hasn't chosen the phone voice, and not under test (unit
  /// and UI tests keep the deterministic on-device path).
  var isEnabled: Bool {
    hasKey && preferences.useNaturalVoice && !LaunchOptions.isAutomatedTest
  }

  /// A client for this read, or nil when the cloud path is off.
  func client() -> OpenAIClient? {
    guard isEnabled, let key else { return nil }
    return OpenAIClient(apiKey: key)
  }

  /// Saves a pasted key. False if it was empty or the Keychain refused it.
  @discardableResult
  func saveKey(_ raw: String) -> Bool {
    guard let key = OpenAIKey.normalized(raw), store.saveKey(key) else { return false }
    reload()
    return true
  }

  func removeKey() {
    store.deleteKey()
    reload()
  }

  private func reload() {
    hasStoredKey = OpenAIKey.normalized(store.readKey()) != nil
    key = OpenAIKey.resolve(store: store, infoDictionary: infoDictionary)
    hasKey = key != nil
  }
}
