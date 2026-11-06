import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Camera

/// Live camera for photographing homework. Prefers an external USB-C camera (iPadOS 17+), then the back camera.
/// Only still photos are taken; no video is recorded or stored.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    enum Status: Equatable { case starting, running, denied, unavailable, failed }

    @Published private(set) var status: Status = .starting
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var current: AVCaptureDevice?
    @Published private(set) var capturing = false

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "cn.littlebear.camera")
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var onPhoto: ((UIImage) -> Void)?

    static func discover() -> [AVCaptureDevice] {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                     mediaType: .video, position: .unspecified).devices
        return found.sorted { rank($0) < rank($1) }
    }
    static var hasCamera: Bool { !discover().isEmpty }

    private static func rank(_ device: AVCaptureDevice) -> Int {
        if device.deviceType == .external { return 0 }
        return device.position == .back ? 1 : 2
    }

    static func name(_ device: AVCaptureDevice) -> String {
        if device.deviceType == .external { return "外接摄像头" }
        return device.position == .front ? "前置摄像头" : "后置摄像头"
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : (self.status = .denied) }
            }
        default: status = .denied
        }
    }

    func stop() {
        previewObservation = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        devices = Self.discover()
        guard let device = devices.first else { status = .unavailable; return }
        use(device)
    }

    func use(_ device: AVCaptureDevice) {
        current = device
        queue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            var ok = false
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                ok = self.session.outputs.contains(self.output)
            }
            self.session.commitConfiguration()
            if ok && !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.status = ok ? .running : .failed
                self.updateRotation()
            }
        }
    }

    /// Called by the preview view; rotation follows device orientation for built-in cameras.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        updateRotation()
    }

    private func updateRotation() {
        guard let device = current, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak layer] c, _ in
            DispatchQueue.main.async {
                guard let connection = layer?.connection else { return }
                let angle = c.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
        }
    }

    func capture(_ done: @escaping (UIImage) -> Void) {
        guard status == .running, !capturing else { return }
        capturing = true
        onPhoto = done
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        queue.async {
            if let angle, let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        DispatchQueue.main.async {
            self.capturing = false
            if let image { self.onPhoto?(image) } else { self.status = .failed }
            self.onPhoto = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        camera.attach(view.previewLayer)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
}

// MARK: - Capture flow: live preview → photo → crop

struct PhotoFlowItem: Identifiable {
    let id = UUID()
    var image: UIImage?   // nil starts with the camera
}

struct PhotoCaptureFlow: View {
    let initial: UIImage?
    let onDone: (Data) -> Void
    let onCancel: () -> Void
    @State private var captured: UIImage?

    var body: some View {
        if let image = captured ?? initial {
            CropView(image: ImageCropper.upright(image), onDone: { cropped in
                if let data = cropped.jpegData(compressionQuality: 0.92) { onDone(data) } else { onCancel() }
            }, onRetake: initial == nil ? { captured = nil } : nil, onCancel: onCancel)
        } else {
            CameraCaptureView(onPhoto: { captured = $0 }, onCancel: onCancel)
        }
    }
}

struct CameraCaptureView: View {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void
    @StateObject private var camera = CameraController()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch camera.status {
                case .denied:
                    message("没有相机权限", "请家长在“设置 → 小熊伴学”中允许使用相机，或改用“从相册选图”。")
                case .unavailable:
                    message("没有可用的摄像头", "可以改用“从相册选图”。")
                case .failed:
                    message("摄像头暂时无法使用", "请关闭后重试，或改用“从相册选图”。")
                case .starting, .running:
                    CameraPreview(camera: camera).ignoresSafeArea(edges: .bottom)
                    VStack {
                        Spacer()
                        Text("把要问的题放在画面中间，拍好后可以框选").font(.callout).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.5), in: Capsule())
                        Button { camera.capture(onPhoto) } label: {
                            Circle().fill(.white).frame(width: 76, height: 76)
                                .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 4).padding(6))
                        }
                        .accessibilityLabel("拍照")
                        .disabled(camera.status != .running || camera.capturing)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("拍题目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                if camera.devices.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(camera.devices, id: \.uniqueID) { device in
                                Button(CameraController.name(device)) { camera.use(device) }
                            }
                        } label: { Label(camera.current.map(CameraController.name) ?? "摄像头", systemImage: "camera.rotate") }
                    }
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(title).font(.title2.bold())
            Text(detail).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white).padding(40)
    }
}

/// Lets the child frame just the question they want to ask about. Only the selected area is kept and sent.
struct CropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    let onRetake: (() -> Void)?
    let onCancel: () -> Void
    @State private var crop = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var dragStart: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28))
                let box = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                                 width: crop.width * frame.width, height: crop.height * frame.height)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    Path { path in path.addRect(frame); path.addRect(box) }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Color.clear.contentShape(Rectangle())
                        .frame(width: box.width, height: box.height)
                        .overlay(Rectangle().stroke(.white, lineWidth: 2))
                        .position(x: box.midX, y: box.midY)
                        .gesture(drag(in: frame) { CropMath.move($0, by: $1) })
                        .accessibilityElement().accessibilityLabel("选框").accessibilityIdentifier("crop-box")
                    ForEach(CropMath.Corner.allCases) { corner in
                        Circle().fill(.white).frame(width: 30, height: 30)
                            .shadow(radius: 2)
                            .frame(width: 56, height: 56).contentShape(Rectangle())
                            .position(corner.point(in: box))
                            .gesture(drag(in: frame) { CropMath.resize($0, corner: corner, by: $1) })
                            .accessibilityElement().accessibilityIdentifier("crop-\(corner.rawValue)")
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("框选要问的题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let onRetake { Button("重拍", action: onRetake) }
                    Button("使用整张") { onDone(image) }
                    Button("使用选中区域") { onDone(ImageCropper.crop(image, to: crop) ?? image) }.bold()
                }
            }
        }
    }

    private func drag(in frame: CGRect, _ apply: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let delta = CGSize(width: value.translation.width / frame.width, height: value.translation.height / frame.height)
                crop = apply(start, delta)
            }
            .onEnded { _ in dragStart = nil }
    }
}

// MARK: - Shared buttons: camera, photo library, then crop

struct PhotoSourceButtons: View {
    var replacing = false
    let onPhoto: (Data) -> Void
    @State private var pickerItem: PhotosPickerItem?
    @State private var flow: PhotoFlowItem?

    var body: some View {
        HStack {
            if CameraController.hasCamera {
                Button { flow = PhotoFlowItem(image: nil) } label: {
                    Label(replacing ? "重新拍题目" : "拍题目", systemImage: "camera")
                }.buttonStyle(.bordered)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) { Label("从相册选图", systemImage: "photo") }
                .buttonStyle(.bordered)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-sample-photo") {
                Button("使用示例图片") { flow = PhotoFlowItem(image: ImageCropper.sampleHomework()) }.buttonStyle(.bordered)
            }
            #endif
        }
        .task(id: pickerItem) {
            guard let item = pickerItem else { return }
            pickerItem = nil
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                flow = PhotoFlowItem(image: image)
            }
        }
        .fullScreenCover(item: $flow) { item in
            PhotoCaptureFlow(initial: item.image, onDone: { data in flow = nil; onPhoto(data) }, onCancel: { flow = nil })
        }
    }
}
