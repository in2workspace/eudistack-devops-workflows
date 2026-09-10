#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(directory, '.runtime-config-test-work');
const script = path.join(directory, 'runtime-config.mjs');
await rm(root, { recursive: true, force: true });
await mkdir(root, { recursive: true });

try {
  const template = path.join(root, 'env.template.js');
  const config = path.join(root, 'config.json');
  const output = path.join(root, 'env.js');
  await writeFile(template, 'window.env = { url: "${PUBLIC_URL}", key: "__SECRET_KEY__" };\n');
  await writeFile(config, JSON.stringify({ PUBLIC_URL: 'https://example.test/a"b', SECRET_KEY: 'hidden' }));
  const success = spawnSync(process.execPath, [
    script, template, output, 'PUBLIC_URL,SECRET_KEY', config,
  ], { encoding: 'utf8' });
  assert.equal(success.status, 0, success.stderr);
  const rendered = await readFile(output, 'utf8');
  assert.match(rendered, /https:\/\/example\.test\/a\\"b/);
  assert.match(rendered, /hidden/);
  assert.doesNotMatch(success.stdout + success.stderr, /hidden/);

  const missing = spawnSync(process.execPath, [
    script, template, path.join(root, 'missing.js'), 'NOT_PRESENT', config,
  ], { encoding: 'utf8' });
  assert.notEqual(missing.status, 0);
  console.log('runtime config tests passed');
} finally {
  await rm(root, { recursive: true, force: true });
}
