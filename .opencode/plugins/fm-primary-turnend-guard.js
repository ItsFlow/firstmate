import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

// The shared guard has two independent stops and says which one fired in its own
// banner (bin/fm-turnend-guard.sh owns both headlines). A captain decision that
// has never been shown to the captain is not a supervision lapse, so the passive
// follow-up must not claim the watcher is down.
const CAPTAIN_CALL_HEADLINE = "TURN WOULD END WITHOUT TELLING THE CAPTAIN";
const UNKNOWN_HEADLINE = "TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS";

function turnEndPrefix(stderr) {
  if (typeof stderr === "string" && stderr.includes(CAPTAIN_CALL_HEADLINE)) {
    return (
      "TURN WOULD END WITHOUT TELLING THE CAPTAIN. " +
      "A decision is waiting on him that he has never been shown. Relay it in plain language before ending the turn.\n\n"
    );
  }
  if (typeof stderr === "string" && stderr.includes(UNKNOWN_HEADLINE)) {
    return (
      "TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS. " +
      "The open decision and wait list is unknown. Restore that list before reporting an all-clear.\n\n"
    );
  }
  return (
    "TURN WOULD END BLIND - supervision is off. " +
    "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n"
  );
}


const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;
const assistantMessages = new Map();

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root, lastAssistantMessage) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(
    `${root}/bin/fm-turnend-guard.sh`,
    [],
    JSON.stringify({ stop_hook_active: false, last_assistant_message: lastAssistantMessage }),
  );
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return;
  try {
    await coordinator.ensureArmed(sessionID, client);
  } catch {
  }
}

function observeAssistantMessage(event) {
  if (event.type === "message.updated") {
    const info = event.properties?.info;
    if (info?.role === "assistant" && info.sessionID && info.id) {
      const current = assistantMessages.get(info.sessionID);
      if (current?.messageID !== info.id) {
        assistantMessages.set(info.sessionID, { messageID: info.id, parts: new Map() });
      }
    }
    return;
  }
  if (event.type !== "message.part.updated") return;
  const part = event.properties?.part;
  if (part?.type !== "text" || part.synthetic || part.ignored) return;
  const current = assistantMessages.get(part.sessionID);
  if (!current || current.messageID !== part.messageID) return;
  current.parts.set(part.id, String(part.text ?? ""));
}

function lastAssistantMessage(sessionID) {
  const current = assistantMessages.get(sessionID);
  return current ? [...current.parts.values()].join("\n") : "";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      observeAssistantMessage(event);
      if (event.type !== "session.idle") return;

      const suppressRoutineFollowup = skipNextIdle;
      if (skipNextIdle) {
        skipNextIdle = false;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      await letWatchArmRun(sessionID, client);

      const result = await runGuard(root, lastAssistantMessage(sessionID));
      if (result.code !== 2) return;
      const attentionStop =
        result.stderr.includes(CAPTAIN_CALL_HEADLINE) || result.stderr.includes(UNKNOWN_HEADLINE);
      if (suppressRoutineFollowup && !attentionStop) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          turnEndPrefix(result.stderr) + result.stderr,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
