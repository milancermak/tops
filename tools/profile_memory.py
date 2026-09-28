#!/usr/bin/env python3
"""Record Tops' macOS physical-footprint totals, not credentials or heap contents."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import time


def measure(row):
    pid, rss, cpu, executable = row
    result = subprocess.run(["vmmap", "-summary", pid], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise SystemExit("Cannot measure Tops process " + pid)
    match = re.search(r"^Physical footprint:\s+([\d.]+)([KMG])", result.stdout, re.M)
    if not match:
        raise SystemExit("Missing physical footprint for Tops process " + pid)
    size = float(match[1]) * {"K": 1 / 1024, "M": 1, "G": 1024}[match[2]]
    return {"process": Path(executable).name, "pid": int(pid), "footprint_mib": size,
            "rss_mib": round(int(rss) / 1024, 2), "cpu_percent": float(cpu)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    listing = subprocess.run(["ps", "-axo", "pid=,rss=,%cpu=,comm="], capture_output=True, text=True, check=True)
    root = str(Path(__file__).resolve().parents[1] / "dist/Tops.app/Contents")
    paths = {root + "/MacOS/Tops", root + "/Resources/tops-engine"}
    rows = [parts for line in listing.stdout.splitlines()
            if len(parts := line.split(None, 3)) == 4 and parts[3] in paths]
    if not rows:
        raise SystemExit("Tops is not running")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        measurements = list(pool.map(measure, rows))
    result = {"label": args.label, "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "processes": measurements,
              "combined_footprint_mib": round(sum(p["footprint_mib"] for p in measurements), 2)}
    encoded = json.dumps(result)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("a") as stream:
            stream.write(encoded + "\n")
    print(encoded)


if __name__ == "__main__":
    main()
