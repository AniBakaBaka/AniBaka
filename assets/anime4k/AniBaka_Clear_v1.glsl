//!DESC AniBaka Clear v1 - Adaptive Luma Detail Recovery
//!HOOK MAIN
//!BIND HOOKED
//!WIDTH HOOKED.w
//!HEIGHT HOOKED.h

// Tuned for animation line art. The pass restores luma detail only, so
// subsampled chroma and codec noise do not turn into coloured edge fringes.
const float AB_STRENGTH = 0.68;
const float AB_ACTIVITY_START = 0.004;
const float AB_ACTIVITY_FULL = 0.085;
const float AB_CONTRAST_START = 0.008;
const float AB_CONTRAST_FULL = 0.060;
const float AB_HALO_MARGIN = 0.055;
const float AB_MAX_DELTA = 0.070;

float ab_luma(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    vec2 s = HOOKED_pt;

    vec4 cTex = HOOKED_tex(p);
    vec3 c = cTex.rgb;
    float Yc  = ab_luma(c);
    float Yn  = ab_luma(HOOKED_tex(p + vec2( 0.0, -s.y)).rgb);
    float Yne = ab_luma(HOOKED_tex(p + vec2( s.x, -s.y)).rgb);
    float Ye  = ab_luma(HOOKED_tex(p + vec2( s.x,  0.0)).rgb);
    float Yse = ab_luma(HOOKED_tex(p + vec2( s.x,  s.y)).rgb);
    float Yso = ab_luma(HOOKED_tex(p + vec2( 0.0,  s.y)).rgb);
    float Ysw = ab_luma(HOOKED_tex(p + vec2(-s.x,  s.y)).rgb);
    float Yw  = ab_luma(HOOKED_tex(p + vec2(-s.x,  0.0)).rgb);
    float Ynw = ab_luma(HOOKED_tex(p + vec2(-s.x, -s.y)).rgb);

    // A scalar 3x3 envelope is enough because only luma is modified. This is
    // cheaper and avoids the hue shifts caused by per-channel sharpening.
    float localMin = min(Yc, min(min(Yn, Yso), min(Ye, Yw)));
    localMin = min(localMin, min(min(Yne, Ysw), min(Ynw, Yse)));
    float localMax = max(Yc, max(max(Yn, Yso), max(Ye, Yw)));
    localMax = max(localMax, max(max(Yne, Ysw), max(Ynw, Yse)));
    float contrast = localMax - localMin;

    // Directional second derivatives recover horizontal, vertical and
    // diagonal strokes. Gradient-plus-curvature weights select the useful
    // directions without hard branches, preventing orientation shimmer.
    float hpH  = Yc - (Yw  + Ye ) * 0.5;
    float hpV  = Yc - (Yn  + Yso) * 0.5;
    float hpD1 = (Yc - (Ynw + Yse) * 0.5) * 0.70710678;
    float hpD2 = (Yc - (Yne + Ysw) * 0.5) * 0.70710678;

    float wH  = abs(Ye  - Yw ) + abs(hpH)  * 0.50;
    float wV  = abs(Yso - Yn ) + abs(hpV)  * 0.50;
    float wD1 = abs(Yse - Ynw) * 0.70710678 + abs(hpD1) * 0.50;
    float wD2 = abs(Ysw - Yne) * 0.70710678 + abs(hpD2) * 0.50;
    float weightSum = wH + wV + wD1 + wD2;

    float directionalDetail =
        (hpH * wH + hpV * wV + hpD1 * wD1 + hpD2 * wD2) /
        max(weightSum, 0.000001);

    // A small isotropic component keeps tiny round features and line
    // intersections from becoming weaker than long straight edges.
    float gaussianMean =
        (Yc * 4.0 + (Yn + Ye + Yso + Yw) * 2.0 +
         (Yne + Yse + Ysw + Ynw)) * 0.0625;
    float detail = mix(Yc - gaussianMean, directionalDetail, 0.82);

    // Sobel magnitude is approximated without sqrt. It provides a stable
    // activity gate, while the contrast gate leaves flat codec noise alone.
    float gx = (Yne + Ye * 2.0 + Yse) - (Ynw + Yw * 2.0 + Ysw);
    float gy = (Ysw + Yso * 2.0 + Yse) - (Ynw + Yn * 2.0 + Yne);
    vec2 gradient = abs(vec2(gx, gy));
    float edge = (max(gradient.x, gradient.y) +
                  min(gradient.x, gradient.y) * 0.5) * 0.25;
    float activity = max(edge, abs(detail) * 2.0);

    float activityGate = smoothstep(
        AB_ACTIVITY_START,
        AB_ACTIVITY_FULL,
        activity
    );
    float contrastGate = smoothstep(
        AB_CONTRAST_START,
        AB_CONTRAST_FULL,
        contrast
    );
    float rawDelta = detail * AB_STRENGTH * activityGate * contrastGate;

    // Compress extreme corrections before clamping. The limiter scales with
    // local contrast, so dark outlines become crisp without bright/dark halos.
    float deltaLimit = min(AB_MAX_DELTA, contrast * 0.12 + 0.0005);
    float delta = rawDelta /
        (1.0 + abs(rawDelta) / max(deltaLimit * 2.0, 0.000001));
    delta = clamp(delta, -deltaLimit, deltaLimit);

    float halo = min(contrast * AB_HALO_MARGIN, AB_MAX_DELTA);
    float restoredY = clamp(Yc + delta, localMin - halo, localMax + halo);

    // Applying a scalar luma delta preserves chroma detail instead of
    // sharpening compression artefacts independently in R, G and B.
    vec3 restored = c + vec3(restoredY - Yc);
    return vec4(restored, cTex.a);
}
