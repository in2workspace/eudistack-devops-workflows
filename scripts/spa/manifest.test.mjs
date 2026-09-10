#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'manifest.mjs');
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '.manifest-test-work');
await rm(root, { recursive: true, force: true });
await mkdir(root, { recursive: true });
try {
  const app = path.join(root, 'app');
  await mkdir(path.join(app, 'assets'), { recursive: true });
  await writeFile(path.join(app, 'index.html'), '<html></html>\n');
  await writeFile(path.join(app, 'assets', 'main.123.js'), 'console.log("ok");\n');
  const first = path.join(root, 'first.json');
  const second = path.join(root, 'second.json');
  execFileSync(process.execPath, [script, 'generate', app, first]);
  execFileSync(process.execPath, [script, 'generate', app, second]);
  assert.equal(await readFile(first, 'utf8'), await readFile(second, 'utf8'));
  execFileSync(process.execPath, [script, 'verify', app, first]);

  await writeFile(path.join(app, 'index.html'), 'tampered\n');
  assert.notEqual(spawnSync(process.execPath, [script, 'verify', app, first]).status, 0);
  await writeFile(path.join(app, 'index.html'), '<html></html>\n');
  await writeFile(path.join(app, 'unexpected.txt'), 'unexpected\n');
  assert.notEqual(spawnSync(process.execPath, [script, 'verify', app, first]).status, 0);

  const unsafe = JSON.parse(await readFile(first, 'utf8'));
  unsafe.files[0].path = '../escape';
  await writeFile(path.join(root, 'unsafe.json'), JSON.stringify(unsafe));
  assert.notEqual(spawnSync(process.execPath, [script, 'verify', app, path.join(root, 'unsafe.json')]).status, 0);
  console.log('manifest tests passed');
} finally {
  await rm(root, { recursive: true, force: true });
}
