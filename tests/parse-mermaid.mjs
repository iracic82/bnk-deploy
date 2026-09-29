// Parse every mermaid diagram in the repo's markdown with the real mermaid library.
// A diagram that fails here renders as an error box on GitHub, so this is a build failure.
import { JSDOM } from 'jsdom';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, extname } from 'node:path';

const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });

const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

const skip = new Set(['.git', 'node_modules']);
function markdown(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (skip.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) markdown(p, out);
    else if (extname(p) === '.md') out.push(p);
  }
  return out;
}

let total = 0, bad = 0;
for (const file of markdown('.').sort()) {
  const blocks = readFileSync(file, 'utf8').matchAll(/```mermaid\n([\s\S]*?)```/g);
  let i = 0;
  for (const m of blocks) {
    i++; total++;
    try {
      await mermaid.parse(m[1]);
      console.log(`  ok    ${file} #${i}`);
    } catch (e) {
      bad++;
      console.log(`  FAIL  ${file} #${i}: ${String(e.message || e).split('\n')[0]}`);
    }
  }
}
console.log(bad ? `\n  ${bad} of ${total} will not render` : `\n  all ${total} diagrams parse`);
process.exit(bad ? 1 : 0);
