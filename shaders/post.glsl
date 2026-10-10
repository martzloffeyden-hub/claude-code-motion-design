// SINGULARITY — post-processing passes. Each pass is selected with a
// #define PASS_xxx injected by the renderer.

in vec2 vUv;
layout(location = 0) out vec4 oCol;

uniform sampler2D uSrc;      // main input
uniform sampler2D uAux;      // aux buffer (depth, light mask, coc)
uniform sampler2D uBloom;    // bloom result
uniform sampler2D uStreak;   // anamorphic streak
uniform sampler2D uRays;     // god rays
uniform vec2  uTexel;        // 1 / size of uSrc
// (uRes, uTime, uFrame, uBar come from common.glsl)

// ------------------------------------------------------------- bloom down --
#ifdef PASS_DOWN
uniform int uFirst;
uniform float uThreshold;
vec3 prefilter(vec3 c) {
    float br = max(c.r, max(c.g, c.b));
    float knee = uThreshold * 0.7;
    float rq = clamp(br - uThreshold + knee, 0.0, 2.0 * knee);
    rq = (rq * rq) / (4.0 * knee + 1e-5);
    float w = max(rq, br - uThreshold) / max(br, 1e-5);
    return c * w;
}
float karis(vec3 c) { return 1.0 / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722)) * 0.25); }
void main() {
    vec2 t = uTexel;
    vec3 a = texture(uSrc, vUv + t * vec2(-2, 2)).rgb;
    vec3 b = texture(uSrc, vUv + t * vec2( 0, 2)).rgb;
    vec3 c = texture(uSrc, vUv + t * vec2( 2, 2)).rgb;
    vec3 d = texture(uSrc, vUv + t * vec2(-2, 0)).rgb;
    vec3 e = texture(uSrc, vUv).rgb;
    vec3 f = texture(uSrc, vUv + t * vec2( 2, 0)).rgb;
    vec3 g = texture(uSrc, vUv + t * vec2(-2,-2)).rgb;
    vec3 h = texture(uSrc, vUv + t * vec2( 0,-2)).rgb;
    vec3 i = texture(uSrc, vUv + t * vec2( 2,-2)).rgb;
    vec3 j = texture(uSrc, vUv + t * vec2(-1, 1)).rgb;
    vec3 k = texture(uSrc, vUv + t * vec2( 1, 1)).rgb;
    vec3 l = texture(uSrc, vUv + t * vec2(-1,-1)).rgb;
    vec3 m = texture(uSrc, vUv + t * vec2( 1,-1)).rgb;
    vec3 col;
    if (uFirst == 1) {
        // Karis average on the first downsample kills fireflies
        vec3 g0 = (a + b + d + e) * 0.25, g1 = (b + c + e + f) * 0.25;
        vec3 g2 = (d + e + g + h) * 0.25, g3 = (e + f + h + i) * 0.25;
        vec3 g4 = (j + k + l + m) * 0.25;
        col = g4 * 0.5 * karis(g4) + (g0 * karis(g0) + g1 * karis(g1) + g2 * karis(g2) + g3 * karis(g3)) * 0.125;
        col /= (0.5 * karis(g4) + 0.125 * (karis(g0) + karis(g1) + karis(g2) + karis(g3)));
        col = prefilter(col);
    } else {
        col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    oCol = vec4(max(col, 0.0), 1.0);
}
#endif

// --------------------------------------------------------------- bloom up --
#ifdef PASS_UP
uniform float uWeight;
void main() {
    vec2 t = uTexel;
    vec3 s = texture(uSrc, vUv).rgb * 4.0;
    s += (texture(uSrc, vUv + t * vec2(-1, 0)).rgb + texture(uSrc, vUv + t * vec2(1, 0)).rgb +
          texture(uSrc, vUv + t * vec2(0, -1)).rgb + texture(uSrc, vUv + t * vec2(0, 1)).rgb) * 2.0;
    s += texture(uSrc, vUv + t * vec2(-1, -1)).rgb + texture(uSrc, vUv + t * vec2(1, -1)).rgb +
         texture(uSrc, vUv + t * vec2(-1, 1)).rgb + texture(uSrc, vUv + t * vec2(1, 1)).rgb;
    oCol = vec4(s / 16.0 * uWeight, 1.0);
}
#endif

// ------------------------------------------------- anamorphic streak (1D) --
#ifdef PASS_STREAK
uniform float uStep;   // tap distance in texels
uniform int uFirst;
uniform float uThreshold;
void main() {
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = -3; i <= 3; i++) {
        float w = exp(-0.18 * float(i * i));
        vec3 c = texture(uSrc, vUv + vec2(float(i) * uStep * uTexel.x, 0.0)).rgb;
        if (uFirst == 1) c = max(c - uThreshold, 0.0);
        acc += c * w;
        wsum += w;
    }
    oCol = vec4(acc / wsum, 1.0);
}
#endif

// --------------------------------------------------------------- god rays --
#ifdef PASS_RAYS
uniform vec2 uLightPos;   // light position in uv
uniform float uRayDecay;
uniform float uRayStrength;
void main() {
    vec2 uv = vUv;
    vec2 dir = (uLightPos - uv);
    const int N = 120;
    vec2 stepv = dir / float(N) * 0.96;
    // interleaved gradient noise: well distributed, low-visibility jitter
    float jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))) + uFrame * 0.618);
    uv += stepv * jitter;
    vec3 acc = vec3(0.0);
    float w = 1.0;
    for (int i = 0; i < N; i++) {
        vec4 a = texture(uAux, uv);
        acc += min(texture(uSrc, uv).rgb, vec3(40.0)) * a.g * w;
        w *= uRayDecay;
        uv += stepv;
    }
    oCol = vec4(acc / float(N) * uRayStrength, 1.0);
}
#endif

// ----------------------------------------------------------- depth of field --
#ifdef PASS_DOF
uniform float uMaxRadius;   // in pixels
void main() {
    const float GOLDEN = 2.39996323;
    float RAD_SCALE = max(1.0, uMaxRadius * uMaxRadius / 360.0);
    vec4 c0 = texture(uSrc, vUv);
    float cs = min(abs(texture(uAux, vUv).b), uMaxRadius);
    float cd = texture(uAux, vUv).r;
    vec3 col = c0.rgb;
    float tot = 1.0;
    float radius = RAD_SCALE;
    float ang = h12(gl_FragCoord.xy) * TAU;
    for (int i = 0; i < 200; i++) {
        if (radius >= uMaxRadius) break;
        vec2 tc = vUv + vec2(cos(ang), sin(ang)) * uTexel * radius;
        vec3 sc = texture(uSrc, tc).rgb;
        vec4 sa = texture(uAux, tc);
        float ssz = min(abs(sa.b), uMaxRadius);
        if (sa.r > cd) ssz = clamp(ssz, 0.0, cs * 2.0);
        float m = smoothstep(radius - 0.5, radius + 0.5, ssz);
        col += mix(col / tot, sc, m);
        tot += 1.0;
        radius += RAD_SCALE / radius;
        ang += GOLDEN;
    }
    oCol = vec4(col / tot, c0.a);
}
#endif

// -------------------------------------------------------------- composite --
#ifdef PASS_COMPOSITE
uniform float uExposure;
uniform float uBloomAmt;
uniform float uStreakAmt;
uniform float uRaysAmt;
uniform float uCA;          // chromatic aberration strength
uniform float uGrain;
uniform float uVignette;
uniform float uFade;        // 0 = black, 1 = image
uniform float uFlash;       // additive white-gold flash
uniform vec3  uLift;
uniform vec3  uGain;
uniform float uSat;
uniform float uContrast;    // AgX "punchy" power

// AgX (Troy Sobotka) — minimal polynomial approximation by B. Wrensch
vec3 agxContrast(vec3 x) {
    vec3 x2 = x * x, x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}
vec3 agx(vec3 val) {
    const mat3 m = mat3(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
                        0.0784335999999992, 0.878468636469772, 0.0784336,
                        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const float mn = -12.47393, mx = 4.026069;
    val = m * val;
    val = clamp(log2(max(val, 1e-10)), mn, mx);
    val = (val - mn) / (mx - mn);
    val = agxContrast(val);
    return pow(max(val, 0.0), vec3(uContrast));
}
vec3 agxEotf(vec3 val) {
    const mat3 mi = mat3(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
                         -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
                         -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    val = mi * val;
    return pow(max(val, 0.0), vec3(2.2));
}
vec3 sampleHDR(vec2 uv) {
    vec3 c = texture(uSrc, uv).rgb;
    return c;
}
void main() {
    vec2 uv = vUv;
    // flip so that glReadPixels returns top-down rows
    uv.y = 1.0 - uv.y;
    vec2 px = uv * uRes;
    // letterbox
    if (px.y < uBar - 0.5 || px.y > uRes.y - uBar + 0.5) { oCol = vec4(0, 0, 0, 1); return; }

    vec2 cc = uv - 0.5;
    float r2 = dot(cc * vec2(uRes.x / uRes.y, 1.0), cc * vec2(uRes.x / uRes.y, 1.0));
    // radial chromatic aberration (lens) — strongest at the edges
    vec2 off = cc * r2 * uCA;
    vec3 col;
    col.r = sampleHDR(uv - off).r;
    col.g = sampleHDR(uv).g;
    col.b = sampleHDR(uv + off).b;

    col += texture(uBloom, uv).rgb * uBloomAmt;
    col += texture(uStreak, uv).rgb * uStreakAmt * vec3(0.75, 0.88, 1.15);
    vec2 rt = 1.5 / uRes;
    vec3 rays = texture(uRays, uv + rt * vec2(1, 1)).rgb + texture(uRays, uv + rt * vec2(-1, 1)).rgb
              + texture(uRays, uv + rt * vec2(1, -1)).rgb + texture(uRays, uv + rt * vec2(-1, -1)).rgb;
    col += rays * 0.25 * uRaysAmt;
    col += uFlash * vec3(1.0, 0.92, 0.8);

    // lens vignette (cos^4-ish)
    float vig = 1.0 - uVignette * smoothstep(0.1, 1.1, r2 * 1.6);
    col *= vig;

    col *= uExposure;
    col = agx(col);
    col = agxEotf(col);

    // grade: saturation, lift/gain (in display space)
    float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(l), col, uSat);
    col = col * uGain + uLift * (1.0 - col);
    col = max(col, 0.0);

    col *= uFade;

    // encode to sRGB-ish display gamma
    col = pow(col, vec3(1.0 / 2.2));

    // film grain: 2-octave, luminance-weighted (stronger in mid-tones)
    vec2 gp = floor(px / 1.5);
    float n1 = h12(gp + vec2(fract(uFrame * 0.1731) * 913.0, fract(uFrame * 0.4123) * 311.0));
    float n2 = h12(floor(px) + vec2(fract(uFrame * 0.6131) * 113.0, 71.0));
    float grain = (n1 * 0.65 + n2 * 0.35) - 0.5;
    float lw = 0.35 + 0.65 * smoothstep(0.0, 0.25, l) * (1.0 - smoothstep(0.6, 1.0, l));
    col += grain * uGrain * lw;

    // dither to 8 bit (triangular)
    float dth = h12(px + 17.0 * fract(uFrame * 0.37)) + h12(px.yx + 3.1 + 23.0 * fract(uFrame * 0.71)) - 1.0;
    col += dth / 255.0;

    oCol = vec4(clamp(col, 0.0, 1.0), 1.0);
}
#endif
