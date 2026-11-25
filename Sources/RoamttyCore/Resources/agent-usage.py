#!/usr/bin/env python3
"""Roamtty: read-only local token, context-window, reasoning-effort and quota collector for AI coding CLIs.

Usage:
  python3 - session <agent> [tmux_session] [cwd]
  python3 - host <today|7d|30d>

Reads only local CLI session transcripts, non-secret settings/caches, and official CLI quota commands
(never credentials or auth files). Prints key=value lines; exits 0 even when no data is found.
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

HOME = os.path.expanduser("~")
EXTRA_PATH = ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin:" + os.path.join(HOME, ".local", "bin")

EFFORT_MAP = {
    "minimal": "minimal",
    "min": "minimal",
    "low": "low",
    "medium": "medium",
    "med": "medium",
    "high": "high",
    "xhigh": "xhigh",
    "extra_high": "xhigh",
    "extra-high": "xhigh",
    "very_high": "xhigh",
    "max": "max",
}


def norm_path(p):
    if not p:
        return ""
    if p == "~":
        return HOME
    if p.startswith("~/"):
        p = os.path.join(HOME, p[2:])
    try:
        return os.path.realpath(p)
    except OSError:
        return os.path.normpath(p)


def parse_iso_ts(val):
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val) / 1000.0 if val > 1e12 else float(val)
    if not isinstance(val, str) or not val:
        return None
    s = val.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def safe_int(v):
    try:
        return max(0, int(v))
    except Exception:
        return 0


def safe_float(v):
    try:
        return float(v)
    except Exception:
        return None


def normalize_effort(val):
    if not isinstance(val, str):
        return ""
    s = val.strip().strip("()[]").lower().replace(" ", "_")
    return EFFORT_MAP.get(s, "")


def split_model_effort(raw_model):
    if not isinstance(raw_model, str):
        return "", ""
    s = raw_model.strip()
    if not s:
        return "", ""
    m = re.search(r"\s*\((minimal|min|low|medium|med|high|xhigh|max)\)\s*$", s, re.I)
    if m:
        return s[:m.start()].strip(), normalize_effort(m.group(1))
    m = re.search(r"-(minimal|low|medium|high|xhigh|max)$", s, re.I)
    if m:
        return s[:m.start()].strip(), normalize_effort(m.group(1))
    return s, ""


def cmd_env():
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "") + EXTRA_PATH
    return env


def tmux_meta(tmux_session):
    if not tmux_session:
        return "", "", "", ""
    fmt = "#{@roamtty_agent}\t#{@roamtty_session}\t#{@roamtty_transcript}\t#{pane_current_path}"
    try:
        out = subprocess.check_output(
            ["tmux", "-u", "display-message", "-p", "-t", f"={tmux_session}:", fmt],
            stderr=subprocess.DEVNULL,
            timeout=2,
            env=cmd_env(),
        ).decode("utf-8", "replace").rstrip("\r\n")
        parts = out.split("\t")
        while len(parts) < 4:
            parts.append("")
        agent_field = parts[0].split("|")[2] if parts[0].count("|") >= 2 else ""
        return agent_field.strip(), parts[1].strip(), parts[2].strip(), parts[3].strip()
    except Exception:
        return "", "", "", ""


def infer_claude_ctx_limit(model, ctx_used):
    m = (model or "").lower()
    if "[1m]" in m or "1m" in m or ctx_used > 200_000:
        return 1_000_000
    return 200_000


def claude_settings_effort(model):
    p = os.path.join(HOME, ".claude", "settings.json")
    try:
        cfg = json.load(open(p, "r", encoding="utf-8", errors="replace"))
        if not isinstance(cfg, dict):
            return ""
        ms = cfg.get("modelSettings")
        if isinstance(ms, dict) and model:
            for key in (model, model.lower()):
                entry = ms.get(key)
                if isinstance(entry, dict):
                    e = normalize_effort(entry.get("effortLevel"))
                    if e:
                        return e
        return normalize_effort(cfg.get("effortLevel"))
    except Exception:
        return ""


def read_claude_quota(now):
    p = os.path.join(HOME, ".roamtty", "quota-claude.json")
    try:
        data = json.load(open(p, "r", encoding="utf-8", errors="replace"))
        if not isinstance(data, dict):
            return None, None
        updated = safe_int(data.get("updated_at"))
        if updated > 0 and now - updated > 7 * 86400:
            return None, None
        q5h = None
        q7d = None
        for key, target in (("five_hour", "5h"), ("seven_day", "7d")):
            w = data.get(key)
            if not isinstance(w, dict):
                continue
            used = safe_float(w.get("used_percentage"))
            if used is None:
                continue
            resets = safe_int(w.get("resets_at"))
            if resets == 0 and isinstance(w.get("resets_at"), str):
                ts = parse_iso_ts(w.get("resets_at"))
                resets = int(ts) if ts else 0
            if resets > 0 and resets < now - 60:
                continue
            rem = max(0.0, min(100.0, 100.0 - used))
            entry = (rem, resets if resets > 0 else None)
            if target == "5h":
                q5h = entry
            else:
                q7d = entry
        return q5h, q7d
    except Exception:
        return None, None


def parse_claude_file(path, cutoff=None):
    by_id = {}
    ordered_keys = []
    latest_model = ""
    latest_effort = ""
    latest_ctx = None
    first_cwd = ""
    has_in_range = False
    idx = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"cwd"' in line and not first_cwd:
                    try:
                        o = json.loads(line)
                        if isinstance(o.get("cwd"), str):
                            first_cwd = o["cwd"]
                    except Exception:
                        pass
                if '"usage"' not in line or '"input_tokens"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "assistant":
                    continue
                eff = normalize_effort(o.get("effort"))
                if eff:
                    latest_effort = eff
                msg = o.get("message")
                if not isinstance(msg, dict):
                    continue
                model = msg.get("model") or ""
                if not model or model == "<synthetic>":
                    continue
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue
                ts = parse_iso_ts(o.get("timestamp"))
                if cutoff is not None and ts is not None and ts < cutoff:
                    continue
                inp = safe_int(usage.get("input_tokens"))
                out = safe_int(usage.get("output_tokens"))
                cr = safe_int(usage.get("cache_read_input_tokens"))
                cc = safe_int(usage.get("cache_creation_input_tokens"))
                if inp == 0 and out == 0 and cr == 0 and cc == 0:
                    continue
                has_in_range = True
                mid = msg.get("id") or f"_row_{idx}"
                idx += 1
                prev = by_id.get(mid)
                if prev is None:
                    ordered_keys.append(mid)
                    by_id[mid] = (inp, out, cr, cc, model)
                else:
                    if out >= prev[1]:
                        by_id[mid] = (inp, out, cr, cc, model)
    except OSError:
        return None

    if not has_in_range:
        return None
    s_in = s_out = s_cr = s_cc = 0
    for k in ordered_keys:
        inp, out, cr, cc, model = by_id[k]
        s_in += inp
        s_out += out
        s_cr += cr
        s_cc += cc
        latest_model = model
        latest_ctx = (inp + cr + cc, cr, cc, inp)
    ctx_used, ctx_cr, ctx_cc, ctx_turn = latest_ctx
    ctx_limit = infer_claude_ctx_limit(latest_model, ctx_used)
    if not latest_effort and cutoff is None:
        latest_effort = claude_settings_effort(latest_model)
    return {
        "model": latest_model,
        "effort": latest_effort,
        "cwd": first_cwd,
        "ctx_used": ctx_used,
        "ctx_limit": ctx_limit,
        "ctx_cache_read": ctx_cr,
        "ctx_cache_create": ctx_cc,
        "ctx_turn": ctx_turn,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": s_cc,
    }


def find_claude_transcript(transcript, sid, cwd):
    if transcript and os.path.isfile(transcript):
        return transcript
    base = os.path.join(HOME, ".claude", "projects")
    if not os.path.isdir(base):
        return None
    if sid:
        hits = glob.glob(os.path.join(base, "*", f"{sid}.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime)
    target = norm_path(cwd)
    if not target:
        return None
    enc = re.sub(r"[^A-Za-z0-9_-]", "-", target)
    proj_dir = os.path.join(base, enc)
    if os.path.isdir(proj_dir):
        proj_hits = [p for p in glob.glob(os.path.join(proj_dir, "*.jsonl")) if os.path.getsize(p) > 0]
        if proj_hits:
            return max(proj_hits, key=os.path.getmtime)
    candidates = glob.glob(os.path.join(base, "*", "*.jsonl"))
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in candidates[:40]:
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for _ in range(40):
                    line = f.readline()
                    if not line:
                        break
                    if '"cwd"' in line:
                        o = json.loads(line)
                        c = o.get("cwd")
                        if c and norm_path(c) == target:
                            return p
        except Exception:
            continue
    return None


def codex_model_ctx_cache():
    out = {}
    p = os.path.join(HOME, ".codex", "models_cache.json")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
        for m in data.get("models", []):
            slug = m.get("slug")
            cw = safe_int(m.get("context_window"))
            if slug and cw > 0:
                eff = safe_int(m.get("effective_context_window_percent") or 100)
                out[slug] = int(cw * eff / 100) if 50 <= eff <= 100 else cw
    except Exception:
        pass
    return out


def codex_config_effort():
    p = os.path.join(os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex"), "config.toml")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'^\s*model_reasoning_effort\s*=\s*"([^"]+)"', line)
                if m:
                    e = normalize_effort(m.group(1))
                    if e:
                        return e
    except Exception:
        pass
    return ""


def extract_codex_rate_limits(rl, now):
    q5h = None
    q7d = None
    if not isinstance(rl, dict):
        return q5h, q7d
    for key in ("primary", "secondary"):
        w = rl.get(key)
        if not isinstance(w, dict):
            continue
        used = safe_float(w.get("used_percent"))
        mins = safe_int(w.get("window_minutes"))
        resets_at = safe_int(w.get("resets_at"))
        if used is None or mins <= 0:
            continue
        if resets_at > 0 and resets_at < now - 60:
            continue
        rem = max(0.0, min(100.0, 100.0 - used))
        entry = (rem, resets_at if resets_at > 0 else None)
        if mins <= 600 and q5h is None:
            q5h = entry
        elif mins >= 7200 and q7d is None:
            q7d = entry
    return q5h, q7d


def is_default_codex_limit(rl):
    if not isinstance(rl, dict):
        return True
    lid = rl.get("limit_id")
    return not lid or lid == "codex"


def parse_codex_file(path, cutoff=None, model_cache=None):
    now = time.time()
    model = ""
    effort = ""
    file_cwd = ""
    last_token_count = None
    best_q5h = None
    best_q5h_ts = -1.0
    best_q5h_default = False
    best_q7d = None
    best_q7d_ts = -1.0
    best_q7d_default = False
    rec_in = rec_out = rec_cr = rec_cc = 0
    rec_count = 0
    first_ts = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if first_ts is None and '"timestamp"' in line:
                    try:
                        o = json.loads(line)
                        first_ts = parse_iso_ts(o.get("timestamp"))
                        if o.get("type") == "session_meta":
                            c = (o.get("payload") or {}).get("cwd")
                            if isinstance(c, str):
                                file_cwd = c
                    except Exception:
                        pass
                if '"turn_context"' in line:
                    try:
                        o = json.loads(line)
                        if o.get("type") == "turn_context":
                            pl = o.get("payload") or {}
                            if isinstance(pl.get("model"), str):
                                model = pl["model"]
                            if isinstance(pl.get("cwd"), str) and not file_cwd:
                                file_cwd = pl["cwd"]
                            e = normalize_effort(pl.get("effort"))
                            if not e:
                                cm = pl.get("collaboration_mode")
                                if isinstance(cm, dict):
                                    st = cm.get("settings")
                                    if isinstance(st, dict):
                                        e = normalize_effort(st.get("reasoning_effort"))
                            if e:
                                effort = e
                    except Exception:
                        pass
                elif '"token_usage_record"' in line:
                    try:
                        o = json.loads(line)
                        if o.get("type") == "token_usage_record":
                            ts = parse_iso_ts(o.get("timestamp"))
                            if cutoff is None or ts is None or ts >= cutoff:
                                u = (o.get("payload") or {}).get("usage") or {}
                                inp = safe_int(u.get("input_tokens"))
                                cr = min(inp, safe_int(u.get("cached_input_tokens")))
                                cc = safe_int(u.get("cache_write_input_tokens"))
                                out = safe_int(u.get("output_tokens"))
                                if inp or out or cr or cc:
                                    rec_in += max(0, inp - cr)
                                    rec_cr += cr
                                    rec_cc += cc
                                    rec_out += out
                                    rec_count += 1
                    except Exception:
                        pass
                elif '"token_count"' in line:
                    try:
                        o = json.loads(line)
                        pl = o.get("payload") or {}
                        if o.get("type") == "event_msg" and pl.get("type") == "token_count":
                            ts = parse_iso_ts(o.get("timestamp")) or 0.0
                            if isinstance(pl.get("info"), dict):
                                last_token_count = (ts, pl["info"])
                            rl = pl.get("rate_limits")
                            if isinstance(rl, dict):
                                e5, e7 = extract_codex_rate_limits(rl, now)
                                is_def = is_default_codex_limit(rl)
                                if e5 and ((is_def and not best_q5h_default) or (is_def == best_q5h_default and ts >= best_q5h_ts)):
                                    best_q5h, best_q5h_ts, best_q5h_default = e5, ts, is_def
                                if e7 and ((is_def and not best_q7d_default) or (is_def == best_q7d_default and ts >= best_q7d_ts)):
                                    best_q7d, best_q7d_ts, best_q7d_default = e7, ts, is_def
                    except Exception:
                        pass
    except OSError:
        return None

    rl_ts = max(best_q5h_ts, best_q7d_ts)
    if cutoff is not None:
        if rec_count > 0:
            return {
                "model": model,
                "effort": effort,
                "cwd": file_cwd,
                "sess_input": rec_in,
                "sess_output": rec_out,
                "sess_cache_read": rec_cr,
                "sess_cache_create": rec_cc,
                "q5h": best_q5h,
                "q7d": best_q7d,
                "rl_ts": rl_ts,
            }
        if last_token_count and (first_ts is None or first_ts >= cutoff):
            tot = last_token_count[1].get("total_token_usage") or {}
            inp = safe_int(tot.get("input_tokens"))
            cr = min(inp, safe_int(tot.get("cached_input_tokens")))
            cc = safe_int(tot.get("cache_write_input_tokens"))
            out = safe_int(tot.get("output_tokens"))
            if inp or out or cr or cc:
                return {
                    "model": model,
                    "effort": effort,
                    "cwd": file_cwd,
                    "sess_input": max(0, inp - cr),
                    "sess_output": out,
                    "sess_cache_read": cr,
                    "sess_cache_create": cc,
                    "q5h": best_q5h,
                    "q7d": best_q7d,
                    "rl_ts": rl_ts,
                }
        return {"rate_only": True, "q5h": best_q5h, "q7d": best_q7d, "rl_ts": rl_ts} if (best_q5h or best_q7d) else None

    if not last_token_count and rec_count == 0 and not (best_q5h or best_q7d):
        return None

    info = last_token_count[1] if last_token_count else {}
    last_u = info.get("last_token_usage") or {}
    tot_u = info.get("total_token_usage") or {}
    ctx_limit = safe_int(info.get("model_context_window"))
    if ctx_limit == 0 and model and model_cache:
        ctx_limit = model_cache.get(model, 0)
    last_inp = safe_int(last_u.get("input_tokens"))
    last_cr = min(last_inp, safe_int(last_u.get("cached_input_tokens")))
    tot_inp = safe_int(tot_u.get("input_tokens"))
    tot_cr = min(tot_inp, safe_int(tot_u.get("cached_input_tokens")))
    tot_cc = safe_int(tot_u.get("cache_write_input_tokens"))
    tot_out = safe_int(tot_u.get("output_tokens"))
    if tot_inp == 0 and tot_out == 0 and rec_count > 0:
        s_in, s_out, s_cr, s_cc = rec_in, rec_out, rec_cr, rec_cc
    else:
        s_in, s_out, s_cr, s_cc = max(0, tot_inp - tot_cr), tot_out, tot_cr, tot_cc
    if not effort:
        effort = codex_config_effort()

    res = {
        "model": model,
        "effort": effort,
        "cwd": file_cwd,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": s_cc,
        "q5h": best_q5h,
        "q7d": best_q7d,
    }
    if last_inp > 0 and ctx_limit > 0:
        res["ctx_used"] = last_inp
        res["ctx_limit"] = ctx_limit
        res["ctx_cache_read"] = last_cr
        res["ctx_cache_create"] = 0
        res["ctx_turn"] = max(0, last_inp - last_cr)
    return res


def latest_codex_account_quotas(exclude_path=None):
    base = os.path.join(HOME, ".codex", "sessions")
    if not os.path.isdir(base):
        return None, None
    paths = glob.glob(os.path.join(base, "*", "*", "*", "*.jsonl"))
    paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    q5h = None
    q7d = None
    for p in paths[:15]:
        if exclude_path and p == exclude_path:
            continue
        r = parse_codex_file(p)
        if not r:
            continue
        if q5h is None and r.get("q5h"):
            q5h = r["q5h"]
        if q7d is None and r.get("q7d"):
            q7d = r["q7d"]
        if q5h and q7d:
            break
    return q5h, q7d


def find_codex_transcript(transcript, sid, cwd):
    if transcript and os.path.isfile(transcript):
        return transcript
    base = os.path.join(HOME, ".codex", "sessions")
    if not os.path.isdir(base):
        return None
    if sid:
        hits = glob.glob(os.path.join(base, "*", "*", "*", f"*{sid}*.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime)
    target = norm_path(cwd)
    if not target:
        return None
    candidates = glob.glob(os.path.join(base, "*", "*", "*", "*.jsonl"))
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in candidates[:30]:
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for _ in range(15):
                    line = f.readline()
                    if not line:
                        break
                    if '"cwd"' in line:
                        o = json.loads(line)
                        c = (o.get("payload") or {}).get("cwd")
                        if c and norm_path(c) == target:
                            return p
        except Exception:
            continue
    return None


def infer_agy_ctx_limit(model, ctx_used):
    m = (model or "").lower()
    if "claude" in m and ctx_used <= 200_000:
        return 200_000
    return 1_000_000


def agy_settings_effort():
    p = os.path.join(HOME, ".gemini", "antigravity-cli", "settings.json")
    try:
        cfg = json.load(open(p, "r", encoding="utf-8", errors="replace"))
        if isinstance(cfg, dict):
            _, eff = split_model_effort(cfg.get("model") or "")
            return eff
    except Exception:
        pass
    return ""


def parse_agy_quota_payload(data, model, now):
    if not isinstance(data, dict):
        return None, None
    groups = ((data.get("command") or {}).get("data") or {}).get("groups")
    if not isinstance(groups, list):
        groups = data.get("groups")
    if not isinstance(groups, list) or not groups:
        return None, None
    m = (model or "").lower()
    want_3p = ("claude" in m or "gpt" in m or "opus" in m or "sonnet" in m)
    chosen = None
    for g in groups:
        if not isinstance(g, dict):
            continue
        name = (g.get("name") or "").lower()
        if want_3p and ("claude" in name or "gpt" in name):
            chosen = g
            break
        if not want_3p and "gemini" in name:
            chosen = g
            break
    if chosen is None:
        chosen = groups[0] if isinstance(groups[0], dict) else None
    if not chosen:
        return None, None
    q5h = None
    q7d = None
    for b in chosen.get("buckets") or []:
        if not isinstance(b, dict):
            continue
        frac = safe_float(b.get("remaining_fraction"))
        if frac is None:
            continue
        rem = max(0.0, min(100.0, frac * 100.0))
        resets = parse_iso_ts(b.get("reset_time"))
        if resets is not None and resets < now - 60:
            continue
        win = (b.get("window") or "").lower()
        entry = (rem, int(resets) if resets else None)
        if win == "5h" and q5h is None:
            q5h = entry
        elif win == "weekly" and q7d is None:
            q7d = entry
    return q5h, q7d


def refresh_agy_quota_file(cache_path, lock_path, sync):
    if os.environ.get("ROAMTTY_NO_LIVE_QUOTA") == "1":
        return None
    try:
        if os.path.isfile(lock_path) and time.time() - os.path.getmtime(lock_path) < 60:
            return None
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(lock_path, "w", encoding="utf-8") as lf:
            lf.write(str(int(time.time())))
    except OSError:
        return None

    env = cmd_env()
    if sync:
        try:
            out = subprocess.check_output(
                ["agy", "-p", "/quota", "--output-format", "json"],
                stderr=subprocess.DEVNULL,
                timeout=9,
                env=env,
            ).decode("utf-8", "replace")
            data = json.loads(out)
            if isinstance(data, dict):
                data["_fetched_at"] = int(time.time())
                tmp = f"{cache_path}.{os.getpid()}.tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(data, f)
                os.replace(tmp, cache_path)
                return data
        except Exception:
            return None
    else:
        helper = (
            "import json,os,subprocess,sys,time;"
            "p=sys.argv[1];"
            "out=subprocess.check_output(['agy','-p','/quota','--output-format','json'],stderr=subprocess.DEVNULL,timeout=12).decode('utf-8','replace');"
            "d=json.loads(out);"
            "d['_fetched_at']=int(time.time());"
            "t=f'{p}.{os.getpid()}.tmp';"
            "open(t,'w',encoding='utf-8').write(json.dumps(d));"
            "os.replace(t,p)"
        )
        try:
            subprocess.Popen(
                [sys.executable, "-c", helper, cache_path],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                env=env,
            )
        except Exception:
            pass
    return None


def read_agy_quota(model, now, allow_sync_fetch=False):
    cache_path = os.path.join(HOME, ".roamtty", "quota-agy.json")
    lock_path = os.path.join(HOME, ".roamtty", "quota-agy.lock")
    cached = None
    fetched_at = 0
    if os.path.isfile(cache_path):
        try:
            cached = json.load(open(cache_path, "r", encoding="utf-8", errors="replace"))
            fetched_at = safe_int(cached.get("_fetched_at")) if isinstance(cached, dict) else 0
            if fetched_at == 0:
                fetched_at = int(os.path.getmtime(cache_path))
        except Exception:
            cached = None

    if cached is not None and (now - fetched_at) < 180:
        return parse_agy_quota_payload(cached, model, now)

    if cached is not None:
        # Serve cached non-expired quota immediately and refresh asynchronously in the background.
        refresh_agy_quota_file(cache_path, lock_path, sync=False)
        return parse_agy_quota_payload(cached, model, now)

    # No cache yet: fetch synchronously once for active session view, or asynchronously for host overview.
    fresh = refresh_agy_quota_file(cache_path, lock_path, sync=allow_sync_fetch)
    return parse_agy_quota_payload(fresh, model, now) if fresh else (None, None)


def parse_agy_file(path, cutoff=None):
    raw_model = ""
    s_in = s_out = s_cr = 0
    latest_ctx = None
    has_in_range = False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"PLANNER_RESPONSE"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "PLANNER_RESPONSE":
                    continue
                ts = parse_iso_ts(o.get("created_at"))
                if cutoff is not None and ts is not None and ts < cutoff:
                    continue
                inp = safe_int(o.get("input_tokens"))
                out = safe_int(o.get("output_tokens"))
                cr = safe_int(o.get("cache_read_tokens"))
                if inp == 0 and out == 0 and cr == 0:
                    continue
                has_in_range = True
                if isinstance(o.get("model"), str) and o["model"]:
                    raw_model = o["model"]
                s_in += inp
                s_out += out
                s_cr += cr
                latest_ctx = (inp + cr, cr, 0, inp)
    except OSError:
        return None
    if not has_in_range:
        return None
    clean_model, effort = split_model_effort(raw_model)
    if not effort and cutoff is None:
        effort = agy_settings_effort()
    ctx_used, ctx_cr, ctx_cc, ctx_turn = latest_ctx
    return {
        "model": clean_model or raw_model,
        "effort": effort,
        "ctx_used": ctx_used,
        "ctx_limit": infer_agy_ctx_limit(clean_model or raw_model, ctx_used),
        "ctx_cache_read": ctx_cr,
        "ctx_cache_create": ctx_cc,
        "ctx_turn": ctx_turn,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": 0,
    }


def find_agy_transcript(transcript, sid, cwd):
    if transcript and os.path.isfile(transcript):
        return transcript
    brain = os.path.join(HOME, ".gemini", "antigravity-cli", "brain")
    if sid:
        p = os.path.join(brain, sid, ".system_generated", "logs", "transcript.jsonl")
        if os.path.isfile(p):
            return p
    target = norm_path(cwd)
    last_conv = os.path.join(HOME, ".gemini", "antigravity-cli", "cache", "last_conversations.json")
    if target and os.path.isfile(last_conv):
        try:
            mapping = json.load(open(last_conv, "r", encoding="utf-8", errors="replace"))
            if isinstance(mapping, dict):
                for k, cid in mapping.items():
                    if norm_path(k) == target and isinstance(cid, str):
                        p = os.path.join(brain, cid, ".system_generated", "logs", "transcript.jsonl")
                        if os.path.isfile(p):
                            return p
        except Exception:
            pass
    hits = glob.glob(os.path.join(brain, "*", ".system_generated", "logs", "transcript.jsonl"))
    if hits:
        newest = max(hits, key=os.path.getmtime)
        if time.time() - os.path.getmtime(newest) < 900:
            return newest
    return None


def grok_model_ctx_cache():
    out = {}
    p = os.path.join(HOME, ".grok", "models_cache.json")
    try:
        data = json.load(open(p, "r", encoding="utf-8", errors="replace"))
        for k, v in (data.get("models") or {}).items():
            info = v.get("info", v) if isinstance(v, dict) else {}
            cw = safe_int(info.get("context_window"))
            if cw > 0:
                out[k] = cw
    except Exception:
        pass
    return out


def parse_grok_file(path, cutoff=None, model_cache=None):
    model = ""
    effort = ""
    summary = os.path.join(os.path.dirname(path), "summary.json")
    if os.path.isfile(summary):
        try:
            s = json.load(open(summary, "r", encoding="utf-8", errors="replace"))
            model = s.get("current_model_id") or ""
            effort = normalize_effort(s.get("reasoning_effort"))
        except Exception:
            pass
    s_in = s_out = s_cr = s_cc = 0
    latest_single = None
    has_in_range = False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"turn_completed"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                u = ((o.get("params") or {}).get("update") or {})
                if u.get("sessionUpdate") != "turn_completed":
                    continue
                ts = parse_iso_ts(o.get("timestamp"))
                if cutoff is not None and ts is not None and ts < cutoff:
                    continue
                usage = u.get("usage")
                if not isinstance(usage, dict):
                    continue
                inp = safe_int(usage.get("inputTokens"))
                cr = min(inp, safe_int(usage.get("cachedReadTokens")))
                cc = safe_int(usage.get("cacheCreationTokens"))
                out = safe_int(usage.get("outputTokens"))
                if inp == 0 and out == 0 and cr == 0 and cc == 0:
                    continue
                has_in_range = True
                s_in += max(0, inp - cr)
                s_cr += cr
                s_cc += cc
                s_out += out
                calls = safe_int(usage.get("modelCalls"))
                if calls == 1:
                    latest_single = (inp, cr, cc, max(0, inp - cr))
                else:
                    latest_single = None
    except OSError:
        return None
    if not has_in_range:
        if cutoff is None and (model or effort):
            return {
                "model": model,
                "effort": effort,
                "sess_input": 0,
                "sess_output": 0,
                "sess_cache_read": 0,
                "sess_cache_create": 0,
            }
        return None
    res = {
        "model": model,
        "effort": effort,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": s_cc,
    }
    ctx_limit = (model_cache or {}).get(model, 0)
    if latest_single and ctx_limit > 0:
        res["ctx_used"] = latest_single[0]
        res["ctx_limit"] = ctx_limit
        res["ctx_cache_read"] = latest_single[1]
        res["ctx_cache_create"] = latest_single[2]
        res["ctx_turn"] = latest_single[3]
    return res


def find_grok_transcript(transcript, sid, cwd):
    if transcript and os.path.isfile(transcript):
        return transcript
    base = os.path.join(HOME, ".grok", "sessions")
    if not os.path.isdir(base):
        return None
    if sid:
        hits = glob.glob(os.path.join(base, "*", sid, "updates.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime)
    target = norm_path(cwd)
    if target:
        enc = urllib.parse.quote(target, safe="")
        folder = os.path.join(base, enc)
        if os.path.isdir(folder):
            hits = glob.glob(os.path.join(folder, "*", "updates.jsonl"))
            if hits:
                return max(hits, key=os.path.getmtime)
    return None


def run_session(agent_arg, tmux_session, cwd_arg):
    now = time.time()
    t_agent, t_sid, t_transcript, t_cwd = tmux_meta(tmux_session)
    agent = (t_agent or agent_arg or "").strip().lower()
    cwd = t_cwd or cwd_arg or ""
    if agent not in ("claude", "codex", "agy", "grok"):
        return

    data = None
    if agent == "claude":
        p = find_claude_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_claude_file(p)
        q5h, q7d = read_claude_quota(now)
        if data is None and (q5h or q7d):
            data = {}
        if data is not None:
            if q5h:
                data["q5h"] = q5h
            if q7d:
                data["q7d"] = q7d
    elif agent == "codex":
        p = find_codex_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_codex_file(p, model_cache=codex_model_ctx_cache())
        if data is None or not data.get("q5h") or not data.get("q7d"):
            fb5, fb7 = latest_codex_account_quotas(exclude_path=p)
            if fb5 or fb7:
                if data is None:
                    data = {}
                if not data.get("q5h") and fb5:
                    data["q5h"] = fb5
                if not data.get("q7d") and fb7:
                    data["q7d"] = fb7
    elif agent == "agy":
        p = find_agy_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_agy_file(p)
        q5h, q7d = read_agy_quota((data or {}).get("model", ""), now, allow_sync_fetch=True)
        if data is None and (q5h or q7d):
            data = {}
        if data is not None:
            if q5h:
                data["q5h"] = q5h
            if q7d:
                data["q7d"] = q7d
    elif agent == "grok":
        p = find_grok_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_grok_file(p, model_cache=grok_model_ctx_cache())

    print(f"agent={agent}")
    if not data:
        return
    if data.get("model"):
        print(f"model={data['model']}")
    if data.get("effort"):
        print(f"effort={data['effort']}")
    for k in ("ctx_used", "ctx_limit", "ctx_cache_read", "ctx_cache_create", "ctx_turn",
              "sess_input", "sess_output", "sess_cache_read", "sess_cache_create"):
        v = data.get(k)
        if v is not None:
            print(f"{k}={int(v)}")
    q5h = data.get("q5h")
    if q5h:
        print(f"q5h_rem={q5h[0]:.1f}")
        if q5h[1]:
            print(f"q5h_reset={int(q5h[1])}")
    q7d = data.get("q7d")
    if q7d:
        print(f"q7d_rem={q7d[0]:.1f}")
        if q7d[1]:
            print(f"q7d_reset={int(q7d[1])}")


def run_host(rng):
    now = time.time()
    if rng == "7d":
        cutoff = now - 7 * 86400
    elif rng == "30d":
        cutoff = now - 30 * 86400
    else:
        rng = "today"
        local = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        cutoff = local.timestamp()

    print(f"range={rng}")
    rows = []

    def aggregate(agent_id, paths, parser, extra_quotas=None):
        sessions = 0
        t_in = t_out = t_cr = t_cc = 0
        best_rl_ts = -1.0
        best_q5h = None
        best_q7d = None
        latest_model = ""
        latest_mtime = -1.0
        for p in paths:
            try:
                mt = os.path.getmtime(p)
                if mt < cutoff:
                    continue
            except OSError:
                continue
            r = parser(p)
            if not r:
                continue
            if r.get("rl_ts", 0) > best_rl_ts and (r.get("q5h") or r.get("q7d")):
                best_rl_ts = r.get("rl_ts", 0)
                if r.get("q5h"):
                    best_q5h = r["q5h"]
                if r.get("q7d"):
                    best_q7d = r["q7d"]
            if r.get("rate_only"):
                continue
            tot = r["sess_input"] + r["sess_output"] + r["sess_cache_read"] + r["sess_cache_create"]
            if tot <= 0:
                continue
            sessions += 1
            t_in += r["sess_input"]
            t_out += r["sess_output"]
            t_cr += r["sess_cache_read"]
            t_cc += r["sess_cache_create"]
            if mt > latest_mtime and r.get("model"):
                latest_mtime = mt
                latest_model = r["model"]
        if extra_quotas is not None:
            eq5, eq7 = extra_quotas(latest_model, sessions > 0)
            if best_q5h is None and eq5:
                best_q5h = eq5
            if best_q7d is None and eq7:
                best_q7d = eq7
        if sessions > 0 or best_q5h or best_q7d:
            rows.append((agent_id, sessions, t_in, t_out, t_cr, t_cc, best_q5h, best_q7d))

    # 1. Claude Code
    claude_paths = glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl"))
    aggregate(
        "claude",
        claude_paths,
        lambda p: parse_claude_file(p, cutoff=cutoff),
        extra_quotas=lambda _m, _has: read_claude_quota(now),
    )

    # 2. Codex (also inspect up to 15 newest rollouts for latest non-expired 5h & 7d quotas)
    codex_paths = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
    codex_paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    codex_scan = []
    for i, p in enumerate(codex_paths):
        try:
            mt = os.path.getmtime(p)
        except OSError:
            continue
        if mt >= cutoff or i < 15:
            codex_scan.append(p)
    c_sess = c_in = c_out = c_cr = c_cc = 0
    c_q5h = c_q7d = None
    c_q5h_ts = c_q7d_ts = -1.0
    for p in codex_scan:
        r = parse_codex_file(p, cutoff=cutoff)
        if not r:
            continue
        ts = r.get("rl_ts", 0)
        if r.get("q5h") and ts >= c_q5h_ts:
            c_q5h, c_q5h_ts = r["q5h"], ts
        if r.get("q7d") and ts >= c_q7d_ts:
            c_q7d, c_q7d_ts = r["q7d"], ts
        if r.get("rate_only"):
            continue
        if r["sess_input"] + r["sess_output"] + r["sess_cache_read"] + r["sess_cache_create"] > 0:
            c_sess += 1
            c_in += r["sess_input"]
            c_out += r["sess_output"]
            c_cr += r["sess_cache_read"]
            c_cc += r["sess_cache_create"]
    if c_sess > 0 or c_q5h or c_q7d:
        rows.append(("codex", c_sess, c_in, c_out, c_cr, c_cc, c_q5h, c_q7d))

    # 3. Antigravity CLI
    agy_paths = glob.glob(os.path.join(HOME, ".gemini", "antigravity-cli", "brain", "*", ".system_generated", "logs", "transcript.jsonl"))
    aggregate(
        "agy",
        agy_paths,
        lambda p: parse_agy_file(p, cutoff=cutoff),
        extra_quotas=lambda latest_m, has_s: read_agy_quota(latest_m, now, allow_sync_fetch=False) if (has_s or os.path.isfile(os.path.join(HOME, ".roamtty", "quota-agy.json"))) else (None, None),
    )

    # 4. Grok
    grok_paths = glob.glob(os.path.join(HOME, ".grok", "sessions", "*", "*", "updates.jsonl"))
    aggregate("grok", grok_paths, lambda p: parse_grok_file(p, cutoff=cutoff))

    rows.sort(key=lambda x: x[2] + x[3] + x[4] + x[5], reverse=True)
    for aid, sess, t_in, t_out, t_cr, t_cc, q5h, q7d in rows:
        q5r = f"{q5h[0]:.1f}" if q5h else ""
        q5t = str(int(q5h[1])) if (q5h and q5h[1]) else ""
        q7r = f"{q7d[0]:.1f}" if q7d else ""
        q7t = str(int(q7d[1])) if (q7d and q7d[1]) else ""
        print(f"agent={aid}|{sess}|{t_in}|{t_out}|{t_cr}|{t_cc}|{q5r}|{q5t}|{q7r}|{q7t}")


def main():
    if len(sys.argv) < 2:
        return
    mode = sys.argv[1]
    if mode == "session":
        agent = sys.argv[2] if len(sys.argv) > 2 else ""
        tmux_s = sys.argv[3] if len(sys.argv) > 3 else ""
        cwd = sys.argv[4] if len(sys.argv) > 4 else ""
        run_session(agent, tmux_s, cwd)
    elif mode == "host":
        rng = sys.argv[2] if len(sys.argv) > 2 else "today"
        run_host(rng)


if __name__ == "__main__":
    main()
