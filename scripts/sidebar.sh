#!/usr/bin/env bash
# Renders the window list inside a sidebar pane. Started by herdr.sh.
# Redraws on SIGUSR1 (sent from tmux hooks), SIGWINCH and periodically.

pane=${TMUX_PANE:?must run inside a tmux pane}

POLL=0.1          # input/signal latency in seconds
FALLBACK_TICKS=20 # force a refresh every FALLBACK_TICKS * POLL seconds

ESC=$'\e'
RESET="${ESC}[0m"

ellipsis='…'
((${#ellipsis} == 1)) || ellipsis='~'

dirty=1
last_frame=
session_id=
declare -a row_window=()
declare -A agent_icons=() agent_styles=()
icon_w=0

# Per pane "state/command/pid " tokens: state and agent pid come from pane
# options set by agent hooks, else "running" if the pane looks like a known
# agent (Copilot runs as node, so it's matched by title). Sidebar panes are
# skipped.
AGENT_DETECT='#{||:#{m:*GitHub Copilot,#{pane_title}},#{m/r:^(claude|codex|opencode|pi|hermes)$,#{pane_current_command}}}'
AGENT_FORMAT="#{P:#{?@herdr_sidebar,,#{?@herdr_agent,#{@herdr_agent},#{?${AGENT_DETECT},running,none}}/#{pane_current_command}/#{@herdr_agent_pid} }}"
SHELL_RE='^-?(ba|z|fi|k|tc|c|da|nu|a)?sh$'

trap 'dirty=1' USR1 WINCH
trap 'exit 0' TERM HUP INT
trap 'printf "%s" "${RESET}${ESC}[?1006l${ESC}[?1000l${ESC}[?25h"' EXIT

# Converts a tmux style (e.g. "fg=black,bg=green,bold") to an SGR sequence.
style_to_sgr() {
	local part key value base codes=(0) names=(black red green yellow blue magenta cyan white) i
	local IFS=', '
	for part in $1; do
		case $part in
		fg=* | bg=*)
			key=${part%%=*} value=${part#*=}
			[[ $key == fg ]] && base=30 || base=40
			case $value in
			default) codes+=($((base + 9))) ;;
			colour[0-9]* | color[0-9]*) codes+=("$((base + 8));5;${value##*[a-z]}") ;;
			'#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
				codes+=("$((base + 8));2;$((16#${value:1:2}));$((16#${value:3:2}));$((16#${value:5:2}))")
				;;
			*)
				for i in "${!names[@]}"; do
					if [[ $value == "${names[i]}" ]]; then
						codes+=($((base + i)))
					elif [[ $value == "bright${names[i]}" ]]; then
						codes+=($((base + 60 + i)))
					fi
				done
				;;
			esac
			;;
		bold | bright) codes+=(1) ;;
		dim) codes+=(2) ;;
		italics) codes+=(3) ;;
		underscore) codes+=(4) ;;
		blink) codes+=(5) ;;
		reverse) codes+=(7) ;;
		hidden) codes+=(8) ;;
		strikethrough) codes+=(9) ;;
		esac
	done
	IFS=';'
	printf '%s[%sm' "$ESC" "${codes[*]}"
}

# Pads or truncates $1 to exactly $2 columns.
fit() {
	local text=$1 width=$2
	((width > 0)) || return 0
	if ((${#text} > width)); then
		text="${text:0:width-1}${ellipsis}"
	fi
	printf '%-*s' "$width" "$text"
}

declare -A sgr_cache=()

# Sets REPLY to the SGR sequence for a tmux style, caching conversions.
sgr() {
	if [[ -z ${sgr_cache[$1]+set} ]]; then
		sgr_cache[$1]=$(style_to_sgr "$1")
	fi
	REPLY=${sgr_cache[$1]}
}

# Reduces the per-pane tokens of a window to one state:
# waiting > working > idle > running (Copilot detected by title, state
# unknown) > busy (some other program is running) > shell (every pane is at
# a shell prompt).
# Hook states are stale once the agent pid is gone; title matches are stale
# once the pane is back at a shell prompt.
window_agent_state() {
	local token state cmd pid best='' rank best_rank=0 any=0
	for token in $1; do
		IFS=/ read -r state cmd pid <<<"$token"
		any=1
		if [[ $state == running ]]; then
			[[ $cmd =~ $SHELL_RE ]] && state=none
		elif [[ $state != none && -n $pid ]]; then
			kill -0 "$pid" 2>/dev/null || state=none
		fi
		[[ $state == none && ! $cmd =~ $SHELL_RE ]] && state=busy
		case $state in
		waiting) rank=5 ;;
		working) rank=4 ;;
		idle) rank=3 ;;
		running) rank=2 ;;
		busy) rank=1 ;;
		*) rank=0 ;;
		esac
		((rank > best_rank)) && best=$state best_rank=$rank
	done
	[[ -z $best ]] && ((any)) && best=shell
	REPLY=$best
}

render() {
	# Fields are '|'-separated (tab is IFS whitespace, so empty fields would
	# collapse); free-form names come last so they may contain '|'.
	local info panes width height zoomed want style active_style header_style show_header session_name
	info=$(tmux display-message -p -t "$pane" \
		'#{session_id}|#{window_panes}|#{pane_width}|#{pane_height}|#{window_zoomed_flag}|#{@herdr-width}|#{@herdr-style}|#{@herdr-active-style}|#{@herdr-header-style}|#{@herdr-header}|#{session_name}' \
		2>/dev/null) || exit 0
	IFS='|' read -r session_id panes width height zoomed want style active_style header_style show_header session_name <<<"$info"

	# Nothing left to be a sidebar for: exit so tmux closes the window.
	((panes <= 1)) && exit 0

	want=${want:-25}
	if [[ $want =~ ^[0-9]+$ ]] && ((width != want && zoomed == 0)); then
		tmux resize-pane -t "$pane" -x "$want" 2>/dev/null
	fi

	local normal_sgr active_sgr header_sgr
	sgr "${style:-default}" && normal_sgr=$REPLY
	sgr "${active_style:-fg=black,bg=green,bold}" && active_sgr=$REPLY
	sgr "${header_style:-bold}" && header_sgr=$REPLY

	local -a lines=() sgrs=() targets=()
	if [[ ${show_header:-on} == on ]]; then
		lines+=("$(fit " ${session_name}" "$width")") sgrs+=("$header_sgr") targets+=("")
		lines+=("$(fit "" "$width")") sgrs+=("$normal_sgr") targets+=("")
	fi

	# Status icons sit in their own column outside the highlighted bar, so they
	# keep their colours (and stay visible) on the active line too.
	local label_w=$width
	((icon_w > 0)) && label_w=$((width - icon_w - 1))

	local index is_active flags agents name marks text icon cell_sgr active_line=0
	while IFS='|' read -r index is_active flags agents name; do
		if ((is_active)); then
			active_line=${#lines[@]}
			sgrs+=("$active_sgr")
		else
			sgrs+=("$normal_sgr")
		fi

		marks=${flags//[*-]/}
		if [[ -n $marks ]]; then
			text="$(fit " ${index} ${name}" $((label_w - ${#marks} - 2))) ${marks} "
		else
			text="$(fit " ${index} ${name}" $((label_w - 1))) "
		fi

		if ((icon_w > 0)); then
			window_agent_state "$agents"
			icon='' cell_sgr=$normal_sgr
			if [[ -n $REPLY && ${agent_icons[$REPLY]} != none ]]; then
				icon=${agent_icons[$REPLY]}
				sgr "${style:-default},${agent_styles[$REPLY]}" && cell_sgr=$REPLY
			fi
			text+="${RESET}${cell_sgr}$(fit "$icon" "$icon_w") "
		fi
		lines+=("$text") targets+=("$index")
	done < <(tmux list-windows -t "$session_id" -F "#{window_index}|#{window_active}|#{window_flags}|${AGENT_FORMAT}|#{window_name}" 2>/dev/null)

	# Scroll so the active window stays visible on short panes.
	local offset=0 i row
	((active_line >= height)) && offset=$((active_line - height + 1))

	local frame="${ESC}[H"
	row_window=()
	for ((i = offset, row = 1; i < ${#lines[@]} && row <= height; i++, row++)); do
		frame+="${sgrs[i]}${lines[i]}${RESET}"
		((row < height)) && frame+=$'\r\n'
		row_window[row]=${targets[i]}
	done
	frame+="${ESC}[J"

	if [[ $frame != "$last_frame" ]]; then
		printf '%s' "$frame"
		last_frame=$frame
	fi
}

# Loads agent/shell/busy status icons and styles ("none" hides an icon); re-read on every fallback refresh.
load_agent_options() {
	local values
	values=$(tmux display-message -p -t "$pane" \
		'#{@herdr-agent-working-icon}|#{@herdr-agent-working-style}|#{@herdr-agent-waiting-icon}|#{@herdr-agent-waiting-style}|#{@herdr-agent-idle-icon}|#{@herdr-agent-idle-style}|#{@herdr-agent-running-icon}|#{@herdr-agent-running-style}|#{@herdr-shell-icon}|#{@herdr-shell-style}|#{@herdr-busy-icon}|#{@herdr-busy-style}' \
		2>/dev/null) || return
	local wi ws ai as ii is ri rs si ss bi bs key
	IFS='|' read -r wi ws ai as ii is ri rs si ss bi bs <<<"$values"
	agent_icons=([working]=${wi:-●} [waiting]=${ai:-●} [idle]=${ii:-●} [running]=${ri:-◌} [shell]=${si:-\$} [busy]=${bi:-●})
	agent_styles=(
		[working]=${ws:-fg=brightyellow,bold} [waiting]=${as:-fg=brightred,bold}
		[idle]=${is:-fg=brightgreen,bold} [running]=${rs:-dim}
		[shell]=${ss:-dim} [busy]=${bs:-fg=brightmagenta,bold}
	)
	icon_w=0
	for key in "${!agent_icons[@]}"; do
		[[ ${agent_icons[$key]} == none ]] && continue
		((${#agent_icons[$key]} > icon_w)) && icon_w=${#agent_icons[$key]}
	done
}

focus_away() {
	tmux last-pane -t "$pane" 2>/dev/null || tmux select-pane -t "$pane" -R 2>/dev/null
}

handle_input() {
	local key=$1 seq='' c
	if [[ $key != "$ESC" ]]; then
		focus_away
		return
	fi
	while read -rsn1 -t 0.01 c; do
		seq+=$c
		[[ $c == [Mm~] || ${#seq} -gt 32 ]] && break
	done
	# SGR mouse report: ESC [ < button ; column ; row M
	if [[ $seq =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)M$ ]]; then
		local button=${BASH_REMATCH[1]} row=${BASH_REMATCH[3]}
		((button == 0)) || return
		local target=${row_window[row]:-}
		focus_away
		[[ -n $target ]] && tmux select-window -t "${session_id}:${target}" 2>/dev/null
		return
	fi
	[[ -z $seq ]] && focus_away
}

# Advertise our pid only now that the USR1 trap is in place.
tmux set-option -p -t "$pane" @herdr_sidebar 1 \; set-option -p -t "$pane" @herdr_pid "$$" 2>/dev/null
tmux select-pane -t "$pane" -T herdr 2>/dev/null

# Hide cursor, enable mouse click reporting (SGR encoding).
printf '%s' "${ESC}[?25l${ESC}[?1000h${ESC}[?1006h${ESC}[2J"

load_agent_options
ticks=0
while :; do
	if ((dirty || ticks >= FALLBACK_TICKS)); then
		((ticks >= FALLBACK_TICKS)) && load_agent_options
		dirty=0 ticks=0
		render
	fi
	if read -rsn1 -t "$POLL" key; then
		handle_input "$key"
	elif (($? <= 128)); then
		sleep "$POLL" # stdin closed; avoid spinning
	fi
	((ticks++))
done
