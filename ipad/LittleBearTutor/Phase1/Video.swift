import AVFoundation
import AVKit
import CoreTransferable
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Video homework: limits and the size we send

/// What a homework video may be and how it is compressed before upload.
enum VideoSpec {
    static let maxDuration: TimeInterval = 1800       // 30 minutes
    static let shortSide: CGFloat = 480               // 480p
    static let videoBitrate = 800_000                 // H.264, bits per second at 480p
    static let audioBitrate = 64_000                  // AAC
    static let serverLimit: Int64 = 300_000_000       // `PUT /v1/files` refuses larger videos

    /// Encoded frame size: short side 480 (never upscaled), aspect kept, both sides even as H.264 needs.
    static func outputSize(for natural: CGSize) -> CGSize {
        let w = abs(natural.width), h = abs(natural.height)
        guard w > 0, h > 0 else { return .zero }
        let scale = min(1, shortSide / min(w, h))
        func even(_ side: CGFloat) -> CGFloat { max(2, (side * scale / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    /// 0.8 Mbps at 480p; a smaller source gets proportionally fewer bits (by area), never under 200 kbps.
    static func videoBitrate(for size: CGSize) -> Int {
        let short = min(size.width, size.height)
        guard short > 0, short < shortSide else { return videoBitrate }
        let ratio = Double(short / shortSide) * Double(short / shortSide)
        return max(200_000, Int((Double(videoBitrate) * ratio).rounded()))
    }

    /// About 194 MB for 30 minutes.
    static func estimatedBytes(seconds: TimeInterval) -> Int64 { Int64(Double(videoBitrate + audioBitrate) / 8 * seconds) }

    /// nil when the clip can be handed in, otherwise what to tell the child. A second of slack covers the camera's rounding.
    static func problem(duration: TimeInterval) -> String? {
        if !duration.isFinite || duration < 1 { return "这段视频太短了，请重新录一段。" }
        if duration > maxDuration + 1 { return "这段视频超过 30 分钟了，交不了。请选一段 30 分钟以内的视频，或者重新录。" }
        return nil
    }
}

enum VideoFiles {
    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
    }
}

// MARK: - Compression (AVAssetReader → AVAssetWriter, so the bitrate is ours, not a preset's)

enum VideoCompressor {
    enum Failure: Error { case noVideoTrack, cannotWrite }

    static func duration(of url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    /// Re-encodes `source` as an H.264/AAC `.mp4` at 480p, streaming frame by frame (nothing is held in memory).
    /// The rotation stays as track metadata, so portrait clips play upright. Reports 0…1; cancelling the task stops it.
    static func compress(_ source: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        do { try await run(source, output, progress) } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func run(_ source: URL, _ output: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let size = VideoSpec.outputSize(for: natural)
        guard size.width > 0 else { throw Failure.noVideoTrack }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // index first, so a player can start before the whole file arrives

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoSpec.videoBitrate(for: size),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw Failure.cannotWrite }
        reader.add(videoOut)
        writer.add(videoIn)

        var audio: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: VideoSpec.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) { reader.add(out); writer.add(input); audio = (out, input) }
        }

        guard reader.startReading() else { throw reader.error ?? Failure.cannotWrite }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? Failure.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let job = Transcode(reader: reader, writer: writer, duration: duration, progress: progress,
                            pairs: [(videoOut, videoIn, true)] + (audio.map { [($0.0, $0.1, false)] } ?? []))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                job.run { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// The reader/writer pair driven on one serial queue; AVFoundation objects are not Sendable, so they live only here.
private final class Transcode: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let duration: Double
    let progress: @Sendable (Double) -> Void
    let pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)]
    private let queue = DispatchQueue(label: "cn.littlebear.video.compress")

    init(reader: AVAssetReader, writer: AVAssetWriter, duration: Double, progress: @escaping @Sendable (Double) -> Void,
         pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)]) {
        self.reader = reader; self.writer = writer; self.duration = duration; self.progress = progress; self.pairs = pairs
    }

    func cancel() { reader.cancelReading() }

    func run(_ done: @escaping @Sendable (Error?) -> Void) {
        let group = DispatchGroup()
        for (output, input, reports) in pairs {
            group.enter()
            var finished = false   // only touched on `queue`
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !finished && input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                        finished = true; input.markAsFinished(); group.leave(); return
                    }
                    if reports, duration > 0 { progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))) }
                    if !input.append(sample) {
                        reader.cancelReading()
                        finished = true; input.markAsFinished(); group.leave(); return
                    }
                }
            }
        }
        group.notify(queue: queue) { [self] in
            if writer.status == .failed {
                reader.cancelReading()
                done(writer.error ?? VideoCompressor.Failure.cannotWrite)
            } else if reader.status != .completed {
                writer.cancelWriting()
                done(reader.status == .cancelled ? CancellationError() : (reader.error ?? VideoCompressor.Failure.cannotWrite))
            } else {
                writer.finishWriting { [self] in
                    if writer.status == .completed { progress(1); done(nil) }
                    else { done(writer.error ?? VideoCompressor.Failure.cannotWrite) }
                }
            }
        }
    }
}

// MARK: - Photo library: keep the compressed video for 钉钉打卡 (the class teacher wants it there too)

enum VideoAlbum {
    /// Asks for add-only access the first time; false when the parent said no or saving failed.
    static func save(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            return true
        } catch { return false }
    }

    static let savedMessage = "已存到相册，可以去钉钉打卡"
    static let failedMessage = "没能存到相册，作业已经交上了。要存的话，请家长到 设置 → 小熊伴学 → 照片，选“仅添加照片”，下次录像就会自动存。"
}

// MARK: - Getting a clip: camera or Photos

/// A video chosen in Photos, copied into our temporary folder (Photos' own copy disappears after loading).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = VideoFiles.temporary(ext: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

/// System camera in video mode, at most 30 minutes. Records 640×480, close to what is uploaded, to keep the temporary file small.
struct VideoCamera: UIViewControllerRepresentable {
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .type640x480
        picker.videoMaximumDuration = VideoSpec.maxDuration
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: VideoCamera
        init(_ parent: VideoCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let url = info[.mediaURL] as? URL else { parent.onCancel(); return }
            // The picker's file is only guaranteed until this method returns.
            let copy = VideoFiles.temporary(ext: url.pathExtension)
            if (try? FileManager.default.moveItem(at: url, to: copy)) != nil || (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                parent.onVideo(copy)
            } else { parent.onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}

// MARK: - Playback

/// A video on the server, streamed with Range requests (no 200 MB download first).
struct RemoteVideoPlayer: View {
    @EnvironmentObject private var store: HomeworkStore
    let fileId: UUID
    @State private var player: AVPlayer?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player) }
            else if unavailable { Label("视频暂时放不了", systemImage: "video.slash").foregroundStyle(.white) }
            else { ProgressView().tint(.white) }
        }
        .accessibilityIdentifier("homework-video")
        .task(id: fileId) {
            guard let api = store.client else { unavailable = true; return }
            let asset = AVURLAsset(url: api.fileURL(fileId), options: ["AVURLAssetHTTPHeaderFieldsKey": api.authorizationHeader])
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}

/// The clip the child just recorded or picked, before it is handed in.
struct LocalVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player) }
        }
        .task(id: url) {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}
