#!/bin/sh
# Roamtty: records what an AI coding agent is doing as options of its tmux session, which the app reads.
# Usage: agent-hook.sh <agent> <event>, with the agent's hook JSON on stdin. Never fails the agent.
# Claude Code and Codex pass the JSON keys this reads in snake_case, Grok in camelCase.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
agent=$1
event=$2
# Grok's hooks are global: only a Grok the app started (through ~/.roamtty/grok) reports.
[ "$agent" != grok ] || [ "$ROAMTTY_AGENT" = grok ] || exit 0
# A Claude Code session sent to the background (/bg) runs on outside tmux, as a new process that resumes the pane's
# session: its hooks find the pane by that session, which the pane's hooks record.
[ -n "$TMUX_PANE" ] || [ "$agent" = claude ] || exit 0
input=$(cat 2>/dev/null)
# A Grok subagent's events are not its session's.
case "$agent:$input" in grok:*'"subagentType"'*) exit 0 ;; esac

# The string value of a JSON key (or of one of "a|b"), cleaned for one line: escapes undone, "|" and control characters gone, shortened.
field() {
  printf '%s' "$input" | sed -nE "s/.*\"($1)\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\2/p" | head -n 1 |
    sed -E 's/\\[nrt]/ /g; s/\\u[0-9a-fA-F]{4}//g; s/\\(["\\/])/\1/g' | tr '|' '/' | tr -d '\000-\037' | cut -c1-"${2:-160}"
}

get() { tmux show-options -qv -t "$TMUX_PANE" "$1" 2>/dev/null; }
put() { tmux set-option -q -t "$TMUX_PANE" "$1" "$2" 2>/dev/null; }

if [ -n "$TMUX_PANE" ]; then
  # Kept past the session's end: a background session that resumed it still reports by it.
  [ "$agent" != claude ] || put @roamtty_session "$(field session_id 64)"
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

case "$event" in
  start)
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record idle "" "" ;;
  prompt)
    # Claude Code also submits "<task-notification>…" itself when a background task ends: that is no task of the user's.
    task=$(field prompt 200)
    case "$task" in "<"*) ;; *) put @roamtty_task "$task" ;; esac
    # A turn starts: the time it began, for how long it worked once it stops.
    put @roamtty_turn "$(date +%s)"
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record working "" "" ;;
  tool)
    tool=$(field 'tool_name|toolName' 40)
    detail=$(field command 120)
    [ -n "$detail" ] || detail=$(field 'file_path|filePath|path' 120)
    [ -n "$detail" ] || detail=$(field pattern 120)
    [ -n "$detail" ] || detail=$(field url 120)
    [ -n "$detail" ] || detail=$(field description 120)
    # Codex edits files with a patch as its command: the file it changes says more.
    case "$tool" in
      apply_patch) detail=$(printf '%s' "$detail" | sed -nE 's/^\*\*\* Begin Patch \*\*\* (Add|Update|Delete) File: ([^ ]+).*/\2/p') ;;
    esac
    record working "$tool" "$detail" ;;
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
    case "$kind" in idle_prompt) record idle "" ""; exit 0 ;; esac
    case "$kind:$(field message 200)" in
      permission_prompt:*|*ermission*|*pprov*)
        # The message is generic: the tool about to run says more.
        current=$(get @roamtty_agent)
        tool=$(printf '%s' "$current" | cut -d '|' -f 4)
        if [ -n "$tool" ]; then record waiting "$tool" "$(printf '%s' "$current" | cut -d '|' -f 5)"
        else record waiting "" "$(field message 120)"; fi ;;
    esac ;;
  stop)
    # How long the turn worked, in seconds; Claude Code shows it as "Worked for …".
    turn=$(get @roamtty_turn)
    case "$turn" in ''|*[!0-9]*) ;; *) put @roamtty_worked "$(( $(date +%s) - turn ))" ;; esac
    # The start of the turn's answer, for the session list; all three agents pass it to their Stop hook.
    reply=$(field 'last_assistant_message|lastAssistantMessage' 400)
    [ -z "$reply" ] || put @roamtty_reply "$reply"
    record idle "" "" ;;
  end)
    for option in @roamtty_agent @roamtty_task @roamtty_turn @roamtty_worked @roamtty_reply; do
      tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null
    done ;;
esac
exit 0
