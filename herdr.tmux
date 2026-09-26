#!/usr/bin/env bash
# tmux-herdr: a vertical window list sidebar for tmux.
# Load with TPM (set -g @plugin ...) or directly: run-shell /path/to/herdr.tmux

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR="$CURRENT_DIR/scripts/herdr.sh"

get_opt() {
	local value
	value=$(tmux show-option -gqv "$1")
	echo "${value:-$2}"
}

# Fixed hook array index so re-sourcing the config doesn't stack duplicates
# and user-defined hooks at other indices are left alone.
HOOK_INDEX=4242

key=$(get_opt @herdr-key B)
if [[ -n $key && $key != none ]]; then
	tmux bind-key "$key" run-shell "'$HERDR' toggle"
fi

refresh_hooks=(
	window-linked window-unlinked window-renamed window-layout-changed
	session-window-changed session-renamed client-session-changed
	alert-bell alert-activity alert-silence
	pane-exited after-kill-pane after-swap-window after-move-window
)
for hook in "${refresh_hooks[@]}"; do
	tmux set-hook -g "${hook}[$HOOK_INDEX]" "run-shell -b '$HERDR refresh'"
done

# Not backgrounded: running synchronously serialises hook invocations, which
# avoids races that could create two sidebars in the same window.
for hook in after-new-window session-created; do
	tmux set-hook -g "${hook}[$HOOK_INDEX]" "run-shell '$HERDR ensure'"
done

"$HERDR" ensure
