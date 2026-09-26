#!/usr/bin/env bash
# Records a coding agent's status on its tmux pane so the sidebar can show it.
# Called from agent hooks/plugins: agent-state.sh working|waiting|idle|clear
# Always exits 0 and prints nothing, so it can never block or alter the agent.

state=${1:-}
[[ -t 0 ]] || cat >/dev/null # drain the hook's JSON payload
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The first non-shell ancestor is the agent process itself; the sidebar uses
# its pid to ignore state left behind if the agent dies without a sessionEnd.
agent_pid() {
	local pid=$PPID comm
	while ((pid > 1)); do
		comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return
		[[ $comm =~ ^-?(ba|z|fi|k|tc|c|da)?sh$ ]] || break
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null) || return
		pid=${pid//[^0-9]/}
	done
	echo "$pid"
}

# The option is set synchronously so back-to-back hook calls can't be applied
# out of order; only the sidebar redraw runs in the background.
case $state in
working | waiting | idle)
	tmux set-option -p -t "$TMUX_PANE" @herdr_agent "$state" \; \
		set-option -p -t "$TMUX_PANE" @herdr_agent_pid "$(agent_pid)" >/dev/null 2>&1
	;;
clear)
	tmux set-option -pu -t "$TMUX_PANE" @herdr_agent \; \
		set-option -pu -t "$TMUX_PANE" @herdr_agent_pid >/dev/null 2>&1
	;;
*) exit 0 ;;
esac

"$SCRIPTS_DIR/herdr.sh" refresh </dev/null >/dev/null 2>&1 &

exit 0
