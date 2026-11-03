#!/usr/bin/env python3
"""wgm telemetry — efficiency report from the event ledger (schema v1) and pi session logs.

Stdlib only. See references/telemetry.md ("Efficiency report"). No figure here is a causal
speedup claim or billing data.

  telemetry.py report --ledger PATH [--run ID] [--sessions DIR]... [--orchestrator-session FILE]
                      [--baseline REPORT.json] [--provenance measured|reconstructed]
                      [--json OUT] [--md OUT]
  telemetry.py record --ledger PATH KIND [key=value ...]
"""
import argparse
import datetime as dt
import json
import math
import os
import re
import sys

SCHEMA = "wgm-telemetry-report/1"
KINDS = {"expect", "run", "phase", "span", "candidate", "unit", "milestone", "estimate"}
_TS = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(?:[.,](\d+))?\s*(Z|z|[+-]\d\d(?::?\d\d)?)?$")


def parse_ts(v):
    """ISO-8601 (optional fraction, Z/offset) or epoch number -> UTC epoch seconds; None if bad."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        x = float(v)
        return x / 1000.0 if abs(x) > 1e11 else x
    if not isinstance(v, str):
        return None
    m = _TS.match(v.strip())
    if not m:
        return None
    y, mo, d, h, mi, s, frac, tz = m.groups()
    try:
        base = dt.datetime(int(y), int(mo), int(d), int(h), int(mi), int(s), tzinfo=dt.timezone.utc)
    except ValueError:
        return None
    t = base.timestamp() + (float("0." + frac) if frac else 0.0)
    if tz and tz not in ("Z", "z"):
        sign = 1 if tz[0] == "+" else -1
        digits = tz[1:].replace(":", "")
        off = int(digits[:2]) * 3600 + (int(digits[2:4]) * 60 if len(digits) > 2 else 0)
        t -= sign * off
    return t


def iso(t):
    if t is None:
        return None
    s = dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat()
    return s.replace("+00:00", "Z")


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def rnd(x):
    if x is None:
        return None
    x = round(float(x), 6)
    return int(x) if x == int(x) and abs(x) < 1e15 else x


def div(a, b):
    if a is None or b is None or b == 0:
        return None
    return a / b


class DQ:
    def __init__(self):
        self.c = dict.fromkeys(["malformed_lines", "unknown_kinds", "unmatched_spans", "unmatched_phases",
                                "negative_intervals", "excluded_turns", "missing_fields",
                                "duplicate_session_files", "missing_inputs", "unowned_events",
                                "invalid_events", "clipped_turns"], 0)


def fnum(v):
    """Finite int/float, booleans excluded."""
    return num(v) and math.isfinite(v)


def sstr(v):
    return isinstance(v, str) and v != ""


def valid_event(e):
    """Per-kind required fields (references/telemetry.md, "Required fields per kind")."""
    k, edge = e["kind"], e.get("edge")
    if k == "run":
        return edge in ("start", "end")
    if k == "phase":
        return sstr(e.get("name")) and edge in ("start", "end")
    if k == "span":
        if not sstr(e.get("span")) or edge not in ("start", "end"):
            return False
        if edge == "start":
            return sstr(e.get("cat"))
        return isinstance(e.get("rc"), int) and not isinstance(e.get("rc"), bool)
    if k == "candidate":
        return sstr(e.get("sha")) and e.get("decision") in ("accept", "reject")
    if k == "unit":
        return sstr(e.get("id")) and sstr(e.get("class")) and sstr(e.get("status"))
    if k == "milestone":
        return e.get("name") in ("ready-to-test", "merged", "verified") \
            and all(x not in e or sstr(e[x]) for x in ("sha", "publication"))
    if k == "expect":
        return isinstance(e.get("publication"), str) and e["publication"] != ""
    if k == "estimate":
        return sstr(e.get("unit_class")) and fnum(e.get("units")) and e["units"] > 0 \
            and fnum(e.get("human_hours")) and e["human_hours"] > 0 and sstr(e.get("by"))
    return False


def read_ledger(path, dq):
    events = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except ValueError:
                dq.c["malformed_lines"] += 1
                continue
            if not isinstance(e, dict) or e.get("v") != 1 or not isinstance(e.get("kind"), str) \
                    or e.get("v") is True:
                dq.c["malformed_lines"] += 1
                continue
            t = parse_ts(e.get("ts")) if isinstance(e.get("ts"), str) else None
            if t is None:
                dq.c["malformed_lines"] += 1
                continue
            e["_t"] = t
            e["_i"] = len(events)  # ledger append position (A12)
            events.append(e)
    return events


def match_edges(events, key, dq, counter):
    """Pair start/end edges by id. Returns (pairs, unmatched_starts); pair = (start_ev, end_ev)."""
    open_, pairs, lost = {}, [], []
    for e in events:
        i = e.get(key)
        edge = e.get("edge")
        if edge == "start":
            if i in open_:
                dq.c[counter] += 1
                lost.append(open_[i])
            open_[i] = e
        elif edge == "end":
            s = open_.pop(i, None)
            if s is None:
                dq.c[counter] += 1
            elif e["_t"] < s["_t"]:
                dq.c["negative_intervals"] += 1
            else:
                pairs.append((s, e))
    dq.c[counter] += len(open_)
    lost.extend(open_.values())
    return pairs, lost


def inventory(dirs, orch, dq):
    """Resolve session inputs to real paths, once each. The orchestrator file is never an agent input.
    Returns the sorted list of agent session files; counts duplicates and missing inputs in dq."""
    orch_real = os.path.realpath(orch) if orch else None
    seen, out = set(), []

    def add(path):
        rp = os.path.realpath(path)
        if rp == orch_real:
            return
        if rp in seen:
            dq.c["duplicate_session_files"] += 1
            return
        seen.add(rp)
        out.append(rp)

    def walk_err(_e):
        dq.c["missing_inputs"] += 1

    for d in dirs:
        if os.path.isfile(d):
            add(d)
        elif not os.path.isdir(d):
            dq.c["missing_inputs"] += 1
        else:
            for root, _, files in os.walk(d, onerror=walk_err):
                for n in files:
                    if n.endswith(".jsonl"):
                        add(os.path.join(root, n))
    return sorted(out)


def parse_session(path, win, dq):
    """Return list of in-window turns: dict(start,end,model_s,tool_s,tokens,cost) (end None=untimed)."""
    msgs = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except ValueError:
                dq.c["malformed_lines"] += 1
                continue
            if not isinstance(e, dict):
                dq.c["malformed_lines"] += 1
                continue
            m = e.get("message") if isinstance(e.get("message"), dict) else e
            role = m.get("role")
            if role not in ("user", "assistant", "toolResult"):
                continue
            t = parse_ts(e.get("timestamp"))
            if t is None:
                t = parse_ts(m.get("timestamp"))
            if t is None:
                dq.c["malformed_lines"] += 1
                continue
            msgs.append((t, role, m, e))
    turns, cur = [], None
    for t, role, m, e in msgs:
        if role == "user":
            cur = {"start": t, "end": None, "msgs": []}
            turns.append(cur)
        elif cur is not None:
            cur["end"] = t
            cur["msgs"].append((role, m, e))
    res = []
    for tr in turns:
        s_, e_ = tr["start"], tr["end"]
        cs, ce = s_, e_
        if e_ is not None and e_ < s_:
            dq.c["negative_intervals"] += 1
            continue
        if win is not None:
            if e_ is None:
                if not (win[0] <= s_ <= win[1]):
                    dq.c["excluded_turns"] += 1
                    continue
            else:
                if e_ < win[0] or s_ > win[1]:
                    dq.c["excluded_turns"] += 1
                    continue
                cs, ce = max(s_, win[0]), min(e_, win[1])
                if (cs, ce) != (s_, e_):
                    dq.c["clipped_turns"] += 1
        model = tool = tokens = cost = 0.0
        for role, m, e in tr["msgs"]:
            miss = False

            def field(*names, src=(m, e)):
                for s in src:
                    cur_ = s
                    for n in names:
                        cur_ = cur_.get(n) if isinstance(cur_, dict) else None
                    if fnum(cur_) and cur_ >= 0:
                        return cur_
                return None
            if role == "assistant":
                d = field("durationMs")
                tk = field("usage", "totalTokens")
                c = field("usage", "cost", "total")
                model += (d or 0) / 1000.0
                tokens += tk or 0
                cost += c or 0
                miss = d is None or tk is None or c is None
            else:
                d = field("durationMs")
                tool += (d or 0) / 1000.0
                miss = d is None
            if miss:
                dq.c["missing_fields"] += 1
        res.append({"start": tr["start"], "end": tr["end"], "cs": cs, "ce": ce, "model_s": model, "tool_s": tool,
                    "tokens": tokens, "cost": cost})
    return res


def agg(turns):
    timed = [t for t in turns if t["end"] is not None]
    return {"turns": len(timed), "turns_untimed": len(turns) - len(timed),
            "active_s": rnd(sum(t["ce"] - t["cs"] for t in timed)),
            "model_s": rnd(sum(t["model_s"] for t in timed)),
            "tool_s": rnd(sum(t["tool_s"] for t in timed)),
            "tokens": rnd(sum(t["tokens"] for t in timed)),
            "cost": rnd(sum(t["cost"] for t in timed))}


def peak(turns):
    pts = []
    for t in turns:
        if t["end"] is not None and t["ce"] > t["cs"]:
            pts.append((t["cs"], 1))
            pts.append((t["ce"], -1))
    pts.sort()  # at equal time -1 sorts before +1: half-open [start,end)
    cur = best = 0
    for _, d in pts:
        cur += d
        best = max(best, cur)
    return best


def judge(bk, bcomplete, bbasis, b, basis, shared, agents, orch, dqc):
    """A5: per-metric comparability. Returns ({wall, agent_active, cost}: bool, {metric: [reasons]})."""
    unk = "baseline coverage unknown"
    wall_r = []
    # Nothing is inferred: wall needs explicit boolean clocks.complete, string clocks.wall_basis, boolean shared_wall.
    if not isinstance(bcomplete, bool) or not isinstance(bbasis, str) or not isinstance(bk.get("shared_wall"), bool):
        wall_r.append(unk)
    else:
        if not bcomplete:
            wall_r.append("incomplete run (baseline)")
        if bbasis != basis:
            wall_r.append("wall basis differs")
        if bk["shared_wall"]:
            wall_r.append("shared wall (baseline)")
    if shared:
        wall_r.append("shared wall (current)")
    ba = b.get("agents") if isinstance(b.get("agents"), dict) else None
    bq = b.get("data_quality") if isinstance(b.get("data_quality"), dict) else None
    act_r, cost_r = list(wall_r), list(wall_r)
    # agent_active
    if not agents["available"]:
        act_r.append("agents unavailable (current)")
    if agents["turns_untimed"] != 0:
        act_r.append("untimed turns (current)")
    if ba is None or "available" not in ba or "turns_untimed" not in ba:
        if unk not in act_r:
            act_r.append(unk)
    else:
        if ba["available"] is not True:
            act_r.append("agents unavailable (baseline)")
        if ba["turns_untimed"] != 0:
            act_r.append("untimed turns (baseline)")
    # cost
    if dqc["missing_fields"] != 0:
        cost_r.append("missing usage fields (current)")
    if dqc["clipped_turns"] != 0:
        cost_r.append("clipped turns (current)")
    if bq is None or "missing_fields" not in bq or "clipped_turns" not in bq or "orchestrator" not in b:
        if unk not in cost_r:
            cost_r.append(unk)
    else:
        if bq["missing_fields"] != 0:
            cost_r.append("missing usage fields (baseline)")
        if bq["clipped_turns"] != 0:
            cost_r.append("clipped turns (baseline)")
        if (orch is not None) != isinstance(b.get("orchestrator"), dict):
            cost_r.append("orchestrator inclusion differs")
    reasons = {"wall": wall_r, "agent_active": act_r, "cost": cost_r}
    return ({k: not v for k, v in reasons.items()}, {k: v for k, v in reasons.items() if v})


def build(args):
    dq = DQ()
    allev = read_ledger(args.ledger, dq)
    # A1: an event without a non-empty string `run` belongs to no run (counted once, whole ledger).
    dq.c["unowned_events"] = sum(1 for e in allev if not sstr(e.get("run")))
    allev = [e for e in allev if sstr(e.get("run"))]
    runs = sorted({e["run"] for e in allev})
    run = args.run
    if run is None:
        if len(runs) > 1:
            raise SystemExit("error: several runs in ledger (%s); choose one with --run" % ", ".join(runs))
        run = runs[0] if runs else None
    if run is None or run not in runs:
        sys.stderr.write("error: run %r has no valid events (0 invalid)\n" % run)
        raise SystemExit(2)
    ev = [e for e in allev if e["run"] == run]
    ev_file = list(ev)  # ledger (append) order: span/phase edges pair in this order, never by ts
    ev.sort(key=lambda e: e["_t"])  # stable; used for window, milestones and "last" selections
    for e in ev:
        if e["kind"] not in KINDS:
            dq.c["unknown_kinds"] += 1
    ev = [e for e in ev if e["kind"] in KINDS]
    ev_file = [e for e in ev_file if e["kind"] in KINDS]
    # A2: per-kind required fields; invalid evidence is excluded and counted, never repaired.
    n_in = len(ev)
    ev = [e for e in ev if valid_event(e)]
    ev_file = [e for e in ev_file if valid_event(e)]
    dq.c["invalid_events"] += n_in - len(ev)
    if not ev:
        sys.stderr.write("error: run %r has no valid events (%d invalid)\n" % (run, dq.c["invalid_events"]))
        raise SystemExit(2)

    rs = [e for e in ev if e["kind"] == "run" and e.get("edge") == "start"]
    re_ = [e for e in ev if e["kind"] == "run" and e.get("edge") == "end"]
    # No `run start` => nothing start-dependent is measured (wall, window filter, pre-registration).
    t0 = rs[0]["_t"] if rs else None
    t1 = re_[-1]["_t"] if re_ else ev[-1]["_t"]
    window_s = t1 - t0 if t0 is not None else None
    first_start_i = min((e["_i"] for e in rs), default=None)

    # clocks
    expected = sorted({e["publication"] for e in ev if e["kind"] == "expect" and isinstance(e.get("publication"), str)})
    ms = [e for e in ev if e["kind"] == "milestone"]
    ver = [e for e in ms if e.get("name") == "verified"]
    verified_pubs = sorted({e["publication"] for e in ver if isinstance(e.get("publication"), str)})
    missing = [p for p in expected if p not in verified_pubs]
    complete = bool(ver) and not missing if expected else bool(ver)
    last_ver = ver[-1]["_t"] if ver else None
    merged = [e for e in ms if e.get("name") == "merged"]
    last_merged = merged[-1]["_t"] if merged else None
    ready = [e for e in ms if e.get("name") == "ready-to-test"]
    ready_t = None
    if ready:
        if last_merged is not None:
            before = [e for e in ready if e["_t"] <= last_merged]
            ready_t = (before[-1] if before else ready[-1])["_t"]
        else:
            ready_t = ready[-1]["_t"]
    if t0 is None:
        basis, wall, complete = "unavailable", None, False
    elif complete:
        basis, wall = "verified", last_ver - t0
    elif expected:
        basis, wall = "incomplete", window_s
    elif ready_t is not None:
        basis, wall = "ready-to-test", ready_t - t0
    else:
        basis, wall = "window", window_s

    phases = {}
    for s, e in match_edges([x for x in ev_file if x["kind"] == "phase"], "name", dq, "unmatched_phases")[0]:
        phases[s["name"]] = phases.get(s["name"], 0) + (e["_t"] - s["_t"])
    clocks = {"wall_s": rnd(wall), "wall_basis": basis, "complete": complete,
              "expected_publications": expected, "verified_publications": verified_pubs,
              "missing_publications": missing,
              "wall_to_ready_s": rnd(ready_t - t0) if ready_t is not None and t0 is not None else None,
              "wall_to_merged_s": rnd(last_merged - t0) if last_merged is not None and t0 is not None else None,
              "wall_to_verified_s": rnd(last_ver - t0) if last_ver is not None and t0 is not None else None,
              "phases_s": {k: rnd(phases[k]) for k in sorted(phases)}}

    # spans
    spairs, slost = match_edges([x for x in ev_file if x["kind"] == "span"], "span", dq, "unmatched_spans")
    gates = [(s, e) for s, e in spairs if s.get("cat") == "gate"]
    gates_o = {"count": len(gates), "total_s": rnd(sum(e["_t"] - s["_t"] for s, e in gates)),
               "failed": sum(1 for s, e in gates if e.get("rc") != 0),
               "unknown": sum(1 for s in slost if s.get("cat") == "gate")}
    lanes = {}
    for s, e in spairs:
        if s.get("cat") == "agent":
            ln = s.get("lane") if isinstance(s.get("lane"), str) and s.get("lane") else s.get("name")
            lo, hi = lanes.get(ln, (s["_t"], e["_t"]))
            lanes[ln] = (min(lo, s["_t"]), max(hi, e["_t"]))
    lives = [hi - lo for lo, hi in lanes.values()]
    par = div(sum(lives), max(lives)) if lives else None

    # candidates
    cand = [e for e in ev if e["kind"] == "candidate"]
    acc = sum(1 for e in cand if e["decision"] == "accept")
    cands = {"evaluated": len(cand), "accepted": acc, "rejected": len(cand) - acc,
             "first_pass_yield": rnd(div(acc, len(cand)))}

    # units
    ids = {}
    for e in ev:
        if e["kind"] == "unit" and e.get("status") == "done" and isinstance(e.get("class"), str):
            ids.setdefault(e["class"], set()).add(e.get("id"))
    units = {k: len(ids[k]) for k in sorted(ids)}
    shared = len(units) > 1

    # sessions
    # A3: one accounting window, the same as the wall: [run start, run start + wall].
    win = (t0, t0 + wall) if t0 is not None and wall is not None else None  # None: no in-window filter
    acct_end = win[1] if win else None
    all_turns, by_lane, nsess = [], {}, 0
    nread = 0
    for p in inventory(args.sessions or [], args.orchestrator_session, dq):
        try:
            ts_ = parse_session(p, win, dq)
        except OSError:
            dq.c["missing_inputs"] += 1
            continue
        nread += 1
        if ts_:
            nsess += 1
        all_turns += ts_
        by_lane.setdefault(os.path.basename(os.path.dirname(p)), []).extend(ts_)
    avail = nread > 0
    untimed = sum(1 for t in all_turns if t["end"] is None)
    ag = agg(all_turns)
    agents = {"available": avail, "sessions": nsess, "turns": ag["turns"], "turns_untimed": untimed,
              "active_s": ag["active_s"] if avail else None, "model_s": ag["model_s"] if avail else None,
              "tool_s": ag["tool_s"] if avail else None, "tokens": ag["tokens"] if avail else None,
              "cost": ag["cost"] if avail else None, "peak_concurrency": peak(all_turns) if avail else None,
              "by_lane": {k: {x: y for x, y in agg(by_lane[k]).items() if x != "turns_untimed"} for k in sorted(by_lane)}}
    orch = None
    if args.orchestrator_session:
        if not os.path.isfile(args.orchestrator_session):
            dq.c["missing_inputs"] += 1
        else:
            try:
                orch = agg(parse_session(args.orchestrator_session, win, dq))
            except OSError:
                dq.c["missing_inputs"] += 1

    per_class = {}
    for k, n in units.items():
        wm = rnd(wall / 60.0 / n) if wall is not None else None
        aa = rnd(agents["active_s"] / 60.0 / n) if avail else None
        if avail or orch:
            cu = rnd(((agents["cost"] if avail else 0) + (orch["cost"] if orch else 0)) / n)
            tu = rnd(((agents["tokens"] if avail else 0) + (orch["tokens"] if orch else 0)) / n)
        else:
            cu = tu = None
        per_class[k] = {"units": n, "wall_min_per_unit": wm, "agent_active_min_per_unit": aa,
                        "cost_per_unit": cu, "tokens_per_unit": tu, "shared_wall": shared,
                        "usage_basis": "whole-run"}

    comp = None
    if avail:
        comp = rnd(div(agents["active_s"] + (orch["model_s"] if orch else 0), wall))
    ratios = {"agent_work_compression": comp, "implementation_parallelism": rnd(par),
              "retry_tax": rnd(div(cands["rejected"], cands["evaluated"]))}

    # estimates
    pre, late, unver = [], [], []
    for e in ev:
        if e["kind"] != "estimate":
            continue
        rec = {"unit_class": e.get("unit_class"), "units": e.get("units"),
               "human_hours": e.get("human_hours"), "by": e.get("by"), "ts": iso(e["_t"])}
        if t0 is None:
            rec["reason"] = "no run start"
            unver.append(rec)  # cannot check pre-registration without a run start
        elif e["_t"] <= t0 and e["_i"] > first_start_i:
            rec["reason"] = "backdated: timestamp precedes the run start but the line was appended after the first run start in the ledger"
            unver.append(rec)
        elif e["_t"] <= t0:
            pc = per_class.get(rec["unit_class"])
            f = None
            if pc and num(rec["units"]) and num(rec["human_hours"]):
                f = div(div(rec["human_hours"] * 60.0, rec["units"]), pc["wall_min_per_unit"])
            rec["factor_x"] = rnd(f)
            pre.append(rec)
        else:
            late.append(rec)

    provenance = args.provenance
    baseline = None
    if args.baseline:
        try:
            with open(args.baseline, encoding="utf-8") as f:
                b = json.load(f)
            if not isinstance(b, dict):
                raise ValueError("not an object")
        except (OSError, ValueError) as ex:
            raise SystemExit("error: cannot read baseline %s: %s" % (args.baseline, ex))
        bprov = b.get("provenance") if isinstance(b.get("provenance"), str) and b.get("provenance") else "unspecified"
        baseline = {"run": b.get("run"), "provenance": bprov, "factors": {}, "refused": []}
        if t0 is None:
            baseline["refused"].append("no run start")
        elif not complete:
            baseline["refused"].append("incomplete run")
        else:
            bc = b.get("clocks") if isinstance(b.get("clocks"), dict) else {}
            bbasis = bc.get("wall_basis")
            bcomplete = bc.get("complete")
            bpc = b.get("per_class") if isinstance(b.get("per_class"), dict) else {}
            common = sorted(set(bpc) & set(per_class))
            if not common:
                baseline["refused"].append("no shared unit class (baseline: %s; current: %s)" % (
                    ", ".join(sorted(bpc)) or "none", ", ".join(sorted(per_class)) or "none"))
            for k in common:
                bk = bpc[k] if isinstance(bpc[k], dict) else {}
                comparable, why = judge(bk, bcomplete, bbasis, b, basis, shared, agents, orch, dq.c)
                fac = {}
                for fname, mname, mkey in (("wall_per_unit_x", "wall_per_unit", "wall_min_per_unit"),
                                           ("agent_active_per_unit_x", "agent_active_per_unit", "agent_active_min_per_unit"),
                                           ("cost_per_unit_x", "cost_per_unit", "cost_per_unit")):
                    cur, base = per_class[k][mkey], bk.get(mkey)
                    if not num(base):
                        base = None
                    if cur == 0:
                        baseline["refused"].append("%s: zero current value for %s" % (mname, k))
                        fac[fname] = None
                    elif base == 0:
                        baseline["refused"].append("%s: zero baseline value for %s" % (mname, k))
                        fac[fname] = None
                    else:
                        fac[fname] = rnd(div(base, cur))
                fac["comparable"] = comparable
                fac["not_comparable"] = why
                fac["baseline_provenance"] = bprov
                baseline["factors"][k] = fac

    return {"schema": SCHEMA, "run": run, "provenance": provenance,
            "window": {"start": iso(t0), "end": iso(t1), "accounting_end": iso(acct_end)}, "clocks": clocks, "agents": agents,
            "orchestrator": orch, "gates": gates_o, "candidates": cands, "units": units,
            "per_class": per_class, "ratios": ratios, "baseline": baseline,
            "estimates": {"preregistered": pre, "ignored_late": late, "unverifiable": unver},
            "data_quality": dict(dq.c)}


def fx(v, unit="", nd=2):
    if v is None:
        return "unavailable"
    return ("%.*f" % (nd, v)).rstrip("0").rstrip(".") + unit if isinstance(v, float) else "%s%s" % (v, unit)


def markdown(r):
    c, a, o, q = r["clocks"], r["agents"], r["orchestrator"], r["data_quality"]
    L = ["# Efficiency report — run %s" % r["run"], "",
         "> No ratio below is a causal speedup claim, and none is billing data: no serial counterfactual was run.", "",
         "Window: %s → %s · accounting window (wall and session figures): %s → %s · provenance: %s" % (
             r["window"]["start"] or "unavailable", r["window"]["end"], r["window"]["start"] or "unavailable",
             r["window"]["accounting_end"] or "unavailable", r["provenance"]), "",
         "## Clocks",
         "- Wall: %s (measured; basis `%s`, complete: %s)" % (fx(c["wall_s"], " s"), c["wall_basis"], str(c["complete"]).lower())
         + (" — wall unavailable: the run has no `run start` event" if c["wall_basis"] == "unavailable" else ""),
         "- Wall to ready / merged / verified: %s / %s / %s (measured)" % (
             fx(c["wall_to_ready_s"], " s"), fx(c["wall_to_merged_s"], " s"), fx(c["wall_to_verified_s"], " s"))]
    if c["missing_publications"]:
        L.append("- Missing publications: %s (run incomplete)" % ", ".join(c["missing_publications"]))
    for k, v in c["phases_s"].items():
        L.append("- Phase `%s`: %s (measured)" % (k, fx(v, " s")))
    L += ["", "## Agents (from session logs)"]
    if not a["available"]:
        L.append("- unavailable (no agent session file was read; measures are not zero, they are missing)")
    else:
        L += ["- Sessions %d, timed turns %d, untimed %d; active %s (lower bound), model %s, tool %s (measured)" % (
                  a["sessions"], a["turns"], a["turns_untimed"], fx(a["active_s"], " s"), fx(a["model_s"], " s"), fx(a["tool_s"], " s")),
              "- Tokens %s, cost %s (measured from session usage fields; missing fields counted; not billing); peak concurrency %d (measured)" % (
                  fx(a["tokens"]), fx(a["cost"]), a["peak_concurrency"])]
        for k, v in a["by_lane"].items():
            L.append("  - lane `%s`: %d turns, active %s (lower bound); tokens %s, cost %s (measured from session usage)" % (
                k, v["turns"], fx(v["active_s"], " s"), fx(v["tokens"]), fx(v["cost"])))
    L.append("- Orchestrator: " + ("unavailable" if o is None else "%d turns (untimed %d), model %s, active %s (lower bound; measured, excluded from agent totals); tokens %s, cost %s (measured from session usage; not billing)" % (
        o["turns"], o["turns_untimed"], fx(o["model_s"], " s"), fx(o["active_s"], " s"), fx(o["tokens"]), fx(o["cost"]))))
    g, cd, rt = r["gates"], r["candidates"], r["ratios"]
    L += ["", "## Gates and candidates",
          "- Gates: %d, %s total, %d failed (measured)" % (g["count"], fx(g["total_s"], " s"), g["failed"]),
          "- Candidates: %d evaluated, %d accepted, %d rejected (measured counts)" % (
              cd["evaluated"], cd["accepted"], cd["rejected"]),
          "- First-pass yield: %s (heuristic; accepted ÷ evaluated)" % fx(cd["first_pass_yield"]),
          "", "## Ratios (heuristic)",
          "- Agent-work compression: %s (heuristic; active time is a lower bound)" % fx(rt["agent_work_compression"], "x"),
          "- Implementation parallelism: %s (heuristic; allocated capacity upper bound)" % fx(rt["implementation_parallelism"], "x"),
          "- Retry tax: %s (heuristic)" % fx(rt["retry_tax"]), "", "## Per unit class"]
    if not r["per_class"]:
        L.append("- unavailable (no units done)")
    for k, p in r["per_class"].items():
        L.append("- `%s`: %d units; wall %s min/unit (measured); agent active %s min/unit (whole-run total ÷ units; lower bound); cost %s/unit; tokens %s/unit (measured from session usage; whole-run totals ÷ units, not attributed to the class, not additive across classes; available sources only)%s" % (
            k, p["units"], fx(p["wall_min_per_unit"]), fx(p["agent_active_min_per_unit"]), fx(p["cost_per_unit"]),
            fx(p["tokens_per_unit"]), "; SHARED WALL (whole wall divided by this class's units)" if p["shared_wall"] else ""))
    L += ["", "## Baseline comparison (descriptive)"]
    b = r["baseline"]
    if b is None:
        L.append("- unavailable (no baseline given)")
    else:
        L.append("- Baseline run `%s`, provenance: %s" % (b["run"], b["provenance"]))
        for k, f in b["factors"].items():
            cm = f["comparable"]
            L.append("- `%s`: wall %s, agent-active (whole-run, lower bound) %s, cost (whole-run, session usage) %s — Nx vs baseline under these boundaries; %s; baseline %s%s" % (
                k, fx(f["wall_per_unit_x"], "x"), fx(f["agent_active_per_unit_x"], "x"), fx(f["cost_per_unit_x"], "x"),
                "; ".join("%s %s" % (m, "comparable" if cm[m] else "NOT comparable (%s)" % ", ".join(f["not_comparable"][m]))
                          for m in ("wall", "agent_active", "cost")),
                f["baseline_provenance"], " (reconstructed, not newly measured)" if f["baseline_provenance"] == "reconstructed" else ""))
        for x in b["refused"]:
            L.append("- refused: %s" % x)
    L += ["", "## Human estimates"]
    e = r["estimates"]
    if not e["preregistered"] and not e["ignored_late"] and not e["unverifiable"]:
        L.append("- none")
    for x in e["preregistered"]:
        L.append("- `%s`: %s units, %s h by %s → %s (pre-registered estimate, not measured; classified by timestamp and ledger order only — not proof of prior registration)" % (
            x["unit_class"], x["units"], x["human_hours"], x["by"], fx(x["factor_x"], "x")))
    for x in e["unverifiable"]:
        L.append("- UNVERIFIABLE (%s; classified by timestamp and ledger order only — not proof of prior registration): `%s`, %s h by %s at %s" % (
            x["reason"], x["unit_class"], x["human_hours"], x["by"], x["ts"]))
    for x in e["ignored_late"]:
        L.append("- IGNORED (registered after run start; classified by timestamp only): `%s`, %s h by %s at %s" % (x["unit_class"], x["human_hours"], x["by"], x["ts"]))
    L += ["", "## Data quality", "- " + ", ".join("%s=%s" % (k, q[k]) for k in q), ""]
    return "\n".join(L)


def record(args):
    ev = {"v": 1, "ts": None, "kind": args.kind}
    for kv in args.fields:
        if "=" not in kv:
            raise SystemExit("error: field %r is not key=value" % kv)
        k, v = kv.split("=", 1)
        try:
            ev[k] = json.loads(v)
        except ValueError:
            ev[k] = v
    ev["ts"] = ev["ts"] or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    os.makedirs(os.path.dirname(os.path.abspath(args.ledger)), exist_ok=True)
    with open(args.ledger, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, separators=(",", ":")) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="telemetry.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("--ledger", required=True)
    r.add_argument("--run")
    r.add_argument("--sessions", action="append")
    r.add_argument("--orchestrator-session")
    r.add_argument("--baseline")
    r.add_argument("--provenance", default="measured")
    r.add_argument("--json")
    r.add_argument("--md")
    w = sub.add_parser("record")
    w.add_argument("--ledger", required=True)
    w.add_argument("kind")
    w.add_argument("fields", nargs="*")
    args = ap.parse_args(argv)
    if args.cmd == "record":
        record(args)
        return 0
    try:
        rep = build(args)
    except OSError as ex:
        raise SystemExit("error: %s" % ex)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=2)
            f.write("\n")
    md = markdown(rep)
    if args.md:
        with open(args.md, "w", encoding="utf-8") as f:
            f.write(md)
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
