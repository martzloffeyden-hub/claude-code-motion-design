// SINGULARITY — scene entry point (appended after every scene shader).
// Each scene defines:
//   vec3 renderSample(vec2 fragCoord, float t, inout vec4 aux)
//        aux.r = depth, aux.g = light-shaft source mask, aux.b = CoC (px)
//   vec4 probe(int i, float t)   -> per-frame post parameters (read back by CPU)

layout(location = 0) out vec4 oCol;
layout(location = 1) out vec4 oAux;

void main() {
    vec2 fc = gl_FragCoord.xy;
#ifdef PROBE
    oCol = probe(int(fc.x), uTime);
    oAux = vec4(0.0);
    return;
#else
    if (fc.y < uBar - 1.0 || fc.y > uRes.y - uBar + 1.0) {
        oCol = vec4(0.0, 0.0, 0.0, 1.0);
        oAux = vec4(1e4, 0.0, 0.0, 0.0);
        return;
    }
    float seed = h12(fc * 1.37 + fract(uFrame * 0.6180339) * 97.0);
    vec3 acc = vec3(0.0);
    vec4 aux = vec4(0.0);
    for (int s = 0; s < uSpp; s++) {
        vec2 o = (uSpp > 1) ? r2(s, seed) : vec2(0.5);
        float tj = (uSpp > 1) ? fract(seed * 7.31 + float(s) * 0.6180339) : 0.5;
        float t = clamp(uTime + (tj - 0.5) * uShutter, uShot.x, uShot.y - 1e-4);
        vec4 a = vec4(0.0);
        acc += renderSample(fc - 0.5 + o, t, a);
        aux += a;
    }
    float inv = 1.0 / float(uSpp);
    // never let a numerical accident poison the bloom pyramid
    if (any(isnan(acc)) || any(isinf(acc))) acc = vec3(0.0);
    acc = min(acc, vec3(4000.0));
    if (any(isnan(aux)) || any(isinf(aux))) aux = vec4(1e3, 0.0, 0.0, 0.0);
    oCol = vec4(max(acc * inv, 0.0), 1.0);
    oAux = aux * inv;
#endif
}
