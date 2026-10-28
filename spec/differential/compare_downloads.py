"""Compare complete offline native and inspected-reference file workflows."""
import argparse,json,subprocess
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--reference',required=True);parser.add_argument('--python',required=True);parser.add_argument('--output',default='/tmp/anna-download-parity.json');args=parser.parse_args()
root=Path(__file__).resolve().parents[2];directory=root/'spec/differential';fixture=directory/'download_cases.json'
commands=[[args.python,'-I',str(directory/'python_download_runner.py'),args.reference,str(fixture)],['crystal','run',str(directory/'crystal_download_runner.cr'),'--',str(fixture)]]
values=[json.loads(subprocess.check_output(command,cwd=root,text=True)) for command in commands]
rows=[]
for left,right in zip(*values,strict=True):
 assert left['name']==right['name']
 equal=left==right
 intentional=left['name']=='crc_corruption' and left['outcome']==right['outcome']=='archive_invalid' and left['file_exists'] and not right['file_exists']
 rows.append(dict(name=left['name'],status='match' if equal else 'intentional' if intentional else 'mismatch',python=left,crystal=right))
report=dict(reference_commit='001ab3250e9cd829e7225b6385e3fb8aac999090',network='none; identical synthetic EPUB and mock responses; no challenge retry wrapper',rows=rows)
Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
for row in rows:print(row['status'].upper(),row['name'])
print(json.dumps({status:sum(row['status']==status for row in rows) for status in ['match','intentional','mismatch']}))
raise SystemExit(any(row['status']=='mismatch' for row in rows))
