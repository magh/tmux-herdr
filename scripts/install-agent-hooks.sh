#!/usr/bin/env bash
# Installs (or with --uninstall removes) hooks/plugins that report coding agent
# working/waiting/idle status to the herdr sidebar.
#
# Usage: install-agent-hooks.sh [--uninstall] [copilot|claude|opencode|pi|hermes ...]
# Without agent names, every supported agent found on this machine is handled.

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_STATE="$ROOT/scripts/agent-state.sh"
MARKER=tmux-herdr
ALL_AGENTS=(copilot claude opencode pi hermes)

COPILOT_DIR=${COPILOT_HOME:-$HOME/.copilot}
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
OPENCODE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/opencode
PI_DIR=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
HERMES_DIR=${HERMES_HOME:-$HOME/.hermes}

uninstall=0
agents=()
for arg in "$@"; do
	case $arg in
	--uninstall) uninstall=1 ;;
	copilot | claude | opencode | pi | hermes) agents+=("$arg") ;;
	-h | --help)
		sed -n '2,6s/^# \{0,1\}//p' "$0"
		exit 0
		;;
	*)
		echo "unknown agent: $arg (supported: ${ALL_AGENTS[*]})" >&2
		exit 2
		;;
	esac
done

config_dir() {
	case $1 in
	copilot) echo "$COPILOT_DIR" ;;
	claude) echo "$CLAUDE_DIR" ;;
	opencode) echo "$OPENCODE_DIR" ;;
	pi) echo "$PI_DIR" ;;
	hermes) echo "$HERMES_DIR" ;;
	esac
}

if ((${#agents[@]} == 0)); then
	for agent in "${ALL_AGENTS[@]}"; do
		if command -v "$agent" >/dev/null 2>&1 || [[ -d $(config_dir "$agent") ]]; then
			agents+=("$agent")
		fi
	done
	if ((${#agents[@]} == 0)); then
		echo "No supported agents found (${ALL_AGENTS[*]})."
		exit 0
	fi
fi

# Copies an integration template, pointing it at this checkout's agent-state.sh.
install_template() {
	local src=$1 dest=$2
	mkdir -p "$(dirname "$dest")"
	sed "s|@AGENT_STATE@|$AGENT_STATE|g" "$src" >"$dest"
}

# --- GitHub Copilot CLI: a dedicated hooks file --------------------------------
install_copilot() {
	local file="$COPILOT_DIR/hooks/$MARKER.json"
	if ((uninstall)); then
		rm -f "$file"
		echo "copilot: removed $file"
		return
	fi
	hook() {
		printf '{ "type": "command", "bash": "%s %s", "timeoutSec": 5%s }' \
			"'$AGENT_STATE'" "$1" "${2:+, \"matcher\": \"$2\"}"
	}
	mkdir -p "$(dirname "$file")"
	cat >"$file" <<EOF
{
  "version": 1,
  "hooks": {
    "sessionStart": [$(hook idle)],
    "userPromptSubmitted": [$(hook working)],
    "preToolUse": [$(hook waiting ask_user)],
    "postToolUse": [$(hook working)],
    "postToolUseFailure": [$(hook working)],
    "notification": [$(hook waiting 'permission_prompt|elicitation_dialog')],
    "agentStop": [$(hook idle)],
    "sessionEnd": [$(hook clear)]
  }
}
EOF
	echo "copilot: installed $file"
}

# --- Claude Code: merged into settings.json ------------------------------------
install_claude() {
	local file="$CLAUDE_DIR/settings.json"
	if ((uninstall)) && [[ ! -f $file ]]; then
		echo "claude: nothing to remove"
		return
	fi
	mkdir -p "$CLAUDE_DIR"
	[[ -f $file ]] && cp "$file" "$file.$MARKER.bak"
	python3 - "$file" "$AGENT_STATE" "$MARKER" "$uninstall" <<'PY'
import json, os, shlex, sys

path, agent_state, marker, uninstall = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    data = json.loads(text) if text.strip() else {}

hooks = data.get("hooks", {})
# Drop entries from a previous install; they're tagged with a shell comment.
for event in list(hooks):
    groups = []
    for group in hooks[event]:
        kept = [h for h in group.get("hooks", []) if f"# {marker}" not in h.get("command", "")]
        if kept:
            groups.append({**group, "hooks": kept})
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]

if not uninstall:
    def add(event, state, matcher=None):
        group = {"hooks": [{
            "type": "command",
            "command": f"{shlex.quote(agent_state)} {state} # {marker}",
            "timeout": 5,
        }]}
        if matcher:
            group = {"matcher": matcher, **group}
        hooks.setdefault(event, []).append(group)

    add("SessionStart", "idle")
    add("UserPromptSubmit", "working")
    add("PermissionRequest", "waiting")
    add("PreToolUse", "waiting", "AskUserQuestion|ExitPlanMode")
    add("PostToolUse", "working")
    add("PostToolUseFailure", "working")
    add("Notification", "waiting", "permission_prompt|elicitation_dialog|elicitation_url_dialog")
    add("Stop", "idle")
    add("StopFailure", "idle")
    add("SessionEnd", "clear")

if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)

with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY
	if ((uninstall)); then
		echo "claude: removed hooks from $file"
	else
		echo "claude: installed hooks in $file (backup: $file.$MARKER.bak)"
	fi
}

# --- OpenCode: a global plugin file --------------------------------------------
install_opencode() {
	local file="$OPENCODE_DIR/plugins/$MARKER.js"
	if ((uninstall)); then
		rm -f "$file"
		echo "opencode: removed $file"
		return
	fi
	install_template "$ROOT/integrations/opencode.js" "$file"
	echo "opencode: installed $file"
}

# --- pi: a global extension ----------------------------------------------------
install_pi() {
	local file="$PI_DIR/extensions/$MARKER.ts"
	if ((uninstall)); then
		rm -f "$file"
		echo "pi: removed $file"
		return
	fi
	install_template "$ROOT/integrations/pi.ts" "$file"
	echo "pi: installed $file"
}

# --- Hermes Agent: shell hooks block in config.yaml ----------------------------
install_hermes() {
	local file="$HERMES_DIR/config.yaml" begin="# >>> $MARKER" end="# <<< $MARKER"
	if [[ -f $file ]] && grep -qxF "$begin" "$file"; then
		sed -i "/^$begin\$/,/^$end\$/d" "$file"
	fi
	if ((uninstall)); then
		echo "hermes: removed hooks from $file"
		return
	fi
	local q="'$AGENT_STATE'"
	local block
	block=$(
		cat <<EOF
$begin
hooks:
  pre_llm_call: [{ command: "$q working" }]
  pre_tool_call: [{ matcher: "clarify", command: "$q waiting" }]
  post_tool_call: [{ command: "$q working" }]
  pre_approval_request: [{ command: "$q waiting" }]
  post_approval_response: [{ command: "$q working" }]
  on_session_end: [{ command: "$q idle" }]
  agent_loop_stopped: [{ command: "$q idle" }]
  on_session_finalize: [{ command: "$q clear" }]
$end
EOF
	)
	if [[ -f $file ]] && grep -q '^hooks:' "$file"; then
		echo "hermes: $file already has a 'hooks:' section; merge these entries into it:"
		echo "$block" | sed '1d;$d'
		return
	fi
	mkdir -p "$HERMES_DIR"
	[[ -s $file && -n $(tail -n1 "$file") ]] && echo >>"$file"
	printf '%s\n' "$block" >>"$file"
	echo "hermes: installed hooks in $file (Hermes asks to approve each hook on first use)"
}

for agent in "${agents[@]}"; do
	install_"$agent"
done
((uninstall)) || echo "Restart running agent sessions to pick up the hooks."
