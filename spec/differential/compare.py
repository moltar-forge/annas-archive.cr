"""Run both pinned implementations offline and retain every comparison result."""
import argparse
import json
import subprocess
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--reference',required=True)
parser.add_argument('--python',required=True)
parser.add_argument('--output',default='/tmp/annas-archive-parity.json')
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
cases=root/'spec/differential/cases.json'
commands=[
 [args.python,'-I',str(root/'spec/differential/reference_runner.py'),args.reference,str(cases)],
 ['crystal','run',str(root/'spec/differential/crystal_runner.cr'),'--',str(cases)],
]
outputs=[json.loads(subprocess.check_output(command,text=True,cwd=root)) for command in commands]

def normalize(value):
    # Canonicalize bibliographic whitespace (including NBSP) only; URLs and
    # request parameters retain their exact bytes and ordering.
    if isinstance(value,list): return [normalize(x) for x in value]
    if isinstance(value,dict):
        return {k:(' '.join(v.split()) if isinstance(v,str) and k in {'title','summary','author','publisher','description','label'} else normalize(v)) for k,v in value.items()}
    return value

intentional={
 'result-bound':'The shard bounds searches to 50 records per explicit page; Python parsing is unbounded.',
 'http-source':'The shard excludes non-HTTPS source links; Python exposes HTTP metadata links.',
 'local-cooldown':'The shard enforces a minimum request interval; Python does not.',
 'server-cooldown':'The shard retains Retry-After across calls; Python reports it but does not throttle later calls.',
 'landing-login':'The shard distinguishes an authentication form from an unsupported landing page.',
 'landing-unknown':'The shard uses a specific closed resolution error instead of operation_failed.',
 'landing-invalid-countdown':'The shard uses a specific closed layout error instead of operation_failed.',
 'input-limit':'The shard bounds query input before invoking the transport.',
}
rows=[]
for left,right in zip(*outputs,strict=True):
    assert left['name']==right['name']
    name=left['name']; equal=normalize(left)==normalize(right)
    status='match' if equal else 'intentional' if name in intentional else 'mismatch'
    rows.append(dict(name=name,status=status,reason=intentional.get(name) if status=='intentional' else None,python=left,crystal=right))
report=dict(reference_commit='001ab3250e9cd829e7225b6385e3fb8aac999090',shard_baseline='ae5274a406365dc5dbd30179c6a7414a57f69bf2',network='disabled; fixtures only; Python challenge-retry and downloader methods disabled; native default retries enabled' ,rows=rows)
Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
for row in rows: print(row['status'].upper(),row['name'])
counts={status:sum(row['status']==status for row in rows) for status in ['match','intentional','mismatch']}
print(json.dumps(counts))
raise SystemExit(bool(counts['mismatch']))
