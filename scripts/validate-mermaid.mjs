#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const ignoredDirs = new Set([".git", "node_modules", ".next", ".omo", ".omc"]);
const inputs = process.argv.slice(2);
const files = [];

function collect(input) {
  const resolved = path.resolve(input);
  let stat;
  try { stat = fs.statSync(resolved); }
  catch { console.error("Missing path: " + input); process.exitCode = 1; return; }
  if (stat.isFile()) {
    if (resolved.endsWith(".md")) files.push(resolved);
    return;
  }
  if (!stat.isDirectory()) return;
  for (const entry of fs.readdirSync(resolved, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirs.has(entry.name)) continue;
    collect(path.join(resolved, entry.name));
  }
}

for (const input of inputs.length ? inputs : [process.cwd()]) collect(input);
let blockCount = 0;
let failureCount = 0;

function checkBlock(file, source, offset, block) {
  const lineOffset = source.slice(0, offset).split("\n").length - 1;
  const errors = [];
  if (!block.trim()) errors.push("empty-block");
  if (/\\n/.test(block)) errors.push("no-literal-newline");
  if (/&(?:amp|#\d+|#x[0-9a-f]+);/i.test(block)) errors.push("no-html-entities");
  if (/^\s*end\s*[\[({>]/im.test(block)) errors.push("reserved-node-id");
  if (/\b[A-Za-z][A-Za-z0-9_]*\[[^"\]\n]*\([^"\]\n]*\)[^"\]\n]*\]/.test(block)) errors.push("quote-parenthesized-label");
  if (/--\s*[^"\n]*\([^"\n]*\)\s*--?>/.test(block)) errors.push("quote-parenthesized-edge-label");
  if (errors.length) {
    failureCount += errors.length;
    for (const error of errors) {
      console.error(path.relative(process.cwd(), file) + ":" + (lineOffset + 1) + " [" + error + "]");
    }
  }
}

const tick = String.fromCharCode(96);
const fence = new RegExp("^[ \\t]*" + tick.repeat(3) + "mermaid[ \\t]*\\r?\\n([\\s\\S]*?)^[ \\t]*" + tick.repeat(3) + "[ \\t]*$", "gm");
for (const file of files) {
  const source = fs.readFileSync(file, "utf8");
  for (const match of source.matchAll(fence)) {
    blockCount += 1;
    checkBlock(file, source, match.index ?? 0, match[1] ?? "");
  }
}
console.log("Scanned " + files.length + " file(s), " + blockCount + " mermaid block(s).");
if (failureCount) {
  console.error("Found " + failureCount + " Mermaid rule violation(s).");
  process.exitCode = 1;
} else {
  console.log("All Mermaid blocks passed.");
}
