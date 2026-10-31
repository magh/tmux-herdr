#!/usr/bin/env bash
# tmux-herdr: Codex CLI hook wrapper.
# Installed by tmux-herdr's install-agent-hooks.sh; reinstalling overwrites it.
#
# Hooks run either in the codex TUI process or in the shared app-server
# daemon, whose environment belongs to the pane that started it. Resolve the
# pane of the codex session this event came from (matching its cwd) and
# report there instead. When no pane can be identified, only report to the
# hook's own pane while it is running codex, so a stale environment can't
# pollute a shell pane.
# Always exits 0 so it can never block or alter the agent.

state=${1:-}
payload=
[[ -t 0 ]] || payload=$(cat)
cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')

target=${TMUX_PANE:-}
if [[ -n ${TMUX:-} && -n $target ]]; then
	panes=$(tmux list-panes -a -F '#{pane_id}|#{pane_current_path}|#{pane_current_command}' 2>/dev/null)
	if [[ -n $cwd ]]; then
		candidates=$(awk -F'|' -v d="$cwd" '$2 == d && $3 == "codex" { print $1 }' <<<"$panes")
		if [[ -n $candidates ]]; then
			grep -qx -- "$target" <<<"$candidates" || target=$(head -n1 <<<"$candidates")
		fi
	fi
	# The fallback target (the hook's own pane) is only valid while it is
	# actually running codex; a stale daemon environment must not report to
	# a shell or some other program.
	if [[ $(awk -F'|' -v t="$target" '$1 == t { print $3; exit }' <<<"$panes") != codex ]]; then
		exit 0
	fi
fi

AGENT_STATE="@AGENT_STATE@"
TMUX_PANE=$target exec "$AGENT_STATE" "$state"
