const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('site/io_worker.js', 'utf8');
async function directoryFor(cacheKey, endpointPresent = true, base = 'http://localhost:8000/data/') {
  let directory;
  const context = vm.createContext({
    URL, setTimeout, clearTimeout, performance,
    BroadcastChannel: class { postMessage() {} },
    self: { postMessage() {} },
    navigator: { storage: { async getDirectory() {
      return { async getDirectoryHandle(name) {
        directory = name;
        throw new Error('fixture ends after directory selection');
      } };
    } } },
    fetch: async (url) => ({
      status: String(url).includes('__launcher') && !endpointPresent ? 404 : 200,
      ok: String(url).includes('__launcher') ? endpointPresent : true,
      async json() { return String(url).includes('__launcher') ? { cacheKey } : { files: [], version: '123-4' }; },
    }),
  });
  vm.runInContext(source, context);
  await vm.runInContext(`init({base:${JSON.stringify(base)}})`, context);
  return directory;
}
(async () => {
  assert.equal(await directoryFor('a'.repeat(64)), 'gamedata-' + 'a'.repeat(64));
  assert.equal(await directoryFor('b'.repeat(64)), 'gamedata-' + 'b'.repeat(64));
  assert.equal(await directoryFor('ignored', false), undefined);
  assert.equal(await directoryFor('ignored', false, 'https://example.com/data/'), 'gamedata');
  assert.equal(await directoryFor('../unsafe'), undefined);
  console.log('Worker source cache isolation passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
