#!/usr/bin/env python3
"""Serial matched coverage-cache measurements; report artifacts stay external."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--after', required=True)
    parser.add_argument('--baseline-repo', required=True)
    parser.add_argument('--after-repo', required=True)
    parser.add_argument('--guard', required=True)
    parser.add_argument('--host-proof')
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    if os.environ.get('TRAE_ZIG_GUARD_ACTIVE') != '1':
        raise RuntimeError('Run the entire measurement process under the shared tree guard')
    baseline = Path(args.baseline_repo)
    after = Path(args.after_repo)
    if subprocess.check_output(['git', 'diff', '--name-only'], cwd=baseline, text=True).strip():
        raise RuntimeError('Baseline tracked product files changed')
    if sha(baseline / 'src/cmap_bench.zig') != sha(after / 'src/cmap_bench.zig'):
        raise RuntimeError('Benchmark drivers differ')
    affinity = []
    cpu = None
    if shutil.which('taskset'):
        allowed = sorted(os.sched_getaffinity(0))
        cpu = 30 if 30 in allowed else allowed[0]
        affinity = ['taskset', '-c', str(cpu)]
    report = {
        'order': ['A', 'B', 'B', 'A'], 'optimize': 'ReleaseFast',
        'timed_driver': 'existing Cache.coversCodepoint', 'query_cache_used': False,
        'timed_counters': False, 'whole_measurement_guarded': True, 'platform': platform.platform(), 'machine': platform.machine(),
        'cpu_affinity': cpu if cpu is not None else 'unavailable: taskset absent',
        'benchmark_driver_sha256': sha(after / 'src/cmap_bench.zig'),
        'baseline_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=baseline, text=True).strip(),
        'binary_sha256': {'A': sha(args.baseline), 'B': sha(args.after)},
        'host_proof_sha256': sha(args.host_proof) if args.host_proof else None,
        'trials': [],
    }
    target = Path(args.report)
    for ordinal, label in enumerate(report['order']):
        binary = args.baseline if label == 'A' else args.after
        workloads = [([], 'synthetic')]
        if args.host_proof:
            workloads.append((['--host-proof=' + args.host_proof], 'host-proof'))
        for extra, workload in workloads:
            command = [*affinity, binary, '--repetitions=8', *extra]
            result = subprocess.run(command, text=True, capture_output=True)
            records = []
            for line in (result.stdout + result.stderr).splitlines():
                if line.startswith('{'):
                    records.append(json.loads(line))
            expected_count = 2 if workload == 'synthetic' else len(json.loads(Path(args.host_proof).read_text())['fonts'])
            if result.returncode or len(records) != expected_count:
                raise RuntimeError('Benchmark failed: ' + ' '.join(command) + '\n' + result.stdout + result.stderr)
            for record in records:
                if record['driver'] != 'Cache.coversCodepoint' or record['warm_opens'] or record['warm_reads'] or record['warm_allocations']:
                    raise RuntimeError('Warm driver contract changed')
                report['trials'].append({'ordinal': ordinal, 'label': label, 'workload': workload, **record})
                print(json.dumps(report['trials'][-1]), flush=True)
            target.write_text(json.dumps(report, indent=2) + '\n')
    keys = sorted({(r['identity'], r['format'], r['face_index']) for r in report['trials']})
    summaries = []
    for key in keys:
        records = [r for r in report['trials'] if (r['identity'], r['format'], r['face_index']) == key]
        stable = ('font_sha256', 'source_groups', 'query_count', 'unique_scalars', 'checksum', 'named_instance', 'cold_opens', 'cold_reads', 'cold_bytes', 'resident_bytes', 'cold_allocations')
        for field in stable:
            if len({r[field] for r in records}) != 1:
                raise RuntimeError('Unmatched field: ' + field + ' for ' + str(key))
        a = [r['warm_ns_per_query'] for r in records if r['label'] == 'A']
        b = [r['warm_ns_per_query'] for r in records if r['label'] == 'B']
        summaries.append({
            'identity': key[0], 'format': key[1], 'face_index': key[2],
            'source_groups': records[0]['source_groups'], 'font_sha256': records[0]['font_sha256'],
            'named_instance': records[0]['named_instance'], 'unique_scalars': records[0]['unique_scalars'],
            'baseline_ns_per_query': statistics.mean(a), 'after_ns_per_query': statistics.mean(b),
            'baseline_samples': a, 'after_samples': b, 'ratio_baseline_over_after': statistics.mean(a) / statistics.mean(b),
            'baseline_cold_ns': [r['cold_ns'] for r in records if r['label'] == 'A'],
            'after_cold_ns': [r['cold_ns'] for r in records if r['label'] == 'B'],
            'preparation_ns': [r['preparation_ns'] for r in records if r['label'] == 'B'],
            'baseline_cache_allocated_bytes': records[0]['cache_allocated_bytes'],
            'after_cache_allocated_bytes': next(r['cache_allocated_bytes'] for r in records if r['label'] == 'B'),
        })
    report['summaries'] = summaries
    target.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'summaries': summaries}), flush=True)


if __name__ == '__main__':
    main()
