import AVFoundation
import XCTest
@testable import LittleBearTutor

/// Video homework: how the kind is chosen and labelled, the 480p/bitrate rules, the 30-minute limit, and a real compression.
final class VideoHomeworkTests: XCTestCase {

    private func homework(mode: String, onlineKind: String?, minutes: Int? = nil) -> RemoteHomework {
        RemoteHomework(id: UUID(), childId: UUID(), subject: "OTHER", date: "2026-11-21", dueDate: nil, content: "跳绳 1 分钟", rawText: "",
                       mode: mode, onlineKind: onlineKind, durationMinutes: minutes, parentTodo: "", status: "NOT_STARTED", source: "PASTE",
                       routineId: nil, attachmentIds: [], version: 1, submissions: [])
    }

    func testVideoKindMapsBothWays() {
        XCTAssertEqual(DoneBy(mode: "ONLINE", onlineKind: "VIDEO"), .video)
        XCTAssertEqual(DoneBy(mode: "ONLINE", onlineKind: "RECORDING"), .recording)
        XCTAssertEqual(DoneBy(mode: "ONLINE", onlineKind: "TIMER"), .timer)
        XCTAssertEqual(DoneBy(mode: "OFFLINE", onlineKind: nil), .photo)
        XCTAssertEqual(DoneBy(mode: "ONLINE", onlineKind: "SOMETHING_NEW"), .recording, "unknown kinds keep the old fallback")
        XCTAssertEqual(DoneBy.video.mode, "ONLINE")
        XCTAssertEqual(DoneBy.video.onlineKind, "VIDEO")
        XCTAssertFalse(DoneBy.video.usesDuration)
        XCTAssertEqual(DoneBy.video.label, "在 iPad 上录像")
        XCTAssertEqual(DoneBy.allCases, [.photo, .timer, .recording, .video], "录像 is offered next to 计时 and 录音")
    }

    func testLabelsForTheChild() {
        let video = homework(mode: "ONLINE", onlineKind: "VIDEO")
        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(video.isRecording)
        XCTAssertEqual(modeLabel(video), "在 iPad 上录像")
        XCTAssertEqual(modeLabel(homework(mode: "ONLINE", onlineKind: "RECORDING")), "在 iPad 上录音")
        XCTAssertEqual(modeLabel(homework(mode: "ONLINE", onlineKind: "TIMER", minutes: 20)), "在 iPad 上计时 20 分钟")
        XCTAssertEqual(APIError.rejected("video_required").errorDescription, "要先录一段视频。")
    }

    func testRoutineWithVideo() {
        var draft = RoutineDraft()
        draft.title = "跳绳"
        draft.kind = .video
        draft.weekdays = Set(1...5)
        XCTAssertEqual(draft.summary, "周一到周五 · 在 iPad 上录像")
        XCTAssertEqual(draft.input.mode, "ONLINE")
        XCTAssertEqual(draft.input.onlineKind, "VIDEO")
        XCTAssertNil(draft.input.durationMinutes)
        let routine = Routine(id: UUID(), childId: UUID(), title: "跳绳", subject: "OTHER", mode: "ONLINE", onlineKind: "VIDEO",
                              durationMinutes: nil, quantity: nil, weekdays: [1, 3], active: true, sortOrder: 0)
        XCTAssertEqual(RoutineDraft(routine).kind, .video)
    }

    func testAIParsedKindIsTheDefault() throws {
        func parsed(_ mode: String, _ kind: String?) -> DraftItem {
            DraftItem(ParsedItem(subject: "OTHER", content: "x", mode: mode, onlineKind: kind, dueText: "", dueDate: nil, parentTodo: ""), date: "2026-11-21", attachImages: false)
        }
        XCTAssertEqual(parsed("ONLINE", "VIDEO").kind, .video)
        XCTAssertEqual(parsed("ONLINE", "TIMER").kind, .timer)
        XCTAssertEqual(parsed("ONLINE", "RECORDING").kind, .recording)
        XCTAssertEqual(parsed("ONLINE", nil).kind, .recording, "no suggestion keeps the old default")
        XCTAssertEqual(parsed("OFFLINE", "VIDEO").kind, .photo)

        // An older server sends no onlineKind at all.
        let json = #"{"items":[{"subject":"CHINESE","content":"朗读第 3 课","mode":"ONLINE","dueText":"","dueDate":null,"parentTodo":""}],"message":""}"#
        let result = try JSONDecoder().decode(ParseResult.self, from: Data(json.utf8))
        XCTAssertNil(result.items[0].onlineKind)
        let current = #"{"items":[{"subject":"OTHER","content":"跳绳","mode":"ONLINE","onlineKind":"VIDEO","dueText":"","dueDate":null,"parentTodo":""}],"message":""}"#
        XCTAssertEqual(try JSONDecoder().decode(ParseResult.self, from: Data(current.utf8)).items[0].onlineKind, "VIDEO")
    }

    func testOutputSizeIs480pKeepingAspect() {
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 854, height: 480))
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 480, height: 854))
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 854, height: 480))
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 1440, height: 1080)), CGSize(width: 640, height: 480))
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 320, height: 240)), CGSize(width: 320, height: 240), "never upscaled")
        XCTAssertEqual(VideoSpec.outputSize(for: CGSize(width: 321, height: 241)), CGSize(width: 322, height: 242), "even sides for H.264")
        XCTAssertEqual(VideoSpec.outputSize(for: .zero), .zero)
    }

    func testBitrateAndSizeFitTheServer() {
        XCTAssertEqual(VideoSpec.videoBitrate(for: CGSize(width: 854, height: 480)), 800_000)
        XCTAssertEqual(VideoSpec.videoBitrate(for: CGSize(width: 480, height: 854)), 800_000)
        XCTAssertEqual(VideoSpec.videoBitrate(for: CGSize(width: 480, height: 360)), 450_000, "smaller source, fewer bits by area")
        XCTAssertEqual(VideoSpec.videoBitrate(for: CGSize(width: 160, height: 120)), 200_000, "floor")
        XCTAssertEqual(VideoSpec.audioBitrate, 64_000)
        let thirtyMinutes = VideoSpec.estimatedBytes(seconds: VideoSpec.maxDuration)
        XCTAssertEqual(thirtyMinutes, 194_400_000)
        XCTAssertLessThan(Double(thirtyMinutes) * 1.05, Double(VideoSpec.serverLimit), "30 minutes stays under the 300 MB upload limit with container overhead")
    }

    func testThirtyMinuteLimit() {
        XCTAssertEqual(VideoSpec.maxDuration, 1800)
        XCTAssertNil(VideoSpec.problem(duration: 75))
        XCTAssertNil(VideoSpec.problem(duration: 1800))
        XCTAssertNil(VideoSpec.problem(duration: 1800.6), "the camera's rounding is not a reason to refuse")
        XCTAssertEqual(VideoSpec.problem(duration: 1802), "这段视频超过 30 分钟了，交不了。请选一段 30 分钟以内的视频，或者重新录。")
        XCTAssertNotNil(VideoSpec.problem(duration: 0.3))
        XCTAssertNotNil(VideoSpec.problem(duration: .nan))
    }

    func testStreamingURLAndHeaders() throws {
        let api = APIClient(baseURL: URL(string: "https://homework.example")!, token: "abc")
        let id = UUID()
        XCTAssertEqual(api.fileURL(id).absoluteString, "https://homework.example/v1/files/\(id.uuidString.lowercased())")
        XCTAssertEqual(api.authorizationHeader, ["Authorization": "Bearer abc"])
    }

    // MARK: Real compression in the simulator

    func testCompressesTo480pH264MP4KeepingRotationAndSound() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)   // exactly 90°, as an iPad camera tags a portrait clip
        try await Self.makeClip(at: source, size: CGSize(width: 1280, height: 720), seconds: 2, transform: rotation)
        let sourceDuration = await VideoCompressor.duration(of: source)
        XCTAssertEqual(sourceDuration ?? 0, 2, accuracy: 0.2)

        let reports = Reports()
        try await VideoCompressor.compress(source, to: output) { reports.add($0) }

        let head = try FileHandle(forReadingFrom: output).read(upToCount: 12) ?? Data()
        XCTAssertEqual(String(data: head.subdata(in: 4..<8), encoding: .ascii), "ftyp", "the server checks bytes 4–8")
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let (size, transform, formats) = try await video.load(.naturalSize, .preferredTransform, .formatDescriptions)
        XCTAssertEqual(size, CGSize(width: 854, height: 480))
        XCTAssertEqual(transform, rotation, "portrait clips still play upright")
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first, "sound is kept")
        let audioFormats = try await audio.load(.formatDescriptions)
        XCTAssertEqual(audioFormats.first.map(CMFormatDescriptionGetMediaSubType), kAudioFormatMPEG4AAC)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.2)
        XCTAssertEqual(reports.last, 1)
        XCTAssertTrue(reports.values.allSatisfy { (0...1).contains($0) })
    }

    func testCompressionFailsCleanlyForANonVideo() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).mp4")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            try await VideoCompressor.compress(source, to: output) { _ in }
            XCTFail("should throw")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no half-written file is left behind")
        let duration = await VideoCompressor.duration(of: source)
        XCTAssertNil(duration)
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []
        func add(_ value: Double) { lock.withLock { _values.append(value) } }
        var values: [Double] { lock.withLock { _values } }
        var last: Double? { values.last }
    }

    /// Writes a short H.264 clip with a sine tone, the way a camera would (rotation as track metadata).
    static func makeClip(at url: URL, size: CGSize, seconds: Int, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                             AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        videoIn.expectsMediaDataInRealTime = true
        videoIn.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                                             AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        audioIn.expectsMediaDataInRealTime = true
        writer.add(videoIn)
        writer.add(audioIn)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)

        func waitUntilReady(_ input: AVAssetWriterInput) async { while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(2)) } }
        let fps = 30, chunk = 4_410   // 0.1 s of audio per step, 3 frames of video per step
        for step in 0..<(seconds * 10) {
            for f in 0..<3 {
                let frame = step * 3 + f
                await waitUntilReady(videoIn)
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
                let pixels = try XCTUnwrap(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(pixels))
                CVPixelBufferUnlockBaseAddress(pixels, [])
                XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))))
            }
            await waitUntilReady(audioIn)
            var samples = (0..<chunk * 2).map { i in Int16(sin(Double(step * chunk + i / 2) / 44_100 * 2 * .pi * 440) * 8_000) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 4, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: chunk * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0, dataLength: chunk * 4)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: try XCTUnwrap(block), formatDescription: try XCTUnwrap(audioFormat),
                                                                 sampleCount: chunk, presentationTimeStamp: CMTime(value: Int64(step * chunk), timescale: 44_100),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            XCTAssertTrue(audioIn.append(try XCTUnwrap(sample)))
        }
        videoIn.markAsFinished()
        audioIn.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}
