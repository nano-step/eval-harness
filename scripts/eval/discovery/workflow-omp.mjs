// workflow-omp.mjs — the single generation transport: one `omp -p` call per generation round.
//
// This reuses the existing OMP runtime exactly like Jev's OmpRuntime.runAgent does (same flags and the
// same `--mode json` event stream), but with every tool disabled: the model returns text only, it
// can read nothing from the host and write nothing. There is no model router and no fallback. The
// model comes from the operator's configured OMP `implement` role (discovered through
// `omp config get modelRoles --json`) or an explicit selector, and the served model must match it.
//
// Nothing here has grading authority. Output is untrusted text handed to candidates validation.

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max", "auto"]);
const USAGE_KEYS = ["input", "output", "cacheRead", "cacheWrite", "costUsd"];
const MAX_EVENT_BYTES = 16 * 1024 * 1024;
const MAX_STDERR_BYTES = 8000;

export const sha256Hex = data => createHash("sha256").update(data).digest("hex");

/** Splits `provider/model:thinking` into the model id and an optional thinking level. */
export function parseSelector(selector) {
  if (typeof selector !== "string" || selector.trim() === "" || /[\s,]/.test(selector.trim())) {
    throw new Error("model selector must be a single provider/model[:thinking] value (comma fallback chains are forbidden)");
  }
  const trimmed = selector.trim();
  const idx = trimmed.lastIndexOf(":");
  if (idx > 0 && THINKING_LEVELS.has(trimmed.slice(idx + 1))) {
    return { model: trimmed.slice(0, idx), thinking: trimmed.slice(idx + 1) };
  }
  return { model: trimmed, thinking: null };
}

/** Reads the configured OMP role (default `implement`) through the OMP CLI. Never falls back. */
export function discoverRoleSelector({ bin = "omp", role = "implement", env = process.env, timeoutMs = 30000 } = {}) {
  const result = spawnSync(bin, ["config", "get", "modelRoles", "--json"], { encoding: "utf8", env, timeout: timeoutMs, maxBuffer: 1 << 20 });
  if (result.error || result.status !== 0) {
    throw new Error(`cannot discover OMP model roles: ${result.error?.message ?? (result.stderr || "").slice(0, 300)}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw new Error("omp config get modelRoles --json did not return JSON");
  }
  const selector = parsed?.value?.[role];
  if (typeof selector !== "string" || selector.trim() === "") {
    throw new Error(`OMP model role '${role}' is not configured`);
  }
  return selector.trim();
}

export function ompVersion({ bin = "omp", env = process.env } = {}) {
  const result = spawnSync(bin, ["--version"], { encoding: "utf8", env, timeout: 15000 });
  return result.status === 0 ? result.stdout.trim() : null;
}

/** Folds `--mode json` events into text, usage, and the served model list (as Jev does). */
export function parseOmpEvents(lines) {
  let text = "";
  let error = null;
  let requests = 0;
  const models = [];
  const totals = {};
  for (const line of lines) {
    if (!line.startsWith("{")) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type !== "message_end" || event.message?.role !== "assistant") continue;
    const message = event.message;
    requests += 1;
    const served = message.provider && message.model ? `${message.provider}/${message.model}` : null;
    if (served && !models.includes(served)) models.push(served);
    const u = message.usage && typeof message.usage === "object" ? message.usage : {};
    for (const key of USAGE_KEYS) {
      const value = key === "costUsd" ? u.cost?.total : u[key];
      const slot = (totals[key] ??= { sum: 0, seen: 0 });
      slot.seen += 1;
      if (typeof value === "number" && Number.isFinite(value)) slot.sum += value;
      else slot.missing = true;
    }
    const messageText = (message.content ?? []).filter(c => c.type === "text" && typeof c.text === "string").map(c => c.text).join("");
    if (messageText.trim()) text = messageText;
    error = message.stopReason === "error" || message.stopReason === "aborted" ? String(message.errorMessage ?? message.stopReason).slice(0, 500) : null;
  }
  // Per field: a total only when EVERY assistant message exposed a finite value; one unknown makes the field null.
  const usage = requests === 0 ? null : Object.fromEntries(USAGE_KEYS.map(k => [k, totals[k] && !totals[k].missing ? totals[k].sum : null]));
  return { text, error, requests, models, usage: usage && Object.values(usage).some(v => v !== null) ? usage : null };
}

/**
 * One generation call. Returns a record; it never throws for model/process failures.
 * `usage` is null when OMP exposed no usage metadata (never a fabricated zero).
 */
export function generateWithOmp({ prompt, system, selector, cwd, timeoutSeconds, transcriptPath, bin = "omp", env = process.env }) {
  const { model, thinking } = parseSelector(selector);
  // A single argv entry is limited to 128 KiB on Linux; large prompts go through OMP's `@file` syntax.
  let promptArg = prompt;
  if (Buffer.byteLength(prompt) > 100000) {
    mkdirSync(cwd, { recursive: true });
    const promptFile = `${cwd}/prompt.txt`;
    writeFileSync(promptFile, prompt, { flag: "w" });
    promptArg = `@${promptFile}`;
  }
  const args = [
    "-p", "--mode", "json", "--no-session", "--no-extensions", "--no-title", "--no-tools", "--no-skills", "--no-rules", "--no-lsp",
    "--model", model,
    ...(thinking ? ["--thinking", thinking] : []),
    "--max-time", `${Math.max(1, Math.ceil(timeoutSeconds))}`,
    ...(system ? ["--system-prompt", system] : []),
    "--cwd", cwd,
    promptArg,
  ];
  const argvForRecord = args.slice(0, -1).map(a => (a === system && system ? "<system-prompt>" : a));
  const started = Date.now();
  return new Promise(resolve => {
    const child = spawn(bin, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    let bytes = 0;
    let stderr = "";
    let timedOut = false;
    let overflow = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => child.exitCode === null && child.kill("SIGKILL"), 5000).unref();
    }, (timeoutSeconds + 30) * 1000);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      bytes += chunk.length;
      if (bytes > MAX_EVENT_BYTES) {
        overflow = true;
        child.kill("SIGTERM");
        return;
      }
      chunks.push(chunk);
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", chunk => {
      stderr = (stderr + chunk).slice(-MAX_STDERR_BYTES);
    });
    child.on("error", err => {
      stderr += `\n${err.message}`;
    });
    child.on("close", code => {
      clearTimeout(timer);
      const raw = chunks.join("");
      if (transcriptPath) {
        mkdirSync(dirname(transcriptPath), { recursive: true });
        writeFileSync(transcriptPath, raw);
      }
      const parsed = parseOmpEvents(raw.split("\n").filter(line => !line.includes('"type":"message_update"')));
      const failure = timedOut
        ? "timed out"
        : overflow
          ? "event stream exceeded the size bound"
          : code !== 0
            ? `omp exited ${code}: ${stderr.slice(-400).replace(/\s+/g, " ").trim()}`
            : parsed.error ?? (parsed.text ? null : "empty response");
      resolve({
        ok: failure === null,
        error: failure,
        text: parsed.text,
        textSha256: sha256Hex(parsed.text),
        selector,
        requestedModel: model,
        thinking,
        servedModels: parsed.models,
        usage: parsed.usage,
        assistantMessages: parsed.requests,
        durationMs: Date.now() - started,
        exitCode: code,
        argv: [bin, ...argvForRecord],
        transcriptPath: transcriptPath ?? null,
        transcriptSha256: sha256Hex(raw),
      });
    });
  });
}
