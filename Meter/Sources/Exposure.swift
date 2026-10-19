import Foundation
import CoreGraphics

enum ExposureParameter: String, CaseIterable, Identifiable {
    case shutter, aperture, iso
    var id: String { rawValue }
    var title: String { switch self { case .shutter: return "快门"; case .aperture: return "光圈"; case .iso: return "ISO" } }
    var stops: [Double] {
        switch self {
        case .shutter: return [1/8000, 1/6400, 1/5000, 1/4000, 1/3200, 1/2500, 1/2000, 1/1600, 1/1250, 1/1000, 1/800, 1/640, 1/500, 1/400, 1/320, 1/250, 1/200, 1/160, 1/125, 1/100, 1/80, 1/60, 1/50, 1/40, 1/30, 1/25, 1/20, 1/15, 1/13, 1/10, 1/8, 1/6, 1/5, 1/4, 0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]
        case .aperture: return [1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32]
        case .iso: return [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600]
        }
    }
    func format(_ value: Double) -> String {
        switch self {
        case .shutter: return value < 0.3 ? "1/\(Int((1 / value).rounded())) s" : String(format: "%g s", value)
        case .aperture: return String(format: "f/%g", value)
        case .iso: return "\(Int(value.rounded()))"
        }
    }
}

struct Exposure: Equatable {
    var shutter: Double = 1 / 125
    var aperture: Double = 2.8
    var iso: Double = 400
    subscript(_ parameter: ExposureParameter) -> Double {
        get { switch parameter { case .shutter: return shutter; case .aperture: return aperture; case .iso: return iso } }
        set { switch parameter { case .shutter: shutter = newValue; case .aperture: aperture = newValue; case .iso: iso = newValue } }
    }
    var caption: String { "\(ExposureParameter.shutter.format(shutter))    ·    \(ExposureParameter.aperture.format(aperture))    ·    ISO \(Int(iso))" }
}

struct MeterReading: Equatable {
    let ev100: Double
    let offset: Double
    let adjusting: Bool
}

struct ExposureSolution {
    let exposure: Exposure
    let outsideRange: Bool
}

enum ExposureMath {
    // Offset is current image brightness minus the camera's exposure target.
    static func ev100(duration: Double, aperture: Double, iso: Double, offset: Double) -> Double? {
        guard duration > 0, aperture > 0, iso > 0, offset.isFinite else { return nil }
        let ev = log2(aperture * aperture / duration * 100 / iso) + offset
        return ev.isFinite ? ev : nil
    }
    static func solve(ev100: Double, compensation: Double, fixed: Exposure, automatic: ExposureParameter) -> ExposureSolution {
        let brightness = pow(2, ev100 - compensation)
        let raw: Double
        switch automatic {
        case .shutter: raw = fixed.aperture * fixed.aperture * 100 / (fixed.iso * brightness)
        case .aperture: raw = sqrt(fixed.shutter * fixed.iso * brightness / 100)
        case .iso: raw = fixed.aperture * fixed.aperture * 100 / (fixed.shutter * brightness)
        }
        let stops = automatic.stops
        let bounded = max(stops.first!, min(stops.last!, raw))
        let nearest = stops.min { abs(log2($0 / bounded)) < abs(log2($1 / bounded)) }!
        var result = fixed
        result[automatic] = nearest
        return ExposureSolution(exposure: result, outsideRange: !raw.isFinite || raw < stops.first! || raw > stops.last!)
    }
}

struct MeterFilter {
    private var smoothed: Double?
    private var displayed: Double?
    mutating func reset() { smoothed = nil; displayed = nil }
    mutating func update(_ ev: Double) -> Double {
        let filtered = smoothed.map { $0 + 0.18 * (ev - $0) } ?? ev
        smoothed = filtered
        // Hysteresis plus low-pass filtering keeps the displayed third-stop stable.
        if displayed == nil || abs(filtered - displayed!) > 0.24 { displayed = (filtered * 3).rounded() / 3 }
        return displayed!
    }
}

/// One automatic parameter makes the two-lock invariant structural.
struct ExposureLocks {
    private(set) var automatic: ExposureParameter = .shutter
    private var previousAutomatic: ExposureParameter = .iso

    func automaticAfterToggling(_ parameter: ExposureParameter) -> ExposureParameter {
        parameter == automatic ? previousAutomatic : parameter
    }
    mutating func toggle(_ parameter: ExposureParameter) {
        let next = automaticAfterToggling(parameter)
        previousAutomatic = automatic
        automatic = next
    }
    mutating func lock(_ parameter: ExposureParameter) {
        if automatic == parameter { toggle(parameter) }
    }
}

enum MeteringMode: String, CaseIterable, Identifiable {
    case full, center, spot, automatic, pointReference
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "全画面"
        case .center: return "中央区域"
        case .spot: return "点测光"
        case .automatic: return "自动测光"
        case .pointReference: return "选点参考"
        }
    }
    var symbol: String {
        switch self {
        case .full: return "rectangle.dashed"
        case .center: return "rectangle.center.inset.filled"
        case .spot: return "scope"
        case .automatic: return "camera.metering.matrix"
        case .pointReference: return "viewfinder"
        }
    }
    var allowsPointSelection: Bool { self == .spot || self == .pointReference }
    static func available(rectangleSupported: Bool, pointSupported: Bool, continuousExposureSupported: Bool) -> [Self] {
        guard continuousExposureSupported else { return [.automatic] }
        if rectangleSupported { return [.full, .center, .spot] }
        return pointSupported ? [.automatic, .pointReference] : [.automatic]
    }
}

struct MeteringState: Equatable {
    var mode: MeteringMode = .automatic
    var availableModes: [MeteringMode] = [.automatic]
    /// Device coordinates, converted by AVCaptureVideoPreviewLayer for display.
    var region: CGRect?
    var point = CGPoint(x: 0.5, y: 0.5)
    var detail: String {
        switch mode {
        case .full: return "整幅画面参与自动曝光估算"
        case .center: return "以框内中央区域为曝光参考"
        case .spot:
            let area = (region?.width ?? 0) * (region?.height ?? 0) * 100
            return String(format: "点击取景移动 · 区域约 %.1f%%", area)
        case .automatic: return "当前镜头使用系统自动测光"
        case .pointReference: return "点击选择参考点 · 区域大小由系统决定"
        }
    }
}

enum MeteringGeometry {
    static func region(mode: MeteringMode, point: CGPoint, minimumSize: CGSize) -> CGRect {
        let side: CGFloat = mode == .full ? 1 : (mode == .center ? 0.5 : 0.1)
        let width = min(1, max(side, minimumSize.width))
        let height = min(1, max(side, minimumSize.height))
        let center = mode == .spot ? point : CGPoint(x: 0.5, y: 0.5)
        return CGRect(x: max(0, min(1 - width, center.x - width / 2)),
                      y: max(0, min(1 - height, center.y - height / 2)), width: width, height: height)
    }
}

enum FocalLengthPreset: Int, CaseIterable, Identifiable {
    case native = 0, mm35 = 35, mm50 = 50, mm85 = 85, mm100 = 100
    var id: Int { rawValue }
    var title: String { self == .native ? "原生" : "\(rawValue)" }
}

struct ZoomProfile: Equatable {
    var baseFocalLength: Double?
    var estimated = false
    var minimumFactor: Double = 1
    var maximumFactor: Double = 1

    func factor(for preset: FocalLengthPreset) -> Double? {
        guard minimumFactor.isFinite, maximumFactor.isFinite, minimumFactor >= 1, maximumFactor >= minimumFactor else { return nil }
        if preset == .native { return minimumFactor }
        guard let baseFocalLength, baseFocalLength.isFinite, baseFocalLength > 0 else { return nil }
        let factor = Double(preset.rawValue) / baseFocalLength
        // Unsupported presets are disabled, never silently labelled as achieved.
        guard factor >= minimumFactor - 0.0001, factor <= maximumFactor + 0.0001 else { return nil }
        return max(minimumFactor, min(maximumFactor, factor))
    }
    static func estimatedFocalLength(horizontalFieldOfView: Double, width: Double, height: Double) -> Double? {
        guard horizontalFieldOfView.isFinite, horizontalFieldOfView > 0, horizontalFieldOfView < 180,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        // Match the diagonal field of view of a 36×24mm frame.
        let diagonalTangent = tan(horizontalFieldOfView * .pi / 360) * sqrt(1 + pow(height / width, 2))
        return hypot(36, 24) / (2 * diagonalTangent)
    }
}

struct ZoomState: Equatable {
    var profile = ZoomProfile()
    var selected: FocalLengthPreset = .native
    var factor: Double = 1
    var changing = false
    var caption: String {
        guard let base = profile.baseFocalLength else { return "等效焦距不可用" }
        return String(format: "约 %.0f mm · 等效", base * factor)
    }
}
