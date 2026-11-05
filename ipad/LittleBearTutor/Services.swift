import Foundation
import Security

struct ServiceConfig: Sendable { var url: String; var token: String; var consent: Bool }

struct CredentialStore {
    private let service = "cn.littlebear.tutor.ipad"
    func load() -> ServiceConfig {
        let defaults = UserDefaults.standard
        let token = keychainRead() ?? ""
        return ServiceConfig(url: defaults.string(forKey: "tutor.service.url") ?? "", token: token, consent: defaults.bool(forKey: "tutor.service.consent"))
    }
    func save(url: String, token: String, consent: Bool) throws {
        UserDefaults.standard.set(url, forKey: "tutor.service.url")
        UserDefaults.standard.set(consent, forKey: "tutor.service.consent")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-token", kSecValueData as String: Data(token.utf8)]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw LocalError.invalidService }
    }
    func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-token"]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "tutor.service.url")
        UserDefaults.standard.removeObject(forKey: "tutor.service.consent")
    }
    private func keychainRead() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct TutorRequest: Encodable, Sendable {
    var mode = "help"; var grade: Int; var subject: String; var textbook: String; var title: String; var instructions: String; var answer: String; var message: String; var image: String?; var history: [[String: String]]
}
struct TutorReply: Decodable, Sendable { var message: String; var assessment: String }

struct TutorClient: Sendable {
    func ask(config: ServiceConfig, child: Child, task: Homework, message: String, includePhoto: String?) async throws -> TutorReply {
        guard let base = URL(string: config.url), base.scheme == "https" else { throw TutorError.invalidConfiguration }
        guard !config.token.isEmpty else { throw TutorError.invalidConfiguration }
        let endpoint = base.appendingPathComponent("v1/tutor")
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let encodedImage = try includePhoto.flatMap { try Data(contentsOf: URL(fileURLWithPath: $0)).base64EncodedString() }
        let body = TutorRequest(grade: child.grade, subject: task.subject.rawValue, textbook: child.textbook, title: task.title, instructions: task.instructions, answer: task.draft, message: message, image: encodedImage, history: task.conversation.suffix(8).map { ["question": $0.question, "reply": $0.reply] })
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TutorError.serviceUnavailable }
        guard data.count <= 65_536 else { throw TutorError.invalidReply }
        guard let reply = try? JSONDecoder().decode(TutorReply.self, from: data), !reply.message.isEmpty else { throw TutorError.invalidReply }
        return reply
    }
}
enum TutorError: LocalizedError { case invalidConfiguration, serviceUnavailable, invalidReply; var errorDescription: String? { switch self { case .invalidConfiguration: "请家长检查辅导服务设置。"; case .serviceUnavailable: "辅导服务暂不可用，请稍后重试。"; case .invalidReply: "辅导回复格式无法识别，请重试。" } } }
