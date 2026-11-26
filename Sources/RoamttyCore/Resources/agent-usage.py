#!/usr/bin/env python3
"""Roamtty: read-only local token, context-window, reasoning-effort and quota collector for AI coding CLIs.

Usage:
  python3 - session <agent> [tmux_session] [cwd] [--fetch-agy-quota]
  python3 - host <today|7d|30d> [--fetch-agy-quota]

Reads only local CLI session transcripts and non-secret settings/caches by default (never credentials
or auth files); runs `agy -p /quota --output-format json` only when `--fetch-agy-quota` is explicitly
requested by the user. Prints key=value lines; exits 0 even when no data is found.
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
        return "", "", "", "", 0
    fmt = "#{@roamtty_agent}\t#{@roamtty_session}\t#{@roamtty_transcript}\t#{pane_current_path}\t#{pane_pid}"
    try:
        out = subprocess.check_output(
            ["tmux", "-u", "display-message", "-p", "-t", f"={tmux_session}:", fmt],
            stderr=subprocess.DEVNULL,
            timeout=2,
            env=cmd_env(),
        ).decode("utf-8", "replace").rstrip("\r\n")
        parts = out.split("\t")
        while len(parts) < 5:
            parts.append("")
        agent_field = parts[0].split("|")[2] if parts[0].count("|") >= 2 else ""
        return agent_field.strip(), parts[1].strip(), parts[2].strip(), parts[3].strip(), safe_int(parts[4].strip())
    except Exception:
        return "", "", "", "", 0


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
    first_ctx = None
    max_ctx_seen = 0
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
                if '"compact_boundary"' in line or '"microcompact_boundary"' in line:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") == "system" and o.get("subtype") in ("compact_boundary", "microcompact_boundary"):
                        cm = o.get("compactMetadata") or o.get("microcompactMetadata")
                        if isinstance(cm, dict):
                            pre = safe_int(cm.get("preTokens"))
                            if pre > max_ctx_seen:
                                max_ctx_seen = pre
                            post = safe_int(cm.get("postTokens"))
                            if post > 0:
                                latest_ctx = (post, 0, 0, 0)
                            elif o.get("subtype") == "compact_boundary" and first_ctx is not None and (pre == 0 or first_ctx < pre):
                                latest_ctx = (first_ctx, 0, 0, 0)
                    continue
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
                    updated = True
                elif out >= prev[1]:
                    by_id[mid] = (inp, out, cr, cc, model)
                    updated = True
                else:
                    updated = False
                if updated:
                    latest_model = model
                    ctx_u = inp + cr + cc
                    if first_ctx is None and ctx_u > 0:
                        first_ctx = ctx_u
                    if ctx_u > max_ctx_seen:
                        max_ctx_seen = ctx_u
                    latest_ctx = (ctx_u, cr, cc, inp)
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
        if not latest_model:
            latest_model = model
    ctx_used, ctx_cr, ctx_cc, ctx_turn = latest_ctx
    ctx_limit = infer_claude_ctx_limit(latest_model, max(ctx_used, max_ctx_seen))
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
    q_meta = {
        "q5h": best_q5h,
        "q5h_ts": best_q5h_ts,
        "q5h_default": best_q5h_default,
        "q7d": best_q7d,
        "q7d_ts": best_q7d_ts,
        "q7d_default": best_q7d_default,
        "rl_ts": rl_ts,
    }
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
                **q_meta,
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
                    **q_meta,
                }
        return {"rate_only": True, **q_meta} if (best_q5h or best_q7d) else None

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
    last_tot = safe_int(last_u.get("total_tokens"))
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
        **q_meta,
    }
    if last_inp > 0 and ctx_limit > 0:
        res["ctx_used"] = last_inp
        res["ctx_limit"] = ctx_limit
        res["ctx_cache_read"] = last_cr
        res["ctx_cache_create"] = 0
        res["ctx_turn"] = max(0, last_inp - last_cr)
    elif last_tot > 0 and ctx_limit > 0:
        # After /compact or auto-compaction, Codex reports retained context in total_tokens with input_tokens=0.
        res["ctx_used"] = last_tot
        res["ctx_limit"] = ctx_limit
        res["ctx_cache_read"] = 0
        res["ctx_cache_create"] = 0
        res["ctx_turn"] = 0
    return res


def pick_better_codex_quota(cur, cur_ts, cur_def, cand, cand_ts, cand_def):
    if not cand:
        return cur, cur_ts, cur_def
    if not cur:
        return cand, cand_ts, cand_def
    if cand_def and not cur_def:
        return cand, cand_ts, cand_def
    if cand_def == cur_def and cand_ts > cur_ts:
        return cand, cand_ts, cand_def
    return cur, cur_ts, cur_def


def latest_codex_account_quotas(exclude_path=None):
    base = os.path.join(HOME, ".codex", "sessions")
    if not os.path.isdir(base):
        return (None, -1.0, False), (None, -1.0, False)
    paths = glob.glob(os.path.join(base, "*", "*", "*", "*.jsonl"))
    paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    q5h, q5h_ts, q5h_def = None, -1.0, False
    q7d, q7d_ts, q7d_def = None, -1.0, False
    for p in paths[:15]:
        if exclude_path and p == exclude_path:
            continue
        r = parse_codex_file(p)
        if not r:
            continue
        q5h, q5h_ts, q5h_def = pick_better_codex_quota(
            q5h, q5h_ts, q5h_def, r.get("q5h"), r.get("q5h_ts", -1.0), r.get("q5h_default", False)
        )
        q7d, q7d_ts, q7d_def = pick_better_codex_quota(
            q7d, q7d_ts, q7d_def, r.get("q7d"), r.get("q7d_ts", -1.0), r.get("q7d_default", False)
        )
    return (q5h, q5h_ts, q5h_def), (q7d, q7d_ts, q7d_def)


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


def agy_settings_model_info():
    p = os.path.join(HOME, ".gemini", "antigravity-cli", "settings.json")
    try:
        cfg = json.load(open(p, "r", encoding="utf-8", errors="replace"))
        if isinstance(cfg, dict):
            raw = cfg.get("model") or ""
            if isinstance(raw, str):
                return split_model_effort(raw)
    except Exception:
        pass
    return "", ""


def agy_settings_effort():
    return agy_settings_model_info()[1]


def agy_settings_model():
    return agy_settings_model_info()[0]


def _extract_agy_bucket(b, now):
    if not isinstance(b, dict):
        return None
    frac = safe_float(b.get("remaining_fraction"))
    if frac is None:
        return None
    rem = max(0.0, min(100.0, frac * 100.0))
    resets = parse_iso_ts(b.get("reset_time"))
    # Untouched 100% buckets report Unix epoch ("1970-01-01T00:00:00Z"); keep them with no reset countdown.
    if resets is not None and resets <= 86400:
        resets = None
    if resets is not None and resets < now - 60:
        return None
    return (rem, int(resets) if resets else None)


def parse_agy_quota_payload(data, model, now):
    if not isinstance(data, dict):
        return None, None
    eff_model = model or (data.get("model") if isinstance(data.get("model"), str) else "") or agy_settings_model()
    m = (eff_model or "").lower()
    want_3p = ("claude" in m or "gpt" in m or "opus" in m or "sonnet" in m)

    groups = ((data.get("command") or {}).get("data") or {}).get("groups")
    if not isinstance(groups, list):
        groups = data.get("groups")
    if isinstance(groups, list) and groups:
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
            entry = _extract_agy_bucket(b, now)
            if entry is None:
                continue
            win = (b.get("window") or "").lower()
            if win == "5h" and q5h is None:
                q5h = entry
            elif win == "weekly" and q7d is None:
                q7d = entry
        return q5h, q7d

    quota_map = data.get("quota")
    if isinstance(quota_map, dict) and quota_map:
        prefixes = ("3p-", "gemini-") if want_3p else ("gemini-", "3p-")
        for prefix in prefixes:
            q5h = _extract_agy_bucket(quota_map.get(f"{prefix}5h"), now)
            q7d = _extract_agy_bucket(quota_map.get(f"{prefix}weekly"), now)
            if q5h is not None or q7d is not None:
                return q5h, q7d
    return None, None


def fetch_agy_quota_file(cache_path):
    if os.environ.get("ROAMTTY_NO_LIVE_QUOTA") == "1":
        return None
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        out = subprocess.check_output(
            ["agy", "-p", "/quota", "--output-format", "json"],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=18,
            env=cmd_env(),
        ).decode("utf-8", "replace")
        data = json.loads(out)
        now = time.time()
        if isinstance(data, dict) and (
            parse_agy_quota_payload(data, "gemini", now) != (None, None)
            or parse_agy_quota_payload(data, "claude", now) != (None, None)
        ):
            data["_fetched_at"] = int(now)
            tmp = f"{cache_path}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, cache_path)
            return data
    except Exception:
        return None
    return None


def read_agy_quota(model, now, fetch_live=False):
    cache_path = os.path.join(HOME, ".roamtty", "quota-agy.json")
    if fetch_live:
        fresh = fetch_agy_quota_file(cache_path)
        if fresh is not None:
            return parse_agy_quota_payload(fresh, model, now)
    if os.path.isfile(cache_path):
        try:
            cached = json.load(open(cache_path, "r", encoding="utf-8", errors="replace"))
            if isinstance(cached, dict):
                return parse_agy_quota_payload(cached, model, now)
        except Exception:
            pass
    return None, None


def parse_agy_file(path, cutoff=None):
    raw_model = ""
    s_in = s_out = s_cr = 0
    latest_ctx = None
    first_ctx = None
    max_ctx_seen = 0
    has_in_range = False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"PLANNER_RESPONSE"' not in line and '"CHECKPOINT"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                typ = o.get("type")
                if typ == "PLANNER_RESPONSE":
                    ts = parse_iso_ts(o.get("created_at"))
                    inp = safe_int(o.get("input_tokens"))
                    out = safe_int(o.get("output_tokens"))
                    cr = safe_int(o.get("cache_read_tokens"))
                    if inp == 0 and out == 0 and cr == 0:
                        continue
                    ctx_u = inp + cr
                    if first_ctx is None and ctx_u > 0:
                        first_ctx = ctx_u
                    if ctx_u > max_ctx_seen:
                        max_ctx_seen = ctx_u
                    if isinstance(o.get("model"), str) and o["model"]:
                        raw_model = o["model"]
                    if cutoff is None or ts is None or ts >= cutoff:
                        has_in_range = True
                        s_in += inp
                        s_out += out
                        s_cr += cr
                        latest_ctx = (ctx_u, cr, 0, inp)
                elif typ == "CHECKPOINT":
                    ts = parse_iso_ts(o.get("created_at"))
                    inp = safe_int(o.get("input_tokens"))
                    out = safe_int(o.get("output_tokens"))
                    cr = safe_int(o.get("cache_read_tokens"))
                    if inp + cr > max_ctx_seen:
                        max_ctx_seen = inp + cr
                    if (cutoff is None or ts is None or ts >= cutoff) and (inp or out or cr):
                        has_in_range = True
                        s_in += inp
                        s_out += out
                        s_cr += cr
                    if cutoff is None:
                        # Compaction replaces prior history with base system prompt + checkpoint summary until next turn.
                        summary_tok = out if out > 0 else (len(o.get("content") or "") // 4)
                        base_tok = first_ctx or 0
                        post_ctx = base_tok + summary_tok
                        if latest_ctx is not None and post_ctx >= latest_ctx[0] and 0 < summary_tok < latest_ctx[0]:
                            post_ctx = summary_tok
                        if post_ctx > 0:
                            latest_ctx = (post_ctx, 0, 0, 0)
    except OSError:
        return None
    if not has_in_range:
        return None
    clean_model, effort = split_model_effort(raw_model)
    if not effort and cutoff is None:
        effort = agy_settings_effort()
    res = {
        "model": clean_model or raw_model,
        "effort": effort,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": 0,
    }
    if latest_ctx is not None:
        ctx_used, ctx_cr, ctx_cc, ctx_turn = latest_ctx
        res["ctx_used"] = ctx_used
        res["ctx_limit"] = infer_agy_ctx_limit(clean_model or raw_model, max(ctx_used, max_ctx_seen))
        res["ctx_cache_read"] = ctx_cr
        res["ctx_cache_create"] = ctx_cc
        res["ctx_turn"] = ctx_turn
    return res


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
            wins = sorted({safe_int(x) for x in (info.get("context_windows") or []) if safe_int(x) > 0})
            if cw > 0 and cw not in wins:
                wins.append(cw)
                wins.sort()
            if cw > 0 or wins:
                out[k] = (cw or wins[0], wins or [cw])
    except Exception:
        pass
    return out


def grok_active_session_for_pid(pane_pid):
    if pane_pid <= 0:
        return ""
    p = os.path.join(HOME, ".grok", "active_sessions.json")
    if not os.path.isfile(p):
        return ""
    try:
        entries = json.load(open(p, "r", encoding="utf-8", errors="replace"))
    except Exception:
        return ""
    if not isinstance(entries, list) or not entries:
        return ""
    ppids = {}
    try:
        out = subprocess.check_output(["ps", "-eo", "pid=,ppid="], stderr=subprocess.DEVNULL, timeout=2).decode("utf-8", "replace")
        for ln in out.splitlines():
            parts = ln.split()
            if len(parts) == 2:
                pid_i, ppid_i = safe_int(parts[0]), safe_int(parts[1])
                if pid_i > 0:
                    ppids[pid_i] = ppid_i
    except Exception:
        return ""
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        sid = entry.get("session_id") or ""
        cur = safe_int(entry.get("pid"))
        if not sid or cur <= 0:
            continue
        for _ in range(8):
            if cur == pane_pid:
                return sid
            nxt = ppids.get(cur, 0)
            if nxt <= 1 or nxt == cur:
                break
            cur = nxt
    return ""


def parse_grok_file(path, cutoff=None, model_cache=None):
    session_dir = path if os.path.isdir(path) else os.path.dirname(path)
    updates_path = os.path.join(session_dir, "updates.jsonl") if os.path.isdir(path) or os.path.basename(path) != "updates.jsonl" else path
    model = ""
    effort = ""
    summary_ctx_win = 0
    summary = os.path.join(session_dir, "summary.json")
    if os.path.isfile(summary):
        try:
            s = json.load(open(summary, "r", encoding="utf-8", errors="replace"))
            model = s.get("current_model_id") or ""
            effort = normalize_effort(s.get("reasoning_effort"))
            summary_ctx_win = safe_int(s.get("context_window"))
        except Exception:
            pass
    sig_ctx_used = sig_ctx_win = 0
    sig_mtime = 0.0
    if cutoff is None:
        signals = os.path.join(session_dir, "signals.json")
        if os.path.isfile(signals):
            try:
                sig_mtime = os.path.getmtime(signals)
                sig = json.load(open(signals, "r", encoding="utf-8", errors="replace"))
                sig_ctx_used = safe_int(sig.get("contextTokensUsed"))
                sig_ctx_win = safe_int(sig.get("contextWindowTokens"))
                if not model:
                    model = sig.get("primaryModelId") or ""
            except Exception:
                pass
    s_in = s_out = s_cr = s_cc = 0
    latest_single = None
    last_meta_tokens = 0
    updates_mtime = 0.0
    has_in_range = False
    if os.path.isfile(updates_path):
        try:
            updates_mtime = os.path.getmtime(updates_path)
            with open(updates_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    has_tc = '"turn_completed"' in line
                    has_meta = cutoff is None and '"totalTokens"' in line
                    if not has_tc and not has_meta:
                        continue
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    params = o.get("params") or {}
                    if has_meta:
                        mtok = safe_int((params.get("_meta") or {}).get("totalTokens"))
                        if mtok > 0:
                            last_meta_tokens = mtok
                    if not has_tc:
                        continue
                    u = params.get("update") or {}
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
            if cutoff is not None:
                return None

    ctx_used = 0
    ctx_limit = 0
    if cutoff is None:
        if sig_ctx_used > 0 and (last_meta_tokens == 0 or sig_mtime >= updates_mtime - 2.0):
            ctx_used = sig_ctx_used
        elif last_meta_tokens > 0:
            ctx_used = last_meta_tokens
        elif latest_single:
            ctx_used = latest_single[0]

        cache_entry = (model_cache or {}).get(model)
        if cache_entry is None and model.endswith("-build"):
            cache_entry = (model_cache or {}).get(model[:-6])
        default_cw = cache_entry[0] if isinstance(cache_entry, tuple) else safe_int(cache_entry)
        wins = cache_entry[1] if isinstance(cache_entry, tuple) else []
        ctx_limit = summary_ctx_win or sig_ctx_win or default_cw
        if ctx_limit <= 0 and ctx_used > 0 and model.lower().startswith("grok-"):
            ctx_limit = 256_000
        if ctx_used > ctx_limit > 0:
            candidates = [w for w in (wins or [256_000, 500_000]) if w >= ctx_used]
            if candidates:
                ctx_limit = candidates[0]

    if not has_in_range:
        if cutoff is None and (model or effort or ctx_used > 0):
            res = {
                "model": model,
                "effort": effort,
                "sess_input": 0,
                "sess_output": 0,
                "sess_cache_read": 0,
                "sess_cache_create": 0,
            }
            if ctx_used > 0 and ctx_limit > 0:
                res["ctx_used"] = ctx_used
                res["ctx_limit"] = ctx_limit
                res["ctx_cache_read"] = 0
                res["ctx_cache_create"] = 0
                res["ctx_turn"] = 0
            return res
        return None
    res = {
        "model": model,
        "effort": effort,
        "sess_input": s_in,
        "sess_output": s_out,
        "sess_cache_read": s_cr,
        "sess_cache_create": s_cc,
    }
    if ctx_used > 0 and ctx_limit > 0:
        res["ctx_used"] = ctx_used
        res["ctx_limit"] = ctx_limit
        if latest_single and abs(latest_single[0] - ctx_used) <= 2000:
            res["ctx_cache_read"] = latest_single[1]
            res["ctx_cache_create"] = latest_single[2]
            res["ctx_turn"] = latest_single[3]
        else:
            res["ctx_cache_read"] = 0
            res["ctx_cache_create"] = 0
            res["ctx_turn"] = 0
    return res


def find_grok_transcript(transcript, sid, cwd, pane_pid=0):
    if transcript:
        if os.path.isfile(transcript):
            return transcript
        if os.path.isdir(transcript):
            for name in ("updates.jsonl", "summary.json"):
                cand = os.path.join(transcript, name)
                if os.path.isfile(cand):
                    return cand
    base = os.path.join(HOME, ".grok", "sessions")
    if not os.path.isdir(base):
        return None
    resolved_sid = sid or grok_active_session_for_pid(pane_pid)
    if resolved_sid:
        for name in ("updates.jsonl", "summary.json"):
            hits = glob.glob(os.path.join(base, "*", resolved_sid, name))
            if hits:
                return max(hits, key=os.path.getmtime)
    target = norm_path(cwd)
    if target:
        enc = urllib.parse.quote(target, safe="")
        folder = os.path.join(base, enc)
        if os.path.isdir(folder):
            for name in ("updates.jsonl", "summary.json"):
                hits = glob.glob(os.path.join(folder, "*", name))
                if hits:
                    return max(hits, key=os.path.getmtime)
    return None


def run_session(agent_arg, tmux_session, cwd_arg, fetch_agy_quota=False):
    now = time.time()
    t_agent, t_sid, t_transcript, t_cwd, t_pid = tmux_meta(tmux_session)
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
        (fb5, fb5_ts, fb5_def), (fb7, fb7_ts, fb7_def) = latest_codex_account_quotas(exclude_path=p)
        cur5 = data.get("q5h") if data else None
        cur5_ts = data.get("q5h_ts", -1.0) if data else -1.0
        cur5_def = data.get("q5h_default", False) if data else False
        cur7 = data.get("q7d") if data else None
        cur7_ts = data.get("q7d_ts", -1.0) if data else -1.0
        cur7_def = data.get("q7d_default", False) if data else False
        best5, _, _ = pick_better_codex_quota(cur5, cur5_ts, cur5_def, fb5, fb5_ts, fb5_def)
        best7, _, _ = pick_better_codex_quota(cur7, cur7_ts, cur7_def, fb7, fb7_ts, fb7_def)
        if data is None and (best5 or best7):
            data = {}
        if data is not None:
            if best5:
                data["q5h"] = best5
            if best7:
                data["q7d"] = best7
    elif agent == "agy":
        p = find_agy_transcript(t_transcript, t_sid, cwd)
        if p:
            data = parse_agy_file(p)
        q5h, q7d = read_agy_quota((data or {}).get("model", ""), now, fetch_live=fetch_agy_quota)
        if data is None and (q5h or q7d):
            data = {}
        if data is not None:
            if q5h:
                data["q5h"] = q5h
            if q7d:
                data["q7d"] = q7d
    elif agent == "grok":
        p = find_grok_transcript(t_transcript, t_sid, cwd, pane_pid=t_pid)
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


def run_host(rng, fetch_agy_quota=False):
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
    c_q5h, c_q5h_ts, c_q5h_def = None, -1.0, False
    c_q7d, c_q7d_ts, c_q7d_def = None, -1.0, False
    for p in codex_scan:
        r = parse_codex_file(p, cutoff=cutoff)
        if not r:
            continue
        c_q5h, c_q5h_ts, c_q5h_def = pick_better_codex_quota(
            c_q5h, c_q5h_ts, c_q5h_def, r.get("q5h"), r.get("q5h_ts", -1.0), r.get("q5h_default", False)
        )
        c_q7d, c_q7d_ts, c_q7d_def = pick_better_codex_quota(
            c_q7d, c_q7d_ts, c_q7d_def, r.get("q7d"), r.get("q7d_ts", -1.0), r.get("q7d_default", False)
        )
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
    has_agy = (
        bool(agy_paths)
        or os.path.isfile(os.path.join(HOME, ".roamtty", "quota-agy.json"))
        or os.path.isfile(os.path.join(HOME, ".gemini", "antigravity-cli", "settings.json"))
    )
    aggregate(
        "agy",
        agy_paths,
        lambda p: parse_agy_file(p, cutoff=cutoff),
        extra_quotas=lambda latest_m, _has: read_agy_quota(latest_m, now, fetch_live=fetch_agy_quota) if has_agy else (None, None),
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
    raw_args = sys.argv[2:]
    fetch_agy_quota = "--fetch-agy-quota" in raw_args
    args = [a for a in raw_args if a != "--fetch-agy-quota"]
    if mode == "session":
        agent = args[0] if len(args) > 0 else ""
        tmux_s = args[1] if len(args) > 1 else ""
        cwd = args[2] if len(args) > 2 else ""
        run_session(agent, tmux_s, cwd, fetch_agy_quota=fetch_agy_quota)
    elif mode == "host":
        rng = args[0] if len(args) > 0 else "today"
        run_host(rng, fetch_agy_quota=fetch_agy_quota)


if __name__ == "__main__":
    main()
