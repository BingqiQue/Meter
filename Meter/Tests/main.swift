import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
check(ExposureParameter.shutter.format(0.8) == "0.8 s", "Fractional second label")
check(ExposureParameter.shutter.format(1 / 125) == "1/125 s", "Reciprocal label")
let sunny = ExposureMath.ev100(duration: 1 / 125, aperture: 16, iso: 100, offset: 0)!
check(abs(sunny - log2(32000)) < 0.00001, "EV conversion")
let reference = Exposure(shutter: 1 / 125, aperture: 2.8, iso: 400)
let ev = ExposureMath.ev100(duration: reference.shutter, aperture: reference.aperture, iso: reference.iso, offset: 0)!
for parameter in ExposureParameter.allCases {
    let solved = ExposureMath.solve(ev100: ev, compensation: 0, fixed: reference, automatic: parameter)
    check(solved.exposure == reference, "Round trip \(parameter)")
    check(!solved.outsideRange, "Range \(parameter)")
    for other in ExposureParameter.allCases where other != parameter {
        check(solved.exposure[other] == reference[other], "Fixed parameter modified")
    }
}
let brighter = ExposureMath.solve(ev100: ev, compensation: 1, fixed: reference, automatic: .iso)
check(brighter.exposure.iso == 800, "Positive compensation doubles ISO")
let darker = ExposureMath.solve(ev100: ev + 1, compensation: 0, fixed: reference, automatic: .shutter)
check(darker.exposure.shutter == 1 / 250, "Positive calibration halves shutter")
check(ExposureMath.solve(ev100: -20, compensation: 0, fixed: reference, automatic: .shutter).outsideRange, "Low bound")
check(ExposureMath.solve(ev100: 40, compensation: 0, fixed: reference, automatic: .aperture).outsideRange, "High bound")
check(ExposureMath.ev100(duration: 0, aperture: 2, iso: 100, offset: 0) == nil, "Invalid reading")
check(abs(ExposureMath.ev100(duration: reference.shutter, aperture: reference.aperture, iso: reference.iso, offset: 1)! - ev - 1) < 0.00001, "Exposure offset sign")
var filter = MeterFilter()
let initial = filter.update(10)
for i in 0..<100 { check(filter.update(i % 2 == 0 ? 10.08 : 9.92) == initial, "Jitter suppression") }
var last = 0.0
for _ in 0..<60 { last = filter.update(13) }
check(abs(last - 13) < 0.34, "Adapt to light change")
filter.reset(); check(filter.update(4) == 4, "Reset")
print("PASS: exposure round trips, fixed invariants, compensation, calibration, limits, offset, filter")

// Lock sequences preserve exactly two fixed parameters, including locking the automatic one.
var locks = ExposureLocks()
locks.toggle(.iso)
check(locks.automatic == .iso, "Unlock ISO")
locks.toggle(.iso)
check(locks.automatic == .shutter, "Lock ISO restores previous automatic parameter")
for sequence in 0..<81 {
    var code = sequence
    var state = ExposureLocks()
    for _ in 0..<4 {
        let parameter = ExposureParameter.allCases[code % 3]
        code /= 3
        let wasAuto = state.automatic == parameter
        state.toggle(parameter)
        check((state.automatic != parameter) == wasAuto, "Lock toggle semantics")
        check(ExposureParameter.allCases.filter { $0 != state.automatic }.count == 2, "Two-lock invariant")
        let result = ExposureMath.solve(ev100: ev, compensation: 0, fixed: reference, automatic: state.automatic)
        for fixed in ExposureParameter.allCases where fixed != state.automatic {
            check(result.exposure[fixed] == reference[fixed], "Toggling must preserve locked values")
        }
    }
}
locks.lock(.shutter)
check(locks.automatic != .shutter, "Editing an automatic parameter locks it")
let nativeModes = MeteringMode.available(rectangleSupported: true, pointSupported: true, continuousExposureSupported: true)
check(nativeModes == [.full, .center, .spot], "Native region modes")
check(MeteringMode.available(rectangleSupported: false, pointSupported: true, continuousExposureSupported: true) == [.automatic, .pointReference], "Honest point fallback")
check(MeteringMode.available(rectangleSupported: true, pointSupported: true, continuousExposureSupported: false) == [.automatic], "Unsupported AE fallback")
for mode in nativeModes {
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.4, y: 0.7)] {
        let rect = MeteringGeometry.region(mode: mode, point: point, minimumSize: CGSize(width: 0.16, height: 0.12))
        check(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1.00001 && rect.maxY <= 1.00001, "Region stays inside image")
        check(rect.width >= 0.16 && rect.height >= 0.12, "Hardware minimum size respected")
    }
}
let full = MeteringGeometry.region(mode: .full, point: .zero, minimumSize: .zero)
check(full == CGRect(x: 0, y: 0, width: 1, height: 1), "Full-frame region")
let center = MeteringGeometry.region(mode: .center, point: .zero, minimumSize: .zero)
check(center == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), "Center region")
let spot = MeteringGeometry.region(mode: .spot, point: CGPoint(x: 0.8, y: 0.3), minimumSize: .zero)
check(abs(spot.midX - 0.8) < 0.00001 && abs(spot.midY - 0.3) < 0.00001, "Spot follows target")
print("PASS: lock transitions, fixed-value invariants, mode capabilities, region geometry and hardware limits")

let zoom24 = ZoomProfile(baseFocalLength: 24, minimumFactor: 1, maximumFactor: 5)
for preset in FocalLengthPreset.allCases where preset != .native {
    check(abs(zoom24.factor(for: preset)! * 24 - Double(preset.rawValue)) < 0.00001, "Equivalent focal length conversion")
}
check(zoom24.factor(for: .native) == 1, "Native reset")
let restrictedZoom = ZoomProfile(baseFocalLength: 26, minimumFactor: 1, maximumFactor: 2)
check(restrictedZoom.factor(for: .mm35) != nil && restrictedZoom.factor(for: .mm50) != nil, "Supported short presets")
check(restrictedZoom.factor(for: .mm85) == nil && restrictedZoom.factor(for: .mm100) == nil, "Unsupported long presets disabled")
check(ZoomProfile(baseFocalLength: 50, minimumFactor: 1, maximumFactor: 5).factor(for: .mm35) == nil, "Cannot zoom out past native lens")
check(ZoomProfile().factor(for: .mm35) == nil, "Unknown focal length disables mm presets")
check(ZoomProfile(baseFocalLength: .nan, maximumFactor: 5).factor(for: .mm50) == nil, "Invalid lens data rejected")
// A 50mm lens on a 36x24 frame has a horizontal FOV of 2*atan(36/(2*50)).
let fieldOfView50 = 2 * atan(36.0 / 100) * 180 / Double.pi
let estimated50 = ZoomProfile.estimatedFocalLength(horizontalFieldOfView: fieldOfView50, width: 3, height: 2)!
check(abs(estimated50 - 50) < 0.00001, "Diagonal equivalent FOV calculation")
check(ZoomProfile.estimatedFocalLength(horizontalFieldOfView: 0, width: 4, height: 3) == nil, "Unknown FOV rejected")
check(ZoomProfile.estimatedFocalLength(horizontalFieldOfView: 70, width: 0, height: 3) == nil, "Invalid frame dimensions rejected")
print("PASS: focal length presets, zoom bounds, native reset, unavailable lens and FOV fallback")
