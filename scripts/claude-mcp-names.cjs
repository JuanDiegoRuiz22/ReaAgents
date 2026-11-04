// Prints ONLY the MCP server names registered in ~/.claude.json
// (user scope, local scope of the kit folder, and any project with a
// rea-like server). Never prints values, commands or secrets.
// Usage: node scripts/claude-mcp-names.cjs <path to ~/.claude.json> [kit root]
const fs = require("fs");
const path = require("path");
const file = process.argv[2];
const kitRoot = process.argv[3] || path.resolve(__dirname, "..");
const j = JSON.parse(fs.readFileSync(file, "utf8"));
const projects = j.projects || {};
const norm = (s) => s.toLowerCase().replace(/\\/g, "/").replace(/\/+$/, "");
const key = Object.keys(projects).find((k) => norm(k) === norm(kitRoot));
const anyProjectWithRea = Object.entries(projects)
  .filter(([, v]) => v && v.mcpServers && Object.keys(v.mcpServers).some((n) => /rea/i.test(n)))
  .map(([k]) => k);
console.log(JSON.stringify({
  user: Object.keys(j.mcpServers || {}),
  thisProjectLocal: key ? Object.keys(projects[key].mcpServers || {}) : [],
  projectsWithReaLikeServer: anyProjectWithRea,
}));
