import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;
let lastAssistantMessage = "";

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function runSessionstartNudge(): string {
  const result = spawnSync(`${root}/bin/fm-sessionstart-nudge.sh`, [], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

// The shared guard has two independent stops and says which one fired in its own
// banner (bin/fm-turnend-guard.sh owns both headlines). A captain decision that
// has never been shown to the captain is not a supervision lapse, so the passive
// follow-up must not claim the watcher is down.
const CAPTAIN_CALL_HEADLINE = "TURN WOULD END WITHOUT TELLING THE CAPTAIN";
const UNKNOWN_HEADLINE = "TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS";

function turnEndPrefix(stderr: string): string {
  if (stderr.includes(CAPTAIN_CALL_HEADLINE)) {
    return (
      "TURN WOULD END WITHOUT TELLING THE CAPTAIN. " +
      "A decision is waiting on him that he has never been shown. Relay it in plain language before ending the turn.\n\n"
    );
  }
  if (stderr.includes(UNKNOWN_HEADLINE)) {
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

function runGuard(message: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end(JSON.stringify({ stop_hook_active: false, last_assistant_message: message }));
  });
}

function assistantText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: string; text: string } =>
      Boolean(part && typeof part === "object" &&
        (part as { type?: unknown }).type === "text" &&
        typeof (part as { text?: unknown }).text === "string"))
    .map((part) => part.text)
    .join("\n");
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", (event) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const nudge = ["startup", "new", "resume"].includes(reason) ? runSessionstartNudge() : "";
    markLoaded();
    if (!nudge) return;
    try {
      pi.sendMessage({
        customType: "firstmate-sessionstart-nudge",
        content: nudge,
        display: false,
        details: { kind: "session-start" },
      });
    } catch {
    }
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("agent_end", (event) => {
    const messages = (event as { messages?: unknown[] }).messages;
    if (!Array.isArray(messages)) return;
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      const message = messages[i] as { role?: unknown };
      if (message?.role !== "assistant") continue;
      lastAssistantMessage = assistantText(message);
      return;
    }
  });

  pi.on("agent_settled", async () => {
    const suppressRoutineFollowup = guardFollowupActive;
    if (guardFollowupActive) {
      guardFollowupActive = false;
    }

    const result = await runGuard(lastAssistantMessage);
    if (result.code !== 2) return;
    const attentionStop =
      result.stderr.includes(CAPTAIN_CALL_HEADLINE) || result.stderr.includes(UNKNOWN_HEADLINE);
    if (suppressRoutineFollowup && !attentionStop) return;

    guardFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        turnEndPrefix(result.stderr) + result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
    }
  });

  markLoaded();
}
