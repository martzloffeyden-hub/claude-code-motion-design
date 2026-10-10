// SINGULARITY — shared GLSL library (hashes, noise, SDF helpers, easing)

#define PI 3.14159265359
#define TAU 6.28318530718

uniform vec2  uRes;       // framebuffer size in pixels
uniform float uTime;      // global time in seconds (shot-independent)
uniform float uFrame;     // global frame index
uniform int   uSpp;       // samples per pixel (spatial AA + shutter)
uniform float uShutter;   // shutter duration in seconds
uniform float uBar;       // letterbox bar height in pixels (render is skipped there)
uniform vec2  uShot;      // [start, end) of the current shot: shutter samples never cross a cut

// ---------------------------------------------------------------- hashing --
uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
float hash11(float p) { return float(pcg(floatBitsToUint(p))) / 4294967295.0; }
float hash21(vec2 p) {
    uvec2 q = floatBitsToUint(p);
    return float(pcg(q.x ^ pcg(q.y))) / 4294967295.0;
}
float hash31(vec3 p) {
    uvec3 q = floatBitsToUint(p);
    return float(pcg(q.x ^ pcg(q.y ^ pcg(q.z)))) / 4294967295.0;
}
// cheap smooth-input hashes (Dave Hoskins, no sine)
float h12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float h13(vec3 p3) {
    p3 = fract(p3 * .1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}
vec3 h33(vec3 p3) {
    p3 = fract(p3 * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}
vec2 h22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// ------------------------------------------------------------------ noise --
float vnoise(vec3 x) {
    vec3 i = floor(x), f = fract(x);
    vec3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(h13(i + vec3(0,0,0)), h13(i + vec3(1,0,0)), u.x),
                   mix(h13(i + vec3(0,1,0)), h13(i + vec3(1,1,0)), u.x), u.y),
               mix(mix(h13(i + vec3(0,0,1)), h13(i + vec3(1,0,1)), u.x),
                   mix(h13(i + vec3(0,1,1)), h13(i + vec3(1,1,1)), u.x), u.y), u.z);
}
float vnoise2(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(h12(i), h12(i + vec2(1,0)), u.x),
               mix(h12(i + vec2(0,1)), h12(i + vec2(1,1)), u.x), u.y);
}
float fbm3(vec3 p, int oct) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * vnoise(p);
        p = p * 2.03 + vec3(1.7, 9.2, 3.1);
        a *= 0.5;
    }
    return s;
}
float fbm2(vec2 p, int oct) {
    float a = 0.5, s = 0.0;
    mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < oct; i++) {
        s += a * vnoise2(p);
        p = m * p;
        a *= 0.5;
    }
    return s;
}

// --------------------------------------------------------------- geometry --
mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }
mat3 rotX(float a) { float c = cos(a), s = sin(a); return mat3(1,0,0, 0,c,s, 0,-s,c); }
mat3 rotY(float a) { float c = cos(a), s = sin(a); return mat3(c,0,-s, 0,1,0, s,0,c); }
mat3 rotZ(float a) { float c = cos(a), s = sin(a); return mat3(c,s,0, -s,c,0, 0,0,1); }

float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
float sdBox2(vec2 p, vec2 b) {
    vec2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}
// box with chamfered (45 deg) edges
float sdChamfer2(vec2 p, vec2 b, float c) {
    p = abs(p);
    return max(sdBox2(p, b), (p.x + p.y - (b.x + b.y - c)) * 0.70710678);
}
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

mat3 lookAt(vec3 ro, vec3 ta, float roll) {
    vec3 f = normalize(ta - ro);
    vec3 r = normalize(cross(f, vec3(sin(roll), cos(roll), 0.0)));
    vec3 u = cross(r, f);
    return mat3(r, u, f);
}

// ----------------------------------------------------------------- easing --
float sat(float x) { return clamp(x, 0.0, 1.0); }
float lin(float a, float b, float x) { return sat((x - a) / (b - a)); }
float ss(float a, float b, float x) { return smoothstep(a, b, x); }
float easeInOutCubic(float x) { x = sat(x); return x < 0.5 ? 4.0*x*x*x : 1.0 - pow(-2.0*x + 2.0, 3.0) / 2.0; }
float easeOutCubic(float x) { x = sat(x); return 1.0 - pow(1.0 - x, 3.0); }
float easeOutQuint(float x) { x = sat(x); return 1.0 - pow(1.0 - x, 5.0); }
float easeInQuint(float x) { x = sat(x); return x*x*x*x*x; }
float easeOutExpo(float x) { x = sat(x); return x >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * x); }
float easeInExpo(float x) { x = sat(x); return x <= 0.0 ? 0.0 : pow(2.0, 10.0 * x - 10.0); }
float easeInOutSine(float x) { x = sat(x); return -(cos(PI * x) - 1.0) / 2.0; }
// smooth "mechanical" step: rest, accelerate, overshoot slightly, settle
float lockEase(float x) {
    x = sat(x);
    float e = easeInOutCubic(x);
    return e + sin(x * PI) * 0.0 + 0.06 * sin(x * PI * 2.0) * exp(-6.0 * (1.0 - x)) * x;
}

// exponential decay after an impact at t0 (0 before it)
float hitPulse(float t, float t0, float k) {
    float x = t - t0;
    return x < 0.0 ? 0.0 : exp(-x * k);
}

// low-discrepancy sample offset for sample s of n (R2 sequence + per-pixel CP rotation)
vec2 r2(int s, float seed) {
    const vec2 a = vec2(0.7548776662466927, 0.5698402909980532);
    return fract(vec2(0.5) + a * float(s) + seed);
}

// blackbody-ish colour ramp (t in [0,1] -> deep red .. white .. faint blue)
vec3 blackbody(float t) {
    t = sat(t);
    vec3 c = vec3(1.0, 0.18, 0.02) * ss(0.0, 0.25, t);
    c = mix(c, vec3(1.0, 0.55, 0.16), ss(0.2, 0.55, t));
    c = mix(c, vec3(1.0, 0.86, 0.62), ss(0.5, 0.82, t));
    c = mix(c, vec3(0.92, 0.95, 1.0), ss(0.8, 1.0, t));
    return c;
}
