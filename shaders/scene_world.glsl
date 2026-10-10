// SINGULARITY — "world" scene: acts I to IV.
//
// A gimbal of five machined rings hovers above an ocean of liquid obsidian,
// back-lit by a low star. Act I is a macro on a seam of light igniting along
// an edge; act II reveals the whole structure; act III unlocks the rings;
// act IV gives birth to a singularity at the core: rays are bent along
// Schwarzschild null geodesics, the star behind becomes an Einstein ring and
// the ocean is pulled up into a vortex.


// ------------------------------------------------------------- constants --
const float RR[5] = float[](0.95, 1.42, 1.92, 2.48, 3.10);       // ring radii
const vec2  RS[5] = vec2[](vec2(0.070, 0.150), vec2(0.082, 0.138), vec2(0.096, 0.126),
                           vec2(0.110, 0.114), vec2(0.128, 0.102)); // half (radial, axial)
const vec3 SUN_COL = vec3(1.0, 0.80, 0.58);
const vec3 SEAM_COL = vec3(1.0, 0.62, 0.30);

// ----------------------------------------------------------- global state --
vec3  gC;              // structure centre
mat3  gM[5];           // world -> ring-local rotation
float gScale[5];       // radius multiplier (collapse)
float gEmit[5];        // seam emission
float gIgnA;           // act I ignition front (angle, outer ring)
float gHole;           // Schwarzschild radius (0 = no singularity)
float gLift;           // water vortex amplitude
float gRipple;         // ripple amplitude under the structure
float gSunI;           // sun intensity
vec3  gSunDir;         // direction towards the sun
vec3  gKeyPos;         // moving key light (sweep)
vec3  gCamPos;
float gKeyI;
vec3  gKeyCol;
float gT;
float gSpinPhase;
float gFp;             // pixel footprint per unit distance (for band-limited emission)
float gFogI;           // fog in-scatter multiplier
mat3  gRoot;           // global orientation of the whole structure (local -> world)

// --------------------------------------------------------------- helpers --
float shake(float t, float t0, float amp) {
    float x = t - t0;
    if (x < 0.0 || x > 1.2) return 0.0;
    return amp * exp(-x * 5.0);
}

// ------------------------------------------------------------ choreography --
// rest pose offsets so the rings are never perfectly coplanar
const vec3 REST[5] = vec3[](vec3(0.16, -0.62, 0.0), vec3(-0.10, -0.40, 0.0), vec3(0.08, -0.22, 0.0),
                            vec3(-0.05, -0.08, 0.0), vec3(0.0, 0.0, 0.0));
// three locked poses (Euler x, y, z) reached at T_LOCK0..2
const vec3 POSE1[5] = vec3[](vec3(1.5708, 0.0, 0.4), vec3(0.0, 1.5708, 0.0), vec3(0.7854, 0.0, 0.0),
                             vec3(0.0, -0.5236, 0.0), vec3(0.0, 0.0, 0.0));
const vec3 POSE2[5] = vec3[](vec3(1.5708, 1.5708, 0.9), vec3(0.7854, 1.5708, 0.0), vec3(0.7854, -1.0472, 0.0),
                             vec3(-0.6, -0.5236, 0.0), vec3(0.0, 0.3, 0.0));
const vec3 POSE3[5] = vec3[](vec3(3.1416, 2.3562, 1.3), vec3(1.5708, 2.3562, 0.0), vec3(-0.3, -1.5708, 0.0),
                             vec3(-1.2, 0.5236, 0.0), vec3(0.45, 0.3, 0.0));
// spin axes for act IV (in ring space after pose 3)
const vec3 SPIN[5] = vec3[](vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.6, 0.8, 0.0),
                            vec3(0.8, 0.0, 0.6), vec3(0.0, 0.6, 0.8));

mat3 euler(vec3 e) { return rotY(e.y) * rotX(e.x) * rotZ(e.z); }
mat3 axisAngle(vec3 a, float ang) {
    a = normalize(a);
    float s = sin(ang), c = cos(ang), oc = 1.0 - c;
    return mat3(oc * a.x * a.x + c, oc * a.x * a.y + a.z * s, oc * a.z * a.x - a.y * s,
                oc * a.x * a.y - a.z * s, oc * a.y * a.y + c, oc * a.y * a.z + a.x * s,
                oc * a.z * a.x + a.y * s, oc * a.y * a.z - a.x * s, oc * a.z * a.z + c);
}

vec3 poseAt(int i, float t) {
    float st = float(i) * 0.07;  // cascade: outer rings follow slightly later
    vec3 e = REST[i];
    // slow idle drift before the unlock
    e += vec3(0.0, 0.0, 0.03 * t * (i % 2 == 0 ? 1.0 : -1.0));
    float d = BEAT * 1.6;
    e = mix(e, POSE1[i], lockEase(lin(T_LOCK0 - d + st, T_LOCK0 + st * 0.3, t)));
    e = mix(e, POSE2[i], lockEase(lin(T_LOCK1 - d + st, T_LOCK1 + st * 0.3, t)));
    e = mix(e, POSE3[i], lockEase(lin(T_LOCK2 - d + st, T_LOCK2 + st * 0.3, t)));
    return e;
}

void setup(float t) {
    gT = t;
    // structure slowly ascends during the reveal
    float rise = easeInOutSine(lin(T_EMERGE - 0.5, T_ANATOMY + 1.5, t));
    gC = vec3(0.0, 3.0 + 0.80 * rise + 0.12 * easeInOutSine(lin(T_ANATOMY, T_DISTORT, t)), 0.0);
    gRoot = rotY(1.05 - 0.028 * t);
    gFogI = 1.0 - 0.75 * ss(T_DISTORT, T_DISTORT + 1.0, t);
    gSunDir = normalize(vec3(0.055, 0.228, 1.0));

    // continuous spin in act IV (angle = integral of an accelerating rate)
    float x = max(t - (T_LOCK2 + 0.25), 0.0);
    gSpinPhase = 0.28 * x + 0.008 * x * x * x;

    for (int i = 0; i < 5; i++) {
        mat3 m = euler(poseAt(i, t));
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float w = (1.0 + 0.35 * float(i)) * dir;
        m = m * axisAngle(SPIN[i], gSpinPhase * w);
        gM[i] = transpose(gRoot * m);  // world -> local
        // collapse: rings contract towards the core at the end of act IV
        float col = easeInExpo(lin(T_COLLAPSE - 2.2, T_COLLAPSE, t));
        gScale[i] = 1.0 - col * (0.28 + 0.06 * float(i));
    }

    // seams: act I ignites the outer ring; act II ignites ring by ring
    float ign[5] = float[](T_IGN0, T_IGN1, T_IGN2, T_IGN3, T_IGN4);
    for (int i = 0; i < 5; i++) {
        float e = ss(ign[4 - i] - 0.05, ign[4 - i] + 0.45, t);
        e += 1.2 * hitPulse(t, ign[4 - i], 3.0) * step(ign[4 - i], t);
        // locks flash the seams
        e += 1.4 * (hitPulse(t, T_LOCK0, 4.0) * step(T_LOCK0, t) + hitPulse(t, T_LOCK1, 4.0) * step(T_LOCK1, t)
                  + hitPulse(t, T_LOCK2, 4.0) * step(T_LOCK2, t));
        // act IV: rings heat up
        e += 3.0 * easeInExpo(lin(T_DISTORT + 2.0, T_COLLAPSE, t));
        gEmit[i] = e;
    }
    if (t < T_EMERGE) {
        for (int i = 0; i < 4; i++) gEmit[i] = 0.0;
        gEmit[4] = 0.32;
    }
    gIgnA = mix(-0.6, 2.2, easeInOutCubic(lin(0.9, 4.3, t)));

    // singularity
    gHole = 0.0;
    if (t >= T_DISTORT) {
        float a = lin(T_DISTORT + 0.35, T_DISTORT + 3.0, t);
        gHole = 0.16 * easeOutQuint(a) + 0.07 * easeInExpo(lin(T_DISTORT + 3.0, T_COLLAPSE, t));
    }
    gLift = (t >= T_DISTORT) ? 3.0 * easeInOutCubic(lin(T_DISTORT + 1.2, T_COLLAPSE + 0.3, t)) : 0.0;
    gRipple = ss(T_EMERGE, T_EMERGE + 2.0, t) * (1.0 + 2.0 * ss(T_ANATOMY, T_DISTORT, t));

    // sun: a sliver in act I, ignites on the act II hit
    if (t < T_EMERGE) gSunI = 0.0;
    else gSunI = 1.0 + 1.2 * hitPulse(t, T_EMERGE, 4.0);

    // key light: sweep along the ring in act I, orbit in act III
    if (t < T_EMERGE) {
        float a = mix(0.2, 1.95, easeInOutSine(lin(0.4, 4.6, t)));
        gKeyPos = gC + gRoot * (vec3(cos(a), sin(a), 0.0) * 3.35 + vec3(0.0, 0.0, -0.55));
        gKeyI = 0.9 * ss(0.3, 1.8, t);
        gKeyCol = vec3(1.0, 0.86, 0.72);
    } else if (t < T_ANATOMY) {
        gKeyPos = gC + vec3(-6.0, 4.0, -5.0);
        gKeyI = 0.0;
        gKeyCol = vec3(0.6, 0.75, 1.0);
    } else {
        float a = (t - T_ANATOMY) * 0.55 + 2.4;
        gKeyPos = gC + vec3(cos(a) * 5.5, 2.5 + sin(t * 0.7), sin(a) * 5.5);
        gKeyI = 14.0 * ss(T_ANATOMY, T_ANATOMY + 0.6, t) * (1.0 - ss(T_DISTORT + 1.0, T_DISTORT + 3.0, t));
        gKeyCol = vec3(0.85, 0.9, 1.0);
    }
}

// ------------------------------------------------------------------ rings --
// cross-section SDF of ring i in its local frame (ring lies in local xy)
float ringBase(int i, vec3 q, float R) {
    vec2 cs = vec2(length(q.xy) - R, q.z);
    return sdChamfer2(cs, RS[i], RS[i].x * 0.35);
}
float ringDetail(int i, vec3 q, float R, out float seam, out float panel) {
    vec2 sz = RS[i];
    float rr = length(q.xy);
    float u = rr - R, v = q.z;
    float d = sdChamfer2(vec2(u, v), sz, sz.x * 0.35);
    // panel slots every ~0.42 units of arc
    float a = atan(q.y, q.x);
    float n = floor(TAU * R / 0.42);
    float cell = TAU / n;
    float ac = mod(a + cell * 0.5, cell) - cell * 0.5;
    panel = floor((a + cell * 0.5) / cell);
    float s = ac * R;
    float g = 0.0045;
    d = max(d, min(g - abs(s), d + 0.012));
    // two circumferential grooves on each face
    float gw = 0.0055, gd = 0.010;
    float gr = max(abs(abs(u) - sz.x * 0.58) - gw, (sz.y - gd) - abs(v));
    d = max(d, -gr);
    // emissive seam channel on the face centre line
    float sw = 0.011, sd = 0.014;
    float sc = max(abs(u) - sw, (sz.y - sd) - abs(v));
    d = max(d, -sc);
    // rim groove on the outer and inner cylinders
    float rg = max(abs(v) - 0.006, (sz.x - 0.010) - abs(u));
    d = max(d, -rg);
    seam = 0.0;
    return d;
}

float mapRings(vec3 p) {
    vec3 lp = p - gC;
    float d = 1e9;
    for (int i = 0; i < 5; i++) {
        vec3 q = gM[i] * lp;
        float R = RR[i] * gScale[i];
        float b = ringBase(i, q, R);
        if (b < 0.04) {
            float s, pn;
            b = ringDetail(i, q, R, s, pn);
        }
        d = min(d, b);
    }
    return d;
}

// identify the closest ring + material at a hit point
int ringId(vec3 p, out vec3 q) {
    vec3 lp = p - gC;
    float best = 1e9;
    int id = 0;
    for (int i = 0; i < 5; i++) {
        vec3 qq = gM[i] * lp;
        float b = ringBase(i, qq, RR[i] * gScale[i]);
        if (b < best) { best = b; id = i; q = qq; }
    }
    return id;
}

// ------------------------------------------------------------------ water --
float waterH(vec2 xz) {
    float t = gT;
    float h = 0.007 * sin(dot(xz, vec2(0.31, 0.95)) * 0.7 + t * 0.45)
            + 0.005 * sin(dot(xz, vec2(-0.72, 0.69)) * 1.3 + t * 0.7)
            + 0.004 * sin(dot(xz, vec2(0.95, -0.3)) * 2.7 + t * 1.1);
    vec2 d = xz - gC.xz;
    float r = length(d);
    h += gRipple * 0.0045 * sin(r * 2.6 - t * 1.8) * exp(-r * 0.22);
    if (gLift > 0.0) {
        float a = atan(d.y, d.x);
        float sw = 0.05 * gLift * sin(5.0 * a + r * 3.0 - t * 5.0) * exp(-r * 0.5);
        float rr = sqrt(r * r + 0.004);
        float col = gLift * exp(-rr / (0.32 + 0.25 * exp(-gLift * 0.5)));
        h += col + 0.22 * gLift * exp(-r * r / 5.0) + sw * ss(0.0, 1.2, r);
    }
    return h;
}

// --------------------------------------------------------------------- sky --
vec3 stars(vec3 d) {
    vec3 c = vec3(0.0);
    for (int k = 0; k < 2; k++) {
        float sc = k == 0 ? 160.0 : 320.0;
        vec3 g = d * sc;
        vec3 id = floor(g);
        vec3 f = fract(g) - 0.5;
        vec3 h = h33(id + float(k) * 17.0);
        if (h.x > (k == 0 ? 0.985 : 0.992)) {
            vec3 o = (h - 0.5) * 0.6;
            float r = length(f - o);
            float br = pow(h.y, 6.0) * 6.0 + 0.15;
            c += br * exp(-r * r * 260.0) * mix(vec3(0.7, 0.8, 1.0), vec3(1.0, 0.85, 0.7), h.z);
        }
    }
    return c;
}
vec3 sky(vec3 d, bool withSun) {
    float el = d.y;
    vec3 base = vec3(0.0016, 0.0022, 0.0036);
    float cs = dot(d, gSunDir);
    // horizon haze, warmer and brighter towards the star
    float hz = exp(-abs(el - 0.005) * 22.0) * (0.3 + 0.7 * gFogI);
    float warm = pow(max(cs, 0.0), 6.0);
    vec3 col = base + hz * (vec3(0.0030, 0.0036, 0.0050) + warm * vec3(0.045, 0.026, 0.012) * gSunI);
    col += vec3(0.6, 0.38, 0.2) * pow(max(cs, 0.0), 160.0) * 0.22 * gSunI * gFogI;   // aureole
    col += stars(d) * 0.05 * ss(-0.02, 0.15, el);
    // act I: faint cold horizon so the void is not dead black
    col += vec3(0.004, 0.006, 0.010) * exp(-abs(el) * 30.0);
    if (withSun) {
        float disc = ss(0.99985, 0.99993, cs);
        col += SUN_COL * disc * 120.0 * gSunI;
        col += SUN_COL * pow(max(cs, 0.0), 4000.0) * 5.0 * gSunI;
    }
    return col;
}

// ------------------------------------------------------------------ fog --
vec3 applyFog(vec3 col, vec3 ro, vec3 rd, float t, out float trans) {
    float a = 0.012, b = 0.30;
    float h0 = max(ro.y, 0.0);
    float fy = abs(rd.y) < 1e-4 ? 1e-4 : rd.y;
    float od = a * exp(-b * h0) * (1.0 - exp(-b * fy * t)) / (b * fy);
    od = max(od, 0.0) + 0.0012 * t;
    trans = exp(-od);
    float cs = max(dot(rd, gSunDir), 0.0);
    float ph = 0.04 + 0.35 * pow(cs, 60.0) + 4.0 * pow(cs, 700.0);
    vec3 fc = vec3(0.0022, 0.0028, 0.0040) + SUN_COL * ph * 0.06 * gSunI * gFogI;
    return col * trans + fc * (1.0 - trans);
}

// --------------------------------------------------------------- marching --
// The march handles: rings (true SDF), water (height field stepped along the
// ray), and gravitational bending around the hole (Schwarzschild, rs=gHole).
struct Hit { float t; int mat; vec3 p; vec3 rd; float minHole; float pathLen; };

const int MAT_SKY = 0, MAT_RING = 1, MAT_WATER = 2, MAT_HOLE = 3;

Hit march(vec3 ro, vec3 rd, float tmax, bool withWater, int maxSteps) {
    Hit h;
    h.mat = MAT_SKY;
    h.minHole = 1e9;
    vec3 p = ro;
    float t = 0.0;
    vec3 v = rd;
    bool bend = gHole > 1e-4;
    for (int i = 0; i < 260; i++) {
        if (i >= maxSteps) break;
        float dr = mapRings(p);
        float dw = 1e9;
        if (withWater) {
            float hy = p.y - waterH(p.xz);
            if (hy < 0.0015 + t * 0.0004) { h.mat = MAT_WATER; break; }
            dw = v.y < -1e-3 ? hy / -v.y * 0.75 : 1e9;
            if (gLift > 0.0) dw = min(dw, hy * 0.13 + 0.003);
        }
        if (dr < 0.0006 + t * 0.00025) { h.mat = MAT_RING; break; }
        float st = min(dr, dw);
        if (bend) {
            vec3 hp = p - gC;
            float r = length(hp);
            h.minHole = min(h.minHole, r / gHole);
            if (r < gHole * 1.02) { h.mat = MAT_HOLE; break; }
            // Schwarzschild photon: a = -1.5 h^2 x / r^5 (units of rs)
            st = min(st, max(0.12 * r, 0.006));
            vec3 x = hp / gHole;
            vec3 hh = cross(x, v);
            float h2 = dot(hh, hh);
            float rx = length(x);
            vec3 acc = -1.5 * h2 * x / pow(rx, 5.0);
            v = normalize(v + acc * (st / gHole));
        }
        p += v * st;
        t += st;
        if (t > tmax) break;
    }
    h.t = t;
    h.p = p;
    h.rd = v;
    h.pathLen = t;
    return h;
}

vec3 ringNormal(vec3 p, float e) {
    const vec2 k = vec2(1.0, -1.0);
    vec3 g = k.xyy * mapRings(p + k.xyy * e) + k.yyx * mapRings(p + k.yyx * e) +
             k.yxy * mapRings(p + k.yxy * e) + k.xxx * mapRings(p + k.xxx * e);
    if (dot(g, g) < 1e-14) {
        // a wide epsilon can straddle a thin groove and cancel out: refine
        e = 0.0006;
        g = k.xyy * mapRings(p + k.xyy * e) + k.yyx * mapRings(p + k.yyx * e) +
            k.yxy * mapRings(p + k.yxy * e) + k.xxx * mapRings(p + k.xxx * e);
    }
    return g * inversesqrt(max(dot(g, g), 1e-20));
}

float softShadow(vec3 ro, vec3 rd, float tmax) {
    float res = 1.0, t = 0.02;
    for (int i = 0; i < 28; i++) {
        float d = mapRings(ro + rd * t);
        res = min(res, 10.0 * d / t);
        t += clamp(d, 0.02, 0.35);
        if (res < 0.01 || t > tmax) break;
    }
    return sat(res);
}
float ao(vec3 p, vec3 n) {
    float o = 0.0, s = 1.0;
    for (int i = 1; i <= 4; i++) {
        float h = 0.02 + 0.06 * float(i);
        o += (h - mapRings(p + n * h)) * s;
        s *= 0.6;
    }
    return sat(1.0 - 2.2 * o);
}

// GGX specular
float ggx(vec3 n, vec3 v, vec3 l, float rough) {
    vec3 hv = normalize(v + l);
    float nh = max(dot(n, hv), 0.0), nl = max(dot(n, l), 0.0), nv = max(dot(n, v), 1e-3);
    float a = rough * rough, a2 = a * a;
    float dd = nh * nh * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * dd * dd);
    float k = a * 0.5;
    float G = nl / (nl * (1.0 - k) + k) * nv / (nv * (1.0 - k) + k);
    return D * G / (4.0 * nv + 1e-4) ;
}

vec3 shadeRing(vec3 p, vec3 rd, bool cheap) {
    vec3 q;
    int id = ringId(p, q);
    float R = RR[id] * gScale[id];
    float seam, panel;
    ringDetail(id, q, R, seam, panel);
    {
        // analytic, footprint-filtered seam band on both faces
        float fp = max(gFp * length(p - gCamPos), 0.0008);
        float u = length(q.xy) - R;
        float sw = 0.011;
        float band = ss(sw + fp, max(sw - fp, 0.0), abs(u));
        float face = ss(RS[id].y - 0.016 - fp, RS[id].y - 0.016 + fp * 0.5, abs(q.z));
        seam = band * face;
    }
    float fpw = gFp * length(p - gCamPos);
    vec3 n = ringNormal(p, clamp(fpw * 0.7, 0.0006, 0.006));
    vec3 v = -rd;
    float hp = h12(vec2(panel, float(id) * 7.0));
    float rough = 0.22 + 0.22 * hp;
    // brushed micro-variation along the circumference
    float a = atan(q.y, q.x);
    float w1 = sat(1.0 - fpw * 3000.0 * 0.5), w2 = sat(1.0 - fpw * 700.0 * 0.5);
    float brushed = 0.5 + (vnoise2(vec2(length(q.xy) * 3000.0, a * 4.0)) - 0.5) * 0.6 * w1
                        + (vnoise2(vec2(length(q.xy) * 700.0, a * 2.0)) - 0.5) * 0.4 * w2;
    rough = clamp(rough + 0.10 * (brushed - 0.5), 0.08, 0.6);
    rough = min(sqrt(rough * rough + (fpw * 28.0) * (fpw * 28.0)), 0.75);   // specular anti-aliasing
    vec3 F0 = mix(vec3(0.42, 0.43, 0.45), vec3(0.50, 0.47, 0.43), hp) * (0.62 + 0.12 * brushed);
    float nv = max(dot(n, v), 0.0);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - nv, 5.0);

    vec3 col = vec3(0.0);
    float occ = cheap ? 1.0 : ao(p, n);
    // sun
    vec3 l = gSunDir;
    float nl = max(dot(n, l), 0.0);
    col += SUN_COL * gSunI * 9.0 * F * ggx(n, v, l, rough) * nl;
    col += SUN_COL * gSunI * 0.02 * nl * occ;
    // key (point light)
    if (gKeyI > 0.0) {
        vec3 kl = gKeyPos - p;
        float kd = length(kl);
        kl /= kd;
        float knl = max(dot(n, kl), 0.0);
        float sh = (cheap || knl <= 0.0) ? 1.0 : softShadow(p + n * 0.003, kl, kd);
        float att = gKeyI / (kd * kd);
        col += gKeyCol * att * (F * ggx(n, v, kl, rough) * knl + 0.004 * knl) * sh;
    }
    // environment reflection (sky + horizon), blurred by roughness
    vec3 r = reflect(rd, n);
    vec3 env = sky(r, false) * 1.0;
    env += SUN_COL * gSunI * pow(max(dot(r, gSunDir), 0.0), mix(400.0, 20.0, sat(rough))) * 0.8;
    // fake reflection of the glowing water band below
    env += vec3(0.015, 0.012, 0.010) * ss(0.0, -0.4, r.y) * gSunI;
    col += env * F * occ;
    // emissive seam
    float em = gEmit[id];
    if (id == 4 && gT < T_EMERGE) {
        // ignition front travelling along the outer ring
        em *= ss(gIgnA + 0.04, gIgnA - 0.12, a) * (1.0 + 2.5 * exp(-abs(a - gIgnA) * 18.0));
    }
    float flow = 0.75 + 0.25 * pow(0.5 + 0.5 * sin(a * R * 6.0 - gT * 5.0 + float(id)), 6.0);
    col += SEAM_COL * seam * em * flow * 9.0;
    return col;
}

vec3 shadeWater(vec3 p, vec3 rd, float tHit, out vec3 reflDir) {
    // normal from the height field + fine noise
    float e = 0.02 + tHit * 0.002;
    float h0 = waterH(p.xz);
    vec3 n = normalize(vec3(h0 - waterH(p.xz + vec2(e, 0.0)), e, h0 - waterH(p.xz + vec2(0.0, e))));
    vec2 np = p.xz * 2.2 + vec2(gT * 0.15, gT * 0.08);
    float fade = exp(-tHit * 0.04);
    n = normalize(n + fade * 0.014 * vec3(vnoise2(np) - 0.5, 0.0, vnoise2(np + 31.7) - 0.5));
    vec3 r = reflect(rd, n);
    reflDir = r;
    float nv = max(dot(n, -rd), 0.0);
    float F = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
    // glitter path of the star
    float spec = ggx(n, -rd, gSunDir, 0.07) * max(dot(n, gSunDir), 0.0);
    vec3 col = SUN_COL * gSunI * spec * 3.5 * F;
    // deep obsidian body
    col += vec3(0.0006, 0.0008, 0.0012);
    if (gLift > 0.0) {
        float heat = ss(gC.y - 2.6, gC.y - 0.4, p.y) * ss(0.0, 1.5, gLift);
        float fl = 0.7 + 0.3 * vnoise(vec3(p.xz * 6.0, p.y * 3.0 - gT * 6.0));
        col += blackbody(0.25 + 0.7 * heat) * heat * heat * 6.0 * fl;
    }
    return col;
}

// ------------------------------------------------------------------ dust --
// world-anchored motes sampled on a few shells around the camera; each mote
// fades in and out smoothly as its shell sweeps through it (no popping)
vec3 dust(vec3 ro, vec3 rd, float tScene) {
    vec3 acc = vec3(0.0);
    const float CELL = 3.2;
    for (int k = 0; k < 7; k++) {
        float dz = 0.35 + float(k) * float(k) * 0.42;
        if (dz > tScene) break;
        vec3 p = ro + rd * dz;
        vec3 g = p * CELL + vec3(0.0, gT * 0.05, gT * 0.035) + float(k) * 13.1;
        vec3 id = floor(g);
        vec3 f = fract(g) - 0.5;
        vec3 hh = h33(id);
        if (hh.x > 0.80) {
            vec3 o = (hh.yzx - 0.5) * 0.5;
            vec3 dd = f - o;
            float along = dot(dd, rd);
            vec3 perp = dd - rd * along;
            float r = length(perp) / CELL;
            float sz = 0.0005 * dz;
            float m = exp(-r * r / (sz * sz)) * ss(0.45, 0.1, abs(along));
            float tw = 0.65 + 0.35 * sin(gT * 1.3 + hh.y * 40.0);
            acc += m * tw * (0.2 + 0.5 * hh.z);
        }
    }
    return acc;
}

// --------------------------------------------------------------- cameras --
struct Cam { vec3 ro; vec3 ta; float zoom; float roll; float focus; float aper; };

Cam camera(float t) {
    Cam c;
    c.roll = 0.0;
    c.aper = 0.0;
    if (t < T_EMERGE) {
        // macro on the upper right arc of the outer ring
        float x = lin(0.0, T_EMERGE, t);
        float a0 = mix(0.62, 0.86, easeInOutSine(x));
        vec3 rp = vec3(cos(a0), sin(a0), 0.0) * 3.10;
        vec3 tg = vec3(-sin(a0), cos(a0), 0.0);
        c.ro = gC + gRoot * (rp + vec3(0.0, 0.0, -1.05) + tg * -0.55 + vec3(cos(a0), sin(a0), 0.0) * 0.22);
        c.ta = gC + gRoot * (rp + tg * 0.55 + vec3(0.0, 0.0, 0.05));
        rp = gC + gRoot * rp;
        c.zoom = 3.3;
        c.roll = -0.18;
        c.focus = length(rp + tg * 0.1 - c.ro);
        c.aper = 0.020;
    } else if (t < T_ANATOMY) {
        float x = lin(T_EMERGE, T_ANATOMY, t);
        float e = easeInOutSine(x);
        c.ro = vec3(mix(-2.2, -0.6, e), mix(0.28, 0.85, e), mix(-13.6, -8.4, e));
        c.ta = vec3(0.0, mix(2.6, 3.2, e), 0.0);
        c.zoom = 1.08;
        c.roll = mix(0.025, -0.01, e);
        c.focus = length(gC - c.ro);
        c.aper = 0.0;
    } else if (t < T_DISTORT) {
        float x = lin(T_ANATOMY, T_DISTORT, t);
        float e = easeInOutSine(x);
        float a = mix(-0.55, 0.95, e);
        float rad = mix(8.6, 6.4, e);
        c.ro = gC + vec3(sin(a) * rad, mix(-2.4, 0.6, e), -cos(a) * rad);
        c.ta = gC + vec3(0.0, -0.1, 0.0);
        c.zoom = 1.6;
        c.roll = mix(-0.06, 0.04, e);
        c.focus = length(gC - c.ro);
        c.aper = 0.0;
    } else {
        float x = lin(T_DISTORT, T_COLLAPSE, t);
        float e = easeInOutSine(x);
        float e2 = easeInOutCubic(lin(T_DISTORT + 1.5, T_COLLAPSE, t));
        float dist = mix(5.6, 8.8, e);
        vec3 dir = normalize(gSunDir + vec3(mix(-0.02, 0.07, e2), mix(0.0, 0.09, e2), 0.0));
        c.ro = gC - dir * dist;
        c.ro.y = max(c.ro.y, 0.6);
        c.ta = gC + vec3(0.0, mix(0.0, -0.7, e2), 0.0);
        c.zoom = mix(1.45, 1.35, e);
        c.roll = mix(0.03, -0.06, e) + 0.015 * sin(t * 0.9);
        c.focus = length(gC - c.ro);
        c.aper = 0.0;
    }
    // impacts shake the camera
    float sh = shake(t, T_EMERGE, 0.06) + shake(t, T_ANATOMY, 0.035) + shake(t, T_DISTORT, 0.05)
             + shake(t, T_LOCK0, 0.018) + shake(t, T_LOCK1, 0.018) + shake(t, T_LOCK2, 0.018)
             + 0.012 * easeInExpo(lin(T_DISTORT + 2.0, T_COLLAPSE, t));
    if (sh > 0.0) {
        vec3 n = vec3(vnoise(vec3(t * 23.0, 1.0, 0.0)), vnoise(vec3(t * 21.0, 7.0, 3.0)), vnoise(vec3(t * 19.0, 3.0, 9.0))) - 0.5;
        c.ta += n * sh * length(c.ta - c.ro) * 0.25;
    }
    return c;
}

vec3 camRay(Cam c, vec2 fc, out mat3 m) {
    vec2 uv = (fc - 0.5 * uRes) / uRes.y;
    m = lookAt(c.ro, c.ta, c.roll);
    return normalize(m * vec3(uv, c.zoom));
}

// ------------------------------------------------------------------ main --
vec3 renderSample(vec2 fc, float t, inout vec4 aux) {
    setup(t);
    Cam cam = camera(t);
    gCamPos = cam.ro;
    gFp = 1.0 / (cam.zoom * uRes.y);
    mat3 cm;
    vec3 rd = camRay(cam, fc, cm);
    vec3 ro = cam.ro;

    Hit h = march(ro, rd, 90.0, true, 220);
    vec3 col;
    float depth = h.t;
    float lightMask = 0.0;
    if (h.mat == MAT_RING) {
        col = shadeRing(h.p, h.rd, false);
    } else if (h.mat == MAT_WATER) {
        vec3 rdir;
        col = shadeWater(h.p, h.rd, h.t, rdir);
        float nv = max(dot(normalize(vec3(0, 1, 0)), -h.rd), 0.0);
        // reflection: march again (no water), cheaper shading
        Hit r = march(h.p + vec3(0.0, 0.004, 0.0), rdir, 60.0, false, 110);
        vec3 rc;
        if (r.mat == MAT_RING) rc = shadeRing(r.p, r.rd, true);
        else if (r.mat == MAT_HOLE) rc = vec3(0.0);
        else rc = sky(r.rd, true);
        float tr;
        rc = applyFog(rc, h.p, rdir, r.t, tr);
        float F = 0.02 + 0.98 * pow(1.0 - max(dot(vec3(0, 1, 0), -h.rd), 0.0), 5.0);
        col += rc * mix(F, 1.0, 0.25) * 0.85;
    } else if (h.mat == MAT_HOLE) {
        col = vec3(0.0);
    } else {
        col = sky(h.rd, true);
        float cs = dot(h.rd, gSunDir);
        lightMask = ss(0.995, 0.9998, cs);
        depth = 1e3;
    }
    // photon ring glow around the singularity
    if (gHole > 0.0 && h.mat != MAT_HOLE && h.minHole < 4.0) {
        float g = exp(-abs(h.minHole - 1.55) * 22.0);
        col += vec3(1.0, 0.72, 0.45) * g * 0.5 * ss(T_DISTORT, T_DISTORT + 1.5, t);
    }
    float tr;
    col = applyFog(col, ro, rd, min(h.t, 120.0), tr);
    lightMask *= tr;

    // floating dust (with its own bokeh)
    col += dust(ro, rd, h.t) * mix(vec3(0.5, 0.6, 0.8), SUN_COL, 0.6) * (0.25 + gSunI * 0.4 + gKeyI * 0.2);

    // circle of confusion (px) for the post DOF
    float coc = cam.aper > 0.0 ? cam.aper * abs(depth - cam.focus) / max(depth, 1e-3) * cam.zoom * uRes.y * 1.0 : 0.0;
    aux = vec4(depth, lightMask, coc, 0.0);
    return col;
}

// --------------------------------------------------------------- probe ---
vec4 probe(int i, float t) {
    setup(t);
    Cam c = camera(t);
    mat3 m = lookAt(c.ro, c.ta, c.roll);
    vec3 d = transpose(m) * gSunDir;
    vec2 suv = d.xy / d.z * c.zoom;
    vec2 luv = vec2(suv.x * uRes.y / uRes.x + 0.5, suv.y + 0.5);
    if (i == 0) {
        float rays = (t < T_EMERGE) ? 0.0 : 1.0;
        if (d.z < 0.0) rays = 0.0;
        rays *= 1.0 + 0.8 * hitPulse(t, T_EMERGE, 1.5);
        rays *= 1.0 - ss(T_DISTORT - 0.01, T_DISTORT, t);
        float dof = c.aper > 0.0 ? 34.0 : 0.0;
        return vec4(luv, rays * 0.55, dof);
    }
    if (i == 1) {
        float exposure = 1.0;
        if (t < T_EMERGE) exposure = 1.25;
        else if (t < T_ANATOMY) exposure = 1.05;
        else if (t < T_DISTORT) exposure = 1.1;
        else exposure = 1.05 + 0.35 * ss(T_COLLAPSE - 1.5, T_COLLAPSE, t);
        float flash = 0.30 * hitPulse(t, T_EMERGE, 16.0) * step(T_EMERGE, t)
                    + 0.18 * hitPulse(t, T_ANATOMY, 10.0) * step(T_ANATOMY, t)
                    + 0.35 * hitPulse(t, T_DISTORT, 8.0) * step(T_DISTORT, t);
        // fade in from black at the very start
        exposure *= ss(0.0, 1.8, t);
        return vec4(exposure, 0.03, 0.025, flash);
    }
    if (i == 2) {
        float fade = ss(0.0, 0.9, t);
        return vec4(fade, 0.004, 0.04, 0.55);
    }
    return vec4(0.95, 1.3, 0.0, 0.0);
}
