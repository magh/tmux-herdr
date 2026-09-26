#!/usr/bin/env bash
# Control script for the herdr sidebar.
# Usage: herdr.sh toggle|open|close|ensure|refresh

set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR="$SCRIPTS_DIR/sidebar.sh"

get_opt() {
	local value
	value=$(tmux show-option -gqv "$1")
	echo "${value:-$2}"
}

is_enabled() {
	[[ $(get_opt @herdr-enabled off) == on ]]
}

# Prints "window_id pane_id renderer_pid" for every sidebar pane on the server.
# renderer_pid is "-" until the renderer has installed its signal handlers.
sidebar_panes() {
	tmux list-panes -a -F '#{window_id} #{pane_id} #{?@herdr_pid,#{@herdr_pid},-} #{@herdr_sidebar}' 2>/dev/null |
		awk '$4 == "1" { print $1, $2, $3 }'
}

open_in_window() {
	local window=$1 width pane
	width=$(get_opt @herdr-width 25)
	pane=$(tmux split-window -hbfd -l "$width" -t "$window" -P -F '#{pane_id}' \
		"exec bash '$SIDEBAR'" 2>/dev/null) || return 0
	tmux set-option -p -t "$pane" @herdr_sidebar 1
}

ensure() {
	is_enabled || return 0
	local have window
	have=$(sidebar_panes | awk '{ print $1 }')
	while read -r window; do
		[[ -z $window ]] && continue
		grep -qxF -- "$window" <<<"$have" || open_in_window "$window"
	done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null | sort -u)
}

close_all() {
	local _window pane _pid
	while read -r _window pane _pid; do
		tmux kill-pane -t "$pane" 2>/dev/null
	done < <(sidebar_panes)
}

refresh() {
	local _window _pane pid
	while read -r _window _pane pid; do
		# Signalling before the trap is installed would kill the renderer.
		[[ $pid == - ]] && continue
		kill -USR1 "$pid" 2>/dev/null
	done < <(sidebar_panes)
}

case "${1:-}" in
toggle)
	if is_enabled; then
		tmux set-option -g @herdr-enabled off
		close_all
	else
		tmux set-option -g @herdr-enabled on
		ensure
	fi
	;;
open)
	tmux set-option -g @herdr-enabled on
	ensure
	;;
close)
	tmux set-option -g @herdr-enabled off
	close_all
	;;
ensure) ensure ;;
refresh) refresh ;;
*)
	echo "usage: $0 toggle|open|close|ensure|refresh" >&2
	exit 2
	;;
esac
