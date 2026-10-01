#!/usr/bin/env node
import { readFileSync, existsSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const VERSION = '1.1.0';
const MAX_ARGUMENT_BYTES = 16 * 1024 * 1024;
const HELP = `MCP Bridge ${VERSION} — Windows command line client for MCP tools

mcp-bridge servers list
mcp-bridge server test <server>
mcp-bridge tools list <server>
mcp-bridge tools describe <server> <tool>
mcp-bridge call <server> <tool> --args-file <path>
mcp-bridge call <server> <tool> --stdin

Options: --config <profile.json>  --timeout <seconds>  --args-file <path>
         --stdin  --direct  --help  --version
Windows calls connect directly to the configured server. App-owned sessions,
Keychain credentials, and cached catalogs are available in the macOS app only.
Arguments must be one JSON object. Output is one JSON document; diagnostics use stderr.
Exit codes: 0 success, 2 input/config, 3 connection/protocol/cancelled, 4 tool error, 5 timeout.`;

class BridgeError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function defaultProfilePath() {
  const base = process.env.APPDATA || path.join(homedir(), 'AppData', 'Roaming');
  return path.join(base, 'MCP Bridge', 'profile.json');
}

function parseArgs(args) {
  const positional = [];
  const seen = new Set();
  let config = defaultProfilePath();
  let timeout;
  let argsFile;
  let useStdin = false;
  let direct = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith('--')) { positional.push(arg); continue; }
    if (seen.has(arg)) throw new BridgeError(2, `Duplicate option '${arg}'.`);
    seen.add(arg);
    switch (arg) {
      case '--stdin': useStdin = true; break;
      case '--direct': direct = true; break;
      case '--config':
      case '--timeout':
      case '--args-file': {
        const value = args[++i];
        if (!value || value.startsWith('--')) throw new BridgeError(2, `Missing value for '${arg}'.`);
        if (arg === '--config') config = path.resolve(value);
        else if (arg === '--args-file') argsFile = value;
        else {
          timeout = Number(value);
          if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 86400) {
            throw new BridgeError(2, 'Timeout must be greater than 0 and no more than 86400 seconds.');
          }
        }
        break;
      }
      case '--cached':
      case '--live':
        throw new BridgeError(2, 'Saved tool catalogs are available through the macOS app. Run tools list without this option to discover live tools.');
      case '--session':
        throw new BridgeError(2, 'App-owned shared sessions are available on macOS only. Use --direct on Windows.');
      default: throw new BridgeError(2, `Unknown option '${arg}'. Run --help for usage.`);
    }
  }
  if (seen.has('--cached') && seen.has('--live')) throw new BridgeError(2, 'Use either --cached or --live, not both.');
  return { positional, config, timeout, argsFile, useStdin, direct };
}

function loadProfile(profilePath) {
  if (!existsSync(profilePath)) {
    throw new BridgeError(2, `Profile not found: ${profilePath}. Create it in MCP Bridge or pass --config.`);
  }
  let profile;
  try { profile = JSON.parse(readFileSync(profilePath, 'utf8')); }
  catch { throw new BridgeError(2, 'Cannot read profile. Check the file and its version-1 JSON format.'); }
  if (profile?.version !== 1 || !Array.isArray(profile.servers)) {
    throw new BridgeError(2, 'Unsupported profile. Expected a version-1 MCP Bridge JSON profile.');
  }
  const ids = new Set();
  for (const server of profile.servers) {
    if (!server || typeof server.id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(server.id) || ids.has(server.id)) {
      throw new BridgeError(2, 'Server IDs must be unique and use letters, digits, dots, underscores or hyphens.');
    }
    ids.add(server.id);
    if (!['stdio', 'http'].includes(server.transport)) throw new BridgeError(2, `Server '${server.id}' has an unsupported transport.`);
    if (server.arguments !== undefined && (!Array.isArray(server.arguments) || server.arguments.some((value) => typeof value !== 'string'))) {
      throw new BridgeError(2, `Server '${server.id}' arguments must be an array of strings.`);
    }
    if (server.timeout !== undefined && (!Number.isFinite(server.timeout) || server.timeout <= 0 || server.timeout > 86400)) {
      throw new BridgeError(2, `Server '${server.id}' has an invalid timeout.`);
    }
    if (server.discoveryWait !== undefined && (!Number.isFinite(server.discoveryWait) || server.discoveryWait < 0 || server.discoveryWait > 86400)) {
      throw new BridgeError(2, `Server '${server.id}' has an invalid discovery wait.`);
    }
  }
  return profile;
}

function getServer(profile, id, direct) {
  const server = profile.servers.find((entry) => entry.id === id);
  if (!server) throw new BridgeError(2, `Unknown server '${id}'. Run 'servers list' to see configured servers.`);
  if (server.enabled === false) throw new BridgeError(2, `Server '${id}' is disabled.`);
  if (server.keepConnected && !direct) {
    throw new BridgeError(2, `Server '${id}' is configured for the macOS app session. Use --direct on Windows to request a separate connection.`);
  }
  return server;
}

function resolveReference(reference) {
  if (!reference || typeof reference.name !== 'string' || !reference.name) throw new BridgeError(2, 'Credential references need a name.');
  if (reference.source === 'environment') {
    const value = process.env[reference.name];
    if (!value) throw new BridgeError(2, `Missing environment variable '${reference.name}'. Set it in your environment.`);
    return value;
  }
  if (reference.source === 'keychain') throw new BridgeError(2, 'Windows does not support macOS Keychain references. Use an environment reference.');
  throw new BridgeError(2, 'Credential references must use source "environment" or "keychain".');
}

function serverEnvironment(server) {
  const inheritedNames = new Set([
    'PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP', 'USERPROFILE',
    'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'PROGRAMFILES',
    'PROGRAMFILES(X86)', 'PROGRAMW6432', 'PROCESSOR_ARCHITECTURE', 'SYSTEMDRIVE', 'USERNAME', 'LANG'
  ]);
  const env = Object.fromEntries(Object.entries(process.env).filter(([key, value]) => inheritedNames.has(key.toUpperCase()) && value !== undefined));
  for (const [key, reference] of Object.entries(server.environment ?? {})) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new BridgeError(2, `Invalid environment variable name '${key}'.`);
    env[key] = resolveReference(reference);
  }
  return env;
}

function transportFor(server) {
  if (server.transport === 'stdio') {
    if (typeof server.command !== 'string' || !server.command) throw new BridgeError(2, 'A stdio server requires an executable command.');
    const cwd = server.workingDirectory ? path.resolve(server.workingDirectory) : undefined;
    if (cwd && (!existsSync(cwd) || !statSync(cwd).isDirectory())) throw new BridgeError(2, 'Configured working directory does not exist.');
    return new StdioClientTransport({
      command: server.command,
      args: Array.isArray(server.arguments) ? server.arguments : [],
      cwd,
      env: serverEnvironment(server),
      stderr: 'ignore'
    });
  }
  let url;
  try { url = new URL(server.url); } catch { throw new BridgeError(2, 'An HTTP server requires a valid URL.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new BridgeError(2, 'Use an HTTP(S) URL without embedded credentials or a fragment.');
  }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname.toLowerCase());
  if (url.protocol === 'http:' && !loopback) throw new BridgeError(2, 'Use HTTPS for remote servers. Plain HTTP is limited to loopback.');
  const headers = {};
  const reservedHeaders = new Set(['host', 'content-length', 'mcp-session-id', 'mcp-protocol-version', 'accept', 'content-type']);
  const seenHeaders = new Set();
  for (const [name, reference] of Object.entries(server.headers ?? {})) {
    const key = name.toLowerCase();
    if (!/^[!#$%&'*+.^_`|~A-Za-z0-9-]+$/.test(name) || reservedHeaders.has(key)) {
      throw new BridgeError(2, `Invalid or transport-managed HTTP header '${name}'.`);
    }
    if (seenHeaders.has(key)) throw new BridgeError(2, 'Header names must be unique, ignoring case.');
    seenHeaders.add(key);
    headers[name] = resolveReference(reference);
  }
  if (server.bearerToken) {
    if (seenHeaders.has('authorization')) {
      throw new BridgeError(2, 'Configure either a bearer token or an Authorization header, not both.');
    }
    headers.Authorization = `Bearer ${resolveReference(server.bearerToken)}`;
  }
  if (Object.values(headers).some((value) => /[\r\n]/.test(value))) throw new BridgeError(2, 'Header values cannot contain newlines.');
  return new StreamableHTTPClientTransport(url, {
    requestInit: { headers, redirect: 'manual', credentials: 'omit' }
  });
}

function readArguments(argsFile, useStdin) {
  if (Boolean(argsFile) === useStdin) throw new BridgeError(2, 'Use exactly one of --stdin or --args-file for tool arguments.');
  let text;
  try { text = readFileSync(useStdin ? 0 : argsFile); }
  catch { throw new BridgeError(2, 'Could not read argument input. Check the file path and permissions.'); }
  if (text.byteLength > MAX_ARGUMENT_BYTES) throw new BridgeError(2, 'Arguments exceed the 16 MiB limit.');
  let value;
  try { value = JSON.parse(text.toString('utf8')); }
  catch { throw new BridgeError(2, 'Arguments are not valid JSON.'); }
  if (!value || Array.isArray(value) || typeof value !== 'object') throw new BridgeError(2, 'Tool arguments must be a JSON object.');
  return value;
}

function delay(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(signal.reason);
    const onAbort = () => { clearTimeout(timer); reject(signal.reason); };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    timer.unref?.();
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

async function discover(client, server, target, signal) {
  const waitSeconds = client.getServerCapabilities()?.tools?.listChanged ? (server.discoveryWait ?? 10) : 0;
  const deadline = Date.now() + waitSeconds * 1000;
  while (true) {
    const result = await client.listTools({}, { signal });
    if (!waitSeconds || (target ? result.tools.some((tool) => tool.name === target) : result.tools.length) || Date.now() >= deadline) return result.tools;
    await delay(Math.min(250, deadline - Date.now()), signal);
  }
}

async function withDeadline(seconds, operation) {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort(new Error('Operation timed out.'));
  }, seconds * 1000);
  try { return await operation(controller.signal); }
  catch (error) {
    if (timedOut) throw new BridgeError(5, `Operation timed out after ${seconds} seconds. Execution was not retried; a remote tool may already have completed.`);
    if (error instanceof BridgeError) throw error;
    if (controller.signal.aborted) throw new BridgeError(3, 'Operation cancelled.');
    throw new BridgeError(3, 'MCP connection or protocol failed. Check the server executable, endpoint, credentials, and compatibility.');
  } finally { clearTimeout(timer); }
}

async function execute(server, operation, timeout) {
  const transport = transportFor(server);
  const client = new Client({ name: 'MCPBridge', version: VERSION });
  try {
    return await withDeadline(timeout, async (signal) => {
      await Promise.race([
        client.connect(transport),
        delay(timeout * 1000, signal)
      ]);
      if (operation.kind === 'test') return { ok: true, server: server.id, operation: 'server.test', result: client.getServerVersion() ?? {} };
      if (operation.kind === 'list' || operation.kind === 'describe') {
        const tools = await discover(client, server, operation.tool, signal);
        if (operation.kind === 'describe') {
          const tool = tools.find((entry) => entry.name === operation.tool);
          if (!tool) throw new BridgeError(2, `Tool '${operation.tool}' was not published during discovery. No tool was executed.`);
          return { ok: true, server: server.id, operation: 'tools.describe', result: tool };
        }
        return {
          ok: true,
          server: server.id,
          operation: 'tools.list',
          result: { tools },
          ...(tools.length ? {} : { warnings: ['Server connected but published no tools during live discovery. No tool was executed.'] })
        };
      }
      const available = await discover(client, server, operation.tool, signal);
      if (!available.some((entry) => entry.name === operation.tool)) {
        throw new BridgeError(2, `Tool '${operation.tool}' was not published during discovery. No tool was executed.`);
      }
      const result = await client.callTool({ name: operation.tool, arguments: operation.arguments }, { signal });
      const isError = result.isError === true;
      return { ok: !isError, server: server.id, operation: 'tools.call', result, exitCode: isError ? 4 : 0 };
    });
  } finally {
    if (transport instanceof StreamableHTTPClientTransport) {
      try { await transport.terminateSession(); } catch { /* Best-effort server cleanup. */ }
    }
    try { await client.close(); } catch { /* Preserve the operation result. */ }
  }
}

async function main() {
  const raw = process.argv.slice(2);
  if (raw.length === 0 || raw.length === 1 && ['--help', '-h'].includes(raw[0])) { process.stdout.write(`${HELP}\n`); return; }
  if (raw.length === 1 && raw[0] === '--version') { process.stdout.write(`${VERSION}\n`); return; }
  let response;
  let exitCode = 0;
  try {
    const options = parseArgs(raw);
    const profile = loadProfile(options.config);
    const args = options.positional;
    if (args.length === 2 && args[0] === 'servers' && args[1] === 'list') {
      if (options.argsFile || options.useStdin) throw new BridgeError(2, 'Argument input is only supported for call.');
      response = { ok: true, servers: profile.servers.map(({ id, transport, enabled }) => ({ id, transport, enabled: enabled !== false })) };
    } else {
      let serverID; let operation;
      if (args.length === 3 && args[0] === 'server' && args[1] === 'test') {
        serverID = args[2]; operation = { kind: 'test' };
      } else if (args.length === 3 && args[0] === 'tools' && args[1] === 'list') {
        serverID = args[2]; operation = { kind: 'list' };
      } else if (args.length === 4 && args[0] === 'tools' && args[1] === 'describe') {
        serverID = args[2]; operation = { kind: 'describe', tool: args[3] };
      } else if (args.length === 3 && args[0] === 'call') {
        serverID = args[1]; operation = { kind: 'call', tool: args[2], arguments: readArguments(options.argsFile, options.useStdin) };
      } else throw new BridgeError(2, 'Invalid command. Run --help for usage.');
      if (operation.kind !== 'call' && (options.argsFile || options.useStdin)) throw new BridgeError(2, 'Argument input is only supported for call.');
      const server = getServer(profile, serverID, options.direct);
      const timeout = options.timeout ?? server.timeout ?? 60;
      if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 86400) throw new BridgeError(2, 'Timeout must be greater than 0 and no more than 86400 seconds.');
      response = await execute(server, operation, timeout);
      exitCode = response.exitCode ?? 0;
      delete response.exitCode;
    }
  } catch (error) {
    const bridgeError = error instanceof BridgeError ? error : new BridgeError(2, 'Could not complete the command. Check the profile and input.');
    response = { ok: false, error: { code: bridgeError.code, message: bridgeError.message } };
    process.stderr.write(`${bridgeError.message}\n`);
    exitCode = bridgeError.code;
  }
  process.stdout.write(`${JSON.stringify(response)}\n`);
  process.exitCode = exitCode;
}

main().catch(() => {
  process.stdout.write('{"ok":false,"error":{"code":2,"message":"Could not complete the command."}}\n');
  process.exitCode = 2;
});
