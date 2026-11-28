#!/bin/sh
# Roamtty: records what an AI coding agent is doing as options of its tmux session, which the app reads.
# Usage: agent-hook.sh <agent> <event> [tmux session], with the agent's hook JSON on stdin. Never fails the agent.
# Claude Code and Codex pass the JSON keys this reads in snake_case, Grok and Antigravity in camelCase.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
agent=$1
event=$2
session=$3
# Merge both files under the same advisory lock. A parse error must leave the user's configuration intact.
if [ "$agent:$event" = codex:install ]; then
  shift 2
  codex_dir=${CODEX_HOME:-"$HOME/.codex"}
  if ! command -v python3 >/dev/null 2>&1 && perl -MJSON::PP -MFcntl -MFile::Temp -e 1 2>/dev/null; then
    # macOS and many minimal Linux installations provide Perl's core JSON and flock without Python.
    perl - "$codex_dir" "$@" <<'__ROAMTTY_PERL__'
use strict;
use warnings;
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile tempdir);
use JSON::PP;

sub read_file {
    my ($name) = @_;
    return '' unless -e $name;
    open my $file, '<:raw', $name or die "$name: $!";
    local $/;
    return <$file> // '';
}
sub publish {
    my ($path, $data) = @_;
    $path = abs_path($path) // die "cannot resolve $path" if -l $path;
    my ($file, $tmp) = tempfile('.roamtty-XXXXXX', DIR => dirname($path), UNLINK => 1);
    binmode $file;
    chmod((stat($path))[2] & 07777, $tmp) or die "chmod: $!" if -e $path;
    print {$file} $data or die "write: $!";
    close $file or die "close: $!";
    rename $tmp, $path or die "$path: $!";
}
eval {
    my $dir = shift;
    make_path($dir);
    $dir = abs_path($dir) // die "cannot resolve $dir";
    open my $lock, '>>', "$dir/.roamtty-hooks.lock" or die "lock: $!";
    flock($lock, LOCK_EX) or die "flock: $!";
    my $file = "$dir/hooks.json";
    my $config = "$dir/config.toml";
    my $json = JSON::PP->new->utf8->canonical;
    my $data = -e $file ? $json->decode(read_file($file)) : {};
    die 'expected a hooks object' unless ref($data) eq 'HASH';
    $data->{hooks} = {} unless exists $data->{hooks};
    die 'expected a hooks object' unless ref($data->{hooks}) eq 'HASH';
    my $before = read_file($config);
    my $after = $before;
    my $changed = 0;
    for my $spec (@ARGV) {
        my ($event, $key, $action, $hash) = split / /, $spec;
        my $hook = {type => 'command', command => "sh ~/.roamtty/agent-hook.sh codex $action", timeout => 3};
        $data->{hooks}{$event} = [] unless exists $data->{hooks}{$event};
        my $groups = $data->{hooks}{$event};
        die "expected hook groups for $event" unless ref($groups) eq 'ARRAY';
        my $index;
        for my $i (0 .. $#$groups) {
            my $g = $groups->[$i];
            die "expected hook groups for $event" unless ref($g) eq 'HASH' && ref($g->{hooks}) eq 'ARRAY';
            my $v = $json->encode($g);
            $index //= $i if $v eq $json->encode({hooks => [$hook]}) ||
                $v eq $json->encode({hooks => [{%$hook, async => JSON::PP::false}]});
        }
        if (!defined $index) {
            $index = @$groups;
            push @$groups, {hooks => [$hook]};
            $changed = 1;
        }
        my $header = '[hooks.state.' . JSON::PP->new->allow_nonref->encode("$file:$key:$index:0") . ']';
        $after .= "\n$header\ntrusted_hash = \"$hash\"\n" unless $before =~ /^\s*\Q$header\E\s*(?:\#.*)?$/m;
    }
    # Let the installed Codex parse the complete candidate before publishing either file.
    if ($before =~ /\S/) {
        my $scratch = tempdir('.roamtty-config-XXXXXX', DIR => $dir, CLEANUP => 1);
        publish("$scratch/config.toml", $after);
        local $ENV{CODEX_HOME} = $scratch;
        my $pid = fork();
        die 'cannot run Codex to validate config.toml' unless defined $pid;
        if (!$pid) {
            open STDOUT, '>', '/dev/null' or exit 1;
            open STDERR, '>', '/dev/null' or exit 1;
            exec 'codex', 'features', 'list';
            exit 1;
        }
        waitpid $pid, 0;
        die 'Codex could not validate the updated config.toml' unless $? == 0;
    }
    publish($file, $json->pretty->encode($data)) if $changed;
    publish($config, $after) if $before ne $after;
    1;
} or die "Roamtty: could not install Codex hooks: $@\n";
__ROAMTTY_PERL__
    exit $?
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    # Without a parser we can still install into a fresh home, without overwriting existing user files.
    mkdir -p "$codex_dir" || exit 1
    codex_dir=$(cd "$codex_dir" && pwd -P) || exit 1
    scratch=$(mktemp -d "$codex_dir/.roamtty-hooks.XXXXXX") || exit 1
    trap 'rm -f "$scratch/hooks" "$scratch/config"; rmdir "$scratch"' 0
    clean_dir=$(printf '%s' "$codex_dir" | LC_ALL=C tr -d '[:cntrl:]')
    [ "$clean_dir" = "$codex_dir" ] || { echo 'Roamtty: Python or Perl is required for this Codex path.' >&2; exit 1; }
    trust_dir=$(printf '%s' "$codex_dir" | sed 's/\\/\\\\/g; s/"/\\"/g')
    (
      umask 077
      printf '{"hooks":{' > "$scratch/hooks"
      separator=
      for spec do
        IFS=' ' read -r name key action hash <<EOF
$spec
EOF
        printf '%s"%s":[{"hooks":[{"type":"command","command":"sh ~/.roamtty/agent-hook.sh codex %s","timeout":3}]}]' "$separator" "$name" "$action" >> "$scratch/hooks"
        printf '\n[hooks.state."%s/hooks.json:%s:0:0"]\ntrusted_hash = "%s"\n' "$trust_dir" "$key" "$hash" >> "$scratch/config"
        separator=,
      done
      printf '}}\n' >> "$scratch/hooks"
    )
    # link(2) publishes complete files exclusively, including on concurrent first launches.
    if [ -e "$codex_dir/config.toml" ] && ! cmp -s "$scratch/config" "$codex_dir/config.toml"; then
      echo 'Roamtty: Python 3 or Perl JSON::PP is needed to merge existing Codex settings.' >&2; exit 1
    fi
    ln "$scratch/hooks" "$codex_dir/hooks.json" 2>/dev/null || cmp -s "$scratch/hooks" "$codex_dir/hooks.json" || {
      echo 'Roamtty: Python 3 or Perl JSON::PP is needed to merge existing Codex hooks.' >&2; exit 1
    }
    ln "$scratch/config" "$codex_dir/config.toml" 2>/dev/null || cmp -s "$scratch/config" "$codex_dir/config.toml"
    exit $?
  fi
  python3 - "$codex_dir" "$@" <<'__ROAMTTY_INSTALL__'
import fcntl, json, os, re, stat, subprocess, sys, tempfile
from pathlib import Path

def read(path):
    try:
        with path.open(encoding="utf-8", newline="") as f:
            return f.read()
    except FileNotFoundError:
        return ""

def replace(path, text):
    fd, tmp = tempfile.mkstemp(prefix=".roamtty-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            if path.exists():
                os.fchmod(f.fileno(), stat.S_IMODE(path.stat().st_mode))
            f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def install(directory, specs):
    directory.mkdir(parents=True, exist_ok=True)
    # Keep a stable lock inode even when a previous launcher exits or is killed.
    with (directory / ".roamtty-hooks.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        hook_file = directory / "hooks.json"
        hook_target = hook_file.resolve()
        config = (directory / "config.toml").resolve()
        original = read(hook_target)
        data = json.loads(original) if hook_target.exists() else {}
        if not isinstance(data, dict) or not isinstance(data.setdefault("hooks", {}), dict):
            raise ValueError("expected a hooks object in " + str(hook_file))
        text = read(config)
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib
            except ImportError:
                try:
                    from pip._vendor import tomli as tomllib
                except ImportError:
                    tomllib = None
        parsed = tomllib.loads(text) if tomllib else {}
        trust = parsed.get("hooks", {}).get("state", {})
        if not isinstance(trust, dict):
            raise ValueError("expected a hooks.state table in config.toml")
        additions = []
        changed = False
        for spec in specs:
            event, key, action, digest = spec.split()
            hook = {"type": "command", "command": "sh ~/.roamtty/agent-hook.sh codex " + action, "timeout": 3}
            groups = data["hooks"].setdefault(event, [])
            if not isinstance(groups, list):
                raise ValueError("expected a hook list for " + event)
            if any(not isinstance(g, dict) or not isinstance(g.get("hooks"), list) for g in groups):
                raise ValueError("expected hook groups for " + event)
            for i, group in enumerate(groups):
                if group == {"hooks": [hook]} or group == {"hooks": [{**hook, "async": False}]}:
                    break
            else:
                i = len(groups)
                groups.append({"hooks": [hook]})
                changed = True
            identity = f"{hook_file}:{key}:{i}:0"
            # A user's existing trust decision takes precedence.
            header = "[hooks.state." + json.dumps(identity, ensure_ascii=False) + "]"
            present = identity in trust if tomllib else re.search(r"^\s*" + re.escape(header) + r"\s*(?:#.*)?$", text, re.M)
            if not present:
                additions.append(f'\n{header}\ntrusted_hash = "{digest}"\n')
        result = text + "".join(additions)
        if tomllib:
            tomllib.loads(result)
        elif text.strip():
            # Older Python installations can use the actual Codex parser without changing the live files.
            with tempfile.TemporaryDirectory(prefix=".roamtty-config-", dir=directory) as scratch:
                (Path(scratch) / "config.toml").write_text(result, encoding="utf-8")
                checked = subprocess.run(["codex", "features", "list"], env={**os.environ, "CODEX_HOME": scratch},
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if checked.returncode:
                    raise ValueError("Codex could not validate the updated config.toml")
        if changed:
            replace(hook_target, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        if additions:
            replace(config, result)

try:
    install(Path(sys.argv[1]).resolve(), sys.argv[2:])
except (OSError, ValueError, TypeError, AttributeError) as e:
    sys.exit("Roamtty: could not install Codex hooks: " + str(e))
__ROAMTTY_INSTALL__
  exit $?
fi

# Roamtty's standard TUI shares the local app server. Its native terminal-title fields
# identify the active thread without inserting a command or changing the server's configuration.
if [ "$agent:$event" = codex:launch ]; then
  shift 2
  # Keep explicit alternate backends, CLI configuration overrides and noninteractive commands native.
  embedded=
  case "$1" in ''|resume|fork|--no-daemon|-s|--sandbox|-m|--model|-a|--ask-for-approval|--dangerously-bypass-approvals-and-sandbox) ;; *) exec codex "$@";; esac
  for arg do
    case "$arg" in --no-daemon) embedded=1 ;; -c*|--config*|--remote*|--oss|--profile*|-p|--enable*|--disable*|--strict-config|--dangerously-bypass-hook-trust|--help|-h) exec codex "$@";; esac
  done
  if [ ! -t 0 ] || [ ! -t 1 ] || [ -z "$TMUX_PANE" ] || [ -n "$CODEX_EXEC_SERVER_URL" ] || ! command -v python3 >/dev/null 2>&1; then exec codex "$@"; fi
  [ "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null)" = "$TMUX_PANE" ] || exec codex "$@"
  surface=$(sh "$0" codex title-options) || exec codex "$@"
  socket_dir=${CODEX_HOME:-"$HOME/.codex"}/app-server-control
  if [ -z "$embedded" ] && [ ! -S "$socket_dir/app-server-control.sock" ]; then
    # This feature is normally enabled. An explicit opt-out or an older CLI keeps its normal launch path.
    codex features list </dev/null 2>/dev/null | grep -Eq '^daemon_auto_start[[:space:]]+[^[:space:]]+[[:space:]]+true[[:space:]]*$' || exec codex "$@"
    codex app-server daemon start </dev/null >/dev/null 2>&1 || exec codex "$@"
  fi
  if [ -z "$embedded" ]; then
    [ -S "$socket_dir/app-server-control.sock" ] || exec codex "$@"
    set -- --remote unix:// "$@"
  fi
  directory=$(cd "${CODEX_HOME:-"$HOME/.codex"}" && pwd -P) || exec codex "$@"
  version=
  if [ "${surface%%=*}" = tui.status_line ]; then version=$(codex --version 2>/dev/null | awk '{print $NF}'); fi
  tmux set-option -pq -t "$TMUX_PANE" @roamtty_codex_surface "${surface%%=*}" \; \
    set-option -pq -t "$TMUX_PANE" @roamtty_codex_home "$directory" \; \
    set-option -pq -t "$TMUX_PANE" @roamtty_codex_version "$version" \; \
    set-option -pq -t "$TMUX_PANE" @roamtty_codex_tracker "$$" 2>/dev/null || exec codex "$@"
  sh "$0" codex title-watch "$$" </dev/null >/dev/null 2>&1 &
  watcher=$!
  trap 'kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null' 0
  codex -c "$surface" "$@"
  exit $?
fi

if [ "$agent:$event" = codex:title-options ]; then
  python3 - <<'__ROAMTTY_CODEX_TITLE_OPTIONS__'
import json, os, sys
from pathlib import Path

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        try:
            from pip._vendor import tomli as tomllib
        except ImportError:
            tomllib = None

directory = Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))
cwd = Path.cwd()
titles = ["activity", "thread-title", "project-name"]
status = ["model-with-reasoning", "current-dir", "thread-name"]
provider = None
try:
    # Retain the display order selected in the user's home or project configuration.
    paths = [Path("/etc/codex/config.toml"), directory / "config.toml"]
    paths.extend(root / ".codex/config.toml" for root in [*reversed(cwd.parents), cwd] if root != Path.home())
    for path in paths:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if tomllib is None:
            if "terminal_title" in text:
                sys.exit(1)
            continue
        config = tomllib.loads(text)
        tui = config.get("tui", {})
        titles = tui.get("terminal_title", titles)
        status = tui.get("status_line", status)
        provider = tui.get("status_line_provider", provider)
    if not isinstance(titles, list) or not all(isinstance(t, str) for t in titles):
        sys.exit(1)
    if not titles:
        # Honor disabled OSC titles. Only use a built-in status bar the user still displays.
        if provider or not isinstance(status, list) or not status or not all(isinstance(t, str) for t in status):
            sys.exit(1)
        # The adjacent version cell authenticates the layout even when a picker occupies the footer.
        status = ["thread-id", "codex-version"] + [t for t in status if t not in ("thread-id", "session-id", "codex-version")]
        print("tui.status_line=" + json.dumps(status, ensure_ascii=True))
        sys.exit(0)
except (OSError, ValueError, AttributeError):
    sys.exit(1)
# Keep all explicitly configured items in their original order. Disable remains disable.
if not any(t in ("thread", "thread-title") for t in titles):
    titles = titles + ["thread-title"]
if not any(t in ("thread-id", "session-id") for t in titles):
    titles = titles + ["thread-id"]
print("tui.terminal_title=" + json.dumps(titles, ensure_ascii=True))
__ROAMTTY_CODEX_TITLE_OPTIONS__
  exit $?
fi

if [ "$agent:$event" = codex:title-watch ] || [ "$agent:$event" = codex:current ]; then
  exec python3 - "$event" "$3" <<'__ROAMTTY_CODEX_PANE__'
import os, re, sqlite3, subprocess, sys, time
from pathlib import Path
from urllib.parse import quote

mode, arg = sys.argv[1:]
watching = mode == "title-watch"
pane = os.environ.get("TMUX_PANE", "") if watching else arg
if not re.fullmatch(r"%[0-9]+", pane):
    sys.exit(1)

uuid_pattern = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
prefix_pattern = re.compile(r"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{5})\.\.\.$")
fmt = "\t".join(("#{pane_id}", "#{@roamtty_codex_tracker}", "#{@roamtty_codex_surface}", "#{@roamtty_codex_home}",
                 "#{@roamtty_codex_version}", "#{pane_title}", "#{pane_height}", "#{pane_pid}", "#{pane_tty}",
                 "#{@roamtty_codex_thread}", "#{@roamtty_session}"))

def tmux(*args):
    return subprocess.check_output(["tmux", *args], stderr=subprocess.DEVNULL, timeout=2).decode("utf-8", "replace").rstrip("\r\n")

def snapshot():
    fields = tmux("display-message", "-p", "-t", pane, fmt).split("\t")
    if len(fields) != 11 or fields[0] != pane or not fields[1].isdigit() or int(fields[1]) < 2:
        raise ValueError("no live tracker")
    if fields[2] not in ("tui.terminal_title", "tui.status_line") or not os.path.isabs(fields[3]):
        raise ValueError("no Codex identity surface")
    return fields

def active_tui(fields):
    # A stale user option or a recycled PID cannot stand in for the foreground TUI on this pane.
    owner, pane_pid = int(fields[1]), int(fields[7])
    if os.getsid(owner) != os.getsid(pane_pid):
        return False
    tty = fields[8][5:] if fields[8].startswith("/dev/") else fields[8]
    rows = subprocess.check_output(["ps", "-t", tty, "-o", "pid=,ppid=,stat=,comm="], stderr=subprocess.DEVNULL, timeout=2).decode().splitlines()
    parents = {}
    codex = []
    for row in rows:
        parts = row.strip().split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            pid = int(parts[0])
            parents[pid] = int(parts[1])
            if "+" in parts[2] and re.fullmatch(r"codex(?:-.*)?", os.path.basename(parts[3])):
                codex.append(pid)
    for pid in codex:
        while pid in parents and parents[pid] != pid:
            if parents[pid] == owner:
                return True
            pid = parents[pid]
    return False

def lookup(directory, prefix):
    # Include archived and historical threads. An abbreviated native ID must have at most one match.
    dbs = sorted(Path(directory).glob("state_*.sqlite"), key=lambda p: int(p.stem[6:]) if p.stem[6:].isdigit() else -1)
    if not dbs:
        return []
    db = sqlite3.connect("file:" + quote(str(dbs[-1])) + "?mode=ro", uri=True, timeout=0.2)
    try:
        return db.execute("SELECT id, rollout_path FROM threads WHERE id >= ? AND id < ? LIMIT 2", (prefix, prefix + "g")).fetchall()
    finally:
        db.close()

def identity(fields):
    _, _, surface, directory, version, title, height = fields[:7]
    full = ""
    if surface == "tui.status_line":
        # Only the reserved status row immediately above Codex's shortcuts footer is consulted.
        # An adjacent native version cell identifies the layout if a picker has replaced the footer.
        if not version or int(height) < 5:
            return "", ""
        row = str(int(height) - 2)
        cells = [c.strip() for c in tmux("capture-pane", "-p", "-S", row, "-E", row, "-t", pane).split(" · ", 2)]
        if len(cells) < 2 or cells[1] != version or not uuid_pattern.fullmatch(cells[0]):
            return "", ""
        full = prefix = cells[0].lower()
    else:
        # Codex puts its animated activity cell and recording indicator before the following item.
        parts = [re.sub(r"^(?:[●⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] +)+", "", p.strip()) for p in title.split(" | ")]
        prefixes = {m[1].lower() for p in parts if (m := prefix_pattern.fullmatch(p))}
        if len(prefixes) != 1:
            return "", ""
        prefix = prefixes.pop()
        # An unnamed TUI shows its full thread-title before any rollout or state row exists.
        labels = {p.lower() for p in parts if p.lower().startswith(prefix) and uuid_pattern.fullmatch(p)}
        if len(labels) > 1:
            return "", ""
        full = next(iter(labels), "")
    rows = lookup(directory, prefix)
    if len(rows) > 1 or (rows and full and rows[0][0] != full):
        return "", ""
    return rows[0] if rows else (full, "")

def update(proof, sid, path):
    changes = [("@roamtty_codex_thread", "")]
    if proof and proof != sid:
        changes.extend((key, "") for key in ("@roamtty_task", "@roamtty_reply", "@roamtty_turn", "@roamtty_worked"))
        changes.append(("@roamtty_agent", "idle|%d|codex||" % time.time()))
    changes.extend((("@roamtty_session", sid), ("@roamtty_transcript", path or ""), ("@roamtty_codex_thread", sid)))
    commands = []
    for key, value in changes:
        if commands:
            commands.append(";")
        commands.extend(("set-option", "-pq", "-t", pane, key, value))
    tmux(*commands)

while True:
    try:
        fields = snapshot()
        owner = fields[1]
        if watching and owner != arg:
            break
        os.kill(int(owner), 0)
        if not watching and not active_tui(fields):
            sys.exit(1)
        sid, path = identity(fields)
        proof, session = fields[-2:]
        if not watching or proof != sid or session != sid:
            checked = snapshot()
            # The native title spinner changes every 100 ms while the thread remains the same.
            if fields[:5] == checked[:5] and fields[6:9] == checked[6:9] and identity(checked)[0] == sid:
                if not watching:
                    if not sid or not active_tui(checked):
                        sys.exit(1)
                    print(sid)
                    sys.exit(0)
                if fields[-2:] == checked[-2:]:
                    update(proof, sid, path)
        if not watching:
            sys.exit(1)
        time.sleep(0.2 if not proof else 0.6)
    except (ProcessLookupError, subprocess.CalledProcessError, ValueError):
        break
    except (OSError, sqlite3.Error, subprocess.TimeoutExpired):
        if not watching:
            break
        time.sleep(0.5)
sys.exit(0 if watching else 1)
__ROAMTTY_CODEX_PANE__
fi

# Grok and Antigravity hooks are global: only an agent the app started (through ~/.roamtty/<agent>) reports,
# except Antigravity's statusLine command which only runs when explicitly pointed at agent-hook.sh.
# Codex hooks run either inside a pane (requires ROAMTTY_AGENT=codex) or inside the shared codex app-server daemon
# (TMUX_PANE unset, matched back to a Roamtty-launched Codex pane by its confirmed session_id below).
case "$agent:$event" in
  agy:statusline) ;;
  grok:*|agy:*) [ "$ROAMTTY_AGENT" = "$agent" ] || exit 0 ;;
esac
# A Claude Code session sent to the background (/bg, or the agents view) runs on outside tmux. Its hooks report to the
# tmux session named in its settings; with older settings, to the pane whose recorded session it resumes.
# Codex hooks fired by the shared app-server daemon also run outside tmux and match their pane by its confirmed session_id.
# statusLine hooks also cache live quotas even if started outside tmux.
[ -n "$TMUX_PANE" ] || [ "$agent" = claude ] || [ "$agent" = codex ] || [ "$event" = statusline ] || exit 0
in_pane=${TMUX_PANE:+1}
input=
if [ "$agent:$event" != codex:bind ]; then input=$(cat 2>/dev/null); fi
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
# Antigravity CLI's official statusLine hook receives live 5h/weekly quota JSON from the running session;
# cache atomically (passively, without spawning extra CLI processes) and forward any user statusLine command.
if [ "$agent" = agy ] && [ "$event" = statusline ]; then
  if command -v python3 >/dev/null 2>&1; then
    user_cmd=$(printf '%s' "$input" | python3 -c '
import json, os, subprocess, sys, time
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}
# Keep Roamtty-managed tmux pane bound to the live conversation (handles fresh start, /clear, /new, /resume)
# and reconcile stale working/waiting state when agy returns to idle/error (e.g. Esc cancel skipping Stop)
# or toggles tool confirmation dialogs.
pane = os.environ.get("TMUX_PANE") or ""
if pane and os.environ.get("ROAMTTY_AGENT") == "agy" and isinstance(data, dict):
    def tmux_get(opt):
        return subprocess.run(
            ["tmux", "show-options", "-qv", "-t", pane, opt],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1,
        ).stdout.decode("utf-8", "replace").strip()

    def tmux_set(opt, val):
        subprocess.run(
            ["tmux", "set-option", "-q", "-t", pane, opt, val],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1,
        )

    def tmux_unset(opt):
        subprocess.run(
            ["tmux", "set-option", "-u", "-q", "-t", pane, opt],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1,
        )

    if "conversation_id" in data:
        cid = data.get("conversation_id") if isinstance(data.get("conversation_id"), str) else ""
        tpath = data.get("transcript_path") if isinstance(data.get("transcript_path"), str) else ""
        try:
            cur_cid = tmux_get("@roamtty_session")
            cur_tp = tmux_get("@roamtty_transcript")
            if cid:
                if cur_cid != cid:
                    tmux_set("@roamtty_session", cid)
                if tpath:
                    if cur_tp != tpath:
                        tmux_set("@roamtty_transcript", tpath)
                elif cur_cid != cid and cur_tp:
                    tmux_unset("@roamtty_transcript")
            else:
                if cur_cid:
                    tmux_unset("@roamtty_session")
                if cur_tp:
                    tmux_unset("@roamtty_transcript")
        except Exception:
            pass

    if "agent_state" in data or "tool_confirmation_pending" in data:
        try:
            cur_agent = tmux_get("@roamtty_agent")
            parts = cur_agent.split("|", 4)
            if len(parts) >= 3 and parts[2] == "agy":
                cur_state = parts[0]
                cur_tool = parts[3] if len(parts) > 3 else ""
                cur_detail = parts[4] if len(parts) > 4 else ""
                astate = data.get("agent_state") if isinstance(data.get("agent_state"), str) else ""
                confirm_pending = data.get("tool_confirmation_pending") is True
                task_count = data.get("task_count")
                if isinstance(task_count, bool) or not isinstance(task_count, int):
                    task_count = 0
                pending_inputs = data.get("pending_input_count")
                if isinstance(pending_inputs, bool) or not isinstance(pending_inputs, int):
                    pending_inputs = 0
                subagents = data.get("subagents") if isinstance(data.get("subagents"), list) else []
                has_running_subagent = any(isinstance(s, dict) and s.get("status") == "running" for s in subagents)
                has_bg = task_count > 0 or has_running_subagent
                now_ts = int(time.time())
                if confirm_pending:
                    if cur_state == "working":
                        tmux_set("@roamtty_agent", f"waiting|{now_ts}|agy|{cur_tool}|{cur_detail}")
                elif astate in ("idle", "error") and not has_bg and pending_inputs <= 0:
                    if cur_state in ("working", "waiting"):
                        turn = tmux_get("@roamtty_turn")
                        if turn.isdigit():
                            tmux_set("@roamtty_worked", str(max(0, now_ts - int(turn))))
                        tmux_set("@roamtty_agent", f"idle|{now_ts}|agy||")
                elif astate in ("working", "thinking", "tool_use"):
                    if cur_state == "waiting" and cur_tool != "ask_question":
                        tmux_set("@roamtty_agent", f"working|{now_ts}|agy|{cur_tool}|{cur_detail}")
        except Exception:
            pass
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
        now = int(time.time())
        d = os.path.expanduser("~/.roamtty")
        os.makedirs(d, exist_ok=True)
        cache_path = os.path.join(d, "quota-agy.json")
        seen_path = os.path.join(d, "quota-agy-seen.json")
        conv_id = data.get("conversation_id")
        pane_id = os.environ.get("TMUX_PANE")
        if isinstance(conv_id, str) and conv_id:
            caller = "conv:" + conv_id
        elif pane_id:
            caller = "pane:" + pane_id
        else:
            caller = "pid:" + sys.argv[1]
        sig = {k: [round(v["remaining_fraction"], 6), v.get("reset_time") or ""] for k, v in sorted(cleaned.items())}
        seen = {}
        try:
            raw_seen = json.load(open(seen_path, encoding="utf-8"))
            if isinstance(raw_seen, dict):
                seen = raw_seen
        except Exception:
            seen = {}
        prev_entry = seen.get(caller)
        prev_sig = prev_entry.get("sig") if isinstance(prev_entry, dict) else None

        def extract_existing_buckets(obj):
            out_b = {}
            if not isinstance(obj, dict):
                return out_b
            qmap = obj.get("quota")
            if isinstance(qmap, dict):
                for bk, bv in qmap.items():
                    if isinstance(bv, dict) and bv.get("remaining_fraction") is not None:
                        out_b[bk] = (float(bv["remaining_fraction"]), bv.get("reset_time") or "")
            groups = ((obj.get("command") or {}).get("data") or {}).get("groups")
            if isinstance(groups, list):
                for g in groups:
                    if not isinstance(g, dict):
                        continue
                    gname = (g.get("name") or "").lower()
                    prefix = "3p-" if ("claude" in gname or "gpt" in gname) else ("gemini-" if "gemini" in gname else "")
                    for bv in g.get("buckets") or []:
                        if not isinstance(bv, dict) or bv.get("remaining_fraction") is None:
                            continue
                        bwin = bv.get("window")
                        bid = bv.get("id") or ((prefix + bwin) if (prefix and isinstance(bwin, str) and bwin) else "")
                        if bid:
                            out_b[bid] = (float(bv["remaining_fraction"]), bv.get("reset_time") or "")
            return out_b

        existing = None
        if os.path.isfile(cache_path):
            try:
                existing = json.load(open(cache_path, encoding="utf-8"))
            except Exception:
                existing = None

        def is_valid_reset(ts_str):
            return isinstance(ts_str, str) and len(ts_str) >= 10 and ts_str > "1970-01-02"

        now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

        should_write = True
        if existing is not None:
            if prev_sig is not None and prev_sig == sig:
                # Idle session TUI redraw re-emits unchanged in-memory quota; do not clobber fresher readings.
                should_write = False
            else:
                ex_ts = int(existing.get("_fetched_at") or 0) if isinstance(existing, dict) else 0
                if ex_ts == 0 or now - ex_ts < 7 * 86400:
                    ex_buckets = extract_existing_buckets(existing)
                    same_window = False
                    newer_reset = False
                    older_reset = False
                    more_consumed = False
                    less_consumed = False
                    for bk, (nfrac, nreset) in ((k, (v["remaining_fraction"], v.get("reset_time") or "")) for k, v in cleaned.items()):
                        if bk not in ex_buckets:
                            continue
                        efrac, ereset = ex_buckets[bk]
                        n_valid = is_valid_reset(nreset)
                        e_valid = is_valid_reset(ereset)
                        if n_valid and e_valid:
                            if nreset != ereset:
                                if nreset > ereset:
                                    newer_reset = True
                                else:
                                    older_reset = True
                            else:
                                same_window = True
                                if nfrac < efrac - 1e-6:
                                    more_consumed = True
                                elif nfrac > efrac + 1e-6:
                                    less_consumed = True
                        elif not n_valid and e_valid:
                            # Untouched 100% bucket (1970-01-01): newer only if the previous window already expired.
                            if ereset < now_iso:
                                newer_reset = True
                            elif efrac < 1.0 - 1e-6:
                                older_reset = True
                        elif n_valid and not e_valid:
                            if nreset >= now_iso:
                                newer_reset = True
                    if older_reset and not newer_reset:
                        should_write = False
                    elif prev_sig is None and same_window and not newer_reset and not more_consumed and less_consumed:
                        should_write = False

        seen[caller] = {"ts": now, "sig": sig}
        if len(seen) > 32:
            keep = sorted(seen.items(), key=lambda kv: (kv[1].get("ts", 0) if isinstance(kv[1], dict) else 0), reverse=True)[:32]
            seen = dict(keep)
        try:
            stmp = os.path.join(d, f".quota-agy-seen.{os.getpid()}.tmp")
            with open(stmp, "w", encoding="utf-8") as f:
                json.dump(seen, f)
            os.replace(stmp, seen_path)
        except Exception:
            pass

        if should_write:
            model_info = data.get("model") if isinstance(data.get("model"), dict) else {}
            out = {
                "_fetched_at": now,
                "_source": "statusline",
                "model": model_info.get("id") or "",
                "quota": cleaned,
            }
            tmp = os.path.join(d, f".quota-agy.{os.getpid()}.tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(out, f)
            os.replace(tmp, cache_path)
try:
    cfg = json.load(open(os.path.expanduser("~/.gemini/antigravity-cli/settings.json"), encoding="utf-8"))
    sl = cfg.get("statusLine") if isinstance(cfg, dict) else None
    if isinstance(sl, dict) and sl.get("enabled", True) is not False:
        cmd = sl.get("command", "")
        if isinstance(cmd, str) and cmd.strip() and "agent-hook.sh" not in cmd:
            print(cmd)
except Exception:
    pass
' "$PPID" 2>/dev/null)
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

get() {
  if [ "$agent" = codex ]; then tmux show-options -pqv -t "$TMUX_PANE" "$1" 2>/dev/null
  else tmux show-options -qv -t "$TMUX_PANE" "$1" 2>/dev/null; fi
}
put() {
  if [ "$agent" = codex ]; then tmux set-option -pq -t "$TMUX_PANE" "$1" "$2" 2>/dev/null
  else tmux set-option -q -t "$TMUX_PANE" "$1" "$2" 2>/dev/null; fi
}
clear_codex_pane() {
  for option in @roamtty_session @roamtty_transcript @roamtty_agent @roamtty_task @roamtty_turn @roamtty_worked @roamtty_reply @roamtty_codex_cwd @roamtty_codex_thread @roamtty_codex_tracker @roamtty_codex_surface @roamtty_codex_home @roamtty_codex_version; do
    tmux set-option -u -pq -t "$TMUX_PANE" "$option" 2>/dev/null
  done
}
codex_unbind() {
  # Empty pane values mask session-level options left by older launchers.
  for option in @roamtty_codex_thread @roamtty_session @roamtty_transcript; do put "$option" ""; done
}

# These two fields agree only after the owning TUI identified its thread. Pane-local options keep split panes independent.
codex_bind() {
  if [ "$(get @roamtty_codex_thread)" != "$sid" ] || [ "$(get @roamtty_session)" != "$sid" ]; then
    put @roamtty_transcript ""
  fi
  put @roamtty_session "$sid"
  put @roamtty_codex_thread "$sid"
}

if [ "$agent" = codex ] && [ "$event" = bind ]; then
  TMUX_PANE=$session
  sid=$4
  case "$TMUX_PANE" in %*) ;; *) exit 1;; esac
  printf '%s\n' "$sid" | grep -Eq '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || exit 1
  [ "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null)" = "$TMUX_PANE" ] || exit 1
  codex_bind
  exit $?
fi

# A global hook can inherit the pane that launched the daemon. Only a direct hook from a
# Roamtty-launched CLI owns its pane. Stop at the first non-shell parent (e.g. a real Codex TUI).
if [ "$agent" = codex ] && [ -n "$in_pane" ] && [ -n "$input" ]; then
  if [ "$ROAMTTY_AGENT" != codex ]; then
    in_pane=
  else
    pid=$PPID
    while [ "$pid" -gt 1 ] 2>/dev/null; do
      program=$(ps -o comm= -p "$pid" 2>/dev/null)
      case "${program##*/}" in
        sh|bash|dash|zsh|ksh|env) ;;
        codex|codex-*)
          if [ -r "/proc/$pid/cmdline" ]; then
            subcommand=$(tr '\000' '\n' < "/proc/$pid/cmdline" | sed -n '2p')
          else
            args=$(ps -ww -o args= -p "$pid" 2>/dev/null)
            case "$args" in "$program "*) args=${args#"$program "} ;; *) args=${args#* } ;; esac
            subcommand=${args%% *}
          fi
          [ "$subcommand" != app-server ] || in_pane=
          break ;;
        *) break ;;
      esac
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    if [ -n "$in_pane" ] && [ "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null)" != "$TMUX_PANE" ]; then in_pane=; fi
  fi
fi

# Codex tool arguments can themselves contain session_id or transcript_path. Its identity
# belongs to the top-level envelope. Keep nested tool data available to the regular status parser.
if [ "$agent" = codex ] && [ -n "$input" ]; then
  envelope=$(printf '%s' "$input" | awk '{
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (!quoted && (c == "{" || c == "[")) depth++
      if (depth == 1) printf "%s", c
      if (quoted) {
        if (escaped) escaped = 0
        else if (c == "\\") escaped = 1
        else if (c == "\"") quoted = 0
      } else if (c == "\"") quoted = 1
      else if (c == "}" || c == "]") depth--
    }
  }')
  payload=$input
  input=$envelope
  [ -z "$(field agent_id 64)" ] || exit 0
  sid=$(field 'session_id|sessionId' 64)
  tpath=$(field 'transcript_path|transcriptPath' 400)
  hook_cwd=$(field cwd 400)
  hook_source=$(field source)
  input=$payload
fi

if [ "$agent" = claude ] && [ -z "$in_pane" ] && [ -n "$session" ]; then
  tmux has-session -t "=$session" 2>/dev/null || exit 0
  TMUX_PANE="=$session:"
elif [ -n "$in_pane" ]; then
  # A new foreground agent replaces even a Codex launcher that died before its end hook.
  if [ "$event" = start ] && [ "$agent" != codex ] && [ -n "$(tmux show-options -pqv -t "$TMUX_PANE" @roamtty_codex_cwd 2>/dev/null)" ]; then
    clear_codex_pane
  fi
  # A background Claude session may continue to report past the foreground session's end.
  prev_sid=$(get @roamtty_session)
  if [ "$agent" != codex ]; then
    sid=$(field 'session_id|sessionId|conversationId' 64)
    tpath=$(field 'transcript_path|transcriptPath' 400)
  fi
  if [ "$agent" = codex ] && [ -n "$sid" ]; then
    # Embedded Codex also reports SessionEnd when switching an otherwise live TUI to another thread.
    if [ "$event" = end ]; then
      if [ -z "$(get @roamtty_codex_tracker)" ] && [ "$prev_sid" = "$sid" ]; then codex_unbind; fi
      exit 0
    fi
    if [ -n "$(get @roamtty_codex_tracker)" ]; then
      [ "$(sh "$0" codex current "$TMUX_PANE" </dev/null 2>/dev/null)" = "$sid" ] || exit 0
    fi
    codex_bind
  elif [ "$agent" = claude ]; then put @roamtty_session "$sid"
  elif [ -n "$sid" ]; then put @roamtty_session "$sid"; fi
  if [ -n "$tpath" ]; then put @roamtty_transcript "$tpath"
  elif [ "$agent" != codex ] && [ -n "$sid" ] && [ "$sid" != "$prev_sid" ]; then tmux set-option -u -q -t "$TMUX_PANE" @roamtty_transcript 2>/dev/null; fi
elif [ "$agent" = codex ]; then
  [ -n "$sid" ] || exit 0
  # A directory can be shared with unmanaged sessions. Only the pane's confirmed
  # identity permits a daemon event to change its state.
  TMUX_PANE=$(tmux list-panes -a -F '#{pane_id}	#{@roamtty_session}	#{@roamtty_codex_thread}' 2>/dev/null |
    awk -F '\t' -v id="$sid" '$2 == id && $3 == id { pane=$1; n++ } END { if (n == 1) print pane }')
  if [ -z "$TMUX_PANE" ]; then
    [ "$event" = start ] || exit 0
    case "$hook_source" in compact) exit 0 ;; esac
    # A live tracker observes its own TUI switches. An unrelated same-directory start
    # cannot invalidate it, including when the user's OSC title is disabled.
    [ -n "$hook_cwd" ] || exit 0
    canon_cwd=$(cd "$hook_cwd" 2>/dev/null && pwd -P || printf '%s' "$hook_cwd")
    tmux list-panes -a -F '#{pane_id}	#{@roamtty_codex_cwd}	#{pane_current_path}	#{@roamtty_codex_thread}	#{@roamtty_agent}	#{@roamtty_codex_tracker}' 2>/dev/null |
      awk -F '\t' -v cwd="$canon_cwd" -v raw="$hook_cwd" '($2 == cwd || $2 == raw || $3 == cwd || $3 == raw) && ($4 != "" || $5 ~ /^[^|]*\|[^|]*\|codex\|/) { print $1, $6 }' |
      while read -r TMUX_PANE tracker; do
        case "$tracker" in ''|*[!0-9]*) ;; *) kill -0 "$tracker" 2>/dev/null && continue ;; esac
        codex_unbind
      done
    exit 0
  fi
  # A delayed event can still match both cached markers just after /resume.
  # Validate the currently displayed identity before changing a tracked pane.
  if [ -n "$(get @roamtty_codex_tracker)" ]; then
    [ "$(sh "$0" codex current "$TMUX_PANE" </dev/null 2>/dev/null)" = "$sid" ] || exit 0
  fi
  if [ "$event" = end ]; then codex_unbind; exit 0; fi
  if [ -n "$tpath" ]; then put @roamtty_transcript "$tpath"; fi
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
    if [ -n "$in_pane" ] && [ -z "$input" ]; then
      if [ "$agent" = codex ]; then
        tmux set-option -u -pq -t "$TMUX_PANE" @roamtty_agy_mic 2>/dev/null
        tmux set-option -u -pq -t "$TMUX_PANE" @roamtty_codex_tracker 2>/dev/null
        codex_unbind
        put @roamtty_codex_cwd "$(pwd -P)"
      elif [ "$agent" = agy ]; then
        tmux set-option -pq -t "$TMUX_PANE" @roamtty_agy_mic "${ANTIGRAVITY_MIC:-}" 2>/dev/null
      fi
    fi
    if [ "$agent" = codex ]; then
      for option in @roamtty_worked @roamtty_reply; do put "$option" ""; done
    else
      for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    fi
    if [ "$agent" != codex ] && [ -z "$sid" ] && [ -z "$tpath" ]; then
      for option in @roamtty_session @roamtty_transcript; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    fi
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
    # Codex voice turns submit "<realtime_delegation><input>…</input>…</realtime_delegation>", and emit a housekeeping
    # "<source>transcript_tail_flush</source>" turn when voice ends (ignore tail flush so it never wipes the real reply).
    task=$(field 'prompt|lastUserInput' 200)
    if [ "$agent" = codex ]; then
      raw_task=$(field 'prompt|lastUserInput' 500)
      case "$raw_task" in
        *'<source>transcript_tail_flush</source>'*) exit 0 ;;
        '<realtime_delegation>'*'<input>'*)
          task=$(printf '%s' "$raw_task" | sed -E 's/^.*<input>//; s/<\/input>.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200) ;;
      esac
    fi
    prev_task=$(get @roamtty_task)
    case "$task" in "<"*) ;; *) [ -z "$task" ] || put @roamtty_task "$task" ;; esac
    # A turn starts: the time it began, for how long it worked once it stops. A turn that waited for background work
    # (see stop) goes on when that work ends and wakes the agent.
    case "$agent:$task:$(get @roamtty_agent)" in
      *:"<"*:working\|*) ;;
      agy:*:working\|*\|Background\|*) [ -z "$task" ] || [ "$task" = "$prev_task" ] || put @roamtty_turn "$(date +%s)" ;;
      *) put @roamtty_turn "$(date +%s)" ;;
    esac
    if [ "$agent" = codex ]; then
      for option in @roamtty_worked @roamtty_reply; do put "$option" ""; done
    else
      for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    fi
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
    [ -n "$reply" ] || reply=$(field error_details 200)
    [ -n "$reply" ] || reply=$(field error 200)
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
    # Ignore Codex housekeeping stops (e.g. transcript_tail_flush) that carry no reply when the pane is already idle.
    if [ "$agent" = codex ] && [ -z "$reply" ]; then
      case "$(get @roamtty_agent)" in idle\|*) exit 0 ;; esac
    fi
    turn=$(get @roamtty_turn)
    case "$turn" in ''|*[!0-9]*) ;; *) put @roamtty_worked "$(( $(date +%s) - turn ))" ;; esac
    record idle "" "" ;;
  end)
    if [ "$agent" = codex ]; then
      clear_codex_pane
      exit 0
    fi
    if [ "$agent" = agy ]; then tmux set-option -u -pq -t "$TMUX_PANE" @roamtty_agy_mic 2>/dev/null; fi
    for option in @roamtty_agent @roamtty_task @roamtty_turn @roamtty_worked @roamtty_reply @roamtty_owner @roamtty_transcript @roamtty_codex_cwd @roamtty_codex_start; do
      tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null
    done ;;
esac
exit 0
