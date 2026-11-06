import Foundation
import Security
import UIKit

// MARK: - Service credentials

struct ServiceConfig: Sendable { var url: String; var token: String; var consent: Bool }

struct CredentialStore {
    private let service = "cn.littlebear.tutor.ipad"
    func load() -> ServiceConfig {
        let defaults = UserDefaults.standard
        return ServiceConfig(url: defaults.string(forKey: "tutor.service.url") ?? "", token: keychainRead() ?? "",
                             consent: defaults.bool(forKey: "tutor.service.consent"))
    }
    func save(url: String, token: String, consent: Bool) throws {
        UserDefaults.standard.set(url, forKey: "tutor.service.url")
        UserDefaults.standard.set(consent, forKey: "tutor.service.consent")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "device-token", kSecValueData as String: Data(token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw TutorError.invalidConfiguration }
    }
    func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "device-token"]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "tutor.service.url")
        UserDefaults.standard.removeObject(forKey: "tutor.service.consent")
    }
    private func keychainRead() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "device-token", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Photos

/// Stores homework photos as gateway-ready JPEGs (≤ 1.9 MB) under Application Support/photos, referenced by file name.
struct PhotoStore {
    static let maxBytes = 1_900_000

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Accepts a file name, or a legacy absolute path from schema 1, and resolves it inside the current container.
    func url(for name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let file = (name as NSString).lastPathComponent
        let current = directory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: current.path) { return current }
        let legacy = directory.deletingLastPathComponent().appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }

    func save(_ data: Data) throws -> String {
        guard let image = UIImage(data: data), let jpeg = Self.gatewayJPEG(image) else { throw PhotoError.unreadable }
        let name = "photo-\(UUID().uuidString).jpg"
        try jpeg.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return name
    }

    func base64(_ name: String) throws -> String {
        guard let url = url(for: name), let data = try? Data(contentsOf: url) else { throw PhotoError.missing }
        guard data.count <= 2_000_000, data.starts(with: [0xFF, 0xD8, 0xFF]) else { throw PhotoError.tooLarge }
        return data.base64EncodedString()
    }

    func delete(_ name: String?) {
        guard let url = url(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll() { try? FileManager.default.removeItem(at: directory) }

    /// Downscales to at most 2000 px on the long side and lowers quality until the JPEG fits the gateway limit.
    static func gatewayJPEG(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 2000 / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }
}

enum PhotoError: LocalizedError {
    case unreadable, missing, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取这张图片，请换一张或重新拍摄。"
        case .missing: "找不到作业图片，请重新选择。"
        case .tooLarge: "图片过大，请拍摄更小的题目区域后重试。"
        }
    }
}

// MARK: - Gateway client (`POST /v1/tutor`, see server/README.md)

struct TutorHistoryItem: Codable, Sendable { var question: String; var reply: String }

struct TutorRequest: Encodable, Sendable {
    var mode: String
    var grade: Int
    var subject: String
    var textbook: String
    var title: String
    var instructions: String
    var answer: String
    var message: String
    var image: String?
    var history: [TutorHistoryItem]

    /// Builds a request within the gateway's field limits.
    init(mode: String, child: Child, subject: Subject, task: Homework?, message: String, image: String?) {
        self.mode = mode
        grade = [2, 3].contains(child.grade) ? child.grade : 2
        self.subject = subject.apiName
        textbook = String(child.textbook.prefix(300))
        title = String((task?.title ?? "").prefix(100))
        instructions = String((task?.instructions ?? "").prefix(2000))
        answer = String((task?.draft ?? "").prefix(2000))
        self.message = String(message.prefix(2000))
        self.image = image
        history = (task?.conversation.suffix(8) ?? []).map {
            TutorHistoryItem(question: String($0.question.prefix(2000)), reply: String($0.reply.prefix(8000)))
        }
    }
}

struct TutorExercise: Decodable, Sendable {
    var id: String
    var subject: String
    var concept: String
    var prompt: String
    var answer: String
    var hints: [String]
    var explanation: String

    /// Generated exercises are always unverified so they never count as mastery evidence.
    func unverified(expected: Subject) -> Exercise? {
        guard Subject(apiName: subject) == expected, hints.count == 3,
              !answer.trimmingCharacters(in: .whitespaces).isEmpty, !prompt.isEmpty else { return nil }
        return Exercise(id: id, subject: expected, concept: concept, prompt: prompt, answer: answer,
                        hints: hints, explanation: explanation, verified: false)
    }
}

struct TutorResponse: Decodable, Sendable {
    var message: String
    var assessment: String?
    var title: String?
    var instructions: String?
    var subject: String?
    var exercise: TutorExercise?
}

/// Refuses redirects so the device token is never forwarded to another host.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct TutorClient: Sendable {
    static func validate(url: String, token: String) throws -> URL {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              parsed.scheme == "https" || isDebugLocal(parsed), parsed.host != nil,
              parsed.user == nil, parsed.query == nil, parsed.fragment == nil
        else { throw TutorError.invalidConfiguration }
        guard (24...512).contains(token.count), !token.contains(where: \.isWhitespace) else { throw TutorError.invalidConfiguration }
        return parsed
    }

    /// Debug builds may reach a gateway on the Mac over plain HTTP: loopback (simulator) or the home Wi-Fi
    /// (a phone or iPad testing against the Mac). Release builds always require HTTPS.
    static func isDebugLocal(_ url: URL) -> Bool {
        #if DEBUG
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
        #else
        return false
        #endif
    }

    func makeRequest(config: ServiceConfig, body: TutorRequest) throws -> URLRequest {
        guard config.consent else { throw TutorError.notEnabled }
        let base = try Self.validate(url: config.url, token: config.token)
        var request = URLRequest(url: base.appendingPathComponent("v1/tutor"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func send(config: ServiceConfig, body: TutorRequest) async throws -> TutorResponse {
        let request = try makeRequest(config: config, body: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect()) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw TutorError.network }
        guard let http = response as? HTTPURLResponse else { throw TutorError.serviceUnavailable }
        guard (200..<300).contains(http.statusCode) else { throw TutorError(status: http.statusCode) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> TutorResponse {
        guard data.count <= 65_536,
              let reply = try? JSONDecoder().decode(TutorResponse.self, from: data),
              !reply.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply.message.count <= 8000,
              ["UNKNOWN", "CORRECT", "INCORRECT"].contains(reply.assessment ?? "UNKNOWN")
        else { throw TutorError.invalidReply }
        return reply
    }
}

enum TutorError: LocalizedError, Equatable {
    #if DEBUG
    static let configurationHint = "服务地址需为 HTTPS（调试版也可用局域网地址，如 http://192.168.x.x:8787），设备访问凭证至少 24 个字符且不含空格。"
    #else
    static let configurationHint = "服务地址必须是 HTTPS，设备访问凭证至少 24 个字符且不含空格。"
    #endif

    case notEnabled, invalidConfiguration, network, unauthorized, rateLimited, modelNotConfigured, imagesNotSupported, serviceUnavailable, invalidReply

    init(status: Int) {
        switch status {
        case 401, 403: self = .unauthorized
        case 422: self = .imagesNotSupported
        case 429: self = .rateLimited
        case 503: self = .modelNotConfigured
        default: self = .serviceUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .notEnabled: "请家长先在家长设置中开启辅导服务。"
        case .invalidConfiguration: Self.configurationHint
        case .network: "无法连接辅导服务，请检查网络后重试。已有记录已保留。"
        case .unauthorized: "访问凭证无效，请家长检查服务设置。"
        case .rateLimited: "请求较多，请稍后再试。"
        case .modelNotConfigured: "模型服务尚未配置或暂不可用。"
        case .imagesNotSupported: "当前辅导服务不能看图。请不勾选图片、用文字描述题目，或请家长配置支持图片的模型。"
        case .serviceUnavailable: "辅导服务暂时无法处理，请稍后重试。"
        case .invalidReply: "辅导回复格式无法识别，请重试或请家长检查服务设置。"
        }
    }
}
