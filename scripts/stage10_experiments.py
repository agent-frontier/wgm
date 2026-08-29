#!/usr/bin/env python3
"""Offline, provider-agnostic Stage 10 experiment comparison.

Manifests and evaluator results are data only.  This command never creates a branch, calls a
provider, opens a PR, or merges; it records enough evidence for a human to do those things.
"""
from __future__ import annotations
import argparse, datetime as dt, hashlib, json, re, sys
from pathlib import Path
from typing import Any

SECRET_RE = re.compile(r"(?i)(?:api[_ -]?key|secret|password|token|authorization|bearer)\s*(?:[:=]|is)\s*[^\s,;]+|\b(?:sk-|ghp_|xoxb-)[A-Za-z0-9._-]{8,}")
MAX_BYTES = 1_000_000

def die(msg: str, code: int = 2) -> None:
    print(f"stage10 experiments: ERROR: {msg}", file=sys.stderr); raise SystemExit(code)
def stamp() -> str: return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
def root(raw: str) -> Path:
    p=Path(raw).expanduser().resolve()
    if not p.is_dir(): die(f"root is not a directory: {p}")
    return p
def under_wgm(r: Path, raw: str|None) -> Path:
    p=(r/".wgm/stage10/experiments"/(raw or "report.json")).resolve() if raw is None or not Path(raw).is_absolute() else Path(raw).resolve()
    try: p.relative_to((r/'.wgm').resolve())
    except ValueError: die(f"output must remain under {r/'.wgm'}")
    return p
def load(path: Path) -> dict[str,Any]:
    try:
        if path.stat().st_size>MAX_BYTES: die("manifest exceeds size limit")
        value=json.loads(path.read_text(encoding='utf-8'))
    except (OSError,json.JSONDecodeError) as e: die(f"invalid manifest: {e}")
    def check(x:Any) -> None:
        if isinstance(x,str) and (SECRET_RE.search(x) or '\n' in x or '\r' in x): die("manifest contains unsafe material")
        if isinstance(x,dict):
            for v in x.values(): check(v)
        if isinstance(x,list):
            for v in x: check(v)
    check(value)
    if not isinstance(value,dict): die("manifest must be an object")
    required=('hypothesis','baseline_sha','route','environment','allowed_files','evaluator','target_metric','non_regression','budget','candidates')
    missing=[k for k in required if k not in value]
    if missing: die("manifest missing: "+', '.join(missing))
    if not isinstance(value['candidates'],list) or not value['candidates']: die("candidates must be non-empty")
    if not isinstance(value['allowed_files'],list) or not all(isinstance(x,str) and x for x in value['allowed_files']): die("allowed_files must be a list of strings")
    if not isinstance(value['non_regression'],list) or not value['non_regression']: die("non_regression must be a non-empty list")
    return value
def atomic(p:Path, text:str) -> None:
    p.parent.mkdir(parents=True,exist_ok=True); t=p.with_name('.'+p.name+'.tmp'); t.write_text(text,encoding='utf-8'); t.replace(p); t.unlink(missing_ok=True)
def compare(a:argparse.Namespace)->None:
    r=root(a.root); mp=Path(a.manifest).expanduser().resolve()
    try: mp.relative_to(r)
    except ValueError: die("manifest must remain under project root")
    m=load(mp)
    retire=m.get('retirements',[]); exception=m.get('exception')
    economy_ok=isinstance(retire,list) and len(retire)>=2 and all(isinstance(x,dict) and x.get('evidence') and x.get('retired') for x in retire)
    if exception is not None:
        economy_ok = isinstance(exception,dict) and exception.get('category') in {'security','correctness','reliability','compatibility'} and bool(exception.get('rationale')) and bool(exception.get('evidence'))
    if not economy_ok: economy_reason='requires two evidence-backed retirements' if exception is None else 'exception is not narrow, justified, and evidenced'
    else: economy_reason='two evidence-backed retirements' if exception is None else 'narrow evidenced exception'
    results=[]
    for c in m['candidates']:
        if not isinstance(c,dict) or not isinstance(c.get('id'),str): die('each candidate needs an id')
        gates=c.get('gates',[]); hard_ok=bool(c.get('holdout_pass',True)) and isinstance(gates,list) and all(isinstance(g,dict) and g.get('passed') is True for g in gates)
        metric=c.get('metric'); metric_ok=isinstance(metric,(int,float))
        eligible=hard_ok and metric_ok and economy_ok
        results.append({'id':c['id'],'branch':c.get('branch'),'metric':metric,'hard_gate_pass':hard_ok,'pr_eligible':eligible,'negative_result':not hard_ok,'reason':[] if eligible else ['hard non-regression gate failed' if not hard_ok else 'metric missing' if not metric_ok else economy_reason]})
    best=max((x for x in results if x['hard_gate_pass'] and isinstance(x['metric'],(int,float))),key=lambda x:x['metric'],default=None)
    out={'recorded_at':stamp(),'manifest':str(mp),'manifest_sha256':hashlib.sha256(mp.read_bytes()).hexdigest(),'baseline_sha':m['baseline_sha'],'frozen_baseline':True,'experiment':{k:m[k] for k in ('hypothesis','route','environment','allowed_files','evaluator','target_metric','non_regression','budget')},'candidates':results,'feature_economy':{'eligible':economy_ok,'reason':economy_reason,'retirements':retire,'exception':exception},'winner':best['id'] if best else None,'pr_recommendation':bool(best and best['pr_eligible'] and all(x['hard_gate_pass'] for x in results)),'authority':'human review required; no merge, push, deploy, or publish'}
    outp=under_wgm(r,a.output); atomic(outp,json.dumps(out,indent=2,sort_keys=True)+'\n')
    card=outp.with_suffix('.md'); lines=['# Stage 10 experiment comparison','','- Baseline: `'+str(m['baseline_sha'])+'` (frozen)','- Winner: **'+str(out['winner'] or 'none')+'**','- PR recommendation: **'+('yes' if out['pr_recommendation'] else 'no')+'**','- Feature economy: '+economy_reason,'','## Results']
    lines += [f"- `{x['id']}` — metric `{x['metric']}`, hard gate `{'pass' if x['hard_gate_pass'] else 'FAIL'}`, PR eligible `{'yes' if x['pr_eligible'] else 'no'}`" for x in results]
    lines += ['','Human review is required; this report never merges, pushes, deploys, or publishes.']
    atomic(card,'\n'.join(lines)+'\n'); print(f"stage10 experiments: wrote {outp} and {card}"); raise SystemExit(0 if all(x['hard_gate_pass'] for x in results) and economy_ok else 1)
def main()->None:
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest='cmd',required=True); q=sub.add_parser('compare'); q.add_argument('--root',required=True); q.add_argument('--manifest',required=True); q.add_argument('--output'); q.set_defaults(func=compare); a=p.parse_args(); a.func(a)
if __name__=='__main__': main()
