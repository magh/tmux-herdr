#!/usr/bin/env bash
# Tests for the agent integrations (OpenCode plugin, pi extension) and the
# hook installer. Needs node and python3; doesn't touch the real agent configs.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failures=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() {
	printf 'FAIL - %s\n' "$1"
	[[ -n ${2:-} ]] && printf '       %s\n' "$2"
	failures=$((failures + 1))
}

# Stand-in for agent-state.sh that records every reported state.
cat >"$TMP/stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"${0%/*}/states"
STUB
chmod +x "$TMP/stub.sh"

expect_states() {
	local name=$1 want=$2 got=''
	[[ -f $TMP/states ]] && got=$(tr '\n' ' ' <"$TMP/states" | sed 's/ $//')
	if [[ $got == "$want" ]]; then pass "$name"; else fail "$name" "want: '$want', got: '$got'"; fi
	rm -f "$TMP/states"
}

run_node() { TMUX_PANE=%0 node --input-type=module -e "$1"; }

# --- OpenCode plugin ------------------------------------------------------------
sed "s|@AGENT_STATE@|$TMP/stub.sh|" "$ROOT/integrations/opencode.js" >"$TMP/opencode.mjs"
run_node "
const { TmuxHerdr } = await import('$TMP/opencode.mjs')
const hooks = await TmuxHerdr({})
const ev = (type, properties) => hooks.event({ event: { type, properties } })
await ev('session.status', { sessionID: 'a', status: { type: 'busy' } })
await ev('session.status', { sessionID: 'b', status: { type: 'busy' } })
await ev('permission.asked', { id: 'p1', sessionID: 'b' })
await ev('permission.replied', { sessionID: 'b', requestID: 'p1', reply: 'once' })
await ev('session.idle', { sessionID: 'b' })
await ev('question.asked', { id: 'q1', sessionID: 'a' })
await ev('question.rejected', { sessionID: 'a', requestID: 'q1' })
await ev('message.updated', {})
await ev('session.status', { sessionID: 'a', status: { type: 'idle' } })
"
expect_states "opencode plugin reports state changes" "idle working waiting working waiting working idle clear"

# --- pi extension -----------------------------------------------------------------
sed "s|@AGENT_STATE@|$TMP/stub.sh|" "$ROOT/integrations/pi.ts" >"$TMP/pi.mjs"
PI_HARNESS="
const { default: ext } = await import('$TMP/pi.mjs')
const handlers = {}
ext({ on: (name, fn) => { handlers[name] = fn } })
const fire = (name, ctx = {}) => handlers[name]({ type: name }, ctx)
"
run_node "$PI_HARNESS
fire('agent_start')
fire('session_start', { mode: 'tui', isIdle: () => true })
fire('agent_start')
fire('ui_prompt_start')
fire('ui_prompt_end')
fire('agent_settled', { isIdle: () => false })
fire('agent_settled', { isIdle: () => true })
fire('session_shutdown')
"
expect_states "pi extension reports state changes" "idle working waiting working idle clear"

run_node "$PI_HARNESS
fire('session_start', { mode: 'print' })
fire('agent_start')
fire('session_shutdown')
"
expect_states "pi extension stays quiet outside the TUI" ""

# --- installer ----------------------------------------------------------------------
home="$TMP/home"
mkdir -p "$home/.claude" "$home/.codex" "$home/.hermes"
echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' >"$home/.claude/settings.json"
cat >"$home/.codex/config.toml" <<'TOML'
model = "x"

[hooks]

[[hooks.Stop]]
hooks = [{ type = "command", command = "echo mine" }]
TOML
echo 'model: x' >"$home/.hermes/config.yaml"
installer() { HOME=$home XDG_CONFIG_HOME=$home/.config "$ROOT/scripts/install-agent-hooks.sh" "$@" >/dev/null; }

installer copilot codex claude opencode pi hermes
installer copilot codex claude opencode pi hermes

if python3 - "$home/.claude/settings.json" <<'PY'; then
import json, sys
d = json.load(open(sys.argv[1]))
ours = [h for gs in d["hooks"].values() for g in gs for h in g["hooks"] if "# tmux-herdr" in h["command"]]
assert d["model"] == "x"
assert len(d["hooks"]["Stop"]) == 2, d["hooks"]["Stop"]
assert len(ours) == 10, len(ours)
PY
	pass "installer merges claude hooks idempotently"
else
	fail "installer merges claude hooks idempotently"
fi

if python3 - "$home/.codex/config.toml" "$home/.codex/tmux-herdr-notify.sh" "$ROOT/scripts/agent-state.sh" <<'PY'; then
import os, sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
wrapper, state = sys.argv[2], sys.argv[3]
hook_command = '"${CODEX_HOME:-$HOME/.codex}/tmux-herdr-notify.sh"'
ours = [h for gs in d["hooks"].values() for g in gs for h in g["hooks"] if h["command"].startswith(hook_command)]
mine = [h for g in d["hooks"]["Stop"] for h in g["hooks"] if "echo mine" in h["command"]]
assert d["model"] == "x"
assert len(ours) == 8, len(ours)
assert len(mine) == 1, mine
assert os.access(wrapper, os.X_OK)
assert state in open(wrapper).read()
assert all(wrapper not in h["command"] for h in ours), ours
PY
	pass "installer writes portable Codex hooks idempotently"
else
	fail "installer writes portable Codex hooks idempotently"
fi

if [[ $(grep -c '^hooks:' "$home/.hermes/config.yaml") -eq 1 ]]; then
	pass "installer adds hermes hooks once"
else
	fail "installer adds hermes hooks once"
fi

if python3 -m json.tool "$home/.copilot/hooks/tmux-herdr.json" >/dev/null &&
	grep -qF "$ROOT/scripts/agent-state.sh" "$home/.config/opencode/plugins/tmux-herdr.js" &&
	grep -qF "$ROOT/scripts/agent-state.sh" "$home/.pi/agent/extensions/tmux-herdr.ts"; then
	pass "installer writes copilot, opencode and pi integrations"
else
	fail "installer writes copilot, opencode and pi integrations"
fi

installer --uninstall copilot codex claude opencode pi hermes
if [[ ! -e $home/.copilot/hooks/tmux-herdr.json && ! -e $home/.config/opencode/plugins/tmux-herdr.js &&
	! -e $home/.pi/agent/extensions/tmux-herdr.ts && ! -e $home/.codex/tmux-herdr-notify.sh ]] &&
	! grep -q tmux-herdr "$home/.claude/settings.json" "$home/.hermes/config.yaml" "$home/.codex/config.toml" &&
	grep -q 'echo mine' "$home/.claude/settings.json" "$home/.codex/config.toml"; then
	pass "uninstall removes only tmux-herdr hooks"
else
	fail "uninstall removes only tmux-herdr hooks"
fi

echo
if ((failures)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all tests passed"
