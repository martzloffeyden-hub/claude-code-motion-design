// SINGULARITY — act VI "the last ring".
// Impact: white-out, a chromatic pressure wave leaves the frame, dust is
// blown outwards and a ring of light springs open and settles around a
// black disc. The singular point stretches into a line, and the title
// condenses out of it, letter by letter, from the centre outwards. At the
// end everything converges back into the point it came from.

uniform sampler2D uTitle;

const float TEX_ASPECT = 4.7222222;   // title texture width / height
const float TEX_CAP = 0.2777778;      // cap height / texture height
const float CAP = 0.050;              // cap height on screen (fraction of height)
const float R0 = 0.285;               // final ring radius
const float NL = 11.0;                // letters

float gT, gLt, gZoom;

float spring(float x) {
    // 0 -> overshoot -> settle at 1
    x = max(x, 0.0);
    return 1.0 - exp(-x * 6.5) * cos(x * 9.0);
}

// ------------------------------------------------------------------ dust --
vec3 dustLayer(vec2 uv, float k, float t) {
    float lt = t - T_IMPACT;
    float depth = 1.0 + k * 0.9;
    float cell = 0.055 * depth;
    // blown outwards by the blast, then a slow drift
    float blast = 1.0 + (2.4 / depth) * easeOutExpo(lt / 2.2);
    float drift = 1.0 + 0.012 * lt / depth;
    float z = blast * drift * gZoom;
    // velocity of the expansion for the streaks
    float dz = (2.4 / depth) * (10.0 * log(2.0) / 2.2) * pow(2.0, -10.0 * lt / 2.2) + 0.012 / depth;
    vec2 P = uv / z;
    vec2 id0 = floor(P / cell);
    vec3 acc = vec3(0.0);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 id = id0 + vec2(i, j);
        vec2 h = h22(id + k * 17.0);
        if (h.x > 0.55) continue;
        vec2 c = (id + 0.2 + 0.6 * h22(id * 1.7 + 3.0 + k)) * cell;
        vec2 p1 = c * z;
        vec2 p0 = c * max(z - dz * 0.045, 0.0);    // position one shutter earlier
        vec2 pa = uv - p0, ba = p1 - p0;
        float hh = sat(dot(pa, ba) / max(dot(ba, ba), 1e-9));
        float d = length(pa - ba * hh);
        float sz = (0.0007 + 0.0011 * h.y) / depth;
        float len = length(ba);
        float m = exp(-d * d / (sz * sz)) * sz / (sz + len * 0.5);
        float tw = 0.6 + 0.4 * sin(t * 2.0 + h.y * 50.0);
        // hidden inside the black disc (behind the singularity)
        float rr = length(p1);
        float occl = ss(R0 * 0.92, R0 * 1.02, rr / gZoom) ;
        occl = mix(1.0, occl, ss(T_IMPACT + 0.6, T_IMPACT + 1.4, t));
        acc += m * tw * (0.35 + h.y) * occl * vec3(0.85, 0.9, 1.0);
    }
    return acc / depth;
}

// ----------------------------------------------------------------- title --
// returns (alpha, glow, heat) for this pixel
vec3 title(vec2 uv, float t, out float knock) {
    knock = 1e3;
    float texH = CAP / TEX_CAP;
    float texW = texH * TEX_ASPECT;
    vec2 tuv = vec2(0.5 + uv.x / texW, 0.5 + uv.y / texH);
    if (tuv.x < 0.0 || tuv.x > 1.0) return vec3(0.0);
    float li = texture(uTitle, vec2(tuv.x, 0.5)).g;
    float idx = floor(li + 0.5);
    float c = (NL - 1.0) * 0.5;
    float ti = T_TITLE + abs(idx - c) * 0.075;
    float p = lin(ti, ti + 1.0, t);
    if (p <= 0.0) return vec3(0.0);
    float pe = easeOutExpo(p);
    // the letters condense out of the horizontal line: vertical squash + blur
    float sy = mix(0.03, 1.0, pe);
    float sx = mix(1.35, 1.0, easeOutQuint(p));
    // per-letter local centre for the horizontal squash
    vec2 q = vec2(tuv.x, 0.5 + (tuv.y - 0.5) / sy);
    float lx = texture(uTitle, vec2(tuv.x, 0.5)).b;
    q.x += (lx - 0.5) * (1.0 / sx - 1.0) * 0.03;
    // fade out at the end: outer letters first, converging to the centre
    float to = T_FADE + (c - abs(idx - c)) * 0.045;
    float out_ = lin(to, to + 0.55, t);
    q.y = 0.5 + (q.y - 0.5) / mix(1.0, 0.15, easeInQuint(out_));
    float d = texture(uTitle, q).r * CAP;
    float px = 1.0 / uRes.y;
    float blur = mix(0.010, 0.0, pe) + px * 0.8 + 0.004 * out_;
    float a = ss(blur, -blur, d);
    // glow, forced to zero well before the texture border (no visible box)
    float inTex = ss(0.0, 0.08, q.y) * ss(1.0, 0.92, q.y) * ss(0.0, 0.03, tuv.x) * ss(1.0, 0.97, tuv.x);
    float glow = (exp(-max(d, 0.0) / 0.0035) * 0.11 + exp(-max(d, 0.0) / 0.012) * 0.025 * ss(0.045, 0.02, d)) * inTex;
    float heat = (1.0 - pe) * 3.0 + 0.3 * exp(-(t - ti - 0.35) * (t - ti - 0.35) * 12.0);
    float vis = (1.0 / sy) ;
    vis = min(vis, 6.0);
    float fadeOut = 1.0 - out_;
    knock = texture(uTitle, vec2(tuv.x, 0.5 + (tuv.y - 0.5))).r * CAP;
    return vec3(a * fadeOut * mix(1.0, vis, 0.3), glow * fadeOut, heat);
}

// ------------------------------------------------------------------ main --
vec3 renderSample(vec2 fc, float t, inout vec4 aux) {
    gT = t;
    gLt = t - T_IMPACT;
    gZoom = 1.0 + 0.035 * lin(T_IMPACT + 1.0, T_END, t);
    vec2 uv = (fc - 0.5 * uRes) / uRes.y;
    uv /= gZoom;
    float lt = gLt;
    float r = length(uv);
    float ang = atan(uv.y, uv.x);
    vec3 col = vec3(0.0);

    // faint cold haze
    col += vec3(0.0016, 0.0020, 0.0030) * (1.0 - r * 0.6);

    // ------------------------------------------------ pressure wave -------
    float Rf = 2.2 * easeOutCubic(lt / 1.35);
    float wf = 0.010 + 0.05 * lin(0.0, 1.3, lt);
    float af = (1.0 - lin(0.0, 1.35, lt)) * step(0.0, lt);
    vec3 shock = vec3(0.0);
    shock.r = exp(-pow((r - Rf - wf * 0.6) / wf, 2.0));
    shock.g = exp(-pow((r - Rf) / wf, 2.0));
    shock.b = exp(-pow((r - Rf + wf * 0.6) / wf, 2.0));
    col += shock * af * af * 3.0;

    // refraction of the dust at the wavefront
    float bump = exp(-pow((r - Rf) / (wf * 1.5), 2.0)) * af * 0.02;
    vec2 duv = uv - normalize(uv + 1e-6) * bump;

    // ------------------------------------------------ dust -----------------
    vec3 dust = vec3(0.0);
    for (int k = 0; k < 3; k++) dust += dustLayer(duv, float(k), t);
    col += dust * (0.9 + 2.5 * exp(-max(lt, 0.0) * 2.0));

    // ------------------------------------------------ the ring -------------
    float grow = spring((lt - 0.05) / 1.25);
    float shrink = easeInExpo(lin(T_FADE + 0.25, T_END - 0.28, t));
    float R = R0 * grow * (1.0 - shrink);
    float hot = exp(-max(lt, 0.0) * 2.2);
    float Iring = (1.4 + 6.0 * hot) / (0.25 + 0.75 * (1.0 - shrink) + 0.001) ;
    // slow asymmetric brightness (Doppler memory of the disk) + shimmer
    float asym = 0.72 + 0.28 * cos(ang - 2.6 - 0.25 * lt);
    float shimmer = 0.9 + 0.1 * vnoise(vec3(ang * 3.0, lt * 1.5, 0.0));
    float core = exp(-pow((r - R) / 0.0016, 2.0));
    float g1 = exp(-abs(r - R) / 0.010);
    float g2 = exp(-abs(r - R) / 0.06);
    vec3 ringCol = vec3(1.0, 0.86, 0.66);
    vec3 disp = vec3(exp(-abs(r - R - 0.003) / 0.012), exp(-abs(r - R) / 0.012), exp(-abs(r - R + 0.003) / 0.012));
    vec3 ring = ringCol * (core * 2.2 + g1 * 0.35 + g2 * 0.06) + disp * vec3(0.10, 0.06, 0.12);
    ring *= Iring * asym * shimmer * step(0.0, lt) * (1.0 - lin(T_END - 0.3, T_END - 0.05, t));

    // ------------------------------------------------ title ----------------
    float knock;
    vec3 tt = title(uv, t, knock);
    // the ring is cut where the letters cross it
    float ko = ss(0.004, 0.016, knock);
    ko = mix(ko, 1.0, ss(T_FADE, T_FADE + 0.5, t));
    col += ring * mix(1.0, ko, ss(T_TITLE, T_TITLE + 0.8, t));
    // black event-horizon disc inside the ring
    float disc = 1.0 - ss(R * 0.97, R * 1.0, r);
    col *= 1.0 - disc * 0.85 * ss(T_IMPACT + 0.3, T_IMPACT + 1.2, t);

    // the point stretches into a line, from which the letters condense
    float lineW = 0.42 * easeOutExpo(lin(T_IMPACT + 0.12, T_TITLE + 0.3, t));
    float lineI = ss(T_IMPACT + 0.1, T_IMPACT + 0.4, t) * (1.0 - ss(T_TITLE + 0.2, T_TITLE + 1.3, t));
    float lth = 0.0012 + 0.002 * (1.0 - lineI);
    float line = exp(-uv.y * uv.y / (lth * lth)) * ss(lineW + 0.03, lineW - 0.05, abs(uv.x));
    col += vec3(1.0, 0.9, 0.75) * line * lineI * 3.0;
    col += vec3(1.0, 0.8, 0.6) * exp(-uv.y * uv.y / 0.0004) * ss(lineW + 0.1, 0.0, abs(uv.x)) * lineI * 0.08;

    vec3 titleCol = vec3(1.0, 0.955, 0.9);
    // one slow light sweep across the word
    float sw = exp(-pow((uv.x - mix(-0.55, 0.55, lin(T_TITLE + 1.9, T_TITLE + 3.2, t))) * 7.0 + uv.y * 4.0, 2.0));
    float tI = 1.25 + 1.6 * sw * ss(T_TITLE + 1.8, T_TITLE + 2.0, t);
    col += titleCol * tt.x * tI * (1.0 + tt.z) + vec3(1.0, 0.85, 0.65) * tt.y * (1.0 + tt.z * 0.5);

    // the converging point at the very end
    float pt = ss(T_END - 0.7, T_END - 0.35, t) * (1.0 - ss(T_END - 0.25, T_END - 0.02, t));
    col += vec3(1.0, 0.9, 0.78) * (exp(-r * r / 0.00002) * 3.0 + exp(-r / 0.02) * 0.15) * pt;

    aux = vec4(10.0, 1.0, 0.0, 0.0);
    return col;
}

// --------------------------------------------------------------- probe ---
vec4 probe(int i, float t) {
    float lt = t - T_IMPACT;
    if (i == 0) {
        // outward light burst through the zoom-blur pass right after impact
        float zb = 0.5 * exp(-max(lt, 0.0) * 4.5);
        return vec4(0.5, 0.5, zb, 0.0);
    }
    if (i == 1) {
        float flash = 3.5 * exp(-max(lt, 0.0) * 12.0) + 0.05 * exp(-max(lt, 0.0) * 4.0);
        return vec4(1.0, 0.05, 0.06, flash);
    }
    if (i == 2) {
        float fade = 1.0 - ss(T_END - 0.12, T_END, t);
        return vec4(fade, 0.003, 0.035, 0.45);
    }
    return vec4(1.0, 1.2, 0.0, 0.0);
}
