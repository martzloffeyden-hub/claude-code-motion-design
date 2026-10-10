#!/usr/bin/env python3
"""Concatenate the rendered segments, mux the soundtrack and encode the
delivery file: H.264 High@4.2, 1920x1080, 60 fps CFR, yuv420p BT.709,
AAC-LC 320 kb/s 48 kHz stereo, faststart MP4.

Two-pass VBR keeps the file below GitHub's 100 MB limit while giving the
grain and the dark gradients enough bits.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import timeline as TL  # noqa: E402

SEG = os.path.join(ROOT, "output", "segments")
OUT = os.path.join(ROOT, "output", "SINGULARITY.mp4")
WAV = os.path.join(ROOT, "audio", "singularity_48k.wav")
VBITRATE = os.environ.get("VBITRATE", "17M")


def probe_frames(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                        "-show_entries", "stream=nb_read_frames", "-of", "json", path],
                       capture_output=True, text=True, check=True)
    return int(json.loads(r.stdout)["streams"][0]["nb_read_frames"])


def main():
    parts = []
    total = 0
    for name, _, a, b in TL.SHOTS:
        p = os.path.join(SEG, f"{name}.mkv")
        if not os.path.exists(p):
            sys.exit(f"missing segment {p}")
        n = probe_frames(p)
        want = int(round(b * TL.FPS)) - int(round(a * TL.FPS))
        if n != want:
            sys.exit(f"segment {name}: {n} frames, expected {want}")
        parts.append(p)
        total += n
        print(f"  {name:9s} {n:5d} frames  ok")
    assert total == TL.TOTAL_FRAMES, total
    lst = os.path.join(SEG, "concat.txt")
    with open(lst, "w") as f:
        for p in parts:
            f.write(f"file '{p}'\n")

    vf = ("scale=in_color_matrix=bt601:out_color_matrix=bt709:in_range=tv:out_range=tv:"
          "flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p")
    common = ["-f", "concat", "-safe", "0", "-i", lst]
    venc = ["-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level:v", "4.2",
            "-b:v", VBITRATE, "-maxrate", "32M", "-bufsize", "48M", "-tune", "film",
            "-x264-params", "aq-mode=3:aq-strength=0.9:deblock=-1,-1:keyint=120:min-keyint=60",
            "-r", str(TL.FPS), "-fps_mode", "cfr", "-vf", vf,
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]
    passlog = os.path.join(SEG, "x264pass")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *common, *venc, "-pass", "1",
                    "-passlogfile", passlog, "-an", "-f", "mp4", os.devnull], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *common, "-i", WAV,
                    "-map", "0:v:0", "-map", "1:a:0", *venc, "-pass", "2", "-passlogfile", passlog,
                    "-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-ac", "2",
                    "-t", f"{TL.DURATION:.3f}", "-movflags", "+faststart",
                    "-metadata", "title=SINGULARITY", OUT], check=True)
    print("wrote", OUT, f"{os.path.getsize(OUT) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
