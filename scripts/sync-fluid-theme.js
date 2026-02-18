const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const src = path.join(repoRoot, 'node_modules', 'hexo-theme-fluid');
const dest = path.join(repoRoot, 'themes', 'fluid');

function exists(p) {
  try {
    fs.accessSync(p);
    return true;
  } catch {
    return false;
  }
}

if (!exists(src)) {
  console.error('hexo-theme-fluid is not installed.');
  process.exit(1);
}

fs.mkdirSync(path.join(repoRoot, 'themes'), { recursive: true });

try {
  fs.rmSync(dest, { recursive: true, force: true });
} catch {}

fs.cpSync(src, dest, { recursive: true });
console.log(`Synced theme fluid -> ${dest}`);
