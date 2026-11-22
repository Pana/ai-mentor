import Foundation
import Security
import SwiftUI

// MARK: - Device session (which server, which role, this device's credential)

struct DeviceSession: Codable, Equatable, Sendable {
    var server: String
    var deviceId: UUID
    var role: String
    var familyId: UUID
    var token: String

    var isParent: Bool { role == "parent" }
}

/// Server address and role in UserDefaults; the device credential only in the Keychain (this device, after first unlock).
struct SessionStore {
    private let service = "cn.littlebear.tutor.homework"
    private let key = "phase1.session"

    func load() -> DeviceSession? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var session = try? JSONDecoder().decode(DeviceSession.self, from: data),
              let token = keychainRead() else { return nil }
        session.token = token
        return session
    }

    func save(_ session: DeviceSession) throws {
        var stored = session
        stored.token = ""
        UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: key)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "device", kSecValueData as String: Data(session.token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw APIError.invalidResponse }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "device"] as CFDictionary)
    }

    private func keychainRead() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "device", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Dates as the server writes them ("yyyy-MM-dd" in the family's time zone)

enum Day {
    static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    static func string(_ date: Date, _ timeZone: TimeZone) -> String { formatter(timeZone).string(from: date) }
    static func date(_ day: String) -> Date? { formatter(TimeZone(identifier: "UTC")!).date(from: day) }
    static func add(_ day: String, _ days: Int) -> String {
        guard let d = date(day) else { return day }
        return formatter(TimeZone(identifier: "UTC")!).string(from: d.addingTimeInterval(Double(days) * 86_400))
    }
    /// 0 = Sunday, as the server stores routine weekdays.
    static func weekday(_ day: String) -> Int {
        guard let d = date(day) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.weekday, from: d) - 1
    }
    static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
    /// "今天 · 11 月 9 日 周一"
    static func label(_ day: String, today: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        let base = "\(parts[1]) 月 \(parts[2]) 日 周\(weekdayNames[weekday(day)])"
        switch day {
        case today: return "今天 · \(base)"
        case add(today, -1): return "昨天 · \(base)"
        case add(today, 1): return "明天 · \(base)"
        default: return base
        }
    }
    static func short(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
    }
}

// MARK: - Offline submission queue (child iPad)

/// A file waiting in `outbox/`; only its name is queued (never its bytes), so a 200 MB video costs nothing in the cache.
/// A photo may carry `thumbName`, its list thumbnail in `outbox/`, uploaded right after it (absent in queues from older versions).
struct PendingFile: Codable, Hashable, Sendable {
    var fileId: UUID
    var localName: String
    var mime: String
    var thumbName: String? = nil
}
struct PendingSubmission: Codable, Identifiable, Hashable, Sendable {
    var id: UUID              // submission id; the server treats a retry with the same id as the same submission
    var homeworkId: UUID
    var files: [PendingFile]
    var submittedAt: Date
    var durationSeconds: Int?
}

/// Everything shown on screen, cached so the app opens instantly and works offline.
private struct Cache: Codable {
    var cursor = 0
    var family: FamilyInfo?
    var children: [RemoteChild] = []
    var homework: [RemoteHomework] = []
    var routines: [Routine] = []
    var rules = RewardRules()
    var rewards: [RewardSummary] = []
    var outbox: [PendingSubmission] = []
    var locks: [LockStatus]?
}

// MARK: - Store

/// Single source of truth on the device: a cache of the server's data, kept current through `/v1/changes`.
@MainActor final class HomeworkStore: ObservableObject {
    @Published private(set) var session: DeviceSession?
    @Published private(set) var family: FamilyInfo?
    @Published private(set) var children: [RemoteChild] = []
    @Published private(set) var homework: [UUID: RemoteHomework] = [:]
    @Published private(set) var routines: [Routine] = []
    @Published private(set) var rules = RewardRules()
    @Published private(set) var rewards: [UUID: RewardSummary] = [:]
    /// Parent only: each child tablet's reward-time lock, from the tablet's heartbeat.
    @Published private(set) var locks: [LockStatus] = []
    @Published private(set) var outbox: [PendingSubmission] = []
    /// Homework id → fraction of its queued files uploaded, while a submission is being sent.
    @Published private(set) var uploadProgress: [UUID: Double] = [:]
    /// Homework id → whether its video also went into the iPad's photo library (for 钉钉打卡). Only for this run of the app.
    @Published private(set) var albumSaves: [UUID: Bool] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var lastSynced: Date?
    @Published var errorMessage: String?
    /// Set when the server no longer accepts this device's credential.
    @Published private(set) var signedOut = false

    private var cursor = 0
    private let directory: URL
    private let sessions: SessionStore
    private let transport: HTTPTransport
    private let uploadTransport: UploadTransport
    private var syncAgain = false
    /// Photos the server has no thumbnail for (uploaded by an older app): lists load the photo itself. Only for this run.
    private var missingThumbnails: Set<UUID> = []
    /// Parent device: the background download of photos the parent is about to open (see `prefetch`).
    private(set) var prefetchTask: Task<Void, Never>?
    /// Failed prefetch downloads by "thumb:<id>" / "file:<id>"; after `prefetchAttempts` failures prefetching gives the
    /// file up for this run (opening the page still tries).
    private var prefetchFailures: [String: Int] = [:]
    static let prefetchAttempts = 2
    private var prefetchGeneration = 0
    /// Whether the app is in the foreground; prefetching stops when it is not.
    private var appActive = true

    init(directory: URL? = nil, sessions: SessionStore = SessionStore(), transport: @escaping HTTPTransport = APIClient.urlSession,
         uploadTransport: @escaping UploadTransport = APIClient.urlSessionUpload) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("homework", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("files"), withIntermediateDirectories: true)
        self.directory = base
        self.sessions = sessions
        self.transport = transport
        self.uploadTransport = uploadTransport
        session = sessions.load()
        loadCache()
    }

    var client: APIClient? {
        guard let session, let url = try? APIClient.validate(session.server) else { return nil }
        return APIClient(baseURL: url, token: session.token, transport: transport, uploadTransport: uploadTransport)
    }

    var timeZone: TimeZone { TimeZone(identifier: family?.timezone ?? "Asia/Shanghai") ?? .current }
    var today: String { Day.string(Date(), timeZone) }

    // MARK: Queries

    func items(child: UUID?) -> [RemoteHomework] {
        homework.values.filter { child == nil || $0.childId == child }
            .sorted { ($0.date, $0.isRoutine ? 1 : 0, $0.content) > ($1.date, $1.isRoutine ? 1 : 0, $1.content) }
    }
    /// Dates newest first, items in a stable order within each day.
    func grouped(child: UUID?, filter: (RemoteHomework) -> Bool = { _ in true }) -> [(day: String, items: [RemoteHomework])] {
        let all = homework.values.filter { (child == nil || $0.childId == child) && filter($0) }
        return Dictionary(grouping: all, by: \.date).sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { ($0.isRoutine ? 1 : 0, $0.subject, $0.content) < ($1.isRoutine ? 1 : 0, $1.subject, $1.content) }) }
    }
    func pending(_ homeworkId: UUID) -> PendingSubmission? { outbox.first { $0.homeworkId == homeworkId } }
    func child(_ id: UUID?) -> RemoteChild? { children.first { $0.id == id } }

    // MARK: Session

    func connectParent(server: String, secret: String, name: String) async throws {
        let url = try APIClient.validate(server)
        let grant = try await APIClient(baseURL: url, token: nil, transport: transport).bootstrap(secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), deviceId: UUID(), name: name)
        try begin(DeviceSession(server: url.absoluteString, deviceId: grant.deviceId, role: grant.role, familyId: grant.familyId, token: grant.deviceToken))
    }

    func pairChild(server: String, code: String, name: String) async throws {
        let url = try APIClient.validate(server)
        let grant = try await APIClient(baseURL: url, token: nil, transport: transport).pair(code: code, deviceId: UUID(), name: name)
        try begin(DeviceSession(server: url.absoluteString, deviceId: grant.deviceId, role: grant.role, familyId: grant.familyId, token: grant.deviceToken))
    }

    func begin(_ new: DeviceSession) throws {
        try sessions.save(new)
        resetData()
        session = new
        signedOut = false
        // RootView starts syncing when the session appears.
    }

    func signOut() {
        sessions.clear()
        resetData()
        session = nil
    }

    private func resetData() {
        cursor = 0; family = nil; children = []; homework = [:]; routines = []; rules = RewardRules(); rewards = [:]; locks = []
        for item in outbox { removeLocalFiles(item) }
        outbox = []
        prefetchTask?.cancel(); prefetchTask = nil
        prefetchFailures = [:]; missingThumbnails = []
        uploadProgress = [:]
        albumSaves = [:]
        lastSynced = nil
        saveCache()
    }

    // MARK: Sync

    func sync() async {
        guard let api = client, !signedOut else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                try await flushOutbox(api)
                if cursor == 0 { try await fullRefresh(api) } else { try await applyChanges(api) }
                // Asking for today also makes the server create today's routine items.
                for item in try await api.homework(from: today, to: today) { homework[item.id] = item }
                lastSynced = Date()
                saveCache()
                startPrefetch()
            } catch APIError.unauthorized {
                signedOut = true
                errorMessage = APIError.unauthorized.errorDescription
            } catch is CancellationError {
            } catch APIError.network {
                // Offline: keep showing the cache; the next sync retries.
            } catch {
                errorMessage = error.localizedDescription
            }
        } while syncAgain
    }

    /// Returns once the server has something new for this family, or after about 25 s with nothing new,
    /// so the sync that follows picks up the other device's change within a second.
    func waitForChanges() async {
        guard let api = client, !signedOut, cursor > 0 else { try? await Task.sleep(for: .seconds(20)); return }
        let started = Date()
        do {
            let feed = try await api.waitForChanges(since: cursor, wait: 25)
            // A server without long-polling answers an empty feed at once: fall back to polling every 20 s.
            if feed.changes.isEmpty, Date().timeIntervalSince(started) < 2 { try? await Task.sleep(for: .seconds(20)) }
        } catch is CancellationError {
        } catch {
            // Offline or the server restarted: retry soon without spinning.
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func fullRefresh(_ api: APIClient) async throws {
        let me = try await api.me()
        apply(me)
        let window = try await api.homework(from: Day.add(today, -45), to: Day.add(today, 14))
        homework = Dictionary(window.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        routines = try await api.routines()
        for child in children { rewards[child.id] = try await api.rewards(childId: child.id) }
        cursor = me.cursor
    }

    private func apply(_ me: MeResponse) {
        family = me.family
        children = me.children
        rules = me.rules
        locks = me.locks ?? []
    }

    private func applyChanges(_ api: APIClient) async throws {
        var more = true
        while more {
            let feed = try await api.changes(since: cursor)
            more = feed.hasMore
            var upserts = Set<UUID>(), deletes = Set<UUID>(), rewardChildren = Set<UUID>()
            var childrenChanged = false, routinesChanged = false, rulesChanged = false, devicesChanged = false
            for change in feed.changes {
                let id = UUID(uuidString: change.id)
                switch change.entity {
                case "homework":
                    guard let id else { continue }
                    if change.op == "DELETE" { deletes.insert(id); upserts.remove(id) } else { upserts.insert(id); deletes.remove(id) }
                case "child": childrenChanged = true
                case "routine": routinesChanged = true
                case "rules": rulesChanged = true
                case "reward": if let id { rewardChildren.insert(id) }
                case "device": devicesChanged = true
                default: break
                }
            }
            for id in deletes { homework[id] = nil }
            if upserts.count > 40 {
                let window = try await api.homework(from: Day.add(today, -45), to: Day.add(today, 14))
                for item in window { homework[item.id] = item }
            } else {
                for id in upserts {
                    do { homework[id] = try await api.homework(id: id) } catch APIError.notFound { homework[id] = nil }
                }
            }
            if childrenChanged || rulesChanged || devicesChanged {
                let me = try await api.me()
                apply(me)
                let known = Set(children.map(\.id))
                homework = homework.filter { known.contains($0.value.childId) }
                rewards = rewards.filter { known.contains($0.key) }
                for child in children where rewards[child.id] == nil { rewardChildren.insert(child.id) }
            }
            if routinesChanged { routines = try await api.routines() }
            for child in rewardChildren where self.child(child) != nil { rewards[child] = try await api.rewards(childId: child) }
            cursor = feed.next
        }
    }

    // MARK: Child: submissions (queued, so a submission made offline is sent later)

    /// `video` is a compressed `.mp4` on disk; it is moved into the queue, never read into memory.
    /// `pages` come from `PhotoStore.homeworkPhoto`; each page's thumbnail is queued next to it.
    func submit(_ item: RemoteHomework, pages: [HomeworkPhoto] = [], audio: Data? = nil, video: URL? = nil, durationSeconds: Int? = nil) async {
        var files: [PendingFile] = []
        for page in pages {
            var file = storeOutboxFile(page.jpeg, mime: "image/jpeg", ext: "jpg")
            if let thumbnail = page.thumbnail {
                let name = "\(file.fileId.uuidString).thumb.jpg"
                if (try? thumbnail.write(to: outboxURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil { file.thumbName = name }
            }
            files.append(file)
        }
        if let audio { files.append(storeOutboxFile(audio, mime: "audio/mp4", ext: "m4a")) }
        if let video {
            guard let file = moveIntoOutbox(video, mime: "video/mp4", ext: "mp4") else { return }
            files.append(file)
        }
        let pending = PendingSubmission(id: UUID(), homeworkId: item.id, files: files, submittedAt: Date(), durationSeconds: durationSeconds)
        outbox.append(pending)
        // Shown as handed in right away; the server's answer replaces this on the next sync.
        var local = item
        local.status = item.isTimer ? "REVIEWED" : "SUBMITTED"
        homework[item.id] = local
        saveCache()
        await sync()
    }

    private func storeOutboxFile(_ data: Data, mime: String, ext: String) -> PendingFile {
        let id = UUID()
        let name = "\(id.uuidString).\(ext)"
        try? data.write(to: directory.appendingPathComponent("outbox").appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return PendingFile(fileId: id, localName: name, mime: mime)
    }

    private func moveIntoOutbox(_ source: URL, mime: String, ext: String) -> PendingFile? {
        let id = UUID()
        let name = "\(id.uuidString).\(ext)"
        let target = directory.appendingPathComponent("outbox").appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: source, to: target) } catch {
            errorMessage = "视频没保存好，请重新录一次。"
            return nil
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        return PendingFile(fileId: id, localName: name, mime: mime)
    }

    /// Records whether a submitted video was also saved to the photo library, so the waiting screen can say so.
    func noteAlbumSave(_ homeworkId: UUID, saved: Bool) { albumSaves[homeworkId] = saved }

    private func removeLocalFiles(_ item: PendingSubmission) {
        for file in item.files {
            try? FileManager.default.removeItem(at: outboxFileURL(file))
            if let thumb = file.thumbName { try? FileManager.default.removeItem(at: outboxURL(thumb)) }
        }
    }

    private func flushOutbox(_ api: APIClient) async throws {
        struct Body: Encodable { var id: UUID; var fileIds: [UUID]; var submittedAt: String; var durationSeconds: Int? }
        for item in outbox {
            defer { uploadProgress[item.homeworkId] = nil }
            do {
                let sizes = item.files.map { Double(fileSize(outboxFileURL($0))) }
                let total = max(1, sizes.reduce(0, +))
                var done = 0.0
                for (index, file) in item.files.enumerated() {
                    let url = outboxFileURL(file)
                    guard FileManager.default.fileExists(atPath: url.path) else { throw APIError.rejected("invalid_file") }
                    let before = done, size = sizes[index], homeworkId = item.homeworkId
                    uploadProgress[homeworkId] = before / total
                    try await api.upload(fileId: file.fileId, file: url, mime: file.mime) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.uploadProgress[homeworkId] != nil else { return }
                            self.uploadProgress[homeworkId] = (before + fraction * size) / total
                        }
                    }
                    done += size
                    // Photos and recordings stay cached for viewing offline; a video is streamed from the server instead of
                    // keeping 200 MB per day on the iPad (the child's own copy is in the photo library).
                    if !file.mime.hasPrefix("video/") { cacheUploaded(url, to: cachedFileURL(file.fileId)) }
                    if let thumb = file.thumbName { await uploadThumbnail(api, of: file.fileId, from: outboxURL(thumb)) }
                }
                let body = Body(id: item.id, fileIds: item.files.map(\.fileId), submittedAt: ISO8601DateFormatter().string(from: item.submittedAt), durationSeconds: item.durationSeconds)
                let updated: RemoteHomework = try await api.send("POST", "v1/homework/\(item.homeworkId.uuidString.lowercased())/submissions", json: body)
                homework[updated.id] = updated
                finish(item)
            } catch let error as APIError where error != .network && error != .unauthorized && error != .server {
                // The server refused it for good (e.g. the homework was deleted); drop it and say why.
                finish(item)
                errorMessage = error.localizedDescription
                if let fresh = try? await api.homework(id: item.homeworkId) { homework[fresh.id] = fresh } else { homework[item.homeworkId] = nil }
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A hard link costs no extra space and outlives the outbox copy; copy when linking is not possible.
    private func cacheUploaded(_ url: URL, to target: URL) {
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        do { try FileManager.default.linkItem(at: url, to: target) } catch { try? FileManager.default.copyItem(at: url, to: target) }
    }

    /// Sends a photo's list thumbnail after the photo itself. Optional: a failure is skipped and never holds up the
    /// submission (lists then load the photo, as for photos from older versions).
    private func uploadThumbnail(_ api: APIClient, of photo: UUID, from url: URL) async {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        do {
            try await api.uploadThumbnail(fileId: photo, data: data)
            cacheUploaded(url, to: cachedThumbnailURL(photo))
        } catch {
            #if DEBUG
            print("[homework] thumbnail upload skipped for \(photo): \(error)")
            #endif
        }
    }

    private func finish(_ item: PendingSubmission) {
        removeLocalFiles(item)
        outbox.removeAll { $0.id == item.id }
        saveCache()
    }

    func startReward(child: UUID, minutes: Int) async throws -> RewardSession {
        guard let api = client else { throw APIError.invalidServer }
        struct Body: Encodable { var id = UUID(); var childId: UUID; var minutes: Int }
        let session: RewardSession = try await api.send("POST", "v1/rewards/sessions", json: Body(childId: child, minutes: minutes))
        await sync()
        return session
    }

    // MARK: Parent actions (online)

    private func call<T: Decodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable)? = nil) async throws -> T {
        guard let api = client else { throw APIError.invalidServer }
        return try await api.send(method, path, query: query, json: json)
    }
    private struct OK: Decodable, Sendable {}

    func saveChild(id: UUID = UUID(), name: String, grade: Int) async throws {
        struct Body: Encodable { var name: String; var grade: Int; var avatar = "" }
        let _: RemoteChild = try await call("PUT", "v1/children/\(id.uuidString.lowercased())", json: Body(name: name, grade: grade))
        await sync()
    }
    func deleteChild(_ id: UUID) async throws {
        let _: OK = try await call("DELETE", "v1/children/\(id.uuidString.lowercased())")
        await sync()
    }
    /// What the voice teacher remembers about a child: a short card of notes written after each conversation.
    func teacherMemory(_ child: UUID) async throws -> TeacherMemory { try await call("GET", "v1/children/\(child.uuidString.lowercased())/teacher-memory") }
    func clearTeacherMemory(_ child: UUID) async throws { let _: OK = try await call("DELETE", "v1/children/\(child.uuidString.lowercased())/teacher-memory") }
    func pairingCode() async throws -> PairingCode { try await call("POST", "v1/devices/pairing-codes") }
    func devices() async throws -> [DeviceRecord] {
        struct Page: Decodable, Sendable { var devices: [DeviceRecord] }
        let page: Page = try await call("GET", "v1/devices")
        return page.devices
    }
    func revoke(_ device: UUID) async throws { let _: OK = try await call("DELETE", "v1/devices/\(device.uuidString.lowercased())") }

    func parse(text: String) async throws -> ParseResult {
        struct Body: Encodable { var text: String; var date: String }
        return try await call("POST", "v1/homework/parse", json: Body(text: text, date: today))
    }

    /// Uploads JPEG attachments (each followed by its thumbnail, when it has one) and returns their file ids.
    func uploadImages(_ images: [HomeworkPhoto]) async throws -> [UUID] {
        guard let api = client else { throw APIError.invalidServer }
        var ids: [UUID] = []
        for image in images {
            let id = UUID()
            try await api.upload(fileId: id, data: image.jpeg, mime: "image/jpeg")
            try? image.jpeg.write(to: cachedFileURL(id))
            if let thumbnail = image.thumbnail {
                do {
                    try await api.uploadThumbnail(fileId: id, data: thumbnail)
                    try? thumbnail.write(to: cachedThumbnailURL(id))
                } catch {
                    #if DEBUG
                    print("[homework] thumbnail upload skipped for \(id): \(error)")
                    #endif
                }
            }
            ids.append(id)
        }
        return ids
    }

    func create(_ items: [NewHomework]) async throws {
        struct Body: Encodable { var items: [NewHomework] }
        struct Page: Decodable, Sendable { var items: [RemoteHomework] }
        let page: Page = try await call("POST", "v1/homework", json: Body(items: items))
        for item in page.items { homework[item.id] = item }
        saveCache()
        await sync()
    }

    func update(_ id: UUID, content: String, subject: String, date: String, dueDate: String?, mode: String, onlineKind: String?, durationMinutes: Int?, parentTodo: String) async throws {
        struct Body: Encodable { var content, subject, date: String; var dueDate: String?; var mode: String; var onlineKind: String?; var durationMinutes: Int?; var parentTodo: String }
        let updated: RemoteHomework = try await call("PATCH", "v1/homework/\(id.uuidString.lowercased())", json: Body(content: content, subject: subject, date: date, dueDate: dueDate, mode: mode, onlineKind: onlineKind, durationMinutes: durationMinutes, parentTodo: parentTodo))
        homework[id] = updated
        await sync()
    }

    func delete(_ id: UUID) async throws {
        let _: OK = try await call("DELETE", "v1/homework/\(id.uuidString.lowercased())")
        homework[id] = nil
        await sync()
    }

    func review(_ submission: Submission, of item: RemoteHomework, grade: String, comment: String, requireCorrection: Bool, overlays: [Data]) async throws {
        guard let api = client else { throw APIError.invalidServer }
        var ids: [UUID] = []
        for png in overlays {
            let id = UUID()
            try await api.upload(fileId: id, data: png, mime: "image/png")
            try? png.write(to: cachedFileURL(id))
            ids.append(id)
        }
        struct Body: Encodable { var grade: String; var comment: String; var requireCorrection: Bool; var annotationFileIds: [UUID] }
        let updated: RemoteHomework = try await call("POST", "v1/submissions/\(submission.id.uuidString.lowercased())/review",
                                                     json: Body(grade: grade, comment: comment, requireCorrection: requireCorrection, annotationFileIds: ids))
        homework[item.id] = updated
        await sync()
    }

    func saveRoutine(id: UUID, _ input: RoutineInput) async throws {
        let _: Routine = try await call("PUT", "v1/routines/\(id.uuidString.lowercased())", json: input)
        await sync()
    }
    func deleteRoutine(_ id: UUID) async throws {
        let _: OK = try await call("DELETE", "v1/routines/\(id.uuidString.lowercased())")
        await sync()
    }
    func saveRules(_ new: RewardRules) async throws {
        rules = try await call("PUT", "v1/reward-rules", json: new)
        await sync()
    }

    // MARK: Files

    func cachedFileURL(_ id: UUID) -> URL { directory.appendingPathComponent("files").appendingPathComponent(id.uuidString) }

    func fileData(_ id: UUID) async throws -> Data {
        let url = cachedFileURL(id)
        if let data = try? Data(contentsOf: url) { return data }
        guard let api = client else { throw APIError.invalidServer }
        let data = try await api.download(fileId: id)
        try? data.write(to: url, options: .atomic)
        return data
    }

    /// A photo's list thumbnail, cached apart from the photo (`<id>.thumb`).
    func cachedThumbnailURL(_ id: UUID) -> URL { directory.appendingPathComponent("files").appendingPathComponent("\(id.uuidString).thumb") }

    /// For lists and other small previews: the thumbnail when there is one, otherwise the photo itself (a photo from an
    /// older app has no thumbnail, `404 thumb_not_found`). A photo already on the device is used as is, with no download.
    func thumbnailData(_ id: UUID) async throws -> Data {
        if let data = try? Data(contentsOf: cachedThumbnailURL(id)) { return data }
        if let data = try? Data(contentsOf: cachedFileURL(id)) { return data }
        if !missingThumbnails.contains(id) {
            guard let api = client else { throw APIError.invalidServer }
            do {
                let data = try await api.downloadThumbnail(fileId: id)
                try? data.write(to: cachedThumbnailURL(id), options: .atomic)
                return data
            } catch APIError.notFound {
                missingThumbnails.insert(id)
            } catch APIError.rejected {
                missingThumbnails.insert(id)
            }
        }
        return try await fileData(id)
    }

    func outboxFileURL(_ file: PendingFile) -> URL { outboxURL(file.localName) }
    func outboxThumbnailURL(_ file: PendingFile) -> URL? { file.thumbName.map(outboxURL) }
    private func outboxURL(_ name: String) -> URL { directory.appendingPathComponent("outbox").appendingPathComponent(name) }

    // MARK: Prefetch (parent device)

    /// Photos the parent is likely to open next, most urgent first: the pages of submissions waiting for review, then
    /// the pictures attached to homework from the last `recentDays` days on. Only photos: recordings and videos are skipped.
    nonisolated static func prefetchTargets(_ items: [RemoteHomework], today: String, recentDays: Int = 7) -> [UUID] {
        var ids: [UUID] = [], seen = Set<UUID>()
        func add(_ id: UUID) { if seen.insert(id).inserted { ids.append(id) } }
        let waiting = items.filter { $0.awaitingReview && $0.isOffline }
            .sorted { ($0.latest?.receivedAt ?? "", $0.id.uuidString) > ($1.latest?.receivedAt ?? "", $1.id.uuidString) }
        for item in waiting { item.latest?.fileIds.forEach(add) }
        let from = Day.add(today, -recentDays)
        for item in items.filter({ $0.date >= from && !$0.attachmentIds.isEmpty }).sorted(by: { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }) {
            item.attachmentIds.forEach(add)
        }
        return ids
    }

    /// Tells the store whether the app is in the foreground; going to the background stops prefetching.
    func setActive(_ active: Bool) {
        appActive = active
        if !active { prefetchTask?.cancel(); prefetchTask = nil }
    }

    /// After a sync on the parent's phone: download, one at a time, the thumbnails and then the photos the parent is
    /// about to open into the disk cache, so the first open is instant. Skips what is cached and what already failed.
    private func startPrefetch() {
        guard session?.isParent == true, appActive, prefetchTask == nil, client != nil else { return }
        let targets = Self.prefetchTargets(Array(homework.values), today: today)
        guard !targets.isEmpty else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchTask = Task { [weak self] in
            await self?.prefetch(targets)
            if let self, self.prefetchGeneration == generation { self.prefetchTask = nil }
        }
    }

    private func prefetch(_ ids: [UUID]) async {
        let fm = FileManager.default
        func gaveUp(_ key: String) -> Bool { prefetchFailures[key, default: 0] >= Self.prefetchAttempts }
        // Thumbnails first so every list fills in quickly, then the full pages for review. A network error ends this
        // round (the next sync starts another); it still counts against the file so one bad file is not retried forever.
        for id in ids {
            guard appActive, session != nil, !Task.isCancelled, let api = client else { return }
            if missingThumbnails.contains(id) || gaveUp("thumb:\(id)") { continue }
            if fm.fileExists(atPath: cachedThumbnailURL(id).path) || fm.fileExists(atPath: cachedFileURL(id).path) { continue }
            do {
                let data = try await api.downloadThumbnail(fileId: id)
                try? data.write(to: cachedThumbnailURL(id), options: .atomic)
            } catch APIError.notFound { missingThumbnails.insert(id) }
            catch APIError.rejected { missingThumbnails.insert(id) }
            catch is CancellationError { return }
            catch {
                prefetchFailures["thumb:\(id)", default: 0] += 1
                if error as? APIError == .network { return }
            }
        }
        for id in ids {
            guard appActive, session != nil, !Task.isCancelled, let api = client else { return }
            if gaveUp("file:\(id)") || fm.fileExists(atPath: cachedFileURL(id).path) { continue }
            do {
                let data = try await api.download(fileId: id)
                try? data.write(to: cachedFileURL(id), options: .atomic)
            } catch is CancellationError { return }
            catch {
                prefetchFailures["file:\(id)", default: 0] += 1
                if error as? APIError == .network { return }
            }
        }
    }

    // MARK: Cache

    private var cacheURL: URL { directory.appendingPathComponent("cache.json") }

    private func loadCache() {
        guard session != nil, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        cursor = cache.cursor; family = cache.family; children = cache.children
        homework = Dictionary(cache.homework.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        routines = cache.routines; rules = cache.rules
        rewards = Dictionary(cache.rewards.map { ($0.childId, $0) }, uniquingKeysWith: { $1 })
        outbox = cache.outbox
        locks = cache.locks ?? []
    }

    private func saveCache() {
        let cache = Cache(cursor: cursor, family: family, children: children, homework: Array(homework.values), routines: routines,
                          rules: rules, rewards: Array(rewards.values), outbox: outbox, locks: locks)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    /// Debug/test hook: drops the cache and every queued submission.
    func wipeLocal() { resetData(); try? FileManager.default.removeItem(at: cacheURL) }
}
