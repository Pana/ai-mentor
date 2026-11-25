import Foundation

// MARK: - Wire types for the phase-1 homework API (`server/src/api.mjs`)
// Enumerations stay as strings on the wire so a newer server value never breaks decoding; views use the helpers.

struct RemoteChild: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var grade: Int
    var avatar: String
}

struct Review: Codable, Hashable, Sendable {
    var id: UUID
    var grade: String
    var comment: String
    var requireCorrection: Bool
    var annotationFileIds: [UUID]
    var reviewedAt: String
}

struct Submission: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var attempt: Int
    var fileIds: [UUID]
    var durationSeconds: Int?
    var submittedAt: String
    var receivedAt: String
    var onTime: Bool
    var review: Review?
}

struct RemoteHomework: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var childId: UUID
    var subject: String
    var date: String
    var dueDate: String?
    var content: String
    var rawText: String
    var mode: String
    var onlineKind: String?
    var durationMinutes: Int?
    var parentTodo: String
    var status: String
    var source: String
    var routineId: UUID?
    var attachmentIds: [UUID]
    var version: Int
    var submissions: [Submission]

    var latest: Submission? { submissions.last }
    var latestReview: Review? { submissions.last(where: { $0.review != nil })?.review }
    var isOffline: Bool { mode == "OFFLINE" }
    var isTimer: Bool { onlineKind == "TIMER" }
    var isRecording: Bool { onlineKind == "RECORDING" }
    var isVideo: Bool { onlineKind == "VIDEO" }
    var isRoutine: Bool { source == "ROUTINE" }
    var needsWork: Bool { status == "NOT_STARTED" || status == "NEEDS_CORRECTION" }
    var awaitingReview: Bool { status == "SUBMITTED" }
}

struct Routine: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var childId: UUID
    var title: String
    var subject: String
    var mode: String
    var onlineKind: String?
    var durationMinutes: Int?
    var quantity: Int?
    var weekdays: [Int]
    var active: Bool
    var sortOrder: Int
}

struct RewardRules: Codable, Hashable, Sendable {
    var finishTime = "19:30"
    var onTime = 5
    var gradeExcellent = 5
    var gradeGood = 3
    var gradeFair = 1
    var checkin = 3
    var streak7 = 10
    var dailyCap = 30
    var windowStart = "19:00"
    var windowEnd = "20:30"
    var requireAllSubmitted = true

    func points(for grade: String) -> Int {
        switch grade { case "EXCELLENT": gradeExcellent; case "GOOD": gradeGood; case "FAIR": gradeFair; default: 0 }
    }
}

struct RewardEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var minutes: Int
    var reason: String
    var refId: String
    var date: String
    var createdAt: String
}

struct RewardSummary: Codable, Hashable, Sendable {
    var childId: UUID
    var balance: Int
    var earnedToday: Int
    var usedToday: Int
    var entries: [RewardEntry]
}

struct FamilyInfo: Codable, Hashable, Sendable { var id: UUID; var name: String; var timezone: String; var today: String }
struct DeviceInfo: Codable, Hashable, Sendable { var id: UUID; var role: String; var name: String }
struct MeResponse: Codable, Sendable {
    var cursor: Int
    var device: DeviceInfo
    var family: FamilyInfo
    var children: [RemoteChild]
    var rules: RewardRules
    /// Parent only, and only from servers that have the lock heartbeat: optional so an older server still decodes.
    var locks: [LockStatus]?
    /// The signed-in parent account; nil on child tablets, on phones connected with the parent secret, and from older servers.
    var account: AccountInfo?
}

/// A parent's own account: the phone number they sign in with and what the family calls them (妈妈, 爸爸…).
struct AccountInfo: Codable, Hashable, Sendable { var id: UUID; var phone: String; var name: String }
/// Another parent of the family, as listed in settings. `phone` is masked (138****8000).
struct FamilyParent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID; var name: String; var phone: String; var createdAt: String; var self_: Bool; var devices: Int
    enum CodingKeys: String, CodingKey { case id, name, phone, createdAt, self_ = "self", devices }
}
struct FamilyParents: Codable, Sendable { var parents: [FamilyParent]; var unboundDevices: Int }
struct InviteCode: Codable, Sendable { var code: String; var expiresAt: String }

/// A child tablet's reward-time lock as the parent sees it (Android tablets report it; see the server's `/v1/devices/self/lock`).
/// `problem`: "off", "paused" (the system froze it) or "silent" (no report for a day); nil when it is working.
struct LockStatus: Codable, Hashable, Sendable {
    var deviceId: String
    var name: String
    var enabled: Bool
    var lockedApps: Int
    var stalled: Bool
    var adminActive: Bool
    var reportedAt: String
    var problem: String?
}

struct Change: Codable, Sendable { var seq: Int; var entity: String; var id: String; var op: String }
struct ChangeFeed: Codable, Sendable { var changes: [Change]; var next: Int; var hasMore: Bool }
struct DeviceGrant: Codable, Sendable { var deviceId: UUID; var deviceToken: String; var role: String; var familyId: UUID; var account: AccountInfo? }
struct PairingCode: Codable, Sendable { var code: String; var expiresAt: String }
struct DeviceRecord: Codable, Identifiable, Hashable, Sendable { var id: UUID; var role: String; var name: String; var createdAt: String; var lastSeenAt: String?; var self_: Bool
    /// The parent account signed in on this phone; nil for tablets and phones connected with the parent secret.
    var accountName: String?
    enum CodingKeys: String, CodingKey { case id, role, name, createdAt, lastSeenAt, self_ = "self", accountName }
}
struct ParsedItem: Codable, Hashable, Sendable {
    var subject: String
    var content: String
    var mode: String
    /// "RECORDING" | "VIDEO" | "TIMER" for ONLINE items; nil when the AI could not tell (or from an older server).
    var onlineKind: String?
    var dueText: String
    var dueDate: String?
    var parentTodo: String
}
struct ParseResult: Codable, Sendable { var items: [ParsedItem]; var message: String }
struct RewardSession: Codable, Sendable { var id: UUID; var minutes: Int; var endsAt: String }

/// Fields for a new homework item (`POST /v1/homework`).
struct NewHomework: Codable, Sendable {
    var id = UUID()
    var childId: UUID
    var subject: String
    var date: String
    var dueDate: String?
    var content: String
    var rawText = ""
    var mode: String
    var onlineKind: String?
    var durationMinutes: Int?
    var parentTodo = ""
    var attachmentIds: [UUID] = []
}

struct RoutineInput: Codable, Sendable {
    var childId: UUID
    var title: String
    var subject: String
    var mode: String
    var onlineKind: String?
    var durationMinutes: Int?
    var quantity: Int?
    var weekdays: [Int]
    var active: Bool
    var sortOrder: Int
}

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    case invalidServer, network, unauthorized, forbidden, notFound, conflict(String), rejected(String), server, invalidResponse

    static func from(status: Int, code: String) -> APIError {
        switch status {
        // A wrong phone number or password is the person's mistake, not this device's credential running out.
        case 401 where ["invalid_login", "wrong_password"].contains(code): .rejected(code)
        case 429 where !code.isEmpty: .rejected(code)
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .conflict(code)
        case 400, 413, 415, 422: .rejected(code)
        default: .server
        }
    }

    var code: String? {
        switch self { case .conflict(let c), .rejected(let c): c; default: nil }
    }

    var errorDescription: String? {
        switch self {
        case .invalidServer: APIError.serverHint
        case .network: "连不上服务器，请检查网络。已保存的内容不会丢。"
        case .unauthorized: "这台设备的登录已失效，请重新连接。"
        case .forbidden: "这台设备没有权限做这件事。"
        case .notFound: "内容已经不存在了，可能被家长删除了。"
        case .conflict(let code): Self.messages[code] ?? "操作和当前状态冲突，刷新后再试。"
        case .rejected(let code): Self.messages[code] ?? "填写的内容不符合要求，请检查后再试。"
        case .server: "服务器暂时出错，请稍后再试。"
        case .invalidResponse: "服务器返回的内容无法识别。"
        }
    }

    #if DEBUG
    static let serverHint = "服务器地址需为 HTTPS（调试版也可用 http://127.0.0.1:8787 或局域网地址）。"
    #else
    static let serverHint = "服务器地址必须是 HTTPS。"
    #endif

    static let messages: [String: String] = [
        "routine_limit": "每天坚持最多 5 项。先暂停或删除一项再加。",
        "not_submittable": "这项作业已经交过了，等家长批改。",
        "duration_not_met": "时间还没到，再坚持一下。",
        "already_reviewed": "这次提交已经批改过了。",
        "not_latest_submission": "孩子已经重新提交，请批改最新一次。",
        "outside_window": "现在不在可以使用奖励时间的时段。",
        "homework_pending": "今天还有作业没交，交完就能用奖励时间。",
        "daily_cap": "今天的奖励时间已经用到上限了。",
        "insufficient_balance": "攒的时间还不够。",
        "photo_required": "要先拍一张作业照片。",
        "recording_required": "要先录一段音。",
        "video_required": "要先录一段视频。",
        "invalid_code": "配对码不对或已过期，请家长重新生成。",
        "model_not_configured": "服务器还没有配置 AI 模型，可以先手动填写。",
        "invalid_model_reply": "AI 这次没整理好，请再试一次或手动填写。",
        "invalid_due_date": "交作业日期不能早于布置日期。",
        "invalid_window": "开始时间要早于结束时间。",
        "unsupported_file_type": "这种文件不能上传。",
        "invalid_file": "文件已损坏，请重新拍摄。",
        "body_too_large": "文件太大了。",
        "invalid_phone": "请填写 11 位手机号。",
        "weak_password": "密码至少 8 位。",
        "phone_taken": "这个手机号已经注册过了，请直接登录。",
        "invalid_login": "手机号或密码不对。",
        "wrong_password": "原密码不对。",
        "too_many_attempts": "密码错误次数太多，请 15 分钟后再试。",
        "rate_limited": "尝试太频繁了，请过一会儿再试。",
        "invalid_invite": "邀请码不对、已经用过或已过期，请家人重新生成。",
        "already_bound": "这台手机已经设置过登录账号了。",
        "cannot_remove_self": "不能把自己移出家庭。"
    ]
}

// MARK: - Client

typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
/// Sends a file from disk as the request body, reporting the fraction sent, so a 200 MB video never sits in memory.
typealias UploadTransport = @Sendable (URLRequest, URL, @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse)

/// Refuses redirects so a device credential is never forwarded to another host.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Same redirect refusal, plus upload progress for a body sent from a file.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    var token: String?
    var transport: HTTPTransport = APIClient.urlSession
    var uploadTransport: UploadTransport = APIClient.urlSessionUpload

    static let urlSession: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    /// Streams the body from disk. `timeoutInterval` is the idle time between packets, not a limit on the whole upload.
    static let urlSessionUpload: UploadTransport = { request, file, progress in
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: UploadProgress(progress))
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    /// Seconds a file upload may sit without any bytes moving, generous for a slow home uplink.
    static let uploadIdleTimeout: TimeInterval = 120

    /// Accepts an HTTPS root URL, or loopback / home-network HTTP in Debug builds.
    static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              url.scheme == "https" || TutorClient.isDebugLocal(url), url.host != nil,
              url.user == nil, url.query == nil, url.fragment == nil else { throw APIError.invalidServer }
        return url
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? (path.hasSuffix("/parse") ? 75 : 30)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func raw(_ request: URLRequest) async throws -> Data { try await checked { try await transport(request) } }

    private func checked(_ exchange: () async throws -> (Data, HTTPURLResponse)) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await exchange() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch let error as APIError { throw error }
        catch { throw APIError.network }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw APIError.from(status: response.statusCode, code: code)
        }
        return data
    }

    func send<T: Decodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable)? = nil, timeout: TimeInterval? = nil) async throws -> T {
        let body = try json.map { try Self.encoder.encode($0) } ?? (["POST", "PUT", "PATCH"].contains(method) ? Data("{}".utf8) : nil)
        let data = try await raw(request(method, path, query: query, body: body, timeout: timeout))
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw APIError.invalidResponse }
    }

    // MARK: Endpoints

    func bootstrap(secret: String, deviceId: UUID, name: String) async throws -> DeviceGrant {
        try await send("POST", "v1/devices/bootstrap", json: ["token": secret, "deviceId": deviceId.uuidString, "name": name])
    }
    func register(phone: String, password: String, name: String, inviteCode: String?, deviceId: UUID, deviceName: String) async throws -> DeviceGrant {
        struct Body: Encodable { var phone: String; var password: String; var name: String; var inviteCode: String?; var deviceId: String; var deviceName: String }
        return try await send("POST", "v1/accounts/register", json: Body(phone: phone, password: password, name: name, inviteCode: inviteCode,
                                                                             deviceId: deviceId.uuidString, deviceName: deviceName))
    }
    func login(phone: String, password: String, deviceId: UUID, deviceName: String) async throws -> DeviceGrant {
        try await send("POST", "v1/accounts/login", json: ["phone": phone, "password": password, "deviceId": deviceId.uuidString, "deviceName": deviceName])
    }
    func pair(code: String, deviceId: UUID, name: String) async throws -> DeviceGrant {
        try await send("POST", "v1/devices/pair", json: ["code": code, "deviceId": deviceId.uuidString, "name": name])
    }
    func me() async throws -> MeResponse { try await send("GET", "v1/me") }
    func changes(since: Int) async throws -> ChangeFeed { try await send("GET", "v1/changes", query: [.init(name: "since", value: String(since))]) }
    /// Held open by the server until the family's next change, or about `wait` seconds with nothing new.
    func waitForChanges(since: Int, wait: Int) async throws -> ChangeFeed {
        try await send("GET", "v1/changes", query: [.init(name: "since", value: String(since)), .init(name: "wait", value: String(wait))], timeout: TimeInterval(wait + 15))
    }
    func homework(from: String, to: String) async throws -> [RemoteHomework] {
        struct Page: Decodable, Sendable { var items: [RemoteHomework] }
        let page: Page = try await send("GET", "v1/homework", query: [.init(name: "from", value: from), .init(name: "to", value: to)])
        return page.items
    }
    func homework(id: UUID) async throws -> RemoteHomework { try await send("GET", "v1/homework/\(id.uuidString.lowercased())") }
    func children() async throws -> [RemoteChild] {
        struct Page: Decodable, Sendable { var children: [RemoteChild] }
        let page: Page = try await send("GET", "v1/children")
        return page.children
    }
    func routines() async throws -> [Routine] {
        struct Page: Decodable, Sendable { var routines: [Routine] }
        let page: Page = try await send("GET", "v1/routines")
        return page.routines
    }
    func rewards(childId: UUID) async throws -> RewardSummary {
        try await send("GET", "v1/rewards", query: [.init(name: "childId", value: childId.uuidString.lowercased())])
    }
    func upload(fileId: UUID, data: Data, mime: String) async throws {
        _ = try await raw(request("PUT", "v1/files/\(fileId.uuidString.lowercased())", body: data, contentType: mime))
    }
    /// Uploads straight from a file on disk (used for every queued submission file, and needed for video).
    func upload(fileId: UUID, file: URL, mime: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var request = try request("PUT", "v1/files/\(fileId.uuidString.lowercased())", timeout: Self.uploadIdleTimeout)
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        _ = try await checked { try await uploadTransport(request, file, progress) }
    }
    func download(fileId: UUID) async throws -> Data {
        try await raw(request("GET", "v1/files/\(fileId.uuidString.lowercased())"))
    }
    /// A photo's small list JPEG, sent after the photo itself (`404 file_not_found` before that). At most 300 KB.
    func uploadThumbnail(fileId: UUID, data: Data) async throws {
        _ = try await raw(request("PUT", "v1/files/\(fileId.uuidString.lowercased())/thumb", body: data, contentType: "image/jpeg"))
    }
    /// `APIError.notFound` (`thumb_not_found`) for a photo uploaded by an older app: load the photo instead.
    func downloadThumbnail(fileId: UUID) async throws -> Data {
        try await raw(request("GET", "v1/files/\(fileId.uuidString.lowercased())/thumb"))
    }
    /// Where a player streams a file from (the server answers `Range` requests); send `authorizationHeader` with it.
    func fileURL(_ fileId: UUID) -> URL { baseURL.appendingPathComponent("v1/files/\(fileId.uuidString.lowercased())") }
    var authorizationHeader: [String: String] { token.map { ["Authorization": "Bearer \($0)"] } ?? [:] }
}
