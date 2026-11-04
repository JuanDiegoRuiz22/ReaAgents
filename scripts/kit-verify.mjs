// Verifies the kit against kit/versions.json and the isolation rules.
// Read-only except for spawning the launcher with --rea-print-env and blocked
// commands (both exit before REA is loaded).
// Usage: <local node> scripts/kit-verify.mjs
// Output: one line per check ("OK", "WARN" or "FAIL"); exit code 1 if any FAIL.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NM = join(ROOT, "node_modules");
const pins = JSON.parse(readFileSync(join(ROOT, "kit", "versions.json"), "utf8"));
let failures = 0;
const ok = (m) => console.log(`  OK   ${m}`);
const warn = (m) => console.log(`  WARN ${m}`);
const fail = (m) => { failures++; console.log(`  FAIL ${m}`); };
const check = (cond, okMsg, failMsg = okMsg) => (cond ? ok(okMsg) : fail(failMsg));
const sha256 = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const readJson = (p) => JSON.parse(readFileSync(p, "utf8").replace(/^﻿/, ""));
const inside = (p) => { const r = relative(ROOT, resolve(p)); return r !== "" && !r.startsWith("..") && !/^[A-Za-z]:/.test(r); };
const same = (a, b) => resolve(a).toLowerCase() === resolve(b).toLowerCase();

// ---- 1. Node
console.log("[verify] Node");
check(process.version === `v${pins.node.version}`, `node ${process.version}`, `node ${process.version} != v${pins.node.version}`);
check(inside(process.execPath), "node.exe is the kit's portable copy", `node.exe outside the kit: ${process.execPath}`);
check(sha256(process.execPath) === pins.node.nodeExeSha256, "node.exe sha256 matches the pin", "node.exe sha256 differs from the pin");

// ---- 2. Lockfile
console.log("[verify] package-lock.json");
const pkg = readJson(join(ROOT, "package.json"));
const lock = readJson(join(ROOT, "package-lock.json"));
const entries = Object.entries(lock.packages ?? {}).filter(([k]) => k !== "");
const badResolved = entries.filter(([, v]) => !v.link && !String(v.resolved ?? "").startsWith("https://registry.npmjs.org/"));
check(badResolved.length === 0, `${entries.length} packages, all resolved from https://registry.npmjs.org/`,
  `packages not from registry.npmjs.org: ${badResolved.map(([k]) => k).join(", ")}`);
const noIntegrity = entries.filter(([, v]) => !v.link && !String(v.integrity ?? "").startsWith("sha512-"));
check(noIntegrity.length === 0, "every package has a sha512 integrity", `missing sha512 integrity: ${noIntegrity.map(([k]) => k).join(", ")}`);
check(JSON.stringify(lock.packages[""]?.dependencies) === JSON.stringify(pkg.dependencies), "lockfile root matches package.json", "lockfile root dependencies differ from package.json");
const reaLock = lock.packages["node_modules/rea-agents"];
check(reaLock?.version === pins.reaAgents.version && reaLock?.integrity === pins.reaAgents.integrity,
  `rea-agents@${pins.reaAgents.version} integrity matches the pin`, "rea-agents version/integrity in lockfile differs from the pin");

// ---- 3. Installed packages
console.log("[verify] node_modules");
if (!existsSync(join(NM, "rea-agents", "package.json"))) {
  fail("node_modules/rea-agents is missing (run bootstrap.ps1)");
} else {
  const rea = readJson(join(NM, "rea-agents", "package.json"));
  check(rea.version === pins.reaAgents.version, `installed rea-agents@${rea.version}`, `installed rea-agents@${rea.version} != ${pins.reaAgents.version}`);
  check(rea.repository?.url === pins.reaAgents.repository, `repository ${rea.repository?.url}`, `unexpected repository: ${rea.repository?.url}`);
  const addon = join(NM, "rea-agents", ...pins.reaAgents.nativeAddon.split("/"));
  const manifest = readJson(join(dirname(addon), "manifest.json"));
  const addonHash = existsSync(addon) ? sha256(addon) : "";
  check(addonHash === pins.reaAgents.nativeAddonSha256 && manifest.artifactSha256 === addonHash,
    "native addon sha256 matches the pin and its manifest", "native addon sha256 differs from the pin or manifest");

  const mismatched = [];
  for (const [key, v] of entries) {
    if (v.optional && !existsSync(join(ROOT, key))) continue; // optional deps for other platforms
    const p = join(ROOT, key, "package.json");
    if (!existsSync(p)) { if (!v.optional) mismatched.push(`${key} (missing)`); continue; }
    const installed = readJson(p).version;
    if (installed !== v.version) mismatched.push(`${key} ${installed} != ${v.version}`);
  }
  check(mismatched.length === 0, "installed versions match the lockfile", `installed tree differs from lockfile: ${mismatched.slice(0, 10).join("; ")}`);

  // Install-time hooks: the audit accepted only frida's (handled manually, never executed).
  const HOOKS = ["preinstall", "install", "postinstall"];
  const hooked = [];
  for (const [key] of entries) {
    const p = join(ROOT, key, "package.json");
    if (!existsSync(p)) continue;
    const j = readJson(p);
    const s = j.scripts ?? {};
    const gyp = existsSync(join(ROOT, key, "binding.gyp")) && !s.install && !s.preinstall;
    if (HOOKS.some((h) => s[h]) || gyp) hooked.push(j.name);
  }
  const unexpected = hooked.filter((n) => n !== "frida");
  check(unexpected.length === 0, `install-time hooks only in: ${hooked.join(", ") || "(none)"}`, `NEW install-time hooks (re-audit): ${unexpected.join(", ")}`);

  // Frida binding (optional)
  const binding = join(NM, "frida", "build", "frida_binding.node");
  if (existsSync(binding)) {
    const fridaVer = readJson(join(NM, "frida", "package.json")).version;
    check(fridaVer === pins.frida.version && sha256(binding) === pins.frida.bindingSha256,
      `frida@${fridaVer} binding sha256 matches the pin`, "frida binding does not match the pin");
  } else {
    warn("frida binding not installed: Frida tools unavailable (bootstrap.ps1 -WithFrida)");
  }
}

// ---- 4. Skill
console.log("[verify] skill");
const upstreamSkill = join(NM, "rea-agents", "skills", "reverse-engineer-anything");
const localSkill = join(ROOT, ".claude", "skills", "reverse-engineer-anything");
if (existsSync(join(upstreamSkill, "SKILL.md"))) {
  check(sha256(join(upstreamSkill, "SKILL.md")) === pins.reaAgents.skillSha256, "upstream SKILL.md sha256 matches the pin", "upstream SKILL.md differs from the audited one");
  if (existsSync(join(localSkill, "SKILL.md"))) {
    const up = readFileSync(join(upstreamSkill, "SKILL.md"), "utf8");
    const body = up.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "").replace(/^\s+/, "");
    const local = readFileSync(join(localSkill, "SKILL.md"), "utf8");
    check(local.includes("LOCAL OVERRIDE: rea-kit") && local.endsWith(body), "local skill = upstream + kit preamble", "local skill is not upstream + kit preamble (re-run bootstrap.ps1)");
    const files = (d) => readdirSync(d, { recursive: true }).filter((f) => statSync(join(d, f)).isFile() && f !== "SKILL.md").sort();
    const a = files(upstreamSkill), b = files(localSkill);
    const differs = a.length !== b.length || a.some((f, i) => f !== b[i] || sha256(join(upstreamSkill, f)) !== sha256(join(localSkill, b[i])));
    check(!differs, `skill references identical to upstream (${a.length} files)`, "skill references differ from upstream");
  } else fail(".claude/skills/reverse-engineer-anything missing (run bootstrap.ps1)");
}

// ---- 5. .mcp.json
console.log("[verify] .mcp.json");
const launcher = join(ROOT, "scripts", "rea-isolated.mjs");
if (existsSync(join(ROOT, ".mcp.json"))) {
  const mcp = readJson(join(ROOT, ".mcp.json"));
  const names = Object.keys(mcp.mcpServers ?? {});
  const s = mcp.mcpServers?.rea;
  check(names.length === 1 && names[0] === "rea", "only server: rea", `unexpected servers: ${names.join(", ")}`);
  check(s && same(s.command, process.execPath) && s.args?.length === 1 && same(s.args[0], launcher) && Object.keys(s.env ?? {}).length === 0,
    "rea -> kit node.exe + scripts/rea-isolated.mjs, no env", "rea server does not point to the kit launcher (re-run bootstrap.ps1)");
} else fail(".mcp.json missing (run bootstrap.ps1)");

// ---- 6. Claude Code permissions
console.log("[verify] .claude/settings.json");
const settings = readJson(join(ROOT, ".claude", "settings.json"));
const perms = settings.permissions ?? {};
const deny = new Set(perms.deny ?? []);
const REQUIRED_DENY = [
  "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.config/**)", "Read(~/.gnupg/**)",
  "Edit(~/.claude.json)", "Edit(~/.npmrc)",
  "mcp__rea__capture_process_scenario", "mcp__rea__execute_rizin_command",
  "mcp__rea__capture_browser_scenario", "mcp__rea__load_frida_script",
];
const missing = REQUIRED_DENY.filter((r) => !deny.has(r));
check(missing.length === 0, `${deny.size} deny rules, key rules present`, `missing deny rules: ${missing.join(", ")}`);
check((perms.ask ?? []).includes("mcp__rea__*"), "every REA tool asks first", "ask rule mcp__rea__* missing");
check(JSON.stringify(settings.enabledMcpjsonServers) === '["rea"]', "only .mcp.json server enabled: rea", "enabledMcpjsonServers is not exactly [rea]");
check(perms.blockReadsOutsideWorkingDirectories === true && perms.blockWritesOutsideWorkingDirectories === true,
  "reads/writes outside the folder blocked for Claude's tools", "blockReads/WritesOutsideWorkingDirectories not enabled");

// ---- 7. Launcher
console.log("[verify] launcher");
const run = (args) => spawnSync(process.execPath, [launcher, ...args], { cwd: ROOT, encoding: "utf8", timeout: 30_000 });
const pe = run(["--rea-print-env"]);
let printed = null;
try { printed = JSON.parse(pe.stderr); } catch { /* reported below */ }
if (!printed) fail("--rea-print-env did not return JSON");
else {
  const e = printed.env;
  const redirected = ["USERPROFILE", "HOME", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "PLAYWRIGHT_BROWSERS_PATH", "npm_config_cache", "npm_config_prefix"];
  const outsideVars = redirected.filter((k) => !e[k] || !inside(e[k]));
  check(outsideVars.length === 0, "home/AppData/TEMP/XDG/npm redirected inside the kit", `not redirected inside: ${outsideVars.join(", ")}`);
  const secretish = Object.keys(e).filter((k) => /token|secret|passw|api_?key|credential|auth/i.test(k) && k !== "REA_REFERENCE_SECRET_PATTERNS_JSON");
  check(secretish.length === 0, `${Object.keys(e).length} env vars passed, none secret-like`, `secret-like vars reach REA: ${secretish.join(", ")}`);
  check(e.NO_UPDATE_NOTIFIER === "1" && e.npm_config_update_notifier === "false", "update checks disabled", "update checks not disabled");
  check(same(printed.cwd, ROOT) && printed.args.join(" ") === "mcp", "default command: mcp (stdio), cwd = kit", "unexpected default command or cwd");
}
for (const blocked of [["setup"], ["update"], ["uninstall"], ["skills", "add"], ["mcp", "add"], ["mcp", "--http"], ["environment", "serve"]]) {
  const r = run(blocked);
  check(r.status === 2 && /blocked/.test(r.stderr), `blocked: rea ${blocked.join(" ")}`, `NOT blocked: rea ${blocked.join(" ")} (exit ${r.status})`);
}

console.log(failures ? `[verify] ${failures} check(s) FAILED` : "[verify] all checks passed");
process.exit(failures ? 1 : 0);
