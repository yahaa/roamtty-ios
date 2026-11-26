#!/bin/sh
# Roamtty: records what an AI coding agent is doing as options of its tmux session, which the app reads.
# Usage: agent-hook.sh <agent> <event> [tmux session], with the agent's hook JSON on stdin. Never fails the agent.
# Claude Code and Codex pass the JSON keys this reads in snake_case, Grok and Antigravity in camelCase.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
agent=$1
event=$2
session=$3
# Grok and Antigravity hooks are global: only an agent the app started (through ~/.roamtty/<agent>) reports.
case "$agent" in grok|agy) [ "$ROAMTTY_AGENT" = "$agent" ] || exit 0 ;; esac
# A Claude Code session sent to the background (/bg, or the agents view) runs on outside tmux. Its hooks report to the
# tmux session named in its settings; with older settings, to the pane whose recorded session it resumes.
# statusLine hooks also cache live quotas even if started outside tmux.
[ -n "$TMUX_PANE" ] || [ "$agent" = claude ] || [ "$event" = statusline ] || exit 0
in_pane=${TMUX_PANE:+1}
input=$(cat 2>/dev/null)
# Claude Code statusLine hook receives official 5h/7d rate_limits JSON; cache for Roamtty and forward user statusLine if set.
if [ "$agent" = claude ] && [ "$event" = statusline ]; then
  if command -v python3 >/dev/null 2>&1; then
    user_cmd=$(printf '%s' "$input" | python3 -c '
import json, os, sys, time
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}
rl = data.get("rate_limits") if isinstance(data, dict) else None
if isinstance(rl, dict):
    out = {"updated_at": int(time.time())}
    for k in ("five_hour", "seven_day"):
        w = rl.get(k)
        if isinstance(w, dict) and w.get("used_percentage") is not None:
            out[k] = {"used_percentage": float(w["used_percentage"]), "resets_at": w.get("resets_at")}
    if "five_hour" in out or "seven_day" in out:
        d = os.path.expanduser("~/.roamtty")
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, f".quota-claude.{os.getpid()}.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(out, f)
        os.replace(tmp, os.path.join(d, "quota-claude.json"))
try:
    cfg = json.load(open(os.path.expanduser("~/.claude/settings.json"), encoding="utf-8"))
    sl = cfg.get("statusLine") if isinstance(cfg, dict) else None
    cmd = sl.get("command", "") if isinstance(sl, dict) else ""
    if isinstance(cmd, str) and cmd.strip() and "agent-hook.sh" not in cmd:
        print(cmd)
except Exception:
    pass
' 2>/dev/null)
    if [ -n "$user_cmd" ]; then
      printf '%s' "$input" | sh -c "$user_cmd" 2>/dev/null || true
    fi
  fi
  exit 0
fi
# Antigravity CLI statusLine hook receives live 5h/weekly quota JSON from the authenticated session; cache atomically
# (works even over macOS SSH where `agy -p /quota` cannot unlock Keychain) and forward any user statusLine command.
if [ "$agent" = agy ] && [ "$event" = statusline ]; then
  if command -v python3 >/dev/null 2>&1; then
    user_cmd=$(printf '%s' "$input" | python3 -c '
import json, os, sys, time
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}
quota = data.get("quota") if isinstance(data, dict) else None
if isinstance(quota, dict):
    cleaned = {}
    for k, v in quota.items():
        if isinstance(v, dict) and v.get("remaining_fraction") is not None:
            cleaned[k] = {
                "remaining_fraction": float(v["remaining_fraction"]),
                "reset_time": v.get("reset_time"),
                "reset_in_seconds": v.get("reset_in_seconds"),
            }
    if cleaned:
        model_info = data.get("model") if isinstance(data.get("model"), dict) else {}
        out = {
            "_fetched_at": int(time.time()),
            "_source": "statusline",
            "model": model_info.get("id") or "",
            "quota": cleaned,
        }
        d = os.path.expanduser("~/.roamtty")
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, f".quota-agy.{os.getpid()}.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(out, f)
        os.replace(tmp, os.path.join(d, "quota-agy.json"))
try:
    cfg = json.load(open(os.path.expanduser("~/.gemini/antigravity-cli/settings.json"), encoding="utf-8"))
    sl = cfg.get("statusLine") if isinstance(cfg, dict) else None
    if isinstance(sl, dict) and sl.get("enabled", True) is not False:
        cmd = sl.get("command", "")
        if isinstance(cmd, str) and cmd.strip() and "agent-hook.sh" not in cmd:
            print(cmd)
except Exception:
    pass
' 2>/dev/null)
    if [ -n "$user_cmd" ]; then
      printf '%s' "$input" | sh -c "$user_cmd" 2>/dev/null || true
    fi
  fi
  exit 0
fi
# A Grok subagent's events are not its session's.
case "$agent:$input" in grok:*'"subagentType"'*) exit 0 ;; esac

# The string value of a JSON key (or of one of "a|b"), cleaned for one line: escapes undone, "|" and control characters gone, shortened.
field() {
  printf '%s' "$input" | sed -nE "s/(^|.*[^\\\\])\"($1)\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\3/p" | head -n 1 |
    sed -E 's/\\[nrt]/ /g; s/\\u[0-9a-fA-F]{4}//g; s/\\(["\\/])/\1/g' | tr '|' '/' | tr -d '\000-\037' | cut -c1-"${2:-160}"
}

# Antigravity nests the tool name at top-level toolCall.name regardless of property order; ignore "name" inside args or siblings.
agy_tool_name() {
  printf '%s' "$input" | awk '
    BEGIN { depth = 0; tc = 0; in_str = 0; tok = ""; want = ""; cap = 0 }
    {
      n = split($0, p, "\"")
      for (k = 1; k <= n; k++) {
        seg = p[k]
        if (in_str) {
          if (cap && length(str) < 80) str = str substr(seg, 1, 80)
          if (k < n) {
            bs = 0; len = length(seg)
            if (len > 0 && substr(seg, len, 1) == "\\") {
              for (j = len; j >= 1 && substr(seg, j, 1) == "\\"; j--) bs++
            }
            if (bs % 2 == 1) {
              if (cap && length(str) < 80) str = str "\""
            } else {
              in_str = 0
              if (want == "name") { print str; exit }
              tok = cap ? str : ""
              want = ""
            }
          }
        } else {
          gsub(/[ \t\r\n]+/, "", seg)
          m = length(seg)
          for (i = 1; i <= m; i++) {
            c = substr(seg, i, 1)
            if (c == ":") {
              if (tc == 0 && depth == 1 && tok == "toolCall") want = "tc"
              else if (tc > 0 && depth == tc && tok == "name") want = "name"
              else want = ""
              tok = ""
            } else if (c == "{") {
              depth++
              if (want == "tc") tc = depth
              want = ""; tok = ""
            } else if (c == "}") {
              if (tc > 0 && depth == tc) exit
              depth--; want = ""; tok = ""
            } else {
              want = ""; tok = ""
            }
          }
          if (k < n) {
            in_str = 1; str = ""
            cap = (want == "name" || (tc == 0 && depth == 1) || (tc > 0 && depth == tc))
          }
        }
      }
    }
  ' | head -n 1 | sed -E 's/\\[nrt]/ /g; s/\\u[0-9a-fA-F]{4}//g; s/\\(["\\/])/\1/g' | tr '|' '/' | tr -d '\000-\037' | cut -c1-40
}

get() { tmux show-options -qv -t "$TMUX_PANE" "$1" 2>/dev/null; }
put() { tmux set-option -q -t "$TMUX_PANE" "$1" "$2" 2>/dev/null; }

if [ -z "$in_pane" ] && [ -n "$session" ]; then
  tmux has-session -t "=$session" 2>/dev/null || exit 0
  TMUX_PANE="=$session:"
elif [ -n "$in_pane" ]; then
  # Kept past the session's end: a background session that resumed it still reports by it.
  sid=$(field 'session_id|sessionId|conversationId' 64)
  if [ "$agent" = claude ]; then put @roamtty_session "$sid"
  elif [ -n "$sid" ]; then put @roamtty_session "$sid"; fi
  tpath=$(field 'transcript_path|transcriptPath' 400)
  [ -z "$tpath" ] || put @roamtty_transcript "$tpath"
else
  # The session a background Claude Code resumed is in its command line ("--resume …/<id>.jsonl"); the hook may run
  # under a shell or two below it.
  pid=$PPID resumed=
  for _ in 1 2 3 4; do
    [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
    resumed=$(ps -ww -o args= -p "$pid" 2>/dev/null | sed -nE 's/.*--resume[= ]+([^ ]*\/)?([0-9a-fA-F-]{36})(\.jsonl)?( .*)?$/\2/p')
    [ -z "$resumed" ] || break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  [ -n "$resumed" ] || exit 0
  TMUX_PANE=$(tmux list-panes -a -F '#{pane_id} #{@roamtty_session}' 2>/dev/null | awk -v id="$resumed" '$2 == id { print $1; exit }')
  [ -n "$TMUX_PANE" ] || exit 0
fi

# state|since|agent|tool|detail; "since" keeps the time the state began while it repeats.
record() {
  now=$(date +%s)
  case "$(get @roamtty_agent)" in "$1|"*) now=$(get @roamtty_agent | cut -d '|' -f 2) ;; esac
  put @roamtty_agent "$1|$now|$agent|$2|$3"
}

# Claude Code runs several sessions for one tmux session once it has background jobs: the one in the pane and any number
# outside it. Codex and Grok have one session per pane.
if [ "$agent" = claude ]; then
  me=$(field session_id 64)
  if [ -z "$in_pane" ]; then
    # A job does not speak for a pane that now runs another agent.
    case "$(get @roamtty_agent | cut -d '|' -f 3)" in ''|claude) ;; *) exit 0 ;; esac
    case "$event" in
      # Spare processes start before any task, and a job starting says nothing about the pane.
      start) exit 0 ;;
      # A job's end leaves the pane's options. Stopped mid-turn, nothing else would say that the work is over.
      end)
        if [ "$(get @roamtty_owner)" = "$me" ]; then
          case "$(get @roamtty_agent)" in working\|*|waiting\|*) record idle "" "" ;; esac
        fi
        exit 0 ;;
    esac
  fi
  case "$event" in
    start|prompt|tool|post|ask) put @roamtty_owner "$me" ;;
    # Only the session that reported last says the work stopped or asks for anything: the one left in the pane notifies
    # while a job works.
    stop|notify)
      owner=$(get @roamtty_owner)
      [ -z "$owner" ] || [ "$owner" = "$me" ] || exit 0 ;;
  esac
fi

case "$event" in
  start)
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record idle "" "" ;;
  prompt)
    # Antigravity fires PreInvocation before every model call in a turn; invocationNum > 0 continues the current turn.
    if [ "$agent" = agy ]; then
      inv=$(printf '%s' "$input" | sed -nE 's/(^|.*[^\\])"invocationNum"[[:space:]]*:[[:space:]]*([0-9]+).*/\2/p' | head -n 1)
      if [ -n "$inv" ] && [ "$inv" != 0 ]; then
        current=$(get @roamtty_agent)
        record working "$(printf '%s' "$current" | cut -d '|' -f 4)" "$(printf '%s' "$current" | cut -d '|' -f 5)"
        exit 0
      fi
    fi
    # Claude Code also submits "<task-notification>…" itself when a background task ends: that is no task of the user's.
    task=$(field 'prompt|lastUserInput' 200)
    prev_task=$(get @roamtty_task)
    case "$task" in "<"*) ;; *) [ -z "$task" ] || put @roamtty_task "$task" ;; esac
    # A turn starts: the time it began, for how long it worked once it stops. A turn that waited for background work
    # (see stop) goes on when that work ends and wakes the agent.
    case "$agent:$task:$(get @roamtty_agent)" in
      *:"<"*:working\|*) ;;
      agy:*:working\|*\|Background\|*) [ -z "$task" ] || [ "$task" = "$prev_task" ] || put @roamtty_turn "$(date +%s)" ;;
      *) put @roamtty_turn "$(date +%s)" ;;
    esac
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record working "" "" ;;
  tool)
    tool=$(field 'tool_name|toolName' 40)
    if [ -z "$tool" ] && [ "$agent" = agy ]; then
      tool=$(agy_tool_name)
    fi
    detail=$(field 'command|CommandLine' 120)
    [ -n "$detail" ] || detail=$(field 'file_path|filePath|path|Path' 120)
    [ -n "$detail" ] || detail=$(field 'pattern|query|question' 120)
    [ -n "$detail" ] || detail=$(field url 120)
    [ -n "$detail" ] || detail=$(field 'description|Description|toolSummary|Role' 120)
    # Codex edits files with a patch as its command: the file it changes says more.
    case "$tool" in
      apply_patch) detail=$(printf '%s' "$detail" | sed -nE 's/^\*\*\* Begin Patch \*\*\* (Add|Update|Delete) File: ([^ ]+).*/\2/p') ;;
    esac
    # Antigravity blocks on ask_question until the user picks an answer.
    if [ "$agent" = agy ] && [ "$tool" = ask_question ]; then
      record waiting "$tool" "$detail"
    else
      record working "$tool" "$detail"
    fi ;;
  post)
    # The finished tool stays shown while the agent works on, until the next tool, a new prompt or the turn's end:
    # most tools end within a second, too quickly for the app to see them otherwise.
    current=$(get @roamtty_agent)
    record working "$(printf '%s' "$current" | cut -d '|' -f 4)" "$(printf '%s' "$current" | cut -d '|' -f 5)" ;;
  ask)
    # Codex asks for permission with a PermissionRequest hook.
    tool=$(field 'tool_name|toolName' 40)
    detail=$(field command 120)
    [ -n "$detail" ] || detail=$(field description 120)
    record waiting "$tool" "$detail" ;;
  notify)
    # Agents also notify when idle for a minute (Grok after a turn that reported no end too); a request for permission
    # waits, idleness settles. Claude Code's older notifications only say so in their message.
    kind=$(field 'notification_type|notificationType' 40)
    # Not while background work is to wake it (see stop): the agent only looks idle.
    case "$kind" in idle_prompt) [ "$(get @roamtty_agent | cut -d '|' -f 4)" = Background ] || record idle "" ""; exit 0 ;; esac
    case "$kind:$(field message 200)" in
      permission_prompt:*|*ermission*|*pprov*)
        # The message is generic: the tool about to run says more.
        current=$(get @roamtty_agent)
        tool=$(printf '%s' "$current" | cut -d '|' -f 4)
        if [ -n "$tool" ]; then record waiting "$tool" "$(printf '%s' "$current" | cut -d '|' -f 5)"
        else record waiting "" "$(field message 120)"; fi ;;
    esac ;;
  stop)
    # The start of the turn's answer, for the session list; Claude, Codex and Grok pass it directly, Antigravity writes
    # it to transcriptPath.
    reply=$(field 'last_assistant_message|lastAssistantMessage' 400)
    if [ -z "$reply" ] && [ "$agent" = agy ]; then
      tpath=$(field transcriptPath 400)
      if [ -n "$tpath" ] && [ -r "$tpath" ]; then
        last_line=$(tail -n 30 "$tpath" 2>/dev/null | grep '"type":"PLANNER_RESPONSE"' | tail -n 1)
        if [ -n "$last_line" ]; then
          saved_input=$input
          input=$last_line
          reply=$(field content 400)
          input=$saved_input
        fi
      fi
    fi
    [ -z "$reply" ] || put @roamtty_reply "$reply"
    # Claude Code and Grok list the background work still running (shells, monitors, subagents), which wakes the
    # agent when it ends: the turn is not over yet. The first task says what it waits for.
    tasks=$(printf '%s' "$input" | sed -nE 's/.*"(background_tasks|backgroundTasks)"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{([^}]*).*/\2/p' | head -n 1)
    if [ -n "$tasks" ]; then
      input="{$tasks}"
      detail=$(field command 120)
      [ -n "$detail" ] || detail=$(field description 120)
      record working Background "$detail"
      exit 0
    fi
    if [ "$agent" = agy ] && printf '%s' "$input" | grep -qE '"fullyIdle"[[:space:]]*:[[:space:]]*false' &&
      [ "$(field terminationReason 40)" = NO_TOOL_CALL ]; then
      record working Background ""
      exit 0
    fi
    # How long the turn worked, in seconds; Claude Code shows it as "Worked for …".
    turn=$(get @roamtty_turn)
    case "$turn" in ''|*[!0-9]*) ;; *) put @roamtty_worked "$(( $(date +%s) - turn ))" ;; esac
    record idle "" "" ;;
  end)
    for option in @roamtty_agent @roamtty_task @roamtty_turn @roamtty_worked @roamtty_reply @roamtty_owner @roamtty_transcript; do
      tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null
    done ;;
esac
exit 0
