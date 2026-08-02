//!DESC AniBaka Clear v1 - Enhanced Full-Directional Edge Recovery
//!HOOK MAIN
//!BIND HOOKED
//!WIDTH HOOKED.w
//!HEIGHT HOOKED.h

const float AB_STRENGTH = 0.48;
const float AB_EDGE_LIMIT = 0.080;
const float AB_NOISE_FLOOR = 0.005;

float ab_luma(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    vec2 s = HOOKED_pt;
    
    // Sample center and 8 surrounding neighbors
    vec4 cTex = HOOKED_tex(p);
    vec3 c   = cTex.rgb;
    vec3 n   = HOOKED_tex(p + vec2( 0.0, -s.y)).rgb;
    vec3 ne  = HOOKED_tex(p + vec2( s.x, -s.y)).rgb;
    vec3 e   = HOOKED_tex(p + vec2( s.x,  0.0)).rgb;
    vec3 se  = HOOKED_tex(p + vec2( s.x,  s.y)).rgb;
    vec3 so  = HOOKED_tex(p + vec2( 0.0,  s.y)).rgb;
    vec3 sw  = HOOKED_tex(p + vec2(-s.x,  s.y)).rgb;
    vec3 w   = HOOKED_tex(p + vec2(-s.x,  0.0)).rgb;
    vec3 nw  = HOOKED_tex(p + vec2(-s.x, -s.y)).rgb;

    // Full 9-tap local min and max envelope (prevents halos and ringing on all axes and corners)
    vec3 minNS = min(n, so);
    vec3 minEW = min(e, w);
    vec3 minDiag1 = min(ne, sw);
    vec3 minDiag2 = min(nw, se);
    vec3 localMin = min(c, min(min(minNS, minEW), min(minDiag1, minDiag2)));

    vec3 maxNS = max(n, so);
    vec3 maxEW = max(e, w);
    vec3 maxDiag1 = max(ne, sw);
    vec3 maxDiag2 = max(nw, se);
    vec3 localMax = max(c, max(max(maxNS, maxEW), max(maxDiag1, maxDiag2)));

    // Fast scalar luma conversion for all 9 samples
    float Yc  = ab_luma(c);
    float Yn  = ab_luma(n);
    float Yne = ab_luma(ne);
    float Ye  = ab_luma(e);
    float Yse = ab_luma(se);
    float Yso = ab_luma(so);
    float Ysw = ab_luma(sw);
    float Yw  = ab_luma(w);
    float Ynw = ab_luma(nw);

    // 4-Directional edge detection (Horizontal, Vertical, and 2 Diagonals)
    float edgeHV = max(abs(Yn - Yso), abs(Ye - Yw));
    float edgeDiag = max(abs(Yne - Ysw), abs(Ynw - Yse)) * 0.7071; // Normalized by 1/sqrt(2)
    float edge = max(edgeHV, edgeDiag);

    // High-frequency detail recovery
    vec3 axialMean = (n + e + so + w) * 0.25;
    vec3 diagonalMean = (ne + se + sw + nw) * 0.25;
    vec3 localMean = axialMean * 0.75 + diagonalMean * 0.25;

    // Scalar luma calculation for localMean: (axialMean*0.75 + diagonalMean*0.25)
    float Ymean = (Yn + Ye + Yso + Yw) * 0.1875 + (Yne + Yse + Ysw + Ynw) * 0.0625;
    float detail = abs(Yc - Ymean);

    float signal = smoothstep(AB_NOISE_FLOOR, AB_EDGE_LIMIT, max(edge, detail));
    float suppress = 1.0 - smoothstep(0.18, 0.42, edge);
    float gain = AB_STRENGTH * signal * suppress;

    // Apply high-pass restoration boost
    vec3 restored = c + (c - localMean) * gain;

    // Strict local envelope clamping with adaptive halo margin
    vec3 margin = (localMax - localMin) * 0.035;
    restored = clamp(restored, localMin - margin, localMax + margin);

    return vec4(restored, cTex.a);
}
