import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LittleBearTutor

/// A photographed exercise-book page: off-white paper with sensor noise, ruled lines and rows of dark characters.
func syntheticHomeworkPage(width: Int = 3024, height: Int = 4032) -> UIImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    var random = SystemRandomNumberGenerator()
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        // Uneven desk-lamp light, and faint paper grain.
        let light = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(white: 1, alpha: 0.35).cgColor, UIColor(white: 0, alpha: 0.12).cgColor] as CFArray, locations: [0, 1])!
        context.cgContext.drawRadialGradient(light, startCenter: CGPoint(x: size.width * 0.3, y: size.height * 0.2), startRadius: 0,
                                             endCenter: CGPoint(x: size.width * 0.3, y: size.height * 0.2), endRadius: size.height, options: .drawsAfterEndLocation)
        for _ in 0..<12_000 {
            UIColor(white: CGFloat.random(in: 0.6...1, using: &random), alpha: 0.06).setFill()
            context.fill(CGRect(x: CGFloat.random(in: 0..<size.width, using: &random), y: CGFloat.random(in: 0..<size.height, using: &random), width: 6, height: 6))
        }
        UIColor(red: 0.6, green: 0.7, blue: 0.85, alpha: 1).setFill()
        let rows = stride(from: CGFloat(240), to: size.height - 160, by: 150)
        for y in rows { context.fill(CGRect(x: 120, y: y, width: size.width - 240, height: 3)) }
        let words = "一二三四五六七八九十口算本第页小熊伴学天地人你我他上下左右大小多少春夏秋冬"
        let font = UIFont.systemFont(ofSize: 92, weight: .medium)
        for (row, y) in rows.enumerated() where row % 7 != 6 {
            let line = String((0..<26).map { _ in words.randomElement(using: &random)! })
            (line as NSString).draw(at: CGPoint(x: 150 + CGFloat.random(in: -8...8, using: &random), y: y - 112),
                                    withAttributes: [.font: font, .foregroundColor: UIColor(white: 0.15, alpha: 0.9)])
        }
    }
}

final class HomeworkPhotoTests: XCTestCase {
    private func pixelSize(_ data: Data) throws -> CGSize { try XCTUnwrap(ImageDecoder.pixelSize(data)) }

    func testHomeworkPhotoIs1400PxAtQuality07WithA480PxThumbnail() throws {
        let page = syntheticHomeworkPage()
        let photo = try XCTUnwrap(PhotoStore.homeworkPhoto(page))
        let thumbnail = try XCTUnwrap(photo.thumbnail)

        XCTAssertTrue(photo.jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try pixelSize(photo.jpeg), CGSize(width: 1050, height: 1400))
        XCTAssertLessThanOrEqual(photo.jpeg.count, PhotoStore.homeworkMaxBytes)
        // Quality starts at 0.7: the same bytes as encoding the 1400 px rendering at 0.7.
        let rendered = try XCTUnwrap(PhotoStore.render(page, longSide: 1400))
        XCTAssertEqual(photo.jpeg, rendered.jpegData(compressionQuality: 0.7))
        XCTAssertEqual(PhotoStore.homeworkJPEG(page), photo.jpeg)

        XCTAssertTrue(thumbnail.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try pixelSize(thumbnail), CGSize(width: 360, height: 480))
        XCTAssertLessThanOrEqual(thumbnail.count, PhotoStore.thumbnailMaxBytes)
        XCTAssertLessThan(thumbnail.count, 120_000, "a list thumbnail is tens of KB, even for a page full of characters")
        XCTAssertEqual(thumbnail, try XCTUnwrap(PhotoStore.render(rendered, longSide: 480)).jpegData(compressionQuality: 0.6))
        XCTAssertLessThan(thumbnail.count * 4, photo.jpeg.count)

        // The old gateway JPEG of the same page, for comparison: the homework JPEG is much smaller.
        let gateway = try XCTUnwrap(PhotoStore.gatewayJPEG(page))
        XCTAssertLessThan(photo.jpeg.count * 5, gateway.count * 3)
    }

    func testSmallPhotosAreNotUpscaledAndQualityStepsDownWhenTooLarge() throws {
        let small = syntheticHomeworkPage(width: 300, height: 200)
        let photo = try XCTUnwrap(PhotoStore.homeworkPhoto(small))
        XCTAssertEqual(try pixelSize(photo.jpeg), CGSize(width: 300, height: 200))
        XCTAssertEqual(try pixelSize(try XCTUnwrap(photo.thumbnail)), CGSize(width: 300, height: 200))

        let page = try XCTUnwrap(PhotoStore.render(syntheticHomeworkPage(), longSide: 1400))
        let atStart = try XCTUnwrap(page.jpegData(compressionQuality: 0.7))
        let squeezed = try XCTUnwrap(PhotoStore.encode(page, from: 0.7, maxBytes: atStart.count - 1))
        XCTAssertLessThan(squeezed.count, atStart.count, "steps below 0.7 only when the JPEG is over the limit")
        XCTAssertNil(PhotoStore.encode(page, from: 0.7, maxBytes: 100))
    }

    /// A camera photo held upright is stored sideways with an EXIF orientation; pages and thumbnails come out upright.
    func testPagesAndThumbnailsAreRenderedUpright() throws {
        // Sensor image 2000×1500: left half red, right half blue. `.right` displays it turned clockwise: red on top.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let sensor = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1500), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1500))
            UIColor.blue.setFill(); context.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1500))
        }
        let camera = UIImage(cgImage: try XCTUnwrap(sensor.cgImage), scale: 1, orientation: .right)
        let photo = try XCTUnwrap(PhotoStore.homeworkPhoto(camera))
        for (data, size) in [(photo.jpeg, CGSize(width: 1050, height: 1400)), (try XCTUnwrap(photo.thumbnail), CGSize(width: 360, height: 480))] {
            XCTAssertEqual(try pixelSize(data), size)
            let decoded = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(decoded.imageOrientation, .up)
            let top = try color(decoded, at: CGPoint(x: 0.5, y: 0.1)), bottom = try color(decoded, at: CGPoint(x: 0.5, y: 0.9))
            XCTAssertGreaterThan(top.r, 0.8); XCTAssertLessThan(top.b, 0.2)
            XCTAssertGreaterThan(bottom.b, 0.8); XCTAssertLessThan(bottom.r, 0.2)
        }
    }

    func testDisplaySizeDecodingAsksForOnlyTheShownPixels() throws {
        // 90×90 attachment, filled, on a 3× phone: the short side must cover 270 px.
        XCTAssertEqual(ImageDecoder.maxPixelSize(image: CGSize(width: 1400, height: 1050), box: CGSize(width: 90, height: 90), mode: .fill, scale: 3), 360)
        // 120×160 submission page, fitted, on a 2× iPad.
        XCTAssertEqual(ImageDecoder.maxPixelSize(image: CGSize(width: 1050, height: 1400), box: CGSize(width: 120, height: 160), mode: .fit, scale: 2), 320)
        // Never more than the image has.
        XCTAssertEqual(ImageDecoder.maxPixelSize(image: CGSize(width: 360, height: 480), box: CGSize(width: 1000, height: 1000), mode: .fit, scale: 3), 480)

        let photo = try XCTUnwrap(PhotoStore.homeworkPhoto(syntheticHomeworkPage()))
        let small = try XCTUnwrap(ImageDecoder.downsample(photo.jpeg, box: CGSize(width: 120, height: 160), mode: .fit, scale: 2))
        XCTAssertEqual(small.cgImage?.width, 240)
        XCTAssertEqual(small.cgImage?.height, 320)
    }

    func testDownsamplingAppliesTheExifOrientation() throws {
        // A 400×300 JPEG tagged orientation 6 (shown turned clockwise, 300×400).
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let sensor = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.blue.setFill(); context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        }.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sensor, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(ImageDecoder.pixelSize(data as Data), CGSize(width: 300, height: 400))
        let shown = try XCTUnwrap(ImageDecoder.downsample(data as Data, box: CGSize(width: 75, height: 100), mode: .fit, scale: 2))
        XCTAssertEqual(shown.cgImage?.width, 150)
        XCTAssertEqual(shown.cgImage?.height, 200)
        XCTAssertGreaterThan(try color(shown, at: CGPoint(x: 0.5, y: 0.1)).r, 0.8, "red on top, as shown")
    }

    /// Average colour of a small patch at a relative position.
    private func color(_ image: UIImage, at point: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Draw so that the requested point (top-left origin) lands on the single pixel.
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: -point.x * w, y: -(1 - point.y) * h, width: w, height: h))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}

// MARK: - Outbox thumbnails, thumbnail loading, prefetching

@MainActor final class PhotoSpeedStoreTests: XCTestCase {
    let childId = UUID(), familyId = UUID(), deviceId = UUID()
    var directory: URL!
    let today = Day.string(Date(), TimeZone(identifier: "Asia/Shanghai")!)

    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() {
        SessionStore().clear()
        try? FileManager.default.removeItem(at: directory)
    }

    private func homework(_ id: UUID, status: String = "NOT_STARTED", date: String? = nil, mode: String = "OFFLINE", onlineKind: String? = nil,
                          attachments: [UUID] = [], submitted: [UUID]? = nil) -> [String: Any] {
        var submissions: [[String: Any]] = []
        if let submitted {
            submissions = [["id": UUID().uuidString, "attempt": 1, "fileIds": submitted.map(\.uuidString), "durationSeconds": NSNull(),
                            "submittedAt": "\(today)T10:00:00Z", "receivedAt": "\(today)T10:00:01Z", "onTime": true, "review": NSNull()]]
        }
        return ["id": id.uuidString, "childId": childId.uuidString, "subject": "MATH", "date": date ?? today, "dueDate": NSNull(), "content": "口算本第 12 页",
                "rawText": "", "mode": mode, "onlineKind": onlineKind ?? NSNull(), "durationMinutes": NSNull(), "parentTodo": "", "status": status,
                "source": "PASTE", "routineId": NSNull(), "attachmentIds": attachments.map(\.uuidString), "version": 1, "submissions": submissions]
    }
    private var me: [String: Any] {
        ["cursor": 7, "device": ["id": deviceId.uuidString, "role": "child", "name": "iPad"],
         "family": ["id": familyId.uuidString, "name": "", "timezone": "Asia/Shanghai", "today": today],
         "children": [["id": childId.uuidString, "name": "林林", "grade": 2, "avatar": ""]],
         "rules": ["finishTime": "19:30", "onTime": 5, "gradeExcellent": 5, "gradeGood": 3, "gradeFair": 1, "checkin": 3, "streak7": 10,
                   "dailyCap": 30, "windowStart": "19:00", "windowEnd": "20:30", "requireAllSubmitted": true]]
    }
    private var rewards: [String: Any] { ["childId": childId.uuidString, "balance": 0, "earnedToday": 0, "usedToday": 0, "entries": []] }

    /// Answers the sync endpoints with `items`; everything else goes to `files`.
    private func serve(_ server: FakeServer, items: @escaping () -> [[String: Any]], files: @escaping (URLRequest) -> (Int, Any)) {
        server.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/v1/me"): return (200, self.me)
            case ("GET", "/v1/homework"): return (200, ["items": items()])
            case ("GET", "/v1/routines"): return (200, ["routines": []])
            case ("GET", "/v1/rewards"): return (200, self.rewards)
            case ("GET", "/v1/changes"): return (200, ["changes": [], "next": 7, "hasMore": false])
            default: return files(request)
            }
        }
    }

    private func store(_ server: FakeServer, role: String) throws -> HomeworkStore {
        let store = HomeworkStore(directory: directory, transport: server.transport, uploadTransport: server.uploadTransport)
        try store.begin(DeviceSession(server: "https://homework.example", deviceId: deviceId, role: role, familyId: familyId, token: String(repeating: "t", count: 64)))
        return store
    }

    private func path(_ id: UUID, thumb: Bool = false) -> String { "/v1/files/\(id.uuidString.lowercased())\(thumb ? "/thumb" : "")" }

    func testOutboxCarriesTheThumbnailAndUploadsItRightAfterThePhoto() async throws {
        let id = UUID()
        let server = FakeServer()
        var submitted = 0
        var submittedBody: [String: Any] = [:]
        serve(server, items: { [self.homework(id, status: submitted > 0 ? "SUBMITTED" : "NOT_STARTED")] }) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("PUT", let p) where p.hasSuffix("/thumb"): return (200, ["id": "x", "bytes": request.httpBody?.count ?? 0])
            case ("PUT", _): return (200, ["id": "x", "kind": "IMAGE", "bytes": 4])
            case ("POST", "/v1/homework/\(id.uuidString.lowercased())/submissions"):
                submitted += 1
                submittedBody = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                return (200, self.homework(id, status: "SUBMITTED"))
            default: return (404, ["error": "not_found"])
            }
        }
        let store = try store(server, role: "child")
        await store.sync()
        let item = try XCTUnwrap(store.homework[id])

        let page = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02]), thumb = Data([0xFF, 0xD8, 0xFF, 0x09])
        server.offline = true
        await store.submit(item, pages: [HomeworkPhoto(jpeg: page, thumbnail: thumb)])
        let file = try XCTUnwrap(store.outbox.first?.files.first)
        let queuedThumb = try XCTUnwrap(store.outboxThumbnailURL(file))
        XCTAssertEqual(try Data(contentsOf: queuedThumb), thumb, "kept as a file next to the photo")
        let cache = try XCTUnwrap(String(data: Data(contentsOf: directory.appendingPathComponent("cache.json")), encoding: .utf8))
        XCTAssertNotNil(cache.range(of: queuedThumb.lastPathComponent), "the queue stores the thumbnail's name")

        // After a restart: photo, then its thumbnail, then the submission.
        let reopened = HomeworkStore(directory: directory, transport: server.transport, uploadTransport: server.uploadTransport)
        let before = server.requests.count
        server.offline = false
        await reopened.sync()
        let sent = server.requests.dropFirst(before).filter { $0.httpMethod != "GET" }
        XCTAssertEqual(sent.map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["PUT \(path(file.fileId))", "PUT \(path(file.fileId, thumb: true))", "POST /v1/homework/\(id.uuidString.lowercased())/submissions"])
        let thumbRequest = sent[1]
        XCTAssertEqual(thumbRequest.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(thumbRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "t", count: 64))")
        XCTAssertEqual(thumbRequest.httpBody, thumb)
        XCTAssertEqual(submittedBody["fileIds"] as? [String], [file.fileId.uuidString], "the thumbnail is not a submitted file")
        XCTAssertEqual(submitted, 1)
        XCTAssertTrue(reopened.outbox.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedThumb.path), "removed from the queue once sent")
        XCTAssertEqual(try Data(contentsOf: reopened.cachedThumbnailURL(file.fileId)), thumb, "kept for the child's own lists")
        XCTAssertEqual(try Data(contentsOf: reopened.cachedFileURL(file.fileId)), page)
    }

    func testAFailedThumbnailUploadNeverHoldsUpTheSubmission() async throws {
        let id = UUID()
        let server = FakeServer()
        var submitted = 0
        serve(server, items: { [self.homework(id, status: submitted > 0 ? "SUBMITTED" : "NOT_STARTED")] }) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("PUT", let p) where p.hasSuffix("/thumb"): return (500, ["error": "internal"])
            case ("PUT", _): return (200, ["id": "x", "kind": "IMAGE", "bytes": 4])
            case ("POST", _):
                submitted += 1
                return (200, self.homework(id, status: "SUBMITTED"))
            default: return (404, ["error": "not_found"])
            }
        }
        let store = try store(server, role: "child")
        await store.sync()
        await store.submit(try XCTUnwrap(store.homework[id]), pages: [HomeworkPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0x01]), thumbnail: Data([0xFF, 0xD8, 0xFF, 0x02]))])
        XCTAssertEqual(submitted, 1)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(server.paths("PUT").filter { $0.hasSuffix("/thumb") }.count, 1, "tried once, then skipped")
        XCTAssertEqual(store.homework[id]?.status, "SUBMITTED")
    }

    func testParentAttachmentsUploadTheirThumbnails() async throws {
        let server = FakeServer()
        serve(server, items: { [] }) { request in
            request.httpMethod == "PUT" ? (200, ["id": "x", "kind": "IMAGE", "bytes": 4]) : (404, ["error": "not_found"])
        }
        let store = try store(server, role: "parent")
        let thumb = Data([0xFF, 0xD8, 0xFF, 0x07])
        let ids = try await store.uploadImages([HomeworkPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0x01]), thumbnail: thumb), HomeworkPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0x03]))])
        XCTAssertEqual(server.paths("PUT"), [path(ids[0]), path(ids[0], thumb: true), path(ids[1])])
        XCTAssertEqual(try Data(contentsOf: store.cachedThumbnailURL(ids[0])), thumb)
    }

    func testListsLoadTheThumbnailAndFallBackToThePhotoOn404() async throws {
        let old = UUID(), new = UUID(), local = UUID()
        let photo = Data([0xFF, 0xD8, 0xFF, 0xAA]), thumb = Data([0xFF, 0xD8, 0xFF, 0xBB])
        let server = FakeServer()
        serve(server, items: { [] }) { request in
            switch request.url!.path {
            case self.path(old, thumb: true): return (404, ["error": "thumb_not_found"])
            case self.path(old): return (200, photo)
            case self.path(new, thumb: true): return (200, thumb)
            default: return (500, ["error": "unexpected"])
            }
        }
        let store = try store(server, role: "child")

        // A photo from an older app: no thumbnail, so the photo itself, cached as the full file.
        do { let loaded = try await store.thumbnailData(old); XCTAssertEqual(loaded, photo) }
        XCTAssertEqual(server.paths("GET"), [path(old, thumb: true), path(old)])
        XCTAssertEqual(try Data(contentsOf: store.cachedFileURL(old)), photo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cachedThumbnailURL(old).path))
        do { let loaded = try await store.thumbnailData(old); XCTAssertEqual(loaded, photo) }
        XCTAssertEqual(server.paths("GET").count, 2, "served from the disk cache the second time")

        // A new photo: only its thumbnail is downloaded, cached apart from the full file.
        do { let loaded = try await store.thumbnailData(new); XCTAssertEqual(loaded, thumb) }
        XCTAssertEqual(server.paths("GET").last, path(new, thumb: true))
        XCTAssertEqual(try Data(contentsOf: store.cachedThumbnailURL(new)), thumb)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cachedFileURL(new).path))
        XCTAssertEqual(store.cachedThumbnailURL(new).lastPathComponent, "\(new.uuidString).thumb")

        // A photo already on the device needs no download at all.
        try photo.write(to: store.cachedFileURL(local))
        do { let loaded = try await store.thumbnailData(local); XCTAssertEqual(loaded, photo) }
        XCTAssertEqual(server.paths("GET").count, 3)
    }

    func testPrefetchPicksPagesWaitingForReviewThenRecentAttachments() throws {
        let decoder = JSONDecoder()
        func item(_ json: [String: Any]) throws -> RemoteHomework { try decoder.decode(RemoteHomework.self, from: JSONSerialization.data(withJSONObject: json)) }
        let p1 = UUID(), p2 = UUID(), audio = UUID(), video = UUID(), reviewed = UUID(), recent = UUID(), old = UUID(), shared = UUID()
        let items = try [
            item(homework(UUID(), status: "SUBMITTED", submitted: [p1, p2])),
            item(homework(UUID(), status: "SUBMITTED", mode: "ONLINE", onlineKind: "RECORDING", submitted: [audio])),
            item(homework(UUID(), status: "SUBMITTED", mode: "ONLINE", onlineKind: "VIDEO", submitted: [video])),
            item(homework(UUID(), status: "REVIEWED", submitted: [reviewed])),
            item(homework(UUID(), date: Day.add(today, -2), attachments: [recent, shared])),
            item(homework(UUID(), date: Day.add(today, -1), attachments: [shared])),
            item(homework(UUID(), date: Day.add(today, -30), attachments: [old]))
        ]
        let targets = HomeworkStore.prefetchTargets(items, today: today)
        XCTAssertEqual(Array(targets.prefix(2)), [p1, p2], "pages waiting for review come first")
        XCTAssertEqual(Set(targets), [p1, p2, recent, shared])
        XCTAssertEqual(targets.count, 4, "each file once")
    }

    func testParentPrefetchesThumbnailsThenPhotosSkippingCachedOnes() async throws {
        let waiting = UUID(), p1 = UUID(), p2 = UUID(), attachment = UUID(), audio = UUID(), broken = UUID()
        let server = FakeServer()
        let items = [homework(waiting, status: "SUBMITTED", submitted: [p1, p2, broken]),
                     homework(UUID(), status: "SUBMITTED", mode: "ONLINE", onlineKind: "RECORDING", submitted: [audio]),
                     homework(UUID(), date: Day.add(today, -1), attachments: [attachment])]
        serve(server, items: { items }) { request in
            switch request.url!.path {
            case self.path(p1, thumb: true): return (200, Data([0xFF, 0xD8, 0xFF, 0x11]))
            case self.path(p1): return (200, Data([0xFF, 0xD8, 0xFF, 0x12]))
            case self.path(attachment, thumb: true), self.path(broken, thumb: true): return (404, ["error": "thumb_not_found"])
            case self.path(attachment): return (200, Data([0xFF, 0xD8, 0xFF, 0x13]))
            case self.path(broken): return (500, ["error": "internal"])
            default: return (404, ["error": "file_not_found"])
            }
        }
        let store = try store(server, role: "parent")
        try Data([0xFF, 0xD8, 0xFF, 0x22]).write(to: store.cachedFileURL(p2))

        await store.sync()
        let task = try XCTUnwrap(store.prefetchTask, "started in the background after the sync")
        await task.value
        let files = server.paths("GET").filter { $0.hasPrefix("/v1/files/") }
        XCTAssertEqual(files, [path(p1, thumb: true), path(broken, thumb: true), path(attachment, thumb: true), path(p1), path(broken), path(attachment)],
                       "thumbnails first, one at a time; nothing for the cached page or the recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cachedThumbnailURL(p1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cachedFileURL(p1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cachedFileURL(attachment).path))

        // Later syncs only retry the failed photo, and give it up after a couple of tries.
        for _ in 0..<3 {
            await store.sync()
            await store.prefetchTask?.value
        }
        let later = server.paths("GET").filter { $0.hasPrefix("/v1/files/") }.dropFirst(files.count)
        XCTAssertEqual(Array(later), [path(broken)], "\(HomeworkStore.prefetchAttempts) tries in all")
    }

    func testNoPrefetchInTheBackgroundOrOnTheChildDevice() async throws {
        let server = FakeServer()
        let photo = UUID()
        serve(server, items: { [self.homework(UUID(), status: "SUBMITTED", submitted: [photo])] }) { _ in (200, Data([0xFF, 0xD8, 0xFF, 0x01])) }

        let parent = try store(server, role: "parent")
        parent.setActive(false)
        await parent.sync()
        XCTAssertNil(parent.prefetchTask)
        parent.signOut()

        let child = try store(server, role: "child")
        await child.sync()
        XCTAssertNil(child.prefetchTask)
        XCTAssertFalse(server.paths("GET").contains { $0.hasPrefix("/v1/files/") })
    }
}
