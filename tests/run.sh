#!/usr/bin/env bash
# Integration tests: runs an isolated tmux server and exercises the sidebar.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="herdr-test-$$"
CONF=$(mktemp)
WRAPPER=$(mktemp)
failures=0

t() { tmux -L "$SOCKET" "$@"; }

cleanup() {
	t kill-server 2>/dev/null
	rm -f "$CONF" "$WRAPPER"
}
trap cleanup EXIT

pass() { printf 'ok   - %s\n' "$1"; }
fail() {
	printf 'FAIL - %s\n' "$1"
	[[ -n ${2:-} ]] && printf '       %s\n' "$2"
	failures=$((failures + 1))
}

# Retries a command for up to ~3s; hooks and redraws are asynchronous.
eventually() {
	local i
	for ((i = 0; i < 30; i++)); do
		"$@" && return 0
		sleep 0.1
	done
	return 1
}

sidebar_in() { t list-panes -t "$1" -F '#{@herdr_sidebar}' | grep -qx 1; }
no_sidebar_in() { ! sidebar_in "$1"; }
sidebar_pane() { t list-panes -t "$1" -F '#{pane_id} #{@herdr_sidebar}' | awk '$2 == "1" { print $1 }'; }
sidebar_shows() { t capture-pane -p -t "$(sidebar_pane "$1")" | grep -q -- "$2"; }
active_window() { t display-message -p -t t '#{window_index}'; }
window_is_active() { [[ $(active_window) == "$1" ]]; }
window_count_is() { [[ $(t list-windows -t t | wc -l) -eq $1 ]]; }

check() {
	local name=$1
	shift
	if eventually "$@"; then pass "$name"; else fail "$name"; fi
}

cat >"$CONF" <<EOF
set -g @herdr-enabled on
set -g mouse on
run-shell '$ROOT/herdr.tmux'
EOF

t -f "$CONF" new-session -d -s t -x 120 -y 30 -n first

check "sidebar opens in first window of a new session" sidebar_in t:first

pane=$(sidebar_pane t:first)
geometry=$(t display-message -p -t "$pane" '#{pane_left} #{pane_width} #{pane_height}')
if [[ $geometry == "0 25 30" ]]; then pass "sidebar is full-height, 25 wide, on the left"; else fail "sidebar geometry" "got: $geometry"; fi

if [[ $(t display-message -p -t t:first '#{@herdr_sidebar}') != 1 ]]; then
	pass "focus stays on the main pane"
else
	fail "focus stays on the main pane"
fi

check "sidebar lists the window" sidebar_shows t:first ' 0 first'

t new-window -t t -n second
check "new window gets a sidebar" sidebar_in t:second
check "new window is listed in the other sidebar" sidebar_shows t:first ' 1 second'

if [[ $(t display-message -p -t t:second '#{@herdr_sidebar}') != 1 ]]; then
	pass "focus in new window is on the main pane"
else
	fail "focus in new window is on the main pane"
fi

t rename-window -t t:second renamed
check "rename shows up in sidebar" sidebar_shows t:renamed ' 1 renamed'

# Active line is rendered with the active style (reverse video / colours).
active_has_style() { t capture-pane -ep -t "$(sidebar_pane t:renamed)" | grep -q $'\e\\[[0-9;]*m 1 renamed'; }
check "active window is highlighted" active_has_style

# Simulate a mouse click on the row of window 0 (header, blank, window 0 = row 3).
t send-keys -t "$(sidebar_pane t:renamed)" -l $'\e[<0;3;3M'
check "clicking a window in the sidebar selects it" window_is_active 0

t select-window -t t:renamed
t select-pane -t "$(sidebar_pane t:renamed)"
t send-keys -t "$(sidebar_pane t:renamed)" x
focus_left_sidebar() { [[ $(t display-message -p -t t:renamed '#{@herdr_sidebar}') != 1 ]]; }
check "pressing a key in the sidebar returns focus" focus_left_sidebar

t select-layout -t t:renamed even-horizontal
width_restored() { [[ $(t display-message -p -t "$(sidebar_pane t:renamed)" '#{pane_width}') == 25 ]]; }
check "sidebar width is restored after layout change" width_restored

t split-window -t t:renamed -h
t kill-pane -t t:renamed.2
check "window survives while a real pane remains" window_count_is 2

main=$(t list-panes -t t:renamed -F '#{pane_id} #{@herdr_sidebar}' | awk '$2 != "1" { print $1; exit }')
t kill-pane -t "$main"
check "window closes when only the sidebar remains" window_count_is 1

t run-shell "$ROOT/scripts/herdr.sh toggle"
check "toggle closes sidebars" no_sidebar_in t:first
t new-window -t t -n third
sleep 0.3
if no_sidebar_in t:third; then pass "no sidebar in new windows while disabled"; else fail "no sidebar in new windows while disabled"; fi

t run-shell "$ROOT/scripts/herdr.sh toggle"
check "toggle reopens sidebars in all windows" sidebar_in t:first
check "toggle reopens sidebars in all windows (2)" sidebar_in t:third

count=$(t list-panes -a -F '#{@herdr_sidebar}' | grep -cx 1)
if [[ $count -eq 2 ]]; then pass "exactly one sidebar per window"; else fail "exactly one sidebar per window" "got $count"; fi

# --- agent status -----------------------------------------------------------
t new-window -t t: -n agent 'sleep 1000'
check "agent window gets a sidebar" sidebar_in t:agent
agent_pane=$(t list-panes -t t:agent -F '#{pane_id} #{@herdr_sidebar}' | awk '$2 != "1" { print $1 }')
socket=$(t display-message -p '#{socket_path}')
agent_state() { TMUX="$socket,0,0" TMUX_PANE=$agent_pane "$ROOT/scripts/agent-state.sh" "$1" </dev/null; }
t select-window -t t:first
agent_line_has() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- " agent .*$1 *\$"; }
# Every agent state is a ● and they differ by colour: 91 bright red (waiting),
# 92 bright green (idle), 93 bright yellow (working), 95 bright magenta (busy).
# Usage: line_ball SIDEBAR_WINDOW LINE_TEXT COLOUR
line_ball() { t capture-pane -ep -t "$(sidebar_pane "$1")" | grep -q -- " $2 .*"$'\e'"\\[$3m●"; }
agent_line_working() { line_ball t:first agent 93; }
agent_line_waiting() { line_ball t:first agent 91; }
agent_line_idle() { line_ball t:first agent 92; }
agent_line_busy() { line_ball t:first agent 95; }
agent_line_plain() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- ' agent *$'; }

agent_state working
check "working agent is shown" agent_line_working
agent_state waiting
check "agent waiting for input is shown" agent_line_waiting
agent_state idle
check "idle agent is shown" agent_line_idle
t select-window -t t:agent
active_line_idle() { line_ball t:agent agent 92; }
check "status ball keeps its colour on the active line" active_line_idle
t select-window -t t:first

agent_state clear
check "cleared agent falls back to busy" agent_line_busy

t select-pane -t "$agent_pane" -T 'Some task - GitHub Copilot'
t run-shell "$ROOT/scripts/herdr.sh refresh"
check "copilot detected by pane title without hooks" agent_line_has ◌

t select-pane -t "$agent_pane" -T plain
t set-option -p -t "$agent_pane" @herdr_agent working \; set-option -p -t "$agent_pane" @herdr_agent_pid 999999999
t run-shell "$ROOT/scripts/herdr.sh refresh"
check "state from an agent that is no longer running is ignored" agent_line_busy

t select-pane -t t:first.1 -T 'Old - GitHub Copilot'
t run-shell "$ROOT/scripts/herdr.sh refresh"
first_line_has() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- " first .*$1 *\$"; }
check "copilot title on a shell prompt is ignored (shown as shell)" first_line_has '\$'

# --- shell indicator ----------------------------------------------------------
check "window at a shell prompt gets the shell indicator" first_line_has '\$'
check "window running another program gets the busy indicator" agent_line_busy
t split-window -d -t "$agent_pane"
t run-shell "$ROOT/scripts/herdr.sh refresh"
sleep 0.5
if agent_line_busy; then pass "window with a busy pane and a shell is busy"; else fail "window with a busy pane and a shell is busy"; fi
t set-option -g @herdr-shell-icon none
t run-shell "$ROOT/scripts/herdr.sh refresh"
sleep 2.5 # options are re-read on the fallback refresh
first_line_plain() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- ' first *$'; }
check "shell indicator can be disabled" first_line_plain

t new-window -d -t t: -n detect 'exec -a claude sleep 1000'
detect_line_running() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- ' detect .*◌ *$'; }
check "claude/opencode/pi/hermes detected by process name" detect_line_running

t new-window -d -t t: -n detect2 'exec -a codex sleep 1000'
detect2_line_running() { t capture-pane -p -t "$(sidebar_pane t:first)" | grep -q -- ' detect2 .*◌ *$'; }
check "codex detected by process name" detect2_line_running

# --- codex hook wrapper ---------------------------------------------------------
# Hooks may run in the shared app-server daemon, whose environment belongs to
# the pane that started it; the wrapper must report to the pane of the codex
# session the event came from (matched by cwd), and must not pollute a pane
# that is not running codex.
# A distinct cwd keeps the pane unambiguous (detect2 above also runs "codex").
t new-window -d -t t: -n codexwrap -c /tmp 'exec -a codex sleep 1000'
codex_pane=$(t list-panes -t t:codexwrap -F '#{pane_id} #{@herdr_sidebar}' | awk '$2 != "1" { print $1; exit }')
codex_cwd=$(t display-message -p -t "$codex_pane" '#{pane_current_path}')
shell_pane=$(t list-panes -t t:codexwrap -F '#{pane_id} #{@herdr_sidebar}' | awk '$2 == "1" { print $1 }')
sed "s|@AGENT_STATE@|$ROOT/scripts/agent-state.sh|" "$ROOT/integrations/codex.sh" >"$WRAPPER"
codex_wrap() { TMUX="$socket,0,0" TMUX_PANE=$1 bash "$WRAPPER" "$2" <<<"$3"; }
pane_agent() { t display-message -p -t "$1" '#{@herdr_agent}'; }

codex_wrap "$shell_pane" working "{\"cwd\":\"$codex_cwd\"}"
codex_pane_working() { [[ $(pane_agent "$codex_pane") == working ]]; }
check "codex wrapper reports to the pane matching the payload cwd" codex_pane_working
shell_pane_clean() { [[ -z $(pane_agent "$shell_pane") ]]; }
check "codex wrapper leaves other panes untouched" shell_pane_clean

codex_wrap "$codex_pane" idle "{\"cwd\":\"$codex_cwd\"}"
codex_pane_idle() { [[ $(pane_agent "$codex_pane") == idle ]]; }
check "codex wrapper keeps its own pane when it matches" codex_pane_idle

codex_wrap "$shell_pane" working '{"cwd":"/nonexistent-herdr-test"}'
check "codex wrapper does not pollute a non-codex pane" shell_pane_clean

TMUX_PANE="$codex_pane" bash "$WRAPPER" working <<<'{}'
check "codex wrapper stays quiet outside tmux" codex_pane_idle

echo
if ((failures)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all tests passed"
