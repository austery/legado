"""Print synthetic C1 evidence to free Actions logs without uploading artifacts."""
import json
from pathlib import Path

root = Path('ci-results')
# Explicit allowlist: no environment dumps, credentials, arbitrary build directories,
# xcresult binaries or source data. Tests use the existing owned synthetic fixtures.
for name in ['checkout-and-tree.txt', 'commit.txt', 'xcode-version.txt', 'cache.txt',
             'cache-sizes.txt', 'runtimes.json', 'devicetypes.json', 'full.json', 'restart.json', 'rerun.json',
             'simulator.txt', 'disk-final.txt', 'sizes-kib.txt', 'resources-error.log',
             'native-product/scope.json', 'native-product/commit.txt',
             'native-product/simulator.txt', 'native-product/summary.json',
             'native-product/project.log', 'native-product/build.log',
             'native-product/boot.log', 'native-product/tests.log',
             'kotlin-native/summary.json', 'kotlin-native/tests.log', 'kotlin-native/simulator.txt']:
    path = root / name
    print(f'===== C1 EVIDENCE {name} =====', flush=True)
    print(path.read_text(errors='replace') if path.is_file() else 'NOT PRODUCED', flush=True)
path = root / 'resources.jsonl'
samples = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
print('===== C1 RESOURCE SAMPLES =====', flush=True)
for sample in samples:
    print(json.dumps(sample), flush=True)
if samples:
    print(json.dumps({
        'sample_count': len(samples),
        'sampled_max_aggregate_rss_kib': max(s['aggregate_process_rss_kib'] for s in samples),
        'sampled_max_process_rss_kib': max(s['largest_process_rss_kib'] for s in samples),
        'minimum_disk_free_bytes': min(s['disk_free_bytes'] for s in samples),
        'limitation': '10 second samples; aggregate process RSS is not physical memory peak',
    }), flush=True)
result = root / 'native-product/NativeReader.xcresult'
if result.exists():
    print('xcresult_bytes=' + str(sum(p.stat().st_size for p in result.rglob('*') if p.is_file())))
print('Cloud artifact upload disabled. Original xcresult is ephemeral; text summaries and logs retained.')
