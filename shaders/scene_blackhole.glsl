// SINGULARITY — act V "collapse": the rings have been torn into an accretion
// disk. Rays are integrated along Schwarzschild null geodesics (rs = 1), the
// thin disk is accumulated at every crossing (primary + lensed images) with
// Keplerian differential rotation, Doppler beaming and gravitational redshift.
// The disk then implodes; one beat of black with a single point of light.

// ---------------------------------------------------------------- state ---
vec3  gCamPos;
float gT, gLt;
float gSpin;      // texture rotation multiplier (integrated)
float gCol;       // collapse 0..1
float gBright;
float gFp;

const float RIN = 2.9;
const float ROUT = 15.0;

// integrated rotation phase for a time-varying speed multiplier
float spinPhase(float lt) {
    // speed(lt) = 7 + 2.2*lt + implosion boost; analytic integral
    float base = 7.0 * lt + 1.1 * lt * lt;
    float ci = max(lt - 5.1, 0.0);
    return base + 60.0 * ci * ci * ci;
}

void setup(float t) {
    gT = t;
    gLt = t - T_COLLAPSE;
    gSpin = spinPhase(gLt);
    gCol = easeInExpo(lin(T_BREATH - 0.95, T_BREATH - 0.04, t));
    gBright = 1.0 + 0.6 * hitPulse(t, T_COLLAPSE, 3.0) * step(T_COLLAPSE, t) + 0.25 * ss(T_COLLAPSE + 2.5, T_BREATH - 0.9, t);
}

// ---------------------------------------------------------------- sky ----
vec3 starfield(vec3 d) {
    vec3 c = vec3(0.0);
    for (int k = 0; k < 3; k++) {
        float sc = 90.0 + 110.0 * float(k);
        vec3 g = d * sc;
        vec3 id = floor(g);
        vec3 f = fract(g) - 0.5;
        vec3 h = h33(id + float(k) * 31.0);
        if (h.x > 0.975) {
            vec3 o = (h.yzx - 0.5) * 0.6;
            float r = length(f - o);
            float br = pow(h.y, 8.0) * 3.0 + 0.08;
            c += br * exp(-r * r * 90.0) * mix(vec3(0.75, 0.82, 1.0), vec3(1.0, 0.82, 0.62), h.z);
        }
    }
    // faint galactic band with dust lanes
    vec3 bn = normalize(vec3(0.25, 1.0, 0.35));
    float b = exp(-pow(dot(d, bn) * 4.0, 2.0));
    float neb = fbm3(d * 4.0 + 3.1, 4);
    float lanes = ss(0.35, 0.65, fbm3(d * 9.0 + 11.0, 3));
    c += b * (0.006 + 0.012 * neb) * mix(1.0, 0.35, lanes) * vec3(0.55, 0.62, 0.85);
    return c * 0.55;
}

// ---------------------------------------------------------------- disk ---
// returns emission (rgb) and opacity (a) at radius r, angle phi
vec4 diskSample(float r, float phi, vec3 rayDir, vec3 pos) {
    // collapse: the material is drawn inwards (sample from further out)
    float rs = r * (1.0 + 3.2 * gCol);
    float rin = RIN;
    if (rs < rin * 0.92 || rs > ROUT) return vec4(0.0);
    float omega = sqrt(0.5 / (rs * rs * rs));
    float ph = phi + omega * gSpin;
    // turbulent gas, stretched along the orbit
    vec3 np = vec3(cos(ph) * 2.2, sin(ph) * 2.2, rs * 1.35);
    float n1 = fbm3(np * vec3(1.0, 1.0, 1.0) + vec3(0.0, 0.0, 0.0), 5);
    float n2 = fbm3(vec3(cos(ph) * 6.0, sin(ph) * 6.0, rs * 4.2) + 7.3, 3);
    float dens = ss(0.30, 0.80, n1) * (0.30 + 0.70 * n2);
    // the five shredded rings: thin bright ringlets
    float rl = 0.0;
    const float RL[5] = float[](3.55, 4.35, 5.30, 6.55, 8.10);
    for (int i = 0; i < 5; i++) {
        float w = 0.035 + 0.012 * float(i);
        float g = exp(-pow((rs - RL[i]) / w, 2.0));
        float clump = 0.55 + 0.45 * vnoise(vec3(cos(ph) * 9.0, sin(ph) * 9.0, float(i) * 3.0));
        rl += g * clump;
    }
    // radial profile
    float edgeIn = ss(rin * 0.92, rin * 1.12, rs);
    float edgeOut = 1.0 - ss(ROUT * 0.45, ROUT, rs);
    float prof = edgeIn * edgeOut;
    // temperature (Shakura-Sunyaev-like) and colour
    float x = max(1.0 - sqrt(rin / rs), 0.0);
    float temp = pow(rin / rs, 0.75) * pow(x + 0.02, 0.25) * 1.7;
    // Doppler beaming + gravitational redshift
    vec3 tang = normalize(vec3(-pos.z, 0.0, pos.x));   // orbital direction (counter-clockwise from above)
    float beta = sqrt(0.5 / max(r, 1.6));
    float gamma = 1.0 / sqrt(1.0 - beta * beta);
    float cosv = dot(tang, -rayDir);
    float D = 1.0 / (gamma * (1.0 - beta * cosv));
    float gr = sqrt(max(1.0 - 1.0 / r, 0.02));
    float g = D * gr;
    float beam = pow(g, 4.0);
    float tc = clamp(temp * g * 0.95, 0.0, 1.25);
    vec3 col = blackbody(tc);
    float I = (dens * 1.1 + rl * 3.2) * prof * beam * (0.15 + 3.0 * pow(temp, 2.5));
    I *= gBright * (1.0 + 2.5 * gCol);
    float a = sat((dens * 0.8 + rl * 0.9) * prof) * 0.85;
    return vec4(col * I, a);
}

// --------------------------------------------------------------- camera --
struct Cam { vec3 ro; vec3 ta; float zoom; float roll; };
Cam camera(float t) {
    Cam c;
    float lt = t - T_COLLAPSE;
    float e = easeInOutSine(lin(0.0, 5.4, lt));
    float push = easeInExpo(lin(4.6, 5.95, lt));
    float d = mix(27.0, 17.5, e) - 5.0 * push;
    float el = mix(0.20, 0.075, e) - 0.03 * push;
    float az = mix(-0.35, 0.35, e) + 0.25 * push;
    c.ro = d * vec3(sin(az) * cos(el), sin(el), -cos(az) * cos(el));
    c.ta = vec3(0.0, mix(-0.6, 0.0, e), 0.0);
    c.zoom = mix(1.55, 1.75, e) + 0.3 * push;
    c.roll = mix(-0.16, -0.05, e) + 0.06 * push;
    // micro shake rising with the energy
    float sh = 0.08 * hitPulse(t, T_COLLAPSE, 6.0) * step(T_COLLAPSE, t) + 0.03 * push;
    vec3 n = vec3(vnoise(vec3(t * 23.0, 1.0, 0.0)), vnoise(vec3(t * 21.0, 7.0, 3.0)), 0.5) - 0.5;
    c.ta += n * sh * 2.0;
    return c;
}

// ------------------------------------------------------------------ main --
vec3 renderSample(vec2 fc, float t, inout vec4 aux) {
    setup(t);
    vec2 uv = (fc - 0.5 * uRes) / uRes.y;
    aux = vec4(1e3, 0.0, 0.0, 0.0);

    // the breath: one beat of black, a single point of light
    if (t >= T_BREATH) {
        float lt = t - T_BREATH;
        float r = length(uv);
        float appear = ss(0.06, 0.35, lt);
        float swell = easeInExpo(lin(0.25, T_IMPACT - T_BREATH, lt));
        float flick = 0.85 + 0.15 * sin(lt * 70.0) * sin(lt * 23.0);
        float core = exp(-r * r / (0.000018 + 0.00025 * swell)) * (2.0 + 60.0 * swell) * flick;
        float halo = exp(-r / (0.012 + 0.05 * swell)) * (0.03 + 0.8 * swell);
        vec3 c = vec3(1.0, 0.9, 0.78) * (core + halo) * appear;
        return c;
    }

    Cam cam = camera(t);
    mat3 m = lookAt(cam.ro, cam.ta, cam.roll);
    vec3 rd = normalize(m * vec3(uv, cam.zoom));
    vec3 x = cam.ro;
    vec3 v = rd;
    vec3 col = vec3(0.0);
    float alpha = 0.0;
    float glow = 0.0;
    bool captured = false;
    float minR = 1e9;
    for (int i = 0; i < 300; i++) {
        float r = length(x);
        minR = min(minR, r);
        if (r < 1.005) { captured = true; break; }
        if (r > 45.0 && dot(x, v) > 0.0) break;
        float dt = clamp(0.07 * (r - 0.9), 0.012, 1.4);
        // near the disk plane take smaller steps so crossings are accurate
        if (abs(x.y) < 1.0 && r < ROUT + 2.0) dt = min(dt, 0.35);
        vec3 hh = cross(x, v);
        float h2 = dot(hh, hh);
        vec3 acc = -1.5 * h2 * x / pow(r, 5.0);
        vec3 xn = x + v * dt;
        vec3 vn = normalize(v + acc * dt);
        // disk crossing
        if (x.y * xn.y < 0.0) {
            float f = x.y / (x.y - xn.y);
            vec3 xp = mix(x, xn, f);
            float rr = length(xp.xz);
            if (rr > 1.2 && rr < ROUT) {
                vec4 d = diskSample(rr, atan(xp.z, xp.x), v, xp);
                col += (1.0 - alpha) * d.rgb * (0.25 + 0.75 * d.a);
                alpha += (1.0 - alpha) * d.a;
            }
        }
        // soft volumetric corona around the disk
        float rh = length(x.xz);
        if (rh < ROUT && rh > RIN * 0.9) {
            float hgt = abs(x.y);
            float cg = exp(-hgt / (0.06 + 0.02 * rh)) * ss(ROUT, RIN, rh) * ss(RIN * 0.9, RIN * 1.4, rh);
            glow += cg * dt * (1.0 - alpha);
        }
        x = xn;
        v = vn;
        if (alpha > 0.995) break;
    }
    vec3 bg = captured ? vec3(0.0) : starfield(v);
    col += (1.0 - alpha) * bg;
    col += vec3(1.0, 0.62, 0.32) * glow * 0.035 * gBright * (1.0 + 2.0 * gCol);

    // the instant before black: everything flares
    col *= 1.0 - ss(T_BREATH - 0.05, T_BREATH - 0.005, t);

    aux = vec4(length(x - cam.ro), 1.0, 0.0, 0.0);  // g = 1 -> zoom blur source everywhere
    return col;
}

// --------------------------------------------------------------- probe ---
vec4 probe(int i, float t) {
    setup(t);
    Cam c = camera(t);
    mat3 m = lookAt(c.ro, c.ta, c.roll);
    vec3 d = transpose(m) * normalize(-c.ro);
    vec2 suv = d.xy / d.z * c.zoom;
    vec2 luv = vec2(suv.x * uRes.y / uRes.x + 0.5, suv.y + 0.5);
    if (i == 0) {
        // radial "zoom" blur towards the hole during the implosion
        float zb = 0.25 * hitPulse(t, T_COLLAPSE, 5.0) * step(T_COLLAPSE, t) + 0.9 * easeInQuint(lin(T_BREATH - 1.0, T_BREATH - 0.02, t));
        if (t >= T_BREATH) zb = 0.0;
        return vec4(luv, zb, 0.0);
    }
    if (i == 1) {
        float exposure = 0.85;
        float flash = 0.25 * hitPulse(t, T_COLLAPSE, 14.0) * step(T_COLLAPSE, t);
        if (t >= T_BREATH) { exposure = 1.0; flash = 0.0; }
        return vec4(exposure, 0.05, 0.05, flash);
    }
    if (i == 2) return vec4(1.0, 0.004, 0.04, 0.6);
    return vec4(1.0, 1.25, 0.0, 0.0);
}
