#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compare owned Cyberpunk benchmark exports without running or modifying a game.

The caller identifies the two runs. Engine frame times do not measure actual
drawable presentation intervals, input latency, thermal state or compositor work.
Only graphics settings, numerical summaries and source hashes enter the report.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


def read_run(folder):
    summary = folder / 'summary.json'
    frames = folder / 'frames.csv'
    data = json.loads(summary.read_text())['Data']
    with frames.open(newline='') as handle:
        rows = list(csv.DictReader(handle, skipinitialspace=True))
    times = [float(row['Frame time (ms)']) for row in rows]
    if not times or any(not math.isfinite(v) or v <= 0 for v in times):
        raise ValueError('Finite, positive engine frame times required')
    ordered = sorted(times)
    def percentile(p):
        return ordered[math.floor((len(ordered) - 1) * p)]
    graphics = {key: value for key, value in data.items()
                if re.search(r'render|windowMode|verticalSync|fpsClamp|upscal|frameGeneration|Enabled|Quality|Preset|Sharpness|DRS|rayTrac', key, re.I)}
    return {
        'averageFPS': float(data['averageFps']),
        'frameCount': len(times),
        'durationSeconds': float(data['time']),
        'engineFrameMilliseconds': {
            'mean': statistics.mean(times), 'p50': percentile(.5),
            'p95': percentile(.95), 'p99': percentile(.99),
            'maximum': max(times), 'over50ms': sum(t > 50 for t in times),
            'over100ms': sum(t > 100 for t in times),
        },
        'graphicsSettings': graphics,
        'sourceHashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (summary, frames)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    baseline, candidate = read_run(args.baseline), read_run(args.candidate)
    a, b = baseline['graphicsSettings'], candidate['graphicsSettings']
    report = {
        'schema': 1,
        'scope': 'Engine benchmark exports; run identity supplied by caller, no on-glass/input-latency or thermal measurement',
        'percentileMethod': 'Sorted samples at floor((n-1)*p)',
        'baseline': baseline, 'candidate': candidate,
        'graphicsSettingsEqual': a == b,
        'differentGraphicsKeys': sorted(k for k in a.keys() | b.keys() if a.get(k) != b.get(k)),
        'candidateFPSChangePercent': (candidate['averageFPS'] / baseline['averageFPS'] - 1) * 100,
        'engineMeanFrameIncreaseMilliseconds': candidate['engineFrameMilliseconds']['mean'] - baseline['engineFrameMilliseconds']['mean'],
    }
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({k: report[k] for k in ('graphicsSettingsEqual', 'differentGraphicsKeys', 'candidateFPSChangePercent', 'engineMeanFrameIncreaseMilliseconds')}))


if __name__ == '__main__':
    main()
