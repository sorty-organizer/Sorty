#include "Common.h"

// MARK: - Palette
//
// Eight compact spots tuned for button-sized elements (~70×36pt).
// The inner-glow layer reuses the same eight positions but with per-spot
// alphas pre-multiplied into the colors, so sampling can pick either the
// border/bloom table or the inner table via a single bool.

constant float4 smSpotPosSize[8] = {
  float4(0.02,  0.68,  9.0, 18.0),
  float4(0.02,  0.68,  4.0,  8.0),
  float4(0.72, -0.03, 59.0,  9.0),
  float4(0.74,  1.00, 42.0,  7.0),
  float4(1.00,  0.27, 10.0, 17.0),
  float4(1.00,  0.27, 10.0, 18.0),
  float4(1.00,  0.27,  5.0, 10.0),
  float4(1.00,  0.27, 11.0, 12.0),
};

// GENERATED-BEGIN: smBorderColors
constant float3 smBorderColors[32] = {
  // colorful
  float3( 50.0, 200.0,  80.0) / 255.0,
  float3( 30.0, 185.0, 170.0) / 255.0,
  float3(255.0, 120.0,  40.0) / 255.0,
  float3(100.0,  70.0, 255.0) / 255.0,
  float3(240.0,  50.0, 180.0) / 255.0,
  float3(180.0,  40.0, 240.0) / 255.0,
  float3( 40.0, 140.0, 255.0) / 255.0,
  float3(255.0,  50.0, 100.0) / 255.0,
  // mono
  float3(160.0, 160.0, 160.0) / 255.0,
  float3(140.0, 140.0, 140.0) / 255.0,
  float3(180.0, 180.0, 180.0) / 255.0,
  float3(150.0, 150.0, 150.0) / 255.0,
  float3(170.0, 170.0, 170.0) / 255.0,
  float3(155.0, 155.0, 155.0) / 255.0,
  float3(145.0, 145.0, 145.0) / 255.0,
  float3(165.0, 165.0, 165.0) / 255.0,
  // ocean
  float3( 60.0, 140.0, 200.0) / 255.0,
  float3( 50.0, 120.0, 180.0) / 255.0,
  float3(100.0,  80.0, 220.0) / 255.0,
  float3( 80.0, 100.0, 255.0) / 255.0,
  float3(120.0,  70.0, 240.0) / 255.0,
  float3( 90.0,  80.0, 220.0) / 255.0,
  float3( 70.0, 110.0, 255.0) / 255.0,
  float3(110.0,  90.0, 230.0) / 255.0,
  // sunset
  float3(255.0, 180.0,  50.0) / 255.0,
  float3(255.0, 150.0,  40.0) / 255.0,
  float3(255.0,  80.0,  60.0) / 255.0,
  float3(255.0, 100.0,  80.0) / 255.0,
  float3(255.0,  60.0,  80.0) / 255.0,
  float3(255.0, 120.0,  60.0) / 255.0,
  float3(255.0, 200.0,  50.0) / 255.0,
  float3(255.0,  90.0,  70.0) / 255.0,
};
// GENERATED-END: smBorderColors

/// Inner-glow colors with per-spot alphas baked in.
/// colorful / ocean / sunset alphas: 0.50, 0.45, 0.35, 0.35, 0.30, 0.40, 0.30, 0.30
/// mono alphas (halved, quantized):  0.25, 0.22, 0.17, 0.17, 0.15, 0.20, 0.15, 0.15
// GENERATED-BEGIN: smInnerColors
constant float3 smInnerColors[32] = {
  // colorful
  float3( 50.0, 200.0,  80.0) * 0.5 / 255.0,
  float3( 30.0, 185.0, 170.0) * 0.45 / 255.0,
  float3(255.0, 120.0,  40.0) * 0.35 / 255.0,
  float3(100.0,  70.0, 255.0) * 0.35 / 255.0,
  float3(240.0,  50.0, 180.0) * 0.3 / 255.0,
  float3(180.0,  40.0, 240.0) * 0.4 / 255.0,
  float3( 40.0, 140.0, 255.0) * 0.3 / 255.0,
  float3(255.0,  50.0, 100.0) * 0.3 / 255.0,
  // mono
  float3(160.0, 160.0, 160.0) * 0.25 / 255.0,
  float3(140.0, 140.0, 140.0) * 0.22 / 255.0,
  float3(180.0, 180.0, 180.0) * 0.17 / 255.0,
  float3(150.0, 150.0, 150.0) * 0.17 / 255.0,
  float3(170.0, 170.0, 170.0) * 0.15 / 255.0,
  float3(155.0, 155.0, 155.0) * 0.2 / 255.0,
  float3(145.0, 145.0, 145.0) * 0.15 / 255.0,
  float3(165.0, 165.0, 165.0) * 0.15 / 255.0,
  // ocean
  float3( 60.0, 140.0, 200.0) * 0.5 / 255.0,
  float3( 50.0, 120.0, 180.0) * 0.45 / 255.0,
  float3(100.0,  80.0, 220.0) * 0.35 / 255.0,
  float3( 80.0, 100.0, 255.0) * 0.35 / 255.0,
  float3(120.0,  70.0, 240.0) * 0.3 / 255.0,
  float3( 90.0,  80.0, 220.0) * 0.4 / 255.0,
  float3( 70.0, 110.0, 255.0) * 0.3 / 255.0,
  float3(110.0,  90.0, 230.0) * 0.3 / 255.0,
  // sunset
  float3(255.0, 180.0,  50.0) * 0.5 / 255.0,
  float3(255.0, 150.0,  40.0) * 0.45 / 255.0,
  float3(255.0,  80.0,  60.0) * 0.35 / 255.0,
  float3(255.0, 100.0,  80.0) * 0.35 / 255.0,
  float3(255.0,  60.0,  80.0) * 0.3 / 255.0,
  float3(255.0, 120.0,  60.0) * 0.4 / 255.0,
  float3(255.0, 200.0,  50.0) * 0.3 / 255.0,
  float3(255.0,  90.0,  70.0) * 0.3 / 255.0,
};
// GENERATED-END: smInnerColors

struct SmallPaletteSample {
  float3 inner;
  float3 border;
};

// Both layers use the same spot geometry. Evaluate each radial falloff once
// and keep the original color tables and accumulation order for each layer.
static SmallPaletteSample sampleSmallPalette(
  float2 p, float2 size, int variant, float paletteScale,
  bool needsInner, bool needsBorder
) {
  SmallPaletteSample sample = {float3(0.0), float3(0.0)};
  if (!needsInner && !needsBorder) return sample;
  int base = variant * 8;
  for (int i = 0; i < 8; i++) {
    float4 ps = smSpotPosSize[i];
    float2 local = (p - ps.xy * size) / (ps.zw * paletteScale);
    float weight = saturate(1.0 - length(local));
    if (needsInner) sample.inner += smInnerColors[base + i] * weight;
    if (needsBorder) sample.border += smBorderColors[base + i] * weight;
  }
  return sample;
}

// MARK: - Conic mask
//
// Wider window than `.medium` so the shorter beam traversal on a small
// element still reads as a single smooth sweep rather than a flicker.

static float smallInnerMask(float a) {
  if (a < 0.22) return 0.0;
  if (a < 0.28) return mix(0.0,  0.12, (a - 0.22) / 0.06);
  if (a < 0.36) return mix(0.12, 0.40, (a - 0.28) / 0.08);
  if (a < 0.46) return mix(0.40, 1.00, (a - 0.36) / 0.10);
  if (a < 0.82) return 1.0;
  if (a < 0.88) return mix(1.00, 0.40, (a - 0.82) / 0.06);
  if (a < 0.94) return mix(0.40, 0.12, (a - 0.88) / 0.06);
  if (a < 0.97) return mix(0.12, 0.00, (a - 0.94) / 0.03);
  return 0.0;
}

// MARK: - Entry point
//
// Compact variant of the `.medium` beam. Uses the 8-spot palette, swaps the
// inner-glow mask for `smallInnerMask` (which covers the entire interior —
// small elements don't benefit from the 28pt corner-carving behaviour), and
// runs the same stroke + bloom composition.

[[ stitchable ]] half4 beamSmall(
  float2 position,
  float4 rect,       // (sizeW, sizeH, cornerRadius, borderWidth)
  float4 timing,     // (time, duration, brightness, saturation)
  float4 opacities,  // (stroke, inner, bloom, strength)
  float4 theme,      // (variant, inkLuma, innerShadowAlpha, inkAlphaScale)
  float4 hueAndScale // (cos, sin, paletteScale, reserved)
) {
  float sizeW = rect.x, sizeH = rect.y;
  float cornerRadius = rect.z, borderWidth = rect.w;
  float time = timing.x, duration = timing.y;
  float brightness = timing.z, saturation = timing.w;
  float strokeOpacity = opacities.x, innerOpacity = opacities.y;
  float bloomOpacity = opacities.z, strength = opacities.w;
  int variant = int(theme.x);
  float inkLuma = theme.y, innerShadowAlpha = theme.z, inkAlphaScale = theme.w;
  float hueCos = hueAndScale.x, hueSin = hueAndScale.y;
  float paletteScale = hueAndScale.z;
  int shapeType = int(hueAndScale.w);

  float2 size = float2(sizeW, sizeH);
  float2 center = size * 0.5;

  float sdfOuter = sdBeamShape(position, center, size * 0.5, cornerRadius, shapeType);
  if (sdfOuter > 0.0) return half4(0.0);
  float distFromEdge = -sdfOuter;

  const float bloomSigma = 8.0;
  const float bloomReach = 24.0;
  const float innerShadowSigma = 5.0;

  float a = beamAngleFract(position, size, time, duration);

  float mInner = smallInnerMask(a);
  float mStroke = distFromEdge <= borderWidth ? strokeConicMask(a) : 0.0;
  float mBloom = distFromEdge <= bloomReach ? bloomConicMask(a) : 0.0;
  bool needFullSpots = (mStroke > 0.0) || (mBloom > 0.0);
  SmallPaletteSample spots = sampleSmallPalette(
    position, size, variant, paletteScale, mInner > 0.0, needFullSpots
  );

  // Inner glow
  half3 innerPrem = half3(0.0);
  half  innerA = 0.0h;
  {
    float m = mInner;
    if (m > 0.0) {
      float3 innerSpots = spots.inner;
      float shadowFactor = exp(-(distFromEdge * distFromEdge) / (innerShadowSigma * innerShadowSigma)) * innerShadowAlpha * inkLuma;
      float3 rgb = saturate(mix(innerSpots, float3(inkLuma), shadowFactor));
      // Gate alpha by final rgb so dim between-spot pixels don't paint dark
      // over the card (see the matching comment in Medium.metal).
      float rgbMax = max(max(rgb.r, rgb.g), rgb.b);
      float alpha = m * innerOpacity * rgbMax;
      innerPrem = half3(rgb * alpha);
      innerA = half(alpha);
    }
  }

  float3 fullSpots = spots.border;
  float fullGate = needFullSpots ? colorGate(fullSpots, inkLuma) : 0.0;

  // Stroke
  half3 strokePrem = half3(0.0);
  half  strokeA = 0.0h;
  if (mStroke > 0.0) {
    float w = whiteConic(a) * inkAlphaScale * inkLuma;
    float3 rgb = saturate(mix(fullSpots, float3(inkLuma), w));
    float alpha = mStroke * strokeOpacity * fullGate;
    strokePrem = half3(rgb * alpha);
    strokeA = half(alpha);
  }

  // Bloom
  half3 bloomPrem = half3(0.0);
  half  bloomA = 0.0h;
  const float bloomNorm = 0.0498;
  if (mBloom > 0.0) {
    float falloff = exp(-(distFromEdge * distFromEdge) / (bloomSigma * bloomSigma));
    float alpha = mBloom * falloff * bloomOpacity * bloomNorm * 1.3 * inkAlphaScale * fullGate;
    float3 rgb = saturate(mix(fullSpots, float3(inkLuma), 0.35 * inkLuma));
    bloomPrem = half3(rgb * alpha);
    bloomA = half(alpha);
  }

  half3 rgb = innerPrem;
  half  aout = innerA;
  rgb  = strokePrem + rgb * (1.0h - strokeA);
  aout = strokeA    + aout * (1.0h - strokeA);
  rgb  = bloomPrem  + rgb * (1.0h - bloomA);
  aout = bloomA     + aout * (1.0h - bloomA);

  return finalize(rgb, aout, brightness, saturation, strength, hueCos, hueSin);
}
