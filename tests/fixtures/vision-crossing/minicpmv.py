#!/usr/bin/env python3
"""Cross-check this build's MiniCPM-V resampler against llama.cpp's clip.

Unlike the other scripts here, the reference is not transformers but
llama.cpp's own clip, run through its llama-mtmd-debug tool: it encodes a
synthetic image and prints the projector's rows. This build encodes the
same pixels and the two are set side by side.

The clean input is a solid white square -- raw 1.0 normalizes to 1.0
whichever way the reference feeds it -- so both encoders see the same
pixels exactly; a rainbow is also offered, built so each raw byte is
255*(v+1)/2, making this build's normalized value equal the value
llama.cpp feeds straight in (to a byte's rounding). Both agree to a cosine
of 0.999 and better, within the half precision llama.cpp runs the encoder
in; a mistake in the sinusoidal place, the position bucket or the
resampler math would part them by far more.

Run from a checkout, with llama.cpp built and a MiniCPM-V-2.6 pair to hand:

    MMPROJ=/path/mmproj.gguf TEXT=/path/text.gguf \\
    LLAMACPP=/path/llama.cpp SEE="tests/bin/tests" \\
    python3 tests/fixtures/vision-crossing/minicpmv.py

It skips, not fails, when a binary or a model is not found.
"""
import math, os, struct, subprocess, sys, tempfile

MMPROJ = os.environ.get("MMPROJ", os.path.expanduser(
    "~/models/minicpmv-2.6-mmproj-f16.gguf"))
TEXT = os.environ.get("TEXT", os.path.expanduser(
    "~/models/minicpmv-2.6-text-Q2_K.gguf"))
LLAMACPP = os.environ.get("LLAMACPP", os.path.expanduser("~/llama.cpp"))
SEE = os.environ.get("SEE", "tests/bin/tests")
THREADS = os.environ.get("THREADS", "8")

DEBUG = os.path.join(LLAMACPP, "build", "bin", "llama-mtmd-debug")


def skip(why):
    print("minicpmv cross-check: skipped --", why)
    sys.exit(0)


def make_ppm(path, size, pattern):
    def toP(v):
        return max(0, min(255, int(round(255 * (v + 1) / 2.0))))
    buf = bytearray()
    if pattern == "white":
        buf = bytes([255]) * (size * size * 3)
    else:  # rainbow, matching llama-mtmd-debug's own
        cx = cy = size / 2.0
        maxd = math.sqrt(cx * cx + cy * cy)
        for y in range(size):
            for x in range(size):
                dx, dy = x - cx, y - cy
                hue = math.atan2(dy, dx) / (2 * math.pi)
                if hue < 0:
                    hue += 1.0
                sat = min(math.sqrt(dx * dx + dy * dy) / maxd, 1.0)
                h6 = hue * 6.0
                i6 = int(h6)
                f = h6 - i6
                p, q, t = 1 - sat, 1 - sat * f, 1 - sat * (1 - f)
                r, g, b = [(1, t, p), (q, 1, p), (p, 1, t),
                           (p, q, 1), (t, p, 1), (1, p, q)][i6 % 6]
                buf += bytes([toP(r), toP(g), toP(b)])
    with open(path, "wb") as fh:
        fh.write(b"P6 %d %d 255 " % (size, size) + bytes(buf))


def mine(size, pattern):
    """This build's rows for the pattern, as a flat list of floats."""
    with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as img, \
         tempfile.NamedTemporaryFile(suffix=".rows", delete=False) as out:
        make_ppm(img.name, size, pattern)
        subprocess.run([SEE, "see", "--mmproj", MMPROJ, "--image", img.name,
                        "--threads", THREADS, "--dump", out.name],
                       check=True, capture_output=True)
        vals = [float(x) for x in open(out.name)]
        os.unlink(img.name)
        os.unlink(out.name)
        return vals


def reference(size, pattern):
    """llama.cpp's rows: the printed proj output. Both the columns (to
    first three and last three) and the rows (first few, then a '...', then
    the last few) are truncated by the print, so the rows after the '...'
    are the LAST rows of the tensor, not the next ones. Returns
    {actual_row_index: (first3, last3)} and the total row count."""
    out = subprocess.run([DEBUG, "-m", TEXT, "--mmproj", MMPROJ, "-n",
                          str(size), "--image", pattern, "-p", "encode",
                          "--threads", THREADS],
                         capture_output=True, text=True).stdout.splitlines()
    start = max(i for i, l in enumerate(out) if "resampler.proj.weight" in l)
    # total rows from the node's shape, "= {3584, 64, 1, 1}"
    node = out[start]
    n_rows = int(node.split("{", 1)[1].split(",")[1])
    head, tail, seen_gap = [], [], False
    for line in out[start + 1:]:
        s = line.strip()
        if s.rstrip(", ") == "...":
            seen_gap = True
            continue
        if s.startswith("[") and "]" in s and "," in s and "resampler" not in s:
            nums = [x for x in s.strip("[], ").split(",")
                    if x.strip() not in ("...", "")]
            try:
                v = [float(x) for x in nums]
            except ValueError:
                continue
            if len(v) == 6:
                (tail if seen_gap else head).append((v[:3], v[3:]))
        elif s.startswith("sum ="):
            break
    rows = {i: r for i, r in enumerate(head)}
    for k, r in enumerate(reversed(tail)):
        rows[n_rows - 1 - k] = r
    return rows


def check(size, pattern, tol_cos=0.999):
    them = reference(size, pattern)
    if not them:
        skip("llama.cpp printed no rows (build without the debug callback?)")
    us = mine(size, pattern)
    W = len(us) // (len(us) // 3584 if len(us) % 3584 == 0 else 1)
    W = 3584 if len(us) % 3584 == 0 else W
    pairs = []
    for r, (f3, l3) in them.items():
        row = us[r * 3584:(r + 1) * 3584]
        if len(row) < 3584:
            continue
        for a, b in zip(f3, row[:3]):
            pairs.append((b, a))
        for a, b in zip(l3, row[-3:]):
            pairs.append((b, a))
    dot = sum(a * b for a, b in pairs)
    na = math.sqrt(sum(a * a for a, _ in pairs))
    nb = math.sqrt(sum(b * b for _, b in pairs))
    cos = dot / (na * nb) if na and nb else 0.0
    mad = sum(abs(a - b) for a, b in pairs) / len(pairs)
    ok = cos >= tol_cos
    print("  %-8s %d: n=%d cosine=%.5f mean|d|=%.4f  %s"
          % (pattern, size, len(pairs), cos, mad, "OK" if ok else "MISMATCH"))
    return ok


def main():
    for path, what in ((SEE, "the tests binary"), (DEBUG, "llama-mtmd-debug"),
                       (MMPROJ, "the projector"), (TEXT, "the text model")):
        if not (os.path.exists(path) or (what == "the tests binary"
                                         and subprocess.run(
                    ["sh", "-c", "command -v " + path],
                    capture_output=True).returncode == 0)):
            skip(what + " not found at " + path)
    print("minicpmv cross-check against llama.cpp's clip:")
    ok = True
    for size in (448, 224):
        ok &= check(size, "white")
    ok &= check(448, "rainbow")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
