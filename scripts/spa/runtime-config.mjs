#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

const [templatePath, outputPath, requiredList = '', configPath = ''] = process.argv.slice(2);
if (!templatePath || !outputPath) {
  fail('Usage: runtime-config.mjs TEMPLATE OUTPUT REQUIRED_VARIABLES_CSV');
}

try {
  const config = configPath ? JSON.parse(await readFile(configPath, 'utf8')) : {};
  if (config === null || Array.isArray(config) || typeof config !== 'object') {
    throw new Error('Runtime configuration JSON must be an object.');
  }
  const required = requiredList.split(',').map((value) => value.trim()).filter(Boolean);
  const missing = required.filter(
    (name) => !/^[A-Z][A-Z0-9_]*$/.test(name) || !(process.env[name] || config[name]),
  );
  if (missing.length > 0) {
    throw new Error(`Missing required runtime configuration variable(s): ${missing.join(', ')}.`);
  }

  let rendered = await readFile(templatePath, 'utf8');
  for (const name of required) {
    const value = process.env[name] || config[name];
    if (typeof value !== 'string') {
      throw new Error(`Runtime configuration variable '${name}' must be a string.`);
    }
    const escaped = JSON.stringify(value).slice(1, -1);
    const patterns = [
      new RegExp(`\\$\\{${name}\\}`, 'g'),
      new RegExp(`\\{\\{${name}\\}\\}`, 'g'),
      new RegExp(`__${name}__`, 'g'),
    ];
    const before = rendered;
    for (const pattern of patterns) rendered = rendered.replace(pattern, escaped);
    if (rendered === before) {
      throw new Error(`Template has no placeholder for required variable '${name}'.`);
    }
  }
  const unresolved = rendered.match(/\$\{[A-Z][A-Z0-9_]*\}|\{\{[A-Z][A-Z0-9_]*\}\}|__[A-Z][A-Z0-9_]*__/g);
  if (unresolved) {
    throw new Error(`Template contains unresolved runtime placeholders: ${[...new Set(unresolved)].join(', ')}.`);
  }
  await writeFile(outputPath, rendered, { flag: 'wx', mode: 0o600 });
  const outputDigest = `sha256:${digest(rendered)}`;
  if (process.env.GITHUB_OUTPUT) {
    await writeFile(process.env.GITHUB_OUTPUT, `digest=${outputDigest}\n`, { flag: 'a' });
  }
  console.log(`Rendered runtime configuration (${outputDigest}).`);
} catch (error) {
  fail(error.message);
}
