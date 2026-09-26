// tmux-herdr: reports pi's working/waiting/idle status to the tmux sidebar.
// Installed by tmux-herdr's install-agent-hooks.sh; reinstalling overwrites it.
// @ts-nocheck

import { spawnSync } from "node:child_process";

const AGENT_STATE = "@AGENT_STATE@";

export default function (pi) {
  if (!process.env.TMUX_PANE) {
    return;
  }

  let tui = false;
  let active = false;
  let prompts = 0;
  let last;

  function report(state) {
    if (state === last) {
      return;
    }
    last = state;
    spawnSync(AGENT_STATE, [state], { stdio: "ignore", timeout: 5000 });
  }

  function publish() {
    if (tui) {
      report(prompts > 0 ? "waiting" : active ? "working" : "idle");
    }
  }

  pi.on("session_start", (_event, ctx) => {
    // Print/JSON/RPC modes have no terminal UI to show a status for.
    if (ctx?.mode !== "tui") {
      return;
    }
    tui = true;
    active = ctx?.isIdle?.() === false;
    publish();
  });

  pi.on("agent_start", () => {
    active = true;
    publish();
  });

  // agent_settled fires once no retry, compaction or queued work will follow.
  pi.on("agent_settled", (_event, ctx) => {
    if (ctx?.isIdle?.() === false) {
      return;
    }
    active = false;
    publish();
  });

  // Blocking extension dialogs (confirm/select/input), e.g. permission gates.
  pi.on("ui_prompt_start", () => {
    prompts += 1;
    publish();
  });

  pi.on("ui_prompt_end", () => {
    prompts = Math.max(0, prompts - 1);
    publish();
  });

  pi.on("session_shutdown", () => {
    if (tui) {
      report("clear");
    }
  });
}
