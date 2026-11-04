// Isolated REA launcher for this kit folder (see SECURITY_AUDIT.md §2, §10, §11).
//
// - Rebuilds the process environment from an allowlist: tokens/API keys from
//   your session are NOT inherited by REA (mitigates SEC-4 / CAP-3).
// - Redirects home, AppData, temp, XDG and caches into ./.rea-runtime so REA
//   and its children write inside this folder (FS-1, FS-2, FS-6, FS-8, FS-9).
// - Disables the incur update check (FS-6/TEL-3) and cwd binary lookup (SEC-7).
// - Refuses commands that write outside the folder (FS-4, FS-5, FS-7, UPD-1).
//
// Usage:
//   <local node> scripts/rea-isolated.mjs                 -> MCP server (stdio), same as `rea mcp`
//   <local node> scripts/rea-isolated.mjs <cli args...>   -> REA CLI, e.g. analyze-javascript-application ./targets/x --json
//   <local node> scripts/rea-isolated.mjs --rea-print-env -> prints the computed environment and exits (does not load REA)
//
// MCP stdio: never write to stdout here; stdout belongs to the protocol.

import { mkdirSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNTIME = join(ROOT, ".rea-runtime");
const HOME = join(RUNTIME, "home");
const REA_ENTRY = join(ROOT, "node_modules", "rea-agents", "scripts", "rea.mjs");

const fail = (message) => {
  process.stderr.write(`[rea-isolated] ${message}\n`);
  process.exit(2);
};

// ---- 1. Refuse commands that modify user-level configuration or global installs.
const args = process.argv.slice(2);
const printEnv = args[0] === "--rea-print-env";
const rest = printEnv ? args.slice(1) : args;
const reaArgs = rest.length === 0 ? ["mcp"] : rest;
const first = (reaArgs[0] ?? "").toLowerCase();
const second = (reaArgs[1] ?? "").toLowerCase();
const FORBIDDEN = new Set(["setup", "update", "upgrade", "uninstall", "skills", "--update", "--upgrade"]);
if (FORBIDDEN.has(first) || reaArgs.some((a) => /^--(update|upgrade|incur-update-check)$/i.test(a)))
  fail(`'${reaArgs.join(" ")}' is blocked: it writes outside ${ROOT} (agent configs, skills or global npm). See SECURITY_AUDIT.md.`);
if ((first === "mcp" || first === "--mcp") && second !== "" && !second.startsWith("-"))
  fail(`'rea mcp ${second}' is blocked (mcp add runs an unpinned 'npx add-mcp -g'). REA is registered in ./.mcp.json.`);
if ((first === "mcp" || first === "--mcp") && reaArgs.includes("--http"))
  fail("'rea mcp --http' is blocked: unauthenticated HTTP listener (SECURITY_AUDIT.md CAP-5). Use stdio.");
if (first === "environment" && second === "serve")
  fail("'rea environment serve' is blocked: unauthenticated listener that fetches arbitrary URLs (SECURITY_AUDIT.md §5).");

// ---- 2. Directories inside the folder.
const dirs = {
  home: HOME,
  appData: join(HOME, "AppData", "Roaming"),
  localAppData: join(HOME, "AppData", "Local"),
  tmp: join(RUNTIME, "tmp"),
  xdgCache: join(RUNTIME, "xdg", "cache"),
  xdgData: join(RUNTIME, "xdg", "data"),
  xdgConfig: join(RUNTIME, "xdg", "config"),
  xdgState: join(RUNTIME, "xdg", "state"),
  playwright: join(RUNTIME, "ms-playwright"),
  kuna: join(RUNTIME, "xdg", "cache", "rea", "kuna"),
  androidHome: join(HOME, ".android"),
  npmCache: join(ROOT, ".npm-cache"),
  npmPrefix: join(ROOT, ".npm-prefix"),
  npmLogs: join(ROOT, "logs", "npm"),
};
if (!printEnv) for (const d of Object.values(dirs)) mkdirSync(d, { recursive: true });

// ---- 3. Allowlisted environment (Windows env names are case-insensitive).
const KEEP = new Set([
  "systemroot", "systemdrive", "windir", "comspec", "pathext", "os",
  "number_of_processors", "processor_architecture", "processor_identifier",
  "processor_level", "processor_revision",
  "programfiles", "programfiles(x86)", "programw6432",
  "commonprogramfiles", "commonprogramfiles(x86)", "commonprogramw6432",
  "programdata", "allusersprofile", "public",
  "computername", "username", "userdomain",
  "java_home", "ghidra_install_dir", "android_home", "android_sdk_root",
  "lang", "lc_all", "tz", "term", "no_color", "force_color",
  "claude_project_dir",
]);
const KEEP_PREFIX = /^(rea_|hopper_)/i; // REA's own (non-secret) settings from .mcp.json "env"
const inherited = { ...process.env };
const env = {};
for (const [key, value] of Object.entries(inherited)) {
  if (value === undefined) continue;
  if (KEEP.has(key.toLowerCase()) || KEEP_PREFIX.test(key)) env[key] = value;
}

// PATH: local Node first; drop empty/relative entries, "." and global npm bins.
const nodeDir = dirname(process.execPath);
const pathValue = inherited.PATH ?? inherited.Path ?? "";
const globalNpmBin = /[\\/]AppData[\\/]Roaming[\\/]npm[\\/]?$/i;
const cleanPath = pathValue
  .split(delimiter)
  .filter((p) => p && /^[A-Za-z]:[\\/]/.test(p) && !globalNpmBin.test(p) && resolve(p) !== nodeDir);

Object.assign(env, {
  PATH: [nodeDir, ...cleanPath].join(delimiter),
  USERPROFILE: dirs.home,
  HOME: dirs.home,
  APPDATA: dirs.appData,
  LOCALAPPDATA: dirs.localAppData,
  TEMP: dirs.tmp,
  TMP: dirs.tmp,
  XDG_CACHE_HOME: dirs.xdgCache,
  XDG_DATA_HOME: dirs.xdgData,
  XDG_CONFIG_HOME: dirs.xdgConfig,
  XDG_STATE_HOME: dirs.xdgState,
  PLAYWRIGHT_BROWSERS_PATH: dirs.playwright,
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: "1",
  REA_KUNA_CACHE_DIR: env.REA_KUNA_CACHE_DIR ?? dirs.kuna,
  ANDROID_USER_HOME: dirs.androidHome,
  npm_config_cache: dirs.npmCache,
  npm_config_prefix: dirs.npmPrefix,
  npm_config_logs_dir: dirs.npmLogs,
  npm_config_ignore_scripts: "true",
  npm_config_update_notifier: "false",
  NO_UPDATE_NOTIFIER: "1",
  NODEFAULTCURRENTDIRECTORYINEXEPATH: "1",
  REA_REFERENCE_SECRET_PATTERNS_JSON:
    env.REA_REFERENCE_SECRET_PATTERNS_JSON ??
    JSON.stringify([".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_ecdsa*", "id_ed25519*", ".npmrc", ".netrc", ".git-credentials", "credentials", "credentials.*"]),
});

if (printEnv) {
  process.stderr.write(JSON.stringify({ cwd: ROOT, entry: REA_ENTRY, args: reaArgs, env }, null, 2) + "\n");
  process.exit(0);
}

// ---- 4. Replace the live environment (children inherit it) and run REA in-process.
for (const key of Object.keys(process.env)) delete process.env[key];
Object.assign(process.env, env);
process.chdir(ROOT); // relative caller paths resolve inside the folder
process.argv = [process.execPath, REA_ENTRY, ...reaArgs];
await import(pathToFileURL(REA_ENTRY).href);
