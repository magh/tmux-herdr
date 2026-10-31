# tmux-herdr

A vertical sidebar for tmux that lists the windows of the current session and
highlights the active one.

```
 work
                      │
 0 editor             │  $ _
 1 server             │
 2 logs             Z │
```

tmux has no vertical status line, so herdr puts a narrow, full-height pane on
the left of every window and renders the window list in it. Tmux hooks tell
the sidebars to redraw when windows are created, renamed, moved, closed or
switched.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'mathias/tmux-herdr'
```

Manually:

```tmux
run-shell /path/to/tmux-herdr/herdr.tmux
```

Requires tmux 3.2+ and bash.

## Usage

- `prefix + B` toggles the sidebar in all windows.
- Click a window in the sidebar to switch to it (needs `set -g mouse on`).
- Pressing any key while the sidebar is focused moves focus back to the
  previous pane.
- When the last non-sidebar pane in a window closes, the window closes too.

Window flags other than current/last (e.g. `#` activity, `!` bell, `Z` zoom)
are shown on the right.

## Coding agent status

Windows running a coding agent get a status icon. Supported agents:
[GitHub Copilot CLI](https://github.com/github/copilot-cli),
[Codex CLI](https://github.com/openai/codex),
[Claude Code](https://code.claude.com), [OpenCode](https://opencode.ai),
[pi](https://github.com/earendil-works/pi) and
[Hermes Agent](https://github.com/NousResearch/hermes-agent).
Other windows are marked as busy when some program is running, or with `$`
when every pane is just sitting at a shell prompt (bash, zsh, fish, …):

| Icon           | State                                            |
| -------------- | ------------------------------------------------ |
| red `●`        | waiting for you (permission prompt or question)  |
| yellow `●`     | working                                          |
| green `●`      | idle, waiting for a new prompt                   |
| dim `◌`        | agent running, status unknown (no hooks)         |
| purple `●`     | no agent, another program is running (e.g. btop) |
| dim `$`        | no agent, every pane is at a shell prompt        |

Icons are drawn in their own column outside the highlight, so they keep their
colour on the active window's line too.

The working/waiting/idle states are reported by agent hooks or plugins.
Install them for every supported agent found on this machine, or name the
agents explicitly:

```sh
scripts/install-agent-hooks.sh
scripts/install-agent-hooks.sh claude pi
scripts/install-agent-hooks.sh --uninstall
```

Restart running agent sessions afterwards. What gets installed:

| Agent    | Integration                                                                                      |
| -------- | ------------------------------------------------------------------------------------------------ |
| copilot  | `~/.copilot/hooks/tmux-herdr.json`                                                               |
| codex    | hooks block in `~/.codex/config.toml` (backup kept as `.bak`); Codex asks to trust them on next start |
| claude   | hooks merged into `~/.claude/settings.json` (backup kept as `.bak`)                               |
| opencode | plugin `~/.config/opencode/plugins/tmux-herdr.js`                   |
| pi       | extension `~/.pi/agent/extensions/tmux-herdr.ts`                    |
| hermes   | shell hooks block in `~/.hermes/config.yaml`; Hermes asks you to approve each hook on first use |

Without the hooks, agents are still detected (Copilot by its pane title, the
others by process name) but shown as `◌`.

The integrations call `scripts/agent-state.sh working|waiting|idle|clear`,
which records the state on the tmux pane, so any other tool can report its
status the same way.

Known limitations: when you interrupt an agent (Esc/Ctrl-C) some agents don't
fire their "turn finished" hook, so the status can stay yellow until the next
prompt. Claude Code and Copilot only report "waiting" for their own permission
prompts and questions, Codex for approval prompts; pi reports it for extension
dialogs (it has no built-in permission prompts).

## Options

Set these before the plugin is loaded:

```tmux
set -g @herdr-enabled on                          # open on startup (default: off)
set -g @herdr-key B                               # toggle key, "none" to disable
set -g @herdr-width 25                            # sidebar width in columns
set -g @herdr-header on                           # show session name at the top
set -g @herdr-style default                       # style of inactive windows
set -g @herdr-active-style 'fg=black,bg=green,bold'
set -g @herdr-header-style bold
```

Agent status icons and styles (`working`, `waiting`, `idle`, `running`) and the
shell and busy indicators; set an icon to `none` to hide it:

```tmux
set -g @herdr-agent-waiting-icon '●'
set -g @herdr-agent-waiting-style 'fg=brightred,bold'
set -g @herdr-agent-working-style 'fg=brightyellow,bold'
set -g @herdr-agent-idle-style 'fg=brightgreen,bold'
set -g @herdr-agent-running-icon '◌'
set -g @herdr-busy-style 'fg=brightmagenta,bold'
set -g @herdr-shell-icon '$'
set -g @herdr-shell-style dim
```

Styles use tmux syntax: `fg=`/`bg=` with colour names, `brightX`, `colourN`
or `#rrggbb`, plus `bold`, `dim`, `italics`, `underscore`, `reverse`, etc.

The sidebar can also be controlled from scripts or key bindings:

```tmux
bind-key S run-shell '/path/to/tmux-herdr/scripts/herdr.sh open'  # or close/toggle
```

## Development

```sh
tests/run.sh           # sidebar tests against an isolated tmux server
tests/integrations.sh  # agent plugins and hook installer (needs node, python3)
```
