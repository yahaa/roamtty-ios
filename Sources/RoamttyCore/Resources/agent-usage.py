#!/usr/bin/env python3
"""Roamtty: read-only local token, context-window and rate-limit collector for AI coding CLIs.

Usage:
  python3 - session <agent> [tmux_session] [cwd]
  python3 - host <today|7d|30d>

Reads only local CLI session transcripts and model metadata caches (never credentials or auth files).
Prints key=value lines; exits 0 even when no data is found.
"""
import datetime
import glob
import json
import os
import subprocess
import sys
import time
import urllib.parse

HOME = os.path.expanduser("~")


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


def tmux_meta(tmux_session):
    if not tmux_session:
        return "", "", "", ""
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
    fmt = "#{@roamtty_agent}\t#{@roamtty_session}\t#{@roamtty_transcript}\t#{pane_current_path}"
    try:
        out = subprocess.check_output(
            ["tmux", "-u", "display-message", "-p", "-t", f"={tmux_session}:", fmt],
            stderr=subprocess.DEVNULL,
            timeout=2,
            env=env,
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


def parse_claude_file(path, cutoff=None):
    by_id = {}
    ordered_keys = []
    latest_model = ""
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
                    # Streaming frames share message.id: keep the highest output count.
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
    return {
        "model": latest_model,
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
    candidates = glob.glob(os.path.join(base, "*", "*.jsonl"))
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in candidates[:40]:
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for _ in range(12):
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
        if 180 <= mins <= 420 and q5h is None:
            q5h = entry
        elif 8000 <= mins <= 12000 and q7d is None:
            q7d = entry
    return q5h, q7d


def parse_codex_file(path, cutoff=None, model_cache=None):
    now = time.time()
    model = ""
    file_cwd = ""
    last_token_count = None
    last_rl = None
    last_rl_ts = 0.0
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
                            if isinstance(pl.get("rate_limits"), dict):
                                last_rl = pl["rate_limits"]
                                last_rl_ts = ts
                    except Exception:
                        pass
    except OSError:
        return None

    q5h, q7d = extract_codex_rate_limits(last_rl, now)
    if cutoff is not None:
        if rec_count > 0:
            return {
                "model": model,
                "cwd": file_cwd,
                "sess_input": rec_in,
                "sess_output": rec_out,
                "sess_cache_read": rec_cr,
                "sess_cache_create": rec_cc,
                "q5h": q5h,
                "q7d": q7d,
                "rl_ts": last_rl_ts,
            }
        # Fallback for older Codex rollouts without token_usage_record: use total if session started in range.
        if last_token_count and (first_ts is None or first_ts >= cutoff):
            tot = last_token_count[1].get("total_token_usage") or {}
            inp = safe_int(tot.get("input_tokens"))
            cr = min(inp, safe_int(tot.get("cached_input_tokens")))
            cc = safe_int(tot.get("cache_write_input_tokens"))
            out = safe_int(tot.get("output_tokens"))
            if inp or out or cr or cc:
                return {
                    "model": model,
                    "cwd": file_cwd,
                    "sess_input": max(0, inp - cr),
                    "sess_output": out,
                    "sess_cache_read": cr,
                    "sess_cache_create": cc,
                    "q5h": q5h,
                    "q7d": q7d,
                    "rl_ts": last_rl_ts,
                }
        return {"rate_only": True, "q5h": q5h, "q7d": q7d, "rl_ts": last_rl_ts} if (q5h or q7d) else None

    if not last_token_count and rec_count == 0 and not (q5h or q7d):
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

    res = {
        "model": model,
        "cwd": file_cwd,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": s_cc,
        "q5h": q5h,
        "q7d": q7d,
    }
    if last_inp > 0 and ctx_limit > 0:
        res["ctx_used"] = last_inp
        res["ctx_limit"] = ctx_limit
        res["ctx_cache_read"] = last_cr
        res["ctx_cache_create"] = 0
        res["ctx_turn"] = max(0, last_inp - last_cr)
    return res


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


def parse_agy_file(path, cutoff=None):
    model = ""
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
                    model = o["model"]
                s_in += inp
                s_out += out
                s_cr += cr
                latest_ctx = (inp + cr, cr, 0, inp)
    except OSError:
        return None
    if not has_in_range:
        return None
    ctx_used, ctx_cr, ctx_cc, ctx_turn = latest_ctx
    return {
        "model": model,
        "ctx_used": ctx_used,
        "ctx_limit": infer_agy_ctx_limit(model, ctx_used),
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
    summary = os.path.join(os.path.dirname(path), "summary.json")
    if os.path.isfile(summary):
        try:
            s = json.load(open(summary, "r", encoding="utf-8", errors="replace"))
            model = s.get("current_model_id") or ""
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
        return None
    res = {
        "model": model,
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
    elif agent == "codex":
        p = find_codex_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_codex_file(p, model_cache=codex_model_ctx_cache())
    elif agent == "agy":
        p = find_agy_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_agy_file(p)
    elif agent == "grok":
        p = find_grok_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_grok_file(p, model_cache=grok_model_ctx_cache())

    print(f"agent={agent}")
    if not data:
        return
    if data.get("model"):
        print(f"model={data['model']}")
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

    def aggregate(agent_id, paths, parser):
        sessions = 0
        t_in = t_out = t_cr = t_cc = 0
        best_rl_ts = -1.0
        best_q5h = None
        best_q7d = None
        for p in paths:
            try:
                if os.path.getmtime(p) < cutoff:
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
        if sessions > 0 or best_q5h or best_q7d:
            rows.append((agent_id, sessions, t_in, t_out, t_cr, t_cc, best_q5h, best_q7d))

    # 1. Claude Code
    claude_paths = glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl"))
    aggregate("claude", claude_paths, lambda p: parse_claude_file(p, cutoff=cutoff))

    # 2. Codex (also check newest files for latest non-expired rate_limits even if today has 0 tokens)
    codex_paths = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
    codex_paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    # Include the 3 newest rollouts in rate-limit check even if older than today's cutoff.
    codex_scan = []
    seen_codex = set()
    for i, p in enumerate(codex_paths):
        try:
            mt = os.path.getmtime(p)
        except OSError:
            continue
        if mt >= cutoff or i < 3:
            codex_scan.append(p)
            seen_codex.add(p)
    # Run custom aggregation for codex so rate-limits from recent files still populate.
    c_sess = c_in = c_out = c_cr = c_cc = 0
    c_rl_ts = -1.0
    c_q5h = c_q7d = None
    for p in codex_scan:
        r = parse_codex_file(p, cutoff=cutoff)
        if not r:
            continue
        if r.get("rl_ts", 0) > c_rl_ts and (r.get("q5h") or r.get("q7d")):
            c_rl_ts = r.get("rl_ts", 0)
            if r.get("q5h"):
                c_q5h = r["q5h"]
            if r.get("q7d"):
                c_q7d = r["q7d"]
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
    aggregate("agy", agy_paths, lambda p: parse_agy_file(p, cutoff=cutoff))

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
