// Lists ALL install-time scripts under node_modules (including nested deps)
// plus implicit "node-gyp rebuild" (binding.gyp without an install script)
// and native binaries shipped in packages. Only reads files.
// Usage: node scripts/audit/lifecycle-scan.mjs <node_modules dir>
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? "node_modules");
const HOOKS = ["preinstall", "install", "postinstall", "prepare", "preprepare", "postprepare"];
const results = [];
const natives = [];

function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === ".bin") continue;
      walk(p);
    } else if (e.isFile()) {
      if (e.name === "package.json" && path.basename(path.dirname(path.dirname(p))) !== "") checkPkg(p);
      if (/\.(node|exe|dll|so|dylib)$/i.test(e.name)) {
        natives.push({ file: path.relative(root, p), bytes: fs.statSync(p).size });
      }
    }
  }
}

function checkPkg(file) {
  let j;
  try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch { return; }
  if (!j.name || !j.version) return; // skip non-package manifests (fixtures, etc.)
  const dir = path.dirname(file);
  const scripts = j.scripts ?? {};
  const hooks = {};
  for (const h of HOOKS) if (scripts[h]) hooks[h] = scripts[h];
  const hasGyp = fs.existsSync(path.join(dir, "binding.gyp"));
  if (hasGyp && !scripts.install && !scripts.preinstall) hooks["(implicit)"] = "node-gyp rebuild (binding.gyp present)";
  if (Object.keys(hooks).length) {
    results.push({ pkg: `${j.name}@${j.version}`, dir: path.relative(root, dir), hooks, gypfile: j.gypfile ?? undefined });
  }
}

walk(root);
console.log(JSON.stringify({ root, lifecycle: results, nativeBinaries: natives }, null, 2));
