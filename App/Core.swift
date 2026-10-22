import Foundation
import Security
import SwiftUI
import UIKit

// MARK: - Theme (LitEnergy Mini App)

enum Theme {
    static let bg = Color.black
    static let surface = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255)
    static let pill = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)
    static let stroke = Color.white.opacity(0.06)
    static let muted = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)
    static let dim = Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4a / 255)
    static let green = Color(red: 0x34 / 255, green: 0xc7 / 255, blue: 0x59 / 255)
    static let red = Color(red: 1, green: 0x45 / 255, blue: 0x3a / 255)
    static let orange = Color(red: 1, green: 0x9f / 255, blue: 0x0a / 255)
    static let cardRadius: CGFloat = 20
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.white.opacity(enabled ? 1 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Theme.pill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct LogoBadge: View {
    var size: CGFloat = 80
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "bolt.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white))
    }
}

struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 17))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.pill)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.litenergy.studio"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc_fallback_" + key)
        guard let value = value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // some sideloading signers strip keychain entitlements — keep the app usable
            UserDefaults.standard.set(value, forKey: "kc_fallback_" + key)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return String(data: data, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: "kc_fallback_" + key)
    }
}

// MARK: - JSON helpers

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }
    func int(_ key: String) -> Int {
        if let n = self[key] as? NSNumber { return n.intValue }
        return Int(str(key)) ?? 0
    }
    func bool(_ key: String) -> Bool {
        if let n = self[key] as? NSNumber { return n.boolValue }
        return false
    }
    func obj(_ key: String) -> JSON? { self[key] as? JSON }
    func arr(_ key: String) -> [JSON] { (self[key] as? [JSON]) ?? [] }
}

// MARK: - API

struct APIError: LocalizedError {
    let message: String
    var unauthorized = false
    var errorDescription: String? { message }
}

enum API {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = AppState.defaultServer }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Separate session = separate connection pool, used for the one retry after a dropped connection.
    static let fresh: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldUsePipelining = false
        return URLSession(configuration: c)
    }()

    static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return "Сервер недоступен. Проверьте адрес и интернет." }
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed: return "Нет подключения к интернету"
        case .timedOut: return "Сервер долго не отвечает. Попробуйте ещё раз."
        case .networkConnectionLost: return "Связь с сервером прервалась. Попробуйте ещё раз."
        default: return "Сервер недоступен. Проверьте адрес и интернет."
        }
    }

    static func request(_ path: String, method: String = "GET", form: [String: String]? = nil,
                        json: JSON? = nil, server: String, token: String?, timeout: TimeInterval = 20) async throws -> JSON {
        guard let url = URL(string: server + path) else { throw APIError(message: "Неверный адрес сервера") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json = json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form = form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            req.httpBody = form.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }.joined(separator: "&").data(using: .utf8)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .networkConnectionLost {
            // The server closed an idle keep-alive connection just as the request went out.
            // iOS retries GET by itself but not POST, so retry once on a fresh connection.
            do {
                (data, response) = try await Self.fresh.data(for: req)
            } catch {
                throw APIError(message: Self.describe(error))
            }
        } catch {
            throw APIError(message: Self.describe(error))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        if code == 401 && !path.hasPrefix("/api/auth/login") {
            throw APIError(message: "Сессия истекла — войдите снова", unauthorized: true)
        }
        if code >= 400 {
            let msg = obj.str("error").isEmpty ? (obj.str("detail").isEmpty ? "Ошибка сервера (\(code))" : obj.str("detail")) : obj.str("error")
            throw APIError(message: msg)
        }
        return obj
    }
}

// MARK: - App state

enum DockTab: String, CaseIterable {
    case home, crosspost, ai, accounts, more

    var title: String {
        switch self {
        case .home: return "Главная"
        case .crosspost: return "Кросспост"
        case .ai: return "AI-видео"
        case .accounts: return "Аккаунты"
        case .more: return "Ещё"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .crosspost: return "paperplane.fill"
        case .ai: return "wand.and.stars"
        case .accounts: return "person.2.fill"
        case .more: return "square.grid.2x2.fill"
        }
    }
}

enum AccountsSection: String, CaseIterable {
    case tiktok, telegram, vk
    var title: String {
        switch self {
        case .tiktok: return "TikTok"
        case .telegram: return "Telegram"
        case .vk: return "ВКонтакте"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultServer = "http://13.143.165.176:8585"

    @Published var server: String
    @Published var token: String?
    @Published var tab: DockTab = .home
    @Published var accounts: AccountsSection = .tiktok
    @Published var moreWeb: String?          // "videos" / "logs" when opened from «Ещё»
    @Published var notice: String?

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? AppState.defaultServer
        token = Keychain.get("token")
    }

    var isLoggedIn: Bool { token != nil }

    /// Which tab of the web panel corresponds to the current dock state (nil = native screen).
    var webTab: String? {
        switch tab {
        case .home: return nil
        case .crosspost: return "crosspost"
        case .ai: return "aivideo"
        case .accounts: return accounts.rawValue
        case .more: return moreWeb
        }
    }

    func login(server raw: String, password: String) async throws {
        let srv = API.normalize(raw)
        let res = try await API.request("/api/auth/login", method: "POST", json: ["password": password], server: srv, token: nil)
        let tok = res.str("token")
        guard res.bool("ok"), !tok.isEmpty else { throw APIError(message: res.str("error").isEmpty ? "Неверный пароль" : res.str("error")) }
        server = srv
        UserDefaults.standard.set(srv, forKey: "server")
        setToken(tok)
        tab = .home
        moreWeb = nil
    }

    func setToken(_ tok: String?) {
        token = tok
        Keychain.set(tok, for: "token")
        WebStore.shared.attach(server: server, token: tok)
    }

    func logout(message: String? = nil) {
        let srv = server
        let tok = token
        if let tok = tok {
            Task { _ = try? await API.request("/api/auth/logout", method: "POST", server: srv, token: tok) }
        }
        notice = message
        setToken(nil)
    }

    func call(_ path: String, method: String = "GET", form: [String: String]? = nil, json: JSON? = nil) async throws -> JSON {
        do {
            return try await API.request(path, method: method, form: form, json: json, server: server, token: token)
        } catch let e as APIError where e.unauthorized {
            logout(message: e.message)
            throw e
        }
    }

    func mediaURL(_ filename: String) -> URL? {
        URL(string: server + "/uploads/" + (filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename))
    }
}
