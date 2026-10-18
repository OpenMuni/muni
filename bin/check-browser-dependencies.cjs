// Keep the audited manifest and the actual scripts/styles served to users in sync.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const manifest = require('../package.json');
const path = 'www/views/layout.erb';
let template = fs.readFileSync(path, 'utf8');
const write = process.argv.includes('--write');
const localPackage = 'maplibre-gl';
const localAssets = ['maplibre-gl.mjs', 'maplibre-gl-shared.mjs', 'maplibre-gl-worker.mjs', 'maplibre-gl.css'];
const localRoot = `www/public/vendor/${localPackage}`;
assert.equal(require(`../node_modules/${localPackage}/package.json`).version, manifest.dependencies[localPackage]);
for (const asset of [...localAssets, 'LICENSE.txt']) {
  const source = `node_modules/${localPackage}/${asset === 'LICENSE.txt' ? '' : 'dist/'}${asset}`;
  const bytes = fs.readFileSync(source);
  const target = `${localRoot}/${asset}`;
  if (write) {
    fs.mkdirSync(localRoot, {recursive: true});
    fs.writeFileSync(target, bytes);
  }
  assert.deepEqual(fs.readFileSync(target), bytes, `Vendored asset differs from its audited package: ${asset}`);
}
assert.ok(template.includes("import('/vendor/maplibre-gl/maplibre-gl.mjs')"));
assert.ok(template.includes('href="/vendor/maplibre-gl/maplibre-gl.css"'));
template = template.replace(/<(?:script|link)[^>]+(?:src|href)="https:\/\/unpkg\.com\/((?:@[^/]+\/)?[^@/]+)@([^/"\s]+)\/([^"\s]+)"[^>]*>/g,
  (tag, name, version, asset) => {
    assert.equal(manifest.dependencies[name], version, `Unaudited CDN dependency: ${name}@${version}`);
    const bytes = fs.readFileSync(`node_modules/${name}/${asset}`);
    const integrity = `sha384-${crypto.createHash('sha384').update(bytes).digest('base64')}`;
    if (write) {
      return tag.replace(/ (?:integrity|crossorigin)="[^"]*"/g, '')
        .replace(/>$/, ` integrity="${integrity}" crossorigin="anonymous">`);
    }
    assert.ok(tag.includes(`integrity="${integrity}"`), `Incorrect integrity hash for ${name}/${asset}`);
    assert.ok(tag.includes('crossorigin="anonymous"'), `Missing anonymous CORS for ${name}/${asset}`);
    return tag;
  });
const urls = [...template.matchAll(/https:\/\/unpkg\.com\/((?:@[^/]+\/)?[^@/]+)@([^/"\s]+)/g)];
assert.ok(urls.length > 0, 'No browser dependencies found');
for (const [, name, version] of urls) {
  assert.equal(manifest.dependencies[name], version, `Unaudited CDN dependency: ${name}@${version}`);
}
for (const name of Object.keys(manifest.dependencies)) {
  if (name === localPackage) continue;
  assert.ok(urls.some(([, used]) => used === name), `Unused browser dependency: ${name}`);
}
console.log('Browser dependencies match the audit manifest.');
if (write) fs.writeFileSync(path, template);
