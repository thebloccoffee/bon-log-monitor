import Foundation

/// Uniforms shared with the Metal shader. Layout must match `struct Uniforms` below:
/// float2 first (8-byte aligned), then scalar floats only.
public struct MonitorUniforms {
    public var fitScale = SIMD2<Float>(1, 1)
    public var time: Float = 0
    public var viewRec709: Float = 1
    public var profile: Float = 0
    public var gainStops: Float = 0
    public var zebraOn: Float = 0
    public var zebraLo: Float = 0.95
    public var zebraHi: Float = 2
    public var zebraOnLog: Float = 0
    public var falseColorOn: Float = 0
    public var skinOn: Float = 0
    public var skinLo: Float = Float(Exposure.defaultSkinLo)
    public var skinHi: Float = Float(Exposure.defaultSkinHi)

    public init() {}
}

public enum ShaderSource {
    /// Metal source with the gamut matrices and false-color bands baked in from
    /// ColorMath / Exposure. Compiled at runtime (no Xcode metal toolchain needed).
    public static func build() -> String {
        let cine = metalMat3(ColorMath.matrix(for: .slog3SGamut3Cine))
        let sg3 = metalMat3(ColorMath.matrix(for: .slog3SGamut3))
        let bands = Exposure.fixedBands.map { b in
            "    if (ire >= \(f(b.lo)) && ire < \(f(b.hi))) return float3(\(f(b.rgb.0)), \(f(b.rgb.1)), \(f(b.rgb.2)));"
        }.joined(separator: "\n")
        let s = Exposure.salmon

        return """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
          float2 fitScale;
          float time;
          float viewRec709;
          float profile;
          float gainStops;
          float zebraOn;
          float zebraLo;
          float zebraHi;
          float zebraOnLog;
          float falseColorOn;
          float skinOn;
          float skinLo;
          float skinHi;
        };

        struct VOut { float4 position [[position]]; float2 uv; };

        vertex VOut monitorVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
          float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
          VOut o;
          o.position = float4(p * u.fitScale, 0.0, 1.0);
          o.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
          return o;
        }

        float slog3ToLinear(float ire) {
          float cv = 64.0 + ire * 876.0;
          if (cv >= 171.2102946929) return pow(10.0, (cv - 420.0) / 261.5) * (0.18 + 0.01) - 0.01;
          return (cv - 95.0) * 0.01125 / (171.2102946929 - 95.0);
        }

        float slog2ToLinear(float ire) {
          if (ire >= 0.030001222851889303)
            return (pow(10.0, (ire - 0.616596 - 0.03) / 0.432699) - 0.037584) * (219.0 / 155.0) * 0.9;
          return (ire - 0.030001222851889303) / 3.53881278538813 * 0.9;
        }

        float linearToRec709(float v) {
          v = max(v, 0.0);
          return clamp(v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099, 0.0, 1.0);
        }

        constant float3x3 SGAMUT3CINE_TO_709 = \(cine);
        constant float3x3 SGAMUT3_TO_709 = \(sg3);
        constant float3 LUMA709 = float3(0.2126, 0.7152, 0.0722);

        float3 logToRec709(float3 c, int profile, float gainStops) {
          float g = exp2(gainStops);
          float3 lin;
          if (profile == 2) {
            lin = SGAMUT3_TO_709 * (float3(slog2ToLinear(c.r), slog2ToLinear(c.g), slog2ToLinear(c.b)) * g);
          } else {
            float3 l = float3(slog3ToLinear(c.r), slog3ToLinear(c.g), slog3ToLinear(c.b)) * g;
            lin = (profile == 1 ? SGAMUT3_TO_709 : SGAMUT3CINE_TO_709) * l;
          }
          return float3(linearToRec709(lin.r), linearToRec709(lin.g), linearToRec709(lin.b));
        }

        float3 falseColor(float ire, float skinLo, float skinHi, thread bool &hit) {
          hit = true;
          if (ire >= skinLo && ire < skinHi) return float3(\(f(s.0)), \(f(s.1)), \(f(s.2)));
        \(bands)
          hit = false;
          return float3(ire);
        }

        fragment float4 monitorFragment(VOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        constant Uniforms &u [[buffer(0)]]) {
          constexpr sampler smp(filter::linear, address::clamp_to_edge);
          float3 logRgb = tex.sample(smp, in.uv).rgb;
          // gainStops (demo source only) acts in scene-linear light, so it moves the
          // 709 view and the overlays; the raw log view stays the untouched signal.
          float3 rec = logToRec709(logRgb, int(u.profile), u.gainStops);
          float ire = dot(rec, LUMA709);
          float3 outRgb = u.viewRec709 > 0.5 ? rec : logRgb;

          if (u.falseColorOn > 0.5) {
            bool hit;
            outRgb = falseColor(ire, u.skinLo, u.skinHi, hit);
          } else if (u.skinOn > 0.5 && ire >= u.skinLo && ire < u.skinHi) {
            outRgb = mix(outRgb, float3(\(f(s.0)), \(f(s.1)), \(f(s.2))), 0.75);
          }

          if (u.zebraOn > 0.5) {
            float zIre = u.zebraOnLog > 0.5 ? dot(logRgb, LUMA709) : ire;
            if (zIre >= u.zebraLo && zIre <= u.zebraHi) {
              float stripe = fract((in.position.x + in.position.y + u.time * 40.0) / 12.0);
              if (stripe < 0.5) outRgb = float3(1.0) - outRgb * 0.15;
            }
          }
          return float4(outRgb, 1.0);
        }
        """
    }

    /// Row-major Mat3 -> Metal float3x3, which is constructed from COLUMNS.
    static func metalMat3(_ m: ColorMath.Mat3) -> String {
        let cols = (0..<3).map { c in "float3(\(f(m[0][c])), \(f(m[1][c])), \(f(m[2][c])))" }
        return "float3x3(\(cols.joined(separator: ", ")))"
    }

    static func f(_ v: Double) -> String { String(format: "%.10f", v) }
}
