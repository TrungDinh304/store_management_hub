// Generates the gitignored environment files from committed *.example.ts templates
// when they are missing (fresh clone / CI). Existing real files are left untouched,
// so local Supabase values are preserved. No external dependencies.
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..', 'src', 'environments');
const pairs = [
  ['environment.example.ts', 'environment.ts'],
  ['environment.prod.example.ts', 'environment.prod.ts'],
];

if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

for (const [template, target] of pairs) {
  const dest = path.join(dir, target);
  if (fs.existsSync(dest)) continue;
  const tpl = path.join(dir, template);
  if (!fs.existsSync(tpl)) {
    console.warn(`[setup:env] template ${template} is missing — skipped ${target}.`);
    continue;
  }
  fs.copyFileSync(tpl, dest);
  console.log(`[setup:env] created ${target} from ${template} — fill in your Supabase values.`);
}
