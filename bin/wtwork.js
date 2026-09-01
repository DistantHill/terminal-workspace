#!/usr/bin/env node

const path = require("node:path");
const { spawnSync } = require("node:child_process");

if (process.platform !== "win32") {
  console.error("WTwork must run on Windows with PowerShell 7 and WSL.");
  process.exit(1);
}

const entryScript = path.join(__dirname, "..", "TerminalWorkspace.ps1");
const result = spawnSync(
  "pwsh.exe",
  [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    entryScript,
    ...process.argv.slice(2),
  ],
  { stdio: "inherit", windowsHide: false },
);

if (result.error) {
  console.error(`Failed to start PowerShell 7: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
