"""Compare actual pinned retry methods against native transport fixtures."""
import argparse, json, subprocess
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--reference', required=True)
parser.add_argument('--python', required=True)
parser.add_argument('--output', default='/tmp/anna-challenge-parity.json')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
directory = root / 'spec/differential'
commands = [[args.python, '-I', str(directory / 'python_challenge_runner.py'), args.reference], ['crystal', 'run', str(directory / 'crystal_challenge_runner.cr')]]
values = [json.loads(subprocess.check_output(command, cwd=root, text=True)) for command in commands]
rows = []
for left, right in zip(*values, strict=True):
    assert left['name'] == right['name']
    rows.append(dict(name=left['name'], status='match' if left == right else 'mismatch', python=left, crystal=right))
report = dict(reference_commit='001ab3250e9cd829e7225b6385e3fb8aac999090', network='none; MockTransport and native exchange seam; original Python retry methods enabled', rows=rows)
Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
for row in rows: print(row['status'].upper(), row['name'])
print(json.dumps({status: sum(row['status'] == status for row in rows) for status in ['match', 'mismatch']}))
raise SystemExit(any(row['status'] == 'mismatch' for row in rows))
