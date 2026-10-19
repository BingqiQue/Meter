import AVFoundation
import SwiftUI
import UIKit

final class CameraService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var ready = false
    @Published var denied = false
    @Published var message: String?
    @Published var reading: MeterReading?
    @Published var capturing = false
    @Published var lastPhoto: CapturedPhoto?
    @Published var canSwitch = false
    @Published private(set) var metering = MeteringState()
    @Published private(set) var meteringChanging = false
    @Published private(set) var zoom = ZoomState()
    private let queue = DispatchQueue(label: "meter.camera")
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var timer: DispatchSourceTimer?
    private var pending: [Int64: Exposure] = [:]
    private var observers: [NSObjectProtocol] = []
    private var desiredRunning = false
    private var configured = false
    // Accessed only on the camera queue, independently of suggested exposure values.
    private var requestedMeteringMode: MeteringMode = .center
    private var meteringPoint = CGPoint(x: 0.5, y: 0.5)
    private var readingValidAfter: TimeInterval = 0
    private var meteringRevision = 0
    private var readingRevision = 0 // Main-thread publication revision.
    private var selectedFocalLength: FocalLengthPreset = .native

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.ready = false; self?.reading = nil; self?.message = "相机暂时被占用，请稍后重试。"
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in self?.start() })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            self?.ready = false; self?.reading = nil; self?.message = "相机发生错误，请重试。"
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); timer?.cancel() }

    func start() {
        queue.async { self.desiredRunning = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { if granted { self?.configureAndStart() } else { self?.denied = true } }
            }
        default: denied = true
        }
    }
    func stop() {
        ready = false; reading = nil
        queue.async { self.desiredRunning = false; self.timer?.cancel(); self.timer = nil; self.session.stopRunning() }
    }
    private func configureAndStart() {
        denied = false
        queue.async {
            guard self.desiredRunning else { return }
            do {
                if !self.configured {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.sessionPreset = .photo
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.unavailable }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { throw CameraError.unavailable }
                    try self.configureExposure(camera)
                    self.session.addInput(input); self.session.addOutput(self.output)
                    self.device = camera
                    self.configured = true
                }
                if let camera = self.device {
                    try self.configureZoom(camera)
                    try self.configureMetering(camera)
                }
                self.session.startRunning()
                self.beginMetering()
                let switchable = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
                DispatchQueue.main.async { self.ready = self.session.isRunning; self.canSwitch = switchable; self.message = nil }
            } catch { self.report(error.localizedDescription) }
        }
    }
    private func configureExposure(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
    }
    private func zoomProfile(for camera: AVCaptureDevice) -> ZoomProfile {
        var base: Double?
        var estimated = false
        if #available(iOS 26.0, *) {
            let nominal = Double(camera.nominalFocalLengthIn35mmFilm)
            if nominal.isFinite, nominal > 0 { base = nominal }
        }
        if base == nil {
            let format = camera.activeFormat
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fieldOfView = camera.isGeometricDistortionCorrectionEnabled
                ? format.geometricDistortionCorrectedVideoFieldOfView : format.videoFieldOfView
            base = ZoomProfile.estimatedFocalLength(horizontalFieldOfView: Double(fieldOfView),
                                                     width: Double(dimensions.width), height: Double(dimensions.height))
            estimated = true
        }
        return ZoomProfile(baseFocalLength: base, estimated: estimated,
                           minimumFactor: Double(camera.minAvailableVideoZoomFactor),
                           maximumFactor: Double(min(camera.maxAvailableVideoZoomFactor, camera.activeFormat.videoMaxZoomFactor)))
    }
    private func configureZoom(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        let profile = zoomProfile(for: camera)
        let preset = profile.factor(for: selectedFocalLength) != nil ? selectedFocalLength : .native
        guard let factor = profile.factor(for: preset) else { return }
        camera.videoZoomFactor = CGFloat(factor)
        selectedFocalLength = preset
        let state = ZoomState(profile: profile, selected: preset, factor: Double(camera.videoZoomFactor))
        DispatchQueue.main.async { self.zoom = state }
    }
    func setFocalLength(_ preset: FocalLengthPreset) {
        guard ready, !capturing, !meteringChanging, !zoom.changing,
              preset != zoom.selected, zoom.profile.factor(for: preset) != nil else { return }
        zoom.changing = true
        reading = nil
        queue.async {
            defer { DispatchQueue.main.async { self.zoom.changing = false } }
            guard let camera = self.device, self.session.isRunning else { return }
            let previous = self.selectedFocalLength
            do {
                // Re-check current hardware limits immediately before applying zoom.
                guard self.zoomProfile(for: camera).factor(for: preset) != nil else {
                    self.report("当前镜头无法达到这个等效焦距。"); return
                }
                self.selectedFocalLength = preset
                try self.configureZoom(camera)
                // Start with the center of the new framing, then allow a new spot selection.
                self.meteringPoint = CGPoint(x: 0.5, y: 0.5)
                try self.configureMetering(camera)
            } catch {
                self.selectedFocalLength = previous
                self.report(error.localizedDescription)
            }
        }
    }
    func setMeteringMode(_ mode: MeteringMode) {
        guard ready, !capturing, !meteringChanging, !zoom.changing, metering.availableModes.contains(mode), mode != metering.mode else { return }
        updateMetering(mode: mode, point: nil)
    }
    func setMeteringPoint(_ point: CGPoint) {
        guard ready, !capturing, !meteringChanging, !zoom.changing, metering.mode.allowsPointSelection,
              point.x.isFinite, point.y.isFinite else { return }
        updateMetering(mode: metering.mode, point: point)
    }
    private func updateMetering(mode: MeteringMode, point: CGPoint?) {
        meteringChanging = true
        reading = nil
        queue.async {
            guard let camera = self.device else {
                DispatchQueue.main.async { self.meteringChanging = false }; return
            }
            let oldMode = self.requestedMeteringMode
            let oldPoint = self.meteringPoint
            self.requestedMeteringMode = mode
            if let point { self.meteringPoint = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))) }
            do { try self.configureMetering(camera) }
            catch {
                self.requestedMeteringMode = oldMode; self.meteringPoint = oldPoint
                self.report(error.localizedDescription)
            }
            DispatchQueue.main.async { self.meteringChanging = false }
        }
    }
    private func configureMetering(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        var rectangleSupported = false
        if #available(iOS 26.0, *) { rectangleSupported = camera.isExposureRectOfInterestSupported }
        let continuous = camera.isExposureModeSupported(.continuousAutoExposure)
        let modes = MeteringMode.available(rectangleSupported: rectangleSupported,
                                          pointSupported: camera.isExposurePointOfInterestSupported,
                                          continuousExposureSupported: continuous)
        let mode = modes.contains(requestedMeteringMode) ? requestedMeteringMode : modes[0]
        var region: CGRect?
        if continuous {
            // Face detection must not override the explicit metering region.
            camera.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            camera.isFaceDrivenAutoExposureEnabled = mode == .automatic
            if #available(iOS 26.0, *), rectangleSupported {
                camera.exposureRectOfInterest = MeteringGeometry.region(mode: mode, point: meteringPoint,
                                                                        minimumSize: camera.minExposureRectOfInterestSize)
                region = camera.exposureRectOfInterest
            } else if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = mode.allowsPointSelection ? meteringPoint : CGPoint(x: 0.5, y: 0.5)
            }
            // Setting a point/rectangle alone does not start a new AE operation.
            camera.exposureMode = .continuousAutoExposure
        }
        let actualPoint = region.map { CGPoint(x: $0.midX, y: $0.midY) } ?? (mode.allowsPointSelection ? meteringPoint : CGPoint(x: 0.5, y: 0.5))
        let state = MeteringState(mode: mode, availableModes: modes, region: region, point: actualPoint)
        requestedMeteringMode = mode
        meteringRevision += 1
        let revision = meteringRevision
        readingValidAfter = ProcessInfo.processInfo.systemUptime + 0.35
        DispatchQueue.main.async {
            self.readingRevision = revision
            self.reading = nil
            self.metering = state
        }
    }
    private func beginMetering() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self, self.session.isRunning, !self.session.isInterrupted,
                  ProcessInfo.processInfo.systemUptime >= self.readingValidAfter, let camera = self.device,
                  let ev = ExposureMath.ev100(duration: CMTimeGetSeconds(camera.exposureDuration), aperture: Double(camera.lensAperture), iso: Double(camera.iso), offset: Double(camera.exposureTargetOffset)) else { return }
            let value = MeterReading(ev100: ev, offset: Double(camera.exposureTargetOffset), adjusting: camera.isAdjustingExposure)
            let revision = self.meteringRevision
            DispatchQueue.main.async {
                guard self.ready, !self.meteringChanging, !self.zoom.changing, self.readingRevision == revision else { return }
                self.reading = value
            }
        }
        self.timer = timer; timer.resume()
    }
    func switchCamera() {
        guard ready, !capturing, !meteringChanging, !zoom.changing else { return }
        ready = false; reading = nil
        queue.async {
            do {
                let position: AVCaptureDevice.Position = self.device?.position == .back ? .front : .back
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position), let old = self.session.inputs.first else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: camera)
                try self.configureExposure(camera)
                self.session.beginConfiguration()
                self.session.removeInput(old)
                if self.session.canAddInput(input) {
                    self.session.addInput(input); self.device = camera
                } else { self.session.addInput(old) }
                self.session.commitConfiguration()
                self.meteringPoint = CGPoint(x: 0.5, y: 0.5)
                if let activeCamera = self.device {
                    try self.configureZoom(activeCamera)
                    try self.configureMetering(activeCamera)
                }
                DispatchQueue.main.async { self.ready = self.session.isRunning }
            } catch { self.report(error.localizedDescription); DispatchQueue.main.async { self.ready = self.session.isRunning } }
        }
    }
    func capture(exposure: Exposure) {
        guard ready, !capturing, !meteringChanging, !zoom.changing else { return }
        capturing = true
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted else {
                self.report("相机不可用，请重试。"); DispatchQueue.main.async { self.capturing = false }; return
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            self.pending[settings.uniqueID] = exposure
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            guard let exposure = self.pending[photo.resolvedSettings.uniqueID] else { return }
            if let error { self.report(error.localizedDescription); return }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { self.report("照片处理失败，请重试。"); return }
            let captured = CapturedPhoto(image: image, exposure: exposure)
            DispatchQueue.main.async { self.lastPhoto = captured }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async { self.pending.removeValue(forKey: resolvedSettings.uniqueID) }
        DispatchQueue.main.async { self.capturing = false; if let error { self.message = error.localizedDescription } }
    }
    private func report(_ text: String) { DispatchQueue.main.async { self.message = text } }
    enum CameraError: LocalizedError { case unavailable; var errorDescription: String? { "无法使用摄像头。请在 iPhone 真机上运行。" } }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let metering: MeteringState
    let showMetering: Bool
    let onMeteringPoint: (CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var metering = MeteringState()
        var showMetering = false
        var onMeteringPoint: ((CGPoint) -> Void)?
        private let regionLayer = CAShapeLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            regionLayer.fillColor = UIColor.clear.cgColor
            regionLayer.strokeColor = UIColor(red: 1, green: 0.69, blue: 0.24, alpha: 0.95).cgColor
            regionLayer.lineWidth = 1.25
            layer.addSublayer(regionLayer)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard showMetering, metering.mode.allowsPointSelection else { return }
            let location = gesture.location(in: self)
            // Aspect-fit bars are outside the camera image and are not metering targets.
            guard displayRect(CGRect(x: 0, y: 0, width: 1, height: 1)).contains(location) else { return }
            let point = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onMeteringPoint?(point)
        }
        private func displayRect(_ rectangle: CGRect) -> CGRect {
            let corners = [CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY),
                           CGPoint(x: rectangle.minX, y: rectangle.maxY), CGPoint(x: rectangle.maxX, y: rectangle.maxY)]
                .map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            regionLayer.frame = bounds
            regionLayer.isHidden = !showMetering
            if let region = metering.region {
                let rectangle = displayRect(region).insetBy(dx: 1, dy: 1)
                regionLayer.path = UIBezierPath(roundedRect: rectangle, cornerRadius: 6).cgPath
                regionLayer.lineDashPattern = metering.mode == .full ? [5, 5] : nil
            } else {
                let point = previewLayer.layerPointConverted(fromCaptureDevicePoint: metering.point)
                regionLayer.path = UIBezierPath(ovalIn: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)).cgPath
                regionLayer.lineDashPattern = [3, 3]
            }
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(); view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspect
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.metering = metering; view.showMetering = showMetering; view.onMeteringPoint = onMeteringPoint
        view.setNeedsLayout()
    }
}
