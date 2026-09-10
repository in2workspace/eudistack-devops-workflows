#!/usr/bin/env node
import {
  createHash,
} from 'node:crypto';
import {
  lstat,
  readFile,
  readdir,
  realpath,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

function validateRelativePath(value) {
  if (
    !value
    || value.includes('\\')
    || value.startsWith('/')
    || value.split('/').some((part) => part === '' || part === '.' || part === '..')
  ) {
    throw new Error(`Unsafe manifest path '${value}'.`);
  }
}

async function collectFiles(root, current = '') {
  const directory = path.join(root, ...current.split('/').filter(Boolean));
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name, 'en'))) {
    const relative = current ? `${current}/${entry.name}` : entry.name;
    validateRelativePath(relative);
    const absolute = path.join(root, ...relative.split('/'));
    const metadata = await lstat(absolute);
    if (metadata.isSymbolicLink()) {
      throw new Error(`Symlinks are not allowed: '${relative}'.`);
    }
    if (metadata.isDirectory()) {
      files.push(...await collectFiles(root, relative));
    } else if (metadata.isFile()) {
      const content = await readFile(absolute);
      files.push({ path: relative, sha256: sha256(content), size: metadata.size });
    } else {
      throw new Error(`Unsupported filesystem entry: '${relative}'.`);
    }
  }
  return files;
}

function canonicalPayload(files) {
  return `${files.map((file) => `${file.sha256}  ${file.size}  ${file.path}`).join('\n')}\n`;
}

async function generate(directory, manifestPath) {
  const root = await realpath(directory);
  const manifestAbsolute = path.resolve(manifestPath);
  if (manifestAbsolute === root || manifestAbsolute.startsWith(`${root}${path.sep}`)) {
    throw new Error('The manifest must be written outside the directory being hashed.');
  }
  const files = await collectFiles(root);
  const digest = sha256(Buffer.from(canonicalPayload(files)));
  const manifest = {
    schemaVersion: 1,
    algorithm: 'sha256',
    digest: `sha256:${digest}`,
    files,
  };
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
  console.log(manifest.digest);
}

async function verify(directory, manifestPath, expectedDigest = '') {
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (
    manifest.schemaVersion !== 1
    || manifest.algorithm !== 'sha256'
    || !Array.isArray(manifest.files)
    || !/^sha256:[0-9a-f]{64}$/.test(manifest.digest)
  ) {
    throw new Error('Manifest schema is invalid.');
  }
  const paths = new Set();
  for (const file of manifest.files) {
    validateRelativePath(file.path);
    if (
      paths.has(file.path)
      || !/^[0-9a-f]{64}$/.test(file.sha256)
      || !Number.isSafeInteger(file.size)
      || file.size < 0
    ) {
      throw new Error(`Invalid or duplicate manifest entry '${file.path}'.`);
    }
    paths.add(file.path);
  }
  const sorted = [...manifest.files].sort((left, right) => left.path.localeCompare(right.path, 'en'));
  if (JSON.stringify(sorted) !== JSON.stringify(manifest.files)) {
    throw new Error('Manifest entries are not canonically sorted.');
  }
  const calculatedDigest = `sha256:${sha256(Buffer.from(canonicalPayload(manifest.files)))}`;
  if (calculatedDigest !== manifest.digest) {
    throw new Error('Manifest aggregate digest is invalid.');
  }
  if (expectedDigest && expectedDigest !== manifest.digest) {
    throw new Error(`Manifest digest '${manifest.digest}' does not match '${expectedDigest}'.`);
  }
  const actualFiles = await collectFiles(await realpath(directory));
  if (JSON.stringify(actualFiles) !== JSON.stringify(manifest.files)) {
    throw new Error('Directory contains missing, unexpected, or changed files.');
  }
  console.log(manifest.digest);
}

const [command, directory, manifestPath, expectedDigest = ''] = process.argv.slice(2);
if (!['generate', 'verify'].includes(command) || !directory || !manifestPath) {
  fail('Usage: manifest.mjs {generate|verify} DIRECTORY MANIFEST [EXPECTED_DIGEST]');
}

try {
  if (command === 'generate') {
    await generate(directory, manifestPath);
  } else {
    await verify(directory, manifestPath, expectedDigest);
  }
} catch (error) {
  fail(error.message);
}
