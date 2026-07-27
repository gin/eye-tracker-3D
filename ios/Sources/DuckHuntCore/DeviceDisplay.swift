#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Physical screen geometry per device.
///
/// There is no public API for a display's size in millimetres or for where the TrueDepth
/// camera sits on it, so this is a table. It does not have to be exact: a constant scale
/// or offset error here is affine, and the per-user calibration absorbs it into the model
/// alongside the kappa angle. Being wrong by a few millimetres costs nothing; being wrong
/// about which axis is which costs everything.
public extension PhysicalDisplay {
    /// The running device's display, falling back to a modern 6.1" iPhone when unknown.
    static var current: PhysicalDisplay { resolve(identifier: machineIdentifier) }

    /// Looks up a display by Apple model identifier, e.g. `"iPhone16,1"`.
    static func resolve(identifier: String) -> PhysicalDisplay {
        table[identifier] ?? fallback
    }

    /// iPhone 15 / 16 class hardware. Chosen because it is the median TrueDepth device
    /// and because every entry in the table is within a few millimetres of it.
    static let fallback = PhysicalDisplay(
        widthMillimetres: 70.8,
        heightMillimetres: 147.6,
        cameraOffsetXMillimetres: 0,
        cameraOffsetYMillimetres: 65.0
    )

    /// Apple model identifier of the running device.
    static var machineIdentifier: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #else
        return ""
        #endif
    }

    /// Active display area and front-camera placement for every TrueDepth iPhone.
    ///
    /// `cameraOffsetY` is measured from the centre of the active area upward. On notch and
    /// Dynamic Island devices the camera sits *inside* the display bounds, so this value is
    /// slightly less than half the display height.
    ///
    /// Sources: Apple HIG device specifications, official tech specs, iOS resolution references,
    /// geometric calculations from published resolutions and PPI values. Notch and Dynamic Island
    /// dimensions from design specifications and public technical documentation. Camera offsets
    /// estimated from known sensor positions relative to TrueDepth cutout geometry.
    internal static let table: [String: PhysicalDisplay] = [
        // iPhone X (2017) — 5.8" OLED notch, 2436×1125 @ 458 ppi
        "iPhone10,3": PhysicalDisplay(
            widthMillimetres: 62.4,
            heightMillimetres: 135.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 59.5
        ),
        "iPhone10,6": PhysicalDisplay(
            widthMillimetres: 62.4,
            heightMillimetres: 135.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 59.5
        ),

        // iPhone XS (2018) — 5.8" OLED notch, same display as X
        "iPhone11,2": PhysicalDisplay(
            widthMillimetres: 62.4,
            heightMillimetres: 135.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 59.5
        ),

        // iPhone XS Max (2018) — 6.5" OLED notch, 2688×1242 @ 458 ppi
        "iPhone11,4": PhysicalDisplay(
            widthMillimetres: 68.9,
            heightMillimetres: 149.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 66.5
        ),
        "iPhone11,6": PhysicalDisplay(
            widthMillimetres: 68.9,
            heightMillimetres: 149.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 66.5
        ),

        // iPhone XR (2018) — 6.1" LCD notch, 1792×828 @ 326 ppi
        "iPhone11,8": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 11 (2019) — 6.1" LCD notch, same as XR
        "iPhone12,1": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 11 Pro (2019) — 5.8" OLED notch, same as X/XS
        "iPhone12,3": PhysicalDisplay(
            widthMillimetres: 62.4,
            heightMillimetres: 135.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 59.5
        ),

        // iPhone 11 Pro Max (2019) — 6.5" OLED notch, same as XS Max
        "iPhone12,5": PhysicalDisplay(
            widthMillimetres: 68.9,
            heightMillimetres: 149.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 66.5
        ),

        // iPhone 12 mini (2020) — 5.4" OLED notch, 2340×1080 @ 476 ppi
        "iPhone13,1": PhysicalDisplay(
            widthMillimetres: 57.7,
            heightMillimetres: 125.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 56.0
        ),

        // iPhone 12 (2020) — 6.1" OLED notch, 2532×1170 @ 460 ppi
        "iPhone13,2": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 12 Pro (2020) — 6.1" OLED notch, same as 12
        "iPhone13,3": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 12 Pro Max (2020) — 6.7" OLED notch, 2778×1284 @ 458 ppi
        "iPhone13,4": PhysicalDisplay(
            widthMillimetres: 71.2,
            heightMillimetres: 153.9,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 13 mini (2021) — 5.4" OLED notch (20% smaller), same resolution as 12 mini
        "iPhone14,4": PhysicalDisplay(
            widthMillimetres: 57.7,
            heightMillimetres: 125.1,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 56.0
        ),

        // iPhone 13 (2021) — 6.1" OLED notch (20% smaller), same resolution as 12
        "iPhone14,5": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 13 Pro (2021) — 6.1" OLED notch (20% smaller), same as 13
        "iPhone14,2": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 13 Pro Max (2021) — 6.7" OLED notch (20% smaller), same as 12 Pro Max
        "iPhone14,3": PhysicalDisplay(
            widthMillimetres: 71.2,
            heightMillimetres: 153.9,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 14 (2022) — 6.1" OLED notch, 2532×1170 @ 460 ppi
        "iPhone14,7": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 14 Plus (2023) — 6.7" OLED notch, 2778×1284 @ 458 ppi
        "iPhone14,8": PhysicalDisplay(
            widthMillimetres: 71.2,
            heightMillimetres: 153.9,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 14 Pro (2022) — 6.1" OLED Dynamic Island, 2532×1170 @ 460 ppi
        "iPhone15,2": PhysicalDisplay(
            widthMillimetres: 64.5,
            heightMillimetres: 140.3,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 63.0
        ),

        // iPhone 14 Pro Max (2022) — 6.7" OLED Dynamic Island, 2778×1284 @ 458 ppi
        "iPhone15,3": PhysicalDisplay(
            widthMillimetres: 71.2,
            heightMillimetres: 153.9,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 15 (2023) — 6.1" OLED Dynamic Island, 2556×1179 @ 460 ppi
        "iPhone15,4": PhysicalDisplay(
            widthMillimetres: 65.2,
            heightMillimetres: 142.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 64.0
        ),

        // iPhone 15 Plus (2023) — 6.7" OLED Dynamic Island, 2796×1290 @ 460 ppi
        "iPhone15,5": PhysicalDisplay(
            widthMillimetres: 71.6,
            heightMillimetres: 155.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 15 Pro (2023) — 6.1" OLED Dynamic Island, same as 15
        "iPhone16,1": PhysicalDisplay(
            widthMillimetres: 65.2,
            heightMillimetres: 142.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 64.0
        ),

        // iPhone 15 Pro Max (2023) — 6.7" OLED Dynamic Island, same as 15 Plus
        "iPhone16,2": PhysicalDisplay(
            widthMillimetres: 71.6,
            heightMillimetres: 155.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 16 (2024) — 6.1" OLED Dynamic Island, 2556×1179 @ 460 ppi
        "iPhone17,3": PhysicalDisplay(
            widthMillimetres: 65.2,
            heightMillimetres: 142.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 64.0
        ),

        // iPhone 16 Plus (2024) — 6.7" OLED Dynamic Island, 2796×1290 @ 460 ppi
        "iPhone17,4": PhysicalDisplay(
            widthMillimetres: 71.6,
            heightMillimetres: 155.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 70.0
        ),

        // iPhone 16 Pro (2024) — 6.3" OLED Dynamic Island, 2622×1206 @ 460 ppi
        "iPhone17,1": PhysicalDisplay(
            widthMillimetres: 66.6,
            heightMillimetres: 145.0,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 65.0
        ),

        // iPhone 16 Pro Max (2024) — 6.9" OLED Dynamic Island, 2868×1320 @ 460 ppi
        "iPhone17,2": PhysicalDisplay(
            widthMillimetres: 72.8,
            heightMillimetres: 158.5,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 71.0
        ),
    ]
}
