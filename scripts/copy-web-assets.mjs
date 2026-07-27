/**
 * Copies the static web app into www/ for Capacitor sync.
 * Does not modify source files (index.html, manifest, icons).
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wwwDir = path.join(projectRoot, "www");

const COPY_FILES = ["index.html", "manifest.json"];
const COPY_DIRS = ["icons", "vendor"];
const SUPABASE_UMD_SRC = path.join(
  projectRoot,
  "node_modules",
  "@supabase",
  "supabase-js",
  "dist",
  "umd",
  "supabase.js"
);
const SUPABASE_UMD_DEST = path.join(projectRoot, "vendor", "supabase-js.min.js");

function rmrf(target) {
  if (!fs.existsSync(target)) return;
  fs.rmSync(target, { recursive: true, force: true });
}

function copyFile(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(from, to);
    else copyFile(from, to);
  }
}

fs.mkdirSync(wwwDir, { recursive: true });

if (!fs.existsSync(SUPABASE_UMD_SRC)) {
  console.error("[web:copy] Missing @supabase/supabase-js UMD bundle. Run: npm install");
  process.exit(1);
}
fs.mkdirSync(path.dirname(SUPABASE_UMD_DEST), { recursive: true });
copyFile(SUPABASE_UMD_SRC, SUPABASE_UMD_DEST);

for (const file of COPY_FILES) {
  const src = path.join(projectRoot, file);
  if (!fs.existsSync(src)) {
    console.error(`[web:copy] Missing required file: ${file}`);
    process.exit(1);
  }
  copyFile(src, path.join(wwwDir, file));
}

for (const dir of COPY_DIRS) {
  const src = path.join(projectRoot, dir);
  if (!fs.existsSync(src)) {
    console.error(`[web:copy] Missing required directory: ${dir}/`);
    process.exit(1);
  }
  const dest = path.join(wwwDir, dir);
  rmrf(dest);
  copyDir(src, dest);
}

console.log("[web:copy] Copied index.html, manifest.json, icons/, vendor/ → www/");
