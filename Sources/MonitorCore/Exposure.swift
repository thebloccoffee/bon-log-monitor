import Foundation

/// False-color bands, measured on Rec.709 luma (0...1 IRE) of the converted image, so
/// a band means the same thing whether the preview shows log or 709.
/// With the plain Rec.709 curve, 18% grey lands at 40.9 IRE and one stop over
/// (typical light skin) at ~59.5 IRE.
public struct FalseColorBand: Identifiable {
    public let id = UUID()
    public let name: String
    public let lo: Double
    public let hi: Double
    public let rgb: (Double, Double, Double)
}

public enum Exposure {
    public static let salmon: (Double, Double, Double) = (0.98, 0.50, 0.45)

    /// Fixed bands. The skin band is user-adjustable and painted over these.
    public static let fixedBands: [FalseColorBand] = [
        FalseColorBand(name: "Crushed", lo: -1.0, hi: 0.02, rgb: (0.50, 0.00, 0.60)),
        FalseColorBand(name: "Near black", lo: 0.02, hi: 0.10, rgb: (0.10, 0.30, 1.00)),
        FalseColorBand(name: "18% grey", lo: 0.38, hi: 0.45, rgb: (0.20, 0.80, 0.20)),
        FalseColorBand(name: "Near white", lo: 0.93, hi: 0.99, rgb: (1.00, 0.90, 0.00)),
        FalseColorBand(name: "Clipped", lo: 0.99, hi: 2.0, rgb: (1.00, 0.00, 0.00)),
    ]

    public static let defaultSkinLo = 0.55
    public static let defaultSkinHi = 0.70

    /// CPU twin of the shader's false-color lookup: nil means "show greyscale luma".
    public static func falseColor(ire: Double, skinLo: Double, skinHi: Double) -> (Double, Double, Double)? {
        if ire >= skinLo && ire < skinHi { return salmon }
        return fixedBands.first { ire >= $0.lo && ire < $0.hi }?.rgb
    }

    /// Zebra test. `hi` above 1 means "everything at or above lo" (Sony's "70+" style);
    /// otherwise it's a range (Sony's "C1 70 ±5" style).
    public static func zebra(ire: Double, lo: Double, hi: Double) -> Bool {
        ire >= lo && ire <= hi
    }
}
