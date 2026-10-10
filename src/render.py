#!/usr/bin/env python3
"""SINGULARITY — offline GPU-style renderer (OpenGL 4.3 via moderngl).

Runs on any OpenGL implementation, including Mesa llvmpipe (pure CPU) in a
headless container. Renders every frame of the film with:

  scene shader (raymarched, N samples/pixel with shutter jitter)
    -> optional depth of field (scatter-as-gather bokeh)
    -> bloom pyramid (13-tap down / tent up)
    -> anamorphic streak
    -> screen-space light shafts
    -> composite (AgX tonemap, grade, lens CA, vignette, grain, dither, letterbox)

and pipes 8-bit RGB frames into ffmpeg.

Usage:
  python3 src/render.py --still 5.0 12.3            # PNG stills into stills/
  python3 src/render.py --shot emerge --scale .25 --fps 15   # quick preview
  python3 src/render.py --shot emerge               # final quality segment
"""
import argparse
import os
import subprocess
import sys
import time

import numpy as np
import moderngl

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import timeline as TL  # noqa: E402

SHADERS = os.path.join(ROOT, "shaders")

# Per-shot render quality (samples per pixel, shutter as a fraction of a frame)
QUALITY = {
    "void": dict(spp=4, shutter=0.5),
    "emerge": dict(spp=4, shutter=0.5),
    "anatomy": dict(spp=5, shutter=0.5),
    "distort": dict(spp=7, shutter=0.35),
    "collapse": dict(spp=4, shutter=0.5),
    "final": dict(spp=4, shutter=0.5),
}

VS = """#version 430
in vec2 aPos;
out vec2 vUv;
void main() { vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }
"""


def read(name):
    with open(os.path.join(SHADERS, name)) as f:
        return f.read()


class Renderer:
    def __init__(self, width, height, spp_scale=1.0):
        self.W, self.H = width, height
        self.spp_scale = spp_scale
        self.ctx = moderngl.create_standalone_context(require=430)
        ctx = self.ctx
        self.vbo = ctx.buffer(np.array([-1, -1, 3, -1, -1, 3], dtype="f4").tobytes())
        self.common = read("common.glsl")
        self.defines = TL.glsl_defines()
        self.scene_progs = {}
        self.probe_progs = {}
        self.vaos = {}
        self.extra_textures = {}

        W, H = width, height
        f2 = "f2"
        self.hdr = ctx.texture((W, H), 4, dtype="f4")
        self.aux = ctx.texture((W, H), 4, dtype="f4")
        for t in (self.hdr, self.aux):
            t.filter = (moderngl.LINEAR, moderngl.LINEAR)
            t.repeat_x = t.repeat_y = False
        self.scene_fbo = ctx.framebuffer(color_attachments=[self.hdr, self.aux])
        self.hdr2 = self._tex(W, H, f2)
        self.hdr2_fbo = ctx.framebuffer(color_attachments=[self.hdr2])

        # bloom pyramid
        self.levels = []
        w, h = W, H
        for _ in range(7):
            w, h = max(1, w // 2), max(1, h // 2)
            t = self._tex(w, h, f2)
            self.levels.append((t, ctx.framebuffer(color_attachments=[t]), w, h))
        # streak ping-pong at quarter res
        self.sw, self.sh = max(1, W // 4), max(1, H // 4)
        self.streak = [self._tex(self.sw, self.sh, f2) for _ in range(2)]
        self.streak_fbo = [ctx.framebuffer(color_attachments=[t]) for t in self.streak]
        # god rays at half res
        self.rays = self._tex(W // 2, H // 2, f2)
        self.rays_fbo = ctx.framebuffer(color_attachments=[self.rays])
        # output
        self.out = ctx.texture((W, H), 4, dtype="f1")
        self.out_fbo = ctx.framebuffer(color_attachments=[self.out])
        # probe
        self.probe_tex = ctx.texture((4, 1), 4, dtype="f4")
        self.probe_aux = ctx.texture((4, 1), 4, dtype="f4")
        self.probe_fbo = ctx.framebuffer(color_attachments=[self.probe_tex, self.probe_aux])

        post = read("post.glsl")
        self.post = {}
        for p in ("DOWN", "UP", "STREAK", "RAYS", "DOF", "COMPOSITE"):
            src = "#version 430\n#define PASS_%s\n" % p + self.common + post
            prog = ctx.program(vertex_shader=VS, fragment_shader=src)
            self.post[p] = (prog, ctx.vertex_array(prog, [(self.vbo, "2f", "aPos")]))
        self.black = self._tex(1, 1, f2)

    def _tex(self, w, h, dtype):
        t = self.ctx.texture((w, h), 4, dtype=dtype)
        t.filter = (moderngl.LINEAR, moderngl.LINEAR)
        t.repeat_x = t.repeat_y = False
        return t

    # ------------------------------------------------------------ scenes --
    def scene(self, name):
        if name not in self.scene_progs:
            body = read(f"scene_{name}.glsl")
            main = read("scene_main.glsl")
            src = "#version 430\n" + self.defines + self.common + body + main
            psrc = "#version 430\n#define PROBE\n" + self.defines + self.common + body + main
            prog = self.ctx.program(vertex_shader=VS, fragment_shader=src)
            pprog = self.ctx.program(vertex_shader=VS, fragment_shader=psrc)
            self.scene_progs[name] = (prog, self.ctx.vertex_array(prog, [(self.vbo, "2f", "aPos")]))
            self.probe_progs[name] = (pprog, self.ctx.vertex_array(pprog, [(self.vbo, "2f", "aPos")]))
            if name == "final":
                self._load_title()
        return self.scene_progs[name], self.probe_progs[name]

    def _load_title(self):
        import title_texture
        img = title_texture.build()  # float32 HxWx4
        h, w = img.shape[:2]
        t = self.ctx.texture((w, h), 4, data=np.ascontiguousarray(img[::-1]).tobytes(), dtype="f4")
        t.filter = (moderngl.LINEAR_MIPMAP_LINEAR, moderngl.LINEAR)
        t.build_mipmaps()
        t.repeat_x = t.repeat_y = False
        self.extra_textures["uTitle"] = t

    @staticmethod
    def set(prog, name, value):
        if name in prog:
            prog[name].value = value

    def common_uniforms(self, prog, t, frame, bar, spp=1, shutter=0.0, shot=(0.0, 1e9)):
        self.set(prog, "uRes", (float(self.W), float(self.H)))
        self.set(prog, "uTime", float(t))
        self.set(prog, "uFrame", float(frame))
        self.set(prog, "uSpp", int(spp))
        self.set(prog, "uShutter", float(shutter))
        self.set(prog, "uBar", float(bar))
        self.set(prog, "uShot", (float(shot[0]), float(shot[1])))

    # ------------------------------------------------------------- frame --
    def render(self, t, frame, shot_shader, spp=None, shot_name=None):
        ctx = self.ctx
        W, H = self.W, self.H
        bar = TL.letterbox_bar(t, H, W)
        q = QUALITY[shot_name]
        spp = spp or max(1, int(round(q["spp"] * self.spp_scale)))
        (prog, vao), (pprog, pvao) = self.scene(shot_shader)

        # probe: per-frame post parameters computed by the scene itself
        self.common_uniforms(pprog, t, frame, bar)
        self.probe_fbo.use()
        ctx.viewport = (0, 0, 4, 1)
        pvao.render(moderngl.TRIANGLES)
        pr = np.frombuffer(self.probe_fbo.read(components=4, dtype="f4", attachment=0), dtype="f4").reshape(4, 4)
        light_uv = (float(pr[0, 0]), float(pr[0, 1]))
        rays_amt, dof_max = float(pr[0, 2]), float(pr[0, 3])
        exposure, bloom_amt, streak_amt, flash = map(float, pr[1])
        fade, ca, grain, vignette = map(float, pr[2])
        sat_, contrast, _, _ = map(float, pr[3])

        # scene
        self.scene_fbo.use()
        ctx.viewport = (0, 0, W, H)
        bounds = next((a, b) for n, _, a, b in TL.SHOTS if n == shot_name)
        self.common_uniforms(prog, t, frame, bar, spp, q["shutter"] / TL.FPS, bounds)
        unit = 4
        for k, tex in self.extra_textures.items():
            if k in prog:
                tex.use(unit)
                prog[k].value = unit
                unit += 1
        vao.render(moderngl.TRIANGLES)

        src = self.hdr
        # depth of field (scale radius with resolution)
        dof_px = dof_max * (W / 1920.0)
        if dof_px > 0.75:
            p, v = self.post["DOF"]
            self.hdr2_fbo.use()
            ctx.viewport = (0, 0, W, H)
            self.hdr.use(0); self.aux.use(1)
            self.set(p, "uSrc", 0); self.set(p, "uAux", 1)
            self.set(p, "uTexel", (1.0 / W, 1.0 / H))
            self.set(p, "uMaxRadius", dof_px)
            v.render(moderngl.TRIANGLES)
            src = self.hdr2

        # bloom down
        p, v = self.post["DOWN"]
        prev, pw, ph = src, W, H
        for i, (tex, fbo, w, h) in enumerate(self.levels):
            fbo.use()
            ctx.viewport = (0, 0, w, h)
            prev.use(0)
            self.set(p, "uSrc", 0)
            self.set(p, "uTexel", (1.0 / pw, 1.0 / ph))
            self.set(p, "uFirst", 1 if i == 0 else 0)
            self.set(p, "uThreshold", 1.0)
            v.render(moderngl.TRIANGLES)
            prev, pw, ph = tex, w, h
        # bloom up (additive)
        p, v = self.post["UP"]
        ctx.enable(moderngl.BLEND)
        ctx.blend_func = moderngl.ONE, moderngl.ONE
        for i in range(len(self.levels) - 2, -1, -1):
            tex, fbo, w, h = self.levels[i]
            stex, _, sw, sh = self.levels[i + 1]
            fbo.use()
            ctx.viewport = (0, 0, w, h)
            stex.use(0)
            self.set(p, "uSrc", 0)
            self.set(p, "uTexel", (1.0 / sw, 1.0 / sh))
            self.set(p, "uWeight", 1.0)
            v.render(moderngl.TRIANGLES)
        ctx.disable(moderngl.BLEND)

        # anamorphic streak from the half-res bright pass (level 0 before up? use level 1)
        p, v = self.post["STREAK"]
        srcs = self.levels[1][0]
        steps = [1, 2, 4, 8, 16, 32, 64]
        cur = srcs
        for i, stp in enumerate(steps):
            dst = i % 2
            self.streak_fbo[dst].use()
            ctx.viewport = (0, 0, self.sw, self.sh)
            cur.use(0)
            self.set(p, "uSrc", 0)
            self.set(p, "uTexel", (1.0 / self.sw, 1.0 / self.sh))
            self.set(p, "uStep", float(stp) * (self.sw / 480.0))
            self.set(p, "uFirst", 1 if i == 0 else 0)
            self.set(p, "uThreshold", 0.6)
            v.render(moderngl.TRIANGLES)
            cur = self.streak[dst]
        streak_tex = cur

        # god rays
        if rays_amt > 1e-3:
            p, v = self.post["RAYS"]
            self.rays_fbo.use()
            ctx.viewport = (0, 0, W // 2, H // 2)
            src.use(0); self.aux.use(1)
            self.set(p, "uSrc", 0); self.set(p, "uAux", 1)
            self.set(p, "uLightPos", light_uv)
            self.set(p, "uRayDecay", 0.975)
            self.set(p, "uRayStrength", 1.0)
            self.set(p, "uFrame", float(frame))
            v.render(moderngl.TRIANGLES)

        # composite
        p, v = self.post["COMPOSITE"]
        self.out_fbo.use()
        ctx.viewport = (0, 0, W, H)
        src.use(0)
        self.levels[0][0].use(1)
        streak_tex.use(2)
        self.rays.use(3)
        self.set(p, "uSrc", 0); self.set(p, "uBloom", 1)
        self.set(p, "uStreak", 2); self.set(p, "uRays", 3)
        self.common_uniforms(p, t, frame, bar)
        self.set(p, "uExposure", exposure)
        self.set(p, "uBloomAmt", bloom_amt)
        self.set(p, "uStreakAmt", streak_amt)
        self.set(p, "uRaysAmt", rays_amt)
        self.set(p, "uCA", ca)
        self.set(p, "uGrain", grain)
        self.set(p, "uVignette", vignette)
        self.set(p, "uFade", fade)
        self.set(p, "uFlash", flash)
        self.set(p, "uSat", sat_ if sat_ > 0 else 1.0)
        self.set(p, "uContrast", contrast if contrast > 0 else 1.0)
        self.set(p, "uLift", (0.00012, 0.0002, 0.0004))
        self.set(p, "uGain", (1.0, 1.0, 1.0))
        v.render(moderngl.TRIANGLES)
        data = self.out_fbo.read(components=3, alignment=1)
        return data


def shot_at(t):
    for name, shader, a, b in TL.SHOTS:
        if a <= t < b:
            return name, shader
    return TL.SHOTS[-1][0], TL.SHOTS[-1][1]


def frames_for(shot_name):
    for name, shader, a, b in TL.SHOTS:
        if name == shot_name:
            return int(round(a * TL.FPS)), int(round(b * TL.FPS))
    raise KeyError(shot_name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--still", type=float, nargs="*")
    ap.add_argument("--shot", type=str)
    ap.add_argument("--range", type=int, nargs=2, help="frame range [a, b)")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--fps", type=float, default=None, help="preview fps (subsample)")
    ap.add_argument("--spp", type=int, default=None)
    ap.add_argument("--out", type=str, default=None)
    ap.add_argument("--crf", type=int, default=8)
    args = ap.parse_args()

    W = int(round(TL.WIDTH * args.scale / 2)) * 2
    H = int(round(TL.HEIGHT * args.scale / 2)) * 2
    r = Renderer(W, H)

    if args.still is not None:
        from PIL import Image
        os.makedirs(os.path.join(ROOT, "stills"), exist_ok=True)
        for t in args.still:
            frame = int(round(t * TL.FPS))
            name, shader = shot_at(t)
            t0 = time.time()
            data = r.render(t, frame, shader, args.spp, name)
            img = Image.frombytes("RGB", (W, H), data)
            out = args.out or os.path.join(ROOT, "stills", f"still_{t:06.2f}.png")
            if len(args.still) > 1 and args.out:
                base, ext = os.path.splitext(args.out)
                out = f"{base}_{t:06.2f}{ext}"
            img.save(out)
            print(f"t={t:.2f} [{name}] {time.time() - t0:.2f}s -> {out}", flush=True)
        return

    if args.shot:
        a, b = frames_for(args.shot)
    elif args.range:
        a, b = args.range
    else:
        a, b = 0, TL.TOTAL_FRAMES
    step = 1
    out_fps = TL.FPS
    if args.fps:
        step = max(1, int(round(TL.FPS / args.fps)))
        out_fps = TL.FPS / step
    out = args.out or os.path.join(ROOT, "output", "segments", f"{args.shot or f'{a}_{b}'}.mkv")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{W}x{H}", "-r", f"{out_fps}", "-i", "-",
           "-c:v", "libx264", "-preset", "medium", "-crf", str(args.crf),
           "-pix_fmt", "yuv444p", out]
    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    t_start = time.time()
    n = 0
    for f in range(a, b, step):
        t = f / TL.FPS
        name, shader = shot_at(t)
        data = r.render(t, f, shader, args.spp, name)
        ff.stdin.write(data)
        n += 1
        if n % 10 == 0 or f + step >= b:
            el = time.time() - t_start
            rem = (b - f - step) / step * el / n
            print(f"frame {f} ({n}/{(b - a + step - 1) // step}) t={t:.3f} [{name}] "
                  f"{el / n:.2f}s/f  eta {rem / 60:.1f} min", flush=True)
    ff.stdin.close()
    ff.wait()
    print(f"done {out} in {(time.time() - t_start) / 60:.1f} min", flush=True)


if __name__ == "__main__":
    main()
