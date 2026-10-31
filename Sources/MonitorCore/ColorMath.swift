import Foundation

// Signal convention: every input value is normalized IRE (0 = black level, 1 = white
// level). That is what AVFoundation hands back for a decoded camera file (video-range
// YUV expanded to BGRA) and what a display-referred live view JPEG holds. Sony's
// formulas are defined on 10-bit code values, so cv = 64 + ire * 876.
//
// Curve constants are Sony's ("Technical Summary for S-Gamut3.Cine/S-Log3 and
// S-Gamut3/S-Log3", and the S-Log2 white paper).

public enum LogProfile: String, CaseIterable, Identifiable, Codable {
    case slog3SGamut3Cine = "S-Log3 / S-Gamut3.Cine"
    case slog3SGamut3 = "S-Log3 / S-Gamut3"
    case slog2SGamut = "S-Log2 / S-Gamut"

    public var id: String { rawValue }
    /// Index passed to the shader.
    public var shaderIndex: Int32 {
        switch self {
        case .slog3SGamut3Cine: return 0
        case .slog3SGamut3: return 1
        case .slog2SGamut: return 2
        }
    }
}

public enum ColorMath {
    // MARK: S-Log3

    public static func slog3ToLinear(_ ire: Double) -> Double {
        let cv = 64 + ire * 876
        if cv >= 171.2102946929 {
            return pow(10, (cv - 420) / 261.5) * (0.18 + 0.01) - 0.01
        }
        return (cv - 95) * 0.01125 / (171.2102946929 - 95)
    }

    public static func linearToSlog3(_ lin: Double) -> Double {
        let cv: Double
        if lin >= 0.01125 {
            cv = 420 + log10((lin + 0.01) / (0.18 + 0.01)) * 261.5
        } else {
            cv = lin * (171.2102946929 - 95) / 0.01125 + 95
        }
        return (cv - 64) / 876
    }

    // MARK: S-Log2 (the trailing * 0.9 makes 0.18 = 18% grey, like S-Log3)

    public static func slog2ToLinear(_ ire: Double) -> Double {
        if ire >= 0.030001222851889303 {
            return (pow(10, (ire - 0.616596 - 0.03) / 0.432699) - 0.037584) * (219.0 / 155.0) * 0.9
        }
        return (ire - 0.030001222851889303) / 3.53881278538813 * 0.9
    }

    // MARK: Rec.709

    public static func linearToRec709(_ v: Double) -> Double {
        let v = max(v, 0)
        let e = v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099
        return min(max(e, 0), 1)
    }

    public static let rec709Luma: [Double] = [0.2126, 0.7152, 0.0722]

    // MARK: Gamut matrices (derived from primaries, SMPTE RP 177; all D65 so no CAT)

    public typealias Mat3 = [[Double]]
    public typealias Primaries = (r: (Double, Double), g: (Double, Double), b: (Double, Double), w: (Double, Double))

    public static let rec709Primaries: Primaries = ((0.64, 0.33), (0.30, 0.60), (0.15, 0.06), (0.3127, 0.329))
    public static let sGamut3CinePrimaries: Primaries = ((0.766, 0.275), (0.225, 0.800), (0.089, -0.087), (0.3127, 0.329))
    /// S-Gamut3 shares S-Gamut's primaries, so this also serves S-Log2 / S-Gamut.
    public static let sGamut3Primaries: Primaries = ((0.73, 0.28), (0.14, 0.855), (0.10, -0.05), (0.3127, 0.329))

    public static func matrix(for profile: LogProfile) -> Mat3 {
        switch profile {
        case .slog3SGamut3Cine: return gamutConvert(sGamut3CinePrimaries, rec709Primaries)
        case .slog3SGamut3, .slog2SGamut: return gamutConvert(sGamut3Primaries, rec709Primaries)
        }
    }

    public static func rgbToXyz(_ p: Primaries) -> Mat3 {
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let r = xyz(p.r), g = xyz(p.g), b = xyz(p.b), w = xyz(p.w)
        let m: Mat3 = [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
        let s = mul(inverse(m), w)
        return [
            [s[0] * r[0], s[1] * g[0], s[2] * b[0]],
            [s[0] * r[1], s[1] * g[1], s[2] * b[1]],
            [s[0] * r[2], s[1] * g[2], s[2] * b[2]],
        ]
    }

    public static func gamutConvert(_ from: Primaries, _ to: Primaries) -> Mat3 {
        mul(inverse(rgbToXyz(to)), rgbToXyz(from))
    }

    public static func mul(_ a: Mat3, _ b: Mat3) -> Mat3 {
        (0..<3).map { i in (0..<3).map { j in a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] } }
    }

    public static func mul(_ m: Mat3, _ v: [Double]) -> [Double] {
        (0..<3).map { i in m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] }
    }

    public static func inverse(_ m: Mat3) -> Mat3 {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2])
        let (d, e, f) = (m[1][0], m[1][1], m[1][2])
        let (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let A = e * i - f * h, B = f * g - d * i, C = d * h - e * g
        let inv = 1 / (a * A + b * B + c * C)
        return [
            [A * inv, (c * h - b * i) * inv, (b * f - c * e) * inv],
            [B * inv, (a * i - c * g) * inv, (c * d - a * f) * inv],
            [C * inv, (b * g - a * h) * inv, (a * e - b * d) * inv],
        ]
    }

    // MARK: Full pipeline (CPU twin of the shader, used by SelfCheck)

    /// Log-encoded RGB (normalized IRE) -> display Rec.709 RGB, with `gainStops` of
    /// exposure applied in scene-linear light.
    public static func logToRec709(_ rgb: [Double], profile: LogProfile, gainStops: Double = 0) -> [Double] {
        let decode: (Double) -> Double = profile == .slog2SGamut ? slog2ToLinear : slog3ToLinear
        let gain = pow(2, gainStops)
        let lin = mul(matrix(for: profile), rgb.map { decode($0) * gain })
        return lin.map(linearToRec709)
    }

    public static func luma(_ rgb: [Double]) -> Double {
        rgb[0] * rec709Luma[0] + rgb[1] * rec709Luma[1] + rgb[2] * rec709Luma[2]
    }
}
