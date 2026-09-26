// tmux-herdr: reports OpenCode's working/waiting/idle status to the tmux sidebar.
// Installed by tmux-herdr's install-agent-hooks.sh; reinstalling overwrites it.

import { spawnSync } from "node:child_process"

const AGENT_STATE = "@AGENT_STATE@"

export const TmuxHerdr = async () => {
  if (!process.env.TMUX_PANE) {
    return {}
  }

  // Sessions (including subagent sessions) that are busy, and permission or
  // question requests that are waiting for the user.
  const busy = new Set()
  const pending = new Set()
  let last

  const report = (state) => {
    if (state === last) {
      return
    }
    last = state
    spawnSync(AGENT_STATE, [state], { stdio: "ignore", timeout: 5000 })
  }

  const publish = () => report(pending.size ? "waiting" : busy.size ? "working" : "idle")

  report("idle")
  process.on("exit", () => report("clear"))

  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      switch (event.type) {
        case "session.status":
          if (p.status?.type === "idle") {
            busy.delete(p.sessionID)
          } else {
            busy.add(p.sessionID)
          }
          break
        case "session.idle":
          busy.delete(p.sessionID)
          break
        case "session.deleted":
          busy.delete(p.info?.id)
          break
        case "permission.asked":
        case "permission.updated":
        case "question.asked":
          pending.add(p.id)
          break
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          pending.delete(p.requestID ?? p.permissionID)
          break
        default:
          return
      }
      publish()
    },
  }
}
