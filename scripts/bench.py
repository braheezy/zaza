#!/usr/bin/env python3
"""Benchmark any GBA ROM against mGBA (requires CMake and a sibling mgba checkout) or a Zaza baseline."""
import argparse
import csv
import hashlib
import os
from pathlib import Path
from statistics import median
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".zig-cache" / "bench"


def build(baseline):
    subprocess.run(["zig", "build", "cli", "-Doptimize=ReleaseFast", "-p", CACHE / "zaza"],
                   cwd=ROOT, check=True)
    zaza = CACHE / "zaza/bin/zaza-cli"
    if baseline:
        return {"Zaza": zaza, "baseline": baseline.resolve(strict=True)}
    mgba = CACHE / "mgba"
    subprocess.run(["cmake", "-S", ROOT.parent / "mgba", "-B", mgba,
                    "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_PERF=ON", "-DBUILD_QT=OFF",
                    "-DBUILD_SDL=OFF", "-DDISABLE_DEPS=ON", "-DM_CORE_GB=OFF"],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["cmake", "--build", mgba, "--target", "mgba-perf", "--parallel", "4"],
                   check=True, stdout=subprocess.DEVNULL)
    return {"Zaza": zaza, "mGBA": mgba / "mgba-perf"}


def measure(argv, cwd, commands=b""):
    # wait4 reports CPU and peak RSS for this child alone, including startup and exit.
    with tempfile.TemporaryFile() as inp, tempfile.TemporaryFile() as out:
        inp.write(commands)
        inp.seek(0)
        start = time.perf_counter()
        with subprocess.Popen(argv, stdin=inp, stdout=out, cwd=cwd) as child:
            _, status, usage = os.wait4(child.pid, 0)
            elapsed = time.perf_counter() - start
            child.returncode = os.waitstatus_to_exitcode(status)
            if child.returncode:
                raise subprocess.CalledProcessError(child.returncode, argv)
        out.seek(0)
        output = out.read().decode().splitlines()
    rss_mib = usage.ru_maxrss / (1024**2 if sys.platform == "darwin" else 1024)
    return output, (elapsed, usage.ru_utime + usage.ru_stime, rss_mib)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rom", type=Path)
    parser.add_argument("frames", nargs="?", type=int, default=3000)
    parser.add_argument("--baseline", type=Path, help="compare against an existing zaza-cli build")
    args = parser.parse_args()
    if not 1 <= args.frames <= 2**31 - 1:
        parser.error("frames must be between 1 and 2147483647")
    rom = args.rom.resolve(strict=True)
    binaries = build(args.baseline)
    print(f"{rom.name}  SHA-256 {hashlib.sha256(rom.read_bytes()).hexdigest()}")
    print(f"{args.frames} display frames, software video, 3 paired runs, whole-process timing")
    results = {name: [] for name in binaries}
    with tempfile.TemporaryDirectory() as cwd:
        for pair in range(3):
            for name in (list(results) if pair % 2 == 0 else list(reversed(results))):
                if name != "mGBA":
                    output, metrics = measure([binaries[name], "session", rom], cwd,
                                              f"step {args.frames} none\nquit\n".encode())
                    if output != [f"ok {args.frames}"]:
                        raise ValueError(f"Unexpected session reply: {output}")
                else:
                    output, metrics = measure([binaries[name], "-P", "-F", str(args.frames), rom], cwd)
                    row, = csv.DictReader(output)
                    if int(row["frames"]) != args.frames or row["renderer"] != "software":
                        raise ValueError(f"Unexpected mGBA result: {row}")
                results[name].append(metrics)
                print(f"  {name:4} {metrics[0]:.3f} s", flush=True)
    print("Median   wall (s)    frames/s    CPU ms/frame    peak RSS (MiB)")
    for name, runs in results.items():
        wall, cpu, rss = map(median, zip(*runs))
        print(f"{name:6} {wall:10.3f} {args.frames / wall:11.1f} "
              f"{1000 * cpu / args.frames:15.3f} {rss:17.2f}")


if __name__ == "__main__":
    main()
