import XCTest
@testable import LittleBearTutor

/// A scripted server: each request goes to `handler`, which returns a status and JSON (or raw `Data`, sent as is).
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _uploads: [(request: URLRequest, file: URL, bytes: Int)] = []
    var offline = false
    var handler: (URLRequest) -> (Int, Any) = { _ in (404, ["error": "not_found"]) }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func paths(_ method: String) -> [String] { requests.filter { $0.httpMethod == method }.compactMap { $0.url?.path } }
    /// Bodies sent from a file: the request, the file it streamed from, and that file's size at the time.
    var uploads: [(request: URLRequest, file: URL, bytes: Int)] { lock.withLock { _uploads } }

    var uploadTransport: UploadTransport {
        { [self] request, file, progress in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
            lock.withLock { _requests.append(request); _uploads.append((request, file, bytes)) }
            if lock.withLock({ offline }) { throw URLError(.notConnectedToInternet) }
            progress(0.5); progress(1)
            let (status, body) = lock.withLock { handler(request) }
            let data = try body as? Data ?? JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
    }

    var transport: HTTPTransport {
        { [self] request in
            lock.withLock { _requests.append(request) }
            if lock.withLock({ offline }) { throw URLError(.notConnectedToInternet) }
            let (status, body) = lock.withLock { handler(request) }
            let data = try body as? Data ?? JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
    }
}

@MainActor final class HomeworkSyncTests: XCTestCase {
    let childId = UUID(), familyId = UUID(), deviceId = UUID()
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        SessionStore().clear()
        try? FileManager.default.removeItem(at: directory)
    }

    private func homework(_ id: UUID, status: String = "NOT_STARTED", content: String = "口算本第 12 页", date: String = "2026-11-09",
                          mode: String = "OFFLINE", onlineKind: String? = nil) -> [String: Any] {
        ["id": id.uuidString, "childId": childId.uuidString, "subject": "MATH", "date": date, "dueDate": NSNull(), "content": content, "rawText": "",
         "mode": mode, "onlineKind": onlineKind ?? NSNull(), "durationMinutes": NSNull(), "parentTodo": "", "status": status, "source": "PASTE",
         "routineId": NSNull(), "attachmentIds": [], "version": 1, "submissions": []]
    }
    private var me: [String: Any] {
        ["cursor": 7, "device": ["id": deviceId.uuidString, "role": "child", "name": "iPad"],
         "family": ["id": familyId.uuidString, "name": "", "timezone": "Asia/Shanghai", "today": "2026-11-09"],
         "children": [["id": childId.uuidString, "name": "林林", "grade": 2, "avatar": ""]],
         "rules": ["finishTime": "19:30", "onTime": 5, "gradeExcellent": 5, "gradeGood": 3, "gradeFair": 1, "checkin": 3, "streak7": 10,
                   "dailyCap": 30, "windowStart": "19:00", "windowEnd": "20:30", "requireAllSubmitted": true]]
    }
    private var rewards: [String: Any] { ["childId": childId.uuidString, "balance": 0, "earnedToday": 0, "usedToday": 0, "entries": []] }

    private func connectedStore(_ server: FakeServer) async throws -> HomeworkStore {
        let store = HomeworkStore(directory: directory, transport: server.transport, uploadTransport: server.uploadTransport)
        try store.begin(DeviceSession(server: "https://homework.example", deviceId: deviceId, role: "child", familyId: familyId, token: String(repeating: "t", count: 64)))
        await store.sync()
        return store
    }

    func testClientValidatesServerAndMapsErrors() throws {
        XCTAssertEqual(try APIClient.validate("https://homework.example/").absoluteString, "https://homework.example")
        XCTAssertThrowsError(try APIClient.validate("http://homework.example"))
        XCTAssertThrowsError(try APIClient.validate("https://user@homework.example"))
        XCTAssertEqual(APIError.from(status: 409, code: "routine_limit"), .conflict("routine_limit"))
        XCTAssertEqual(APIError.from(status: 401, code: ""), .unauthorized)
        XCTAssertEqual(APIError.conflict("homework_pending").errorDescription, "今天还有作业没交，交完就能用奖励时间。")
        let request = try APIClient(baseURL: URL(string: "https://homework.example")!, token: "abc").request("GET", "v1/homework", query: [.init(name: "from", value: "2026-11-01")])
        XCTAssertEqual(request.url?.absoluteString, "https://homework.example/v1/homework?from=2026-11-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func testDayHelpers() {
        XCTAssertEqual(Day.add("2026-11-09", 1), "2026-11-10")
        XCTAssertEqual(Day.add("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(Day.weekday("2026-11-09"), 1, "Monday")
        XCTAssertEqual(Day.label("2026-11-08", today: "2026-11-09"), "昨天 · 11 月 8 日 周日")
    }

    func testFullRefreshThenChangeFeed() async throws {
        let first = UUID(), second = UUID()
        let server = FakeServer()
        var feed: [[String: Any]] = []
        var items = [homework(first)]
        server.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/v1/me"): return (200, self.me)
            case ("GET", "/v1/homework"):
                // Same limit as the server: at most 62 days per request.
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                let from = q.first { $0.name == "from" }?.value ?? "", to = q.first { $0.name == "to" }?.value ?? ""
                guard to >= from, Day.add(from, 62) >= to else { return (400, ["error": "invalid_range"]) }
                return (200, ["items": items])
            case ("GET", "/v1/routines"): return (200, ["routines": []])
            case ("GET", "/v1/rewards"): return (200, self.rewards)
            case ("GET", "/v1/changes"): return (200, ["changes": feed, "next": 9, "hasMore": false])
            case ("GET", "/v1/homework/\(second.uuidString.lowercased())"): return (200, self.homework(second, content: "背诵《咏柳》"))
            default: return (404, ["error": "not_found"])
            }
        }
        let store = try await connectedStore(server)
        XCTAssertEqual(store.children.map(\.name), ["林林"])
        XCTAssertEqual(store.homework[first]?.content, "口算本第 12 页")
        XCTAssertFalse(server.paths("GET").contains("/v1/changes"), "a fresh device starts from me.cursor instead of replaying the feed")

        feed = [["seq": 8, "entity": "homework", "id": second.uuidString.lowercased(), "op": "UPSERT"],
                ["seq": 9, "entity": "homework", "id": first.uuidString.lowercased(), "op": "DELETE"]]
        items = []
        await store.sync()
        XCTAssertNil(store.homework[first])
        XCTAssertEqual(store.homework[second]?.content, "背诵《咏柳》")
        XCTAssertTrue(server.requests.contains { $0.url?.query == "since=7" })
    }

    func testSubmissionMadeOfflineIsQueuedThenSentOnce() async throws {
        let id = UUID()
        let server = FakeServer()
        var submitted = 0
        server.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/v1/me"): return (200, self.me)
            case ("GET", "/v1/homework"): return (200, ["items": submitted > 0 ? [self.homework(id, status: "SUBMITTED")] : [self.homework(id)]])
            case ("GET", "/v1/routines"): return (200, ["routines": []])
            case ("GET", "/v1/rewards"): return (200, self.rewards)
            case ("GET", "/v1/changes"): return (200, ["changes": [], "next": 7, "hasMore": false])
            case ("PUT", _): return (200, ["id": "x", "kind": "IMAGE", "bytes": 4])
            case ("POST", "/v1/homework/\(id.uuidString.lowercased())/submissions"):
                submitted += 1
                return (200, self.homework(id, status: "SUBMITTED"))
            default: return (404, ["error": "not_found"])
            }
        }
        let store = try await connectedStore(server)
        let item = try XCTUnwrap(store.homework[id])

        server.offline = true
        await store.submit(item, pages: [HomeworkPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0x00]))])
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertEqual(store.homework[id]?.status, "SUBMITTED", "shown as handed in while offline")
        XCTAssertNil(store.errorMessage, "being offline is not an error")

        // A restart keeps the queue.
        let reopened = HomeworkStore(directory: directory, transport: server.transport, uploadTransport: server.uploadTransport)
        XCTAssertEqual(reopened.outbox.count, 1)

        server.offline = false
        await reopened.sync()
        XCTAssertTrue(reopened.outbox.isEmpty)
        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(server.paths("PUT").count, 2, "one failed and one successful upload of the same file id")
        XCTAssertEqual(Set(server.paths("PUT")).count, 1, "the retry reuses the file id")
        await reopened.sync()
        XCTAssertEqual(submitted, 1, "never sent twice")
    }

    func testVideoIsQueuedAsAFilePathAndUploadedFromDisk() async throws {
        let id = UUID()
        let server = FakeServer()
        var submitted = 0
        var submittedBody: [String: Any] = [:]
        server.handler = { request in
            let video = { (status: String) in self.homework(id, status: status, content: "跳绳 1 分钟，拍视频", mode: "ONLINE", onlineKind: "VIDEO") }
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/v1/me"): return (200, self.me)
            case ("GET", "/v1/homework"): return (200, ["items": [video(submitted > 0 ? "SUBMITTED" : "NOT_STARTED")]])
            case ("GET", "/v1/routines"): return (200, ["routines": []])
            case ("GET", "/v1/rewards"): return (200, self.rewards)
            case ("GET", "/v1/changes"): return (200, ["changes": [], "next": 7, "hasMore": false])
            case ("PUT", _): return (200, ["id": "x", "kind": "VIDEO", "bytes": 4])
            case ("POST", "/v1/homework/\(id.uuidString.lowercased())/submissions"):
                submitted += 1
                submittedBody = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                return (200, video("SUBMITTED"))
            default: return (404, ["error": "not_found"])
            }
        }
        let store = try await connectedStore(server)
        let item = try XCTUnwrap(store.homework[id])
        XCTAssertTrue(item.isVideo)

        // A compressed clip on disk (an MP4 header plus padding), handed in while offline.
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        var bytes = Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8)
        bytes.append(Data(count: 2_000_000))
        try bytes.write(to: clip)
        server.offline = true
        await store.submit(item, video: clip, durationSeconds: 75)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path), "moved into the queue, not copied")
        let pending = try XCTUnwrap(store.outbox.first)
        let file = try XCTUnwrap(pending.files.first)
        XCTAssertEqual(pending.files.count, 1)
        XCTAssertEqual(file.mime, "video/mp4")
        XCTAssertTrue(file.localName.hasSuffix(".mp4"))
        XCTAssertEqual(pending.durationSeconds, 75)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.outboxFileURL(file).path))
        let cache = try Data(contentsOf: directory.appendingPathComponent("cache.json"))
        XCTAssertLessThan(cache.count, 20_000, "the queue stores a file name, never the video bytes")
        XCTAssertNotNil(String(data: cache, encoding: .utf8)?.range(of: file.localName))
        XCTAssertEqual(store.homework[id]?.status, "SUBMITTED")

        // After a restart the queued video is uploaded from its file.
        let reopened = HomeworkStore(directory: directory, transport: server.transport, uploadTransport: server.uploadTransport)
        server.offline = false
        await reopened.sync()
        XCTAssertTrue(reopened.outbox.isEmpty)
        XCTAssertEqual(submitted, 1)
        let upload = try XCTUnwrap(server.uploads.last)
        XCTAssertEqual(upload.file.lastPathComponent, file.localName)
        XCTAssertEqual(upload.bytes, bytes.count)
        XCTAssertNil(upload.request.httpBody, "streamed from disk, not loaded into the request")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(upload.request.url?.path, "/v1/files/\(file.fileId.uuidString.lowercased())")
        XCTAssertGreaterThanOrEqual(upload.request.timeoutInterval, 120)
        XCTAssertEqual(submittedBody["fileIds"] as? [String], [file.fileId.uuidString])
        XCTAssertEqual(submittedBody["durationSeconds"] as? Int, 75)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.outboxFileURL(file).path), "the queued copy is removed once sent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.cachedFileURL(file.fileId).path), "videos are streamed later, not kept on the iPad")
        XCTAssertTrue(reopened.uploadProgress.isEmpty)
    }

    func testRejectedCredentialSignsTheDeviceOut() async throws {
        let server = FakeServer()
        server.handler = { _ in (401, ["error": "unauthorized"]) }
        let store = try await connectedStore(server)
        XCTAssertTrue(store.signedOut)
        XCTAssertEqual(store.errorMessage, APIError.unauthorized.errorDescription)
    }
}
