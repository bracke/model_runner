#!/usr/bin/env python3
"""Write a `tests image --expect` file from a reference run's dump.

The run is stable-diffusion.cpp's, through the mr-reference harness
(docs/plan-image-generation.md, step 0), with `--dump final_result`: its
t000000.f32 is the text encoder's rows for the whole template, system turn
and all, and t000001.f32 onwards the velocity of each step, 64 planes of the
latent's rows by its columns, as this program lays a latent out.

    record.py RUN_DIR OUT.expect --prompt TEXT --size WxH --seed N --steps N
              --file NAME [--dropped N]

Recorded: three of the rows kept (the first, the middle, the last), every
second value of each; and the first two steps' velocities, every 32nd value.
"""
import argparse
import array
import sys


def floats(path):
    values = array.array("f")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("out")
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--size", required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--steps", type=int, required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--dropped", type=int, default=14)
    parser.add_argument("--width", type=int, default=4096)
    args = parser.parse_args()

    width, height = (int(side) for side in args.size.split("x"))
    rows = floats(args.run + "/t000000.f32")
    count = len(rows) // args.width - args.dropped
    with open(args.out, "w") as out:
        out.write("# mr-reference, stable-diffusion.cpp b13a48219d, on the processor;"
                  " written by record.py\n")
        out.write("file %s\n" % args.file)
        out.write("prompt %s\n" % args.prompt)
        out.write("size %d %d\n" % (width, height))
        out.write("seed %d\n" % args.seed)
        out.write("steps %d\n" % args.steps)
        out.write("rows %d\n" % count)
        out.write("row-tolerance 0.08\n")
        out.write("velocity-cosine 0.9999\n")
        for kept in sorted({0, count // 2, count - 1}):
            start = (args.dropped + kept) * args.width
            picked = rows[start:start + args.width:2]
            out.write("row %d stride 2 %s\n" % (kept, " ".join("%.7g" % v for v in picked)))
        for step in (1, 2):
            speed = floats(args.run + "/t%06d.f32" % step)
            out.write("velocity %d stride 32 %s\n"
                      % (step, " ".join("%.7g" % v for v in speed[::32])))


main()
