import { existsSync, readFileSync, mkdirSync, rmdirSync, writeFileSync, renameSync, unlinkSync, chmodSync } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export class BridgeError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const fields = new Set(['id', 'transport', 'enabled', 'command', 'arguments', 'url', 'workingDirectory', 'environment', 'headers', 'bearerToken', 'timeout', 'discoveryWait', 'keepConnected']);
const optionalFields = new Set(['command', 'url', 'workingDirectory', 'bearerToken']);
const reservedHeaders = new Set(['host', 'content-length', 'mcp-session-id', 'mcp-protocol-version', 'accept', 'content-type']);
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const fail = (message) => { throw new BridgeError(2, message); };

function validateReference(reference) {
  if (!object(reference) || !['environment', 'keychain'].includes(reference.source) || typeof reference.name !== 'string' || !reference.name) {
    fail('Credential references require source "environment" or "keychain" and a nonempty name.');
  }
}

function validateServer(server) {
  if (!object(server) || typeof server.id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(server.id)) {
    fail('Server IDs must start with a letter or digit and use up to 100 letters, digits, dots, underscores or hyphens.');
  }
  if (!['stdio', 'http'].includes(server.transport)) fail('Server transport must be "stdio" or "http".');
  for (const key of ['enabled', 'keepConnected']) {
    if (server[key] !== undefined && typeof server[key] !== 'boolean') fail(`Field '${key}' must be a boolean.`);
  }
  for (const key of optionalFields) {
    if (key !== 'bearerToken' && server[key] != null && (typeof server[key] !== 'string' || server[key].includes('\0'))) fail(`Field '${key}' must be a string without NUL characters.`);
  }
  if (server.arguments !== undefined && (!Array.isArray(server.arguments) || server.arguments.some((value) => typeof value !== 'string' || value.includes('\0')))) {
    fail('Server arguments must be an array of strings without NUL characters.');
  }
  if (server.transport === 'stdio' && !server.command) fail('A stdio server requires an executable command.');
  if (server.transport === 'http') {
    let url;
    try { url = new URL(server.url); } catch { fail('An HTTP server requires a valid URL.'); }
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail('Use an HTTP(S) URL without embedded credentials or a fragment.');
    if (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname.toLowerCase())) fail('Use HTTPS for remote servers. Plain HTTP is limited to loopback.');
  }
  if (server.workingDirectory != null && !path.isAbsolute(server.workingDirectory)) fail('Working directories must be absolute paths.');
  for (const key of ['timeout', 'discoveryWait']) {
    if (server[key] !== undefined && (!Number.isFinite(server[key]) || server[key] < 0 || server[key] > 86400 || key === 'timeout' && server[key] === 0)) fail(`Invalid ${key}; maximum is 86400 seconds, and timeout must be greater than zero.`);
  }
  for (const key of ['environment', 'headers']) {
    if (server[key] !== undefined && !object(server[key])) fail(`Field '${key}' must be an object of credential references.`);
    for (const [name, reference] of Object.entries(server[key] ?? {})) {
      const valid = key === 'environment' ? /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) : /^[!#$%&'*+.^_`|~A-Za-z0-9-]+$/.test(name) && !reservedHeaders.has(name.toLowerCase());
      if (!valid) fail(`Invalid or transport-managed name in '${key}'.`);
      validateReference(reference);
    }
  }
  const headers = Object.keys(server.headers ?? {}).map((name) => name.toLowerCase());
  if (new Set(headers).size !== headers.length) fail('Header names must be unique, ignoring case.');
  if (server.bearerToken != null) {
    validateReference(server.bearerToken);
    if (headers.includes('authorization')) fail('Configure either a bearer token or an Authorization header, not both.');
  }
}

export function validateProfile(profile) {
  if (!object(profile) || profile.version !== 1 || !Array.isArray(profile.servers)) fail('Unsupported profile. Expected a version-1 MCP Bridge JSON profile.');
  const ids = new Set();
  for (const server of profile.servers) {
    validateServer(server);
    if (ids.has(server.id)) fail('Server IDs must be unique.');
    ids.add(server.id);
  }
  return profile;
}

export function loadProfile(profilePath, allowMissing = false) {
  if (!existsSync(profilePath)) {
    if (allowMissing) return { version: 1, servers: [] };
    fail('Profile not found. Use server add to create it, or pass --config.');
  }
  let profile;
  try { profile = JSON.parse(readFileSync(profilePath, 'utf8')); }
  catch { fail('Cannot read profile. Check permissions and the version-1 JSON format.'); }
  return validateProfile(profile);
}

export function manageServer(action, id, input, profilePath) {
  if (input !== undefined) {
    if (!object(input)) fail('Server input must be a JSON object.');
    for (const [key, value] of Object.entries(input)) {
      if (!fields.has(key)) fail('Unknown server configuration field. Use the version-1 server format.');
      if (value === null && !optionalFields.has(key)) fail(`Field '${key}' cannot be null.`);
    }
    if (Object.hasOwn(input, 'id') && input.id !== id) fail('Input id must match the server ID in the command.');
  }
  if (action === 'show') {
    const server = loadProfile(profilePath).servers.find((entry) => entry.id === id);
    if (!server) fail(`Unknown server '${id}'.`);
    return { ok: true, operation: 'server.show', server: id, profile: profilePath, configuration: server };
  }
  const lock = `${profilePath}.lock`;
  try {
    mkdirSync(path.dirname(profilePath), { recursive: true });
    mkdirSync(lock, { mode: 0o700 });
  } catch { fail('Cannot lock profile. Another process may be saving it, or the directory is not writable.'); }
  const temporary = path.join(path.dirname(profilePath), `.${path.basename(profilePath)}.${randomUUID()}.tmp`);
  try {
    const profile = loadProfile(profilePath, action === 'add');
    const index = profile.servers.findIndex((entry) => entry.id === id);
    if (action === 'add') {
      if (index !== -1) fail(`Server '${id}' already exists. Use server update.`);
      profile.servers.push({ ...input, id });
    } else {
      if (index === -1) fail(`Unknown server '${id}'.`);
      if (action === 'update') profile.servers[index] = { ...profile.servers[index], ...input, id };
      else if (action === 'remove') profile.servers.splice(index, 1);
      else fail('Unsupported server configuration operation.');
    }
    validateProfile(profile);
    writeFileSync(temporary, `${JSON.stringify(profile, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    renameSync(temporary, profilePath);
    if (process.platform !== 'win32') chmodSync(profilePath, 0o600);
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    fail('Cannot save profile. Check directory permissions and whether another program has the file open.');
  } finally {
    try { unlinkSync(temporary); } catch { /* The successful rename already removed this path. */ }
    rmdirSync(lock);
  }
  return { ok: true, operation: `server.${action}`, server: id, profile: profilePath };
}
