import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - External (USB-C) camera

/// Whether a USB camera is plugged in, and how it is mounted. A desk camera points at the homework, so the child can
/// take a photo with one tap without lifting the iPad. Needs a USB-C iPad on iPadOS 17+ and a UVC camera.
final class ExternalCamera: ObservableObject {
    static let shared = ExternalCamera()
    private static let rotationKey = "camera.external.rotation"

    @Published private(set) var isConnected = false
    /// Clockwise quarter turns, in degrees, that make the camera's picture upright on screen. Saved across launches.
    @Published private(set) var rotation: Int
    private var observers: [NSObjectProtocol] = []

    private init() {
        rotation = Self.normalized(UserDefaults.standard.integer(forKey: Self.rotationKey))
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.refresh(changed: note.object as? AVCaptureDevice, connected: name == AVCaptureDevice.wasConnectedNotification)
            })
        }
    }

    private func refresh(changed: AVCaptureDevice? = nil, connected: Bool = true) {
        isConnected = CameraController.discover(externalOnly: true).contains { connected || $0.uniqueID != changed?.uniqueID }
    }

    func turn() {
        rotation = Self.normalized(rotation + 90)
        UserDefaults.standard.set(rotation, forKey: Self.rotationKey)
    }

    static func normalized(_ degrees: Int) -> Int { ((degrees / 90 % 4) + 4) % 4 * 90 }
}

// MARK: - Camera

/// Live camera for photographing homework. Prefers an external USB-C camera (iPadOS 17+), then the back camera, and
/// follows the camera being plugged in or out. Only still photos are taken; no video is recorded or stored.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    enum Status: Equatable { case starting, running, denied, unavailable, failed }

    @Published private(set) var status: Status = .starting
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var current: AVCaptureDevice?
    @Published private(set) var capturing = false

    /// Only the USB camera: used by the in-page desk camera, which disappears when it is unplugged.
    let externalOnly: Bool
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "cn.littlebear.camera")
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var onPhoto: ((UIImage) -> Void)?
    private var softwareTurn = 0
    private var active = false
    private var observers: [NSObjectProtocol] = []

    init(externalOnly: Bool = false) {
        self.externalOnly = externalOnly
        super.init()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.devicesChanged(note.object as? AVCaptureDevice, connected: name == AVCaptureDevice.wasConnectedNotification)
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func discover(externalOnly: Bool = false) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = externalOnly ? [.external] : [.external, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return found.filter(\.isConnected).sorted { rank($0) < rank($1) }
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

    var isExternal: Bool { current?.deviceType == .external }

    func start() {
        active = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard self.active else { return }
                    granted ? self.configure() : (self.status = .denied)
                }
            }
        default: status = .denied
        }
    }

    func stop() {
        active = false
        previewObservation = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        devices = Self.discover(externalOnly: externalOnly)
        guard let device = devices.first else { status = .unavailable; return }
        use(device)
    }

    /// A camera was plugged in or out while this one is showing: switch to the USB camera when it arrives, and to
    /// the next camera (or the "no camera" message) when the one in use is unplugged.
    private func devicesChanged(_ device: AVCaptureDevice?, connected: Bool) {
        guard active, status != .denied, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        devices = Self.discover(externalOnly: externalOnly).filter { connected || $0.uniqueID != device?.uniqueID }
        if !connected, let device, device.uniqueID == current?.uniqueID {
            current = nil
            if let next = devices.first { use(next) } else {
                status = .unavailable
                queue.async { if self.session.isRunning { self.session.stopRunning() } }
            }
        } else if connected, let device, device.deviceType == .external, !isExternal {
            use(device)
        } else if connected, current == nil, let first = devices.first {
            use(first)
        }
    }

    func use(_ device: AVCaptureDevice) {
        current = device
        if status != .running { status = .starting }
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
                guard self.current?.uniqueID == device.uniqueID else { return }
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

    /// Built-in cameras turn with the iPad. A USB camera stands still on the desk, so its picture keeps the turn the
    /// child picked with the rotate button, and is not mirrored: the preview matches the photo.
    func updateRotation() {
        guard let device = current, let layer = previewLayer else { return }
        if device.deviceType == .external {
            rotation = nil
            previewObservation = nil
            guard let connection = layer.connection else { return }
            let angle = CGFloat(ExternalCamera.shared.rotation)
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            return
        }
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
        let external = isExternal
        let angle = external ? CGFloat(ExternalCamera.shared.rotation) : rotation?.videoRotationAngleForHorizonLevelCapture
        queue.async {
            var turn = 0
            if let angle, let connection = self.output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                else if external { connection.videoRotationAngle = 0; turn = Int(angle) }
                if external, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            self.softwareTurn = turn
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let turn = softwareTurn   // set on the camera queue just before this photo was requested
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:)).map { turn == 0 ? $0 : ImageCropper.rotated($0, clockwise: turn) }
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

/// The rotate button for a USB camera: each tap turns its picture a quarter turn clockwise, remembered for next time.
struct ExternalCameraRotateButton: View {
    let camera: CameraController
    @ObservedObject private var external = ExternalCamera.shared
    var body: some View {
        Button { external.turn(); camera.updateRotation() } label: {
            Image(systemName: "rotate.right").font(.title2.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 56, height: 56).background(.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("画面转一下")
    }
}

/// A white flash over the camera picture so the child sees that a photo was taken.
private struct ShutterFlash: ViewModifier {
    let shots: Int
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .overlay(Color.white.opacity(visible ? 0.75 : 0).allowsHitTesting(false))
            .onChange(of: shots) {
                visible = true
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.35)) { visible = false } }
            }
    }
}

// MARK: - Desk camera inside a page

/// Live picture from the USB desk camera, shown right in the page. A tap anywhere on it (or on the big button) takes
/// the photo, so the iPad can stay on its stand. Show it only while `ExternalCamera.shared.isConnected`.
struct DeskCameraPanel: View {
    var buttonTitle = "拍这一页"
    var hint = "点一下画面就能拍"
    let onPhoto: (UIImage) -> Void
    @StateObject private var camera = CameraController(externalOnly: true)
    @State private var shots = 0

    var body: some View {
        ZStack {
            Color.black
            switch camera.status {
            case .denied:
                note("没有相机权限", "请家长在“设置 → 小熊伴学”中允许使用相机。")
            case .failed:
                note("外接摄像头暂时用不了", "拔下来重新插一下试试，或者用下面的按钮从相册选。")
            case .unavailable:
                note("没找到外接摄像头", "检查一下摄像头有没有插好。")
            case .starting, .running:
                CameraPreview(camera: camera)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: shoot)
                    .accessibilityElement()
                    .accessibilityLabel("外接摄像头画面，点一下拍照")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { shoot() }
                    .accessibilityIdentifier("desk-camera")
                    .modifier(ShutterFlash(shots: shots))
                VStack(spacing: 12) {
                    HStack {
                        Label("外接摄像头", systemImage: "web.camera").font(.subheadline.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                        ExternalCameraRotateButton(camera: camera)
                    }
                    Spacer()
                    Text(hint).font(.callout).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule()).allowsHitTesting(false)
                    Button(action: shoot) {
                        Label(camera.capturing ? "正在拍…" : buttonTitle, systemImage: "camera.fill")
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(Color.black)
                            .padding(.horizontal, 28).frame(height: 64).background(.white, in: Capsule())
                    }
                    .disabled(camera.status != .running || camera.capturing)
                }
                .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private func shoot() {
        guard camera.status == .running, !camera.capturing else { return }
        shots += 1
        camera.capture(onPhoto)
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "web.camera").font(.largeTitle)
            Text(title).font(.title3.bold())
            Text(detail).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white).padding(28)
    }
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
    @State private var shots = 0

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
                    // With a USB camera the iPad stays put, so a tap anywhere on the picture takes the photo.
                    CameraPreview(camera: camera).ignoresSafeArea(edges: .bottom)
                        .contentShape(Rectangle())
                        .onTapGesture { if camera.isExternal { shoot() } }
                        .modifier(ShutterFlash(shots: shots))
                    VStack {
                        if camera.isExternal {
                            HStack { Spacer(); ExternalCameraRotateButton(camera: camera) }.padding(16)
                        }
                        Spacer()
                        Text(camera.isExternal ? "把要问的题放在摄像头下面，点一下画面就能拍" : "把要问的题放在画面中间，拍好后可以框选")
                            .font(.callout).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.5), in: Capsule()).allowsHitTesting(false)
                        Button(action: shoot) {
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

    private func shoot() {
        guard camera.status == .running, !camera.capturing else { return }
        shots += 1
        camera.capture(onPhoto)
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
    var cameraTitle: String?
    var showsCamera = true
    var showsLibrary = true
    let onPhoto: (Data) -> Void
    @State private var pickerItem: PhotosPickerItem?
    @State private var flow: PhotoFlowItem?

    var body: some View {
        HStack {
            if showsCamera, CameraController.hasCamera {
                Button { flow = PhotoFlowItem(image: nil) } label: {
                    Label(cameraTitle ?? (replacing ? "重新拍题目" : "拍题目"), systemImage: "camera")
                }.buttonStyle(.bordered)
            }
            if showsLibrary {
                PhotosPicker(selection: $pickerItem, matching: .images) { Label("从相册选图", systemImage: "photo") }
                    .buttonStyle(.bordered)
            }
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
