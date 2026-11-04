// Minimal MCP stdio client that drives REA the same way Claude Code does:
// spawns scripts/rea-isolated.mjs, then initialize -> tools/list -> tools/call
// analyze_javascript_application. Used by run-monitored.ps1 -Mode mcp.
// Usage: <local node> scripts/mcp-smoke.mjs <absolute target path>
import { spawn } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const target = process.argv[2];
if (!target) {
  process.stderr.write("usage: mcp-smoke.mjs <absolute target path>\n");
  process.exit(2);
}

const child = spawn(process.execPath, [join(ROOT, "scripts", "rea-isolated.mjs")], {
  cwd: ROOT,
  stdio: ["pipe", "pipe", "pipe"],
});
child.stderr.on("data", (d) => process.stderr.write(d));

let buffer = "";
let nextId = 0;
const pending = new Map();
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    let message;
    try { message = JSON.parse(line); } catch { process.stderr.write(`[smoke] non-JSON stdout: ${line.slice(0, 200)}\n`); continue; }
    if (message.id !== undefined && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  }
});

const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
const request = (method, params, timeoutMs = 300_000) => {
  const id = ++nextId;
  send({ jsonrpc: "2.0", id, method, params });
  return new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), timeoutMs);
    pending.set(id, (message) => { clearTimeout(timer); resolvePromise(message); });
  });
};

const summary = {};
try {
  const init = await request("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "rea-isolation-smoke", version: "1.0.0" },
  });
  summary.initialize = init.error ?? { protocolVersion: init.result?.protocolVersion, serverInfo: init.result?.serverInfo };
  send({ jsonrpc: "2.0", method: "notifications/initialized" });

  const tools = [];
  let cursor;
  do {
    const page = await request("tools/list", cursor ? { cursor } : {});
    if (page.error) { summary.toolsListError = page.error; break; }
    tools.push(...(page.result?.tools ?? []));
    cursor = page.result?.nextCursor;
  } while (cursor);
  summary.toolCount = tools.length;
  summary.hasAnalyzeJavaScriptApplication = tools.some((t) => t.name === "analyze_javascript_application");

  const call = await request("tools/call", {
    name: "analyze_javascript_application",
    arguments: { input_path: target },
  });
  summary.toolCall = call.error ?? call.result;
} catch (cause) {
  summary.failure = String(cause?.stack ?? cause);
  process.exitCode = 1;
} finally {
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
  child.stdin.end(); // MCP stdio shutdown: close stdin, then wait
  const exited = await new Promise((r) => {
    const t = setTimeout(() => r(false), 10_000);
    child.once("exit", () => { clearTimeout(t); r(true); });
  });
  if (!exited) child.kill();
}
