import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createConnection } from 'node:net';
import { fileURLToPath } from 'node:url';
import { watchCompanion } from './companion-dev.mjs';

const project = new URL('../', import.meta.url);
const port = Number(process.env.PORT ?? 5173);
const clients = new Set();
let building = false;
let pendingBuild = false;
let timer;
let status = 'Building the Slint preview…';
let companionStatus = '';
const previewHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);

function queryCompanion(message) {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port: 5174 });
    let reply = '';
    socket.setEncoding('utf8');
    socket.setTimeout(1800, () => socket.destroy(new Error('Companion timed out')));
    socket.on('error', reject);
    socket.on('close', () => reject(new Error('Companion disconnected')));
    socket.once('connect', () => socket.write(`${JSON.stringify(message)}\n`));
    socket.on('data', (chunk) => {
      reply += chunk;
      if (reply.length > 1024 * 1024) {
        socket.destroy(new Error('Companion response too large'));
        return;
      }
      const end = reply.indexOf('\n');
      if (end !== -1) {
        resolve(reply.slice(0, end));
        socket.destroy();
      }
    });
  });
}

async function serveCompanion(request, response, path) {
  const listRequest = { '/api/cameras': 'camera_list', '/api/displays': 'display_list' }[path];
  let message = { type: listRequest ?? 'get_audio', version: 1 };
  if (request.method === 'POST') {
    if (request.headers.origin !== `http://${request.headers.host}` || request.headers['content-type'] !== 'application/json') {
      response.writeHead(403).end();
      return;
    }
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of request) {
        size += chunk.length;
        if (size > 2048) {
          response.writeHead(413, { Connection: 'close' }).end();
          request.resume();
          return;
        }
        chunks.push(chunk);
      }
      const { direction, id, enabled, brightness } = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (path === '/api/meter' && typeof enabled === 'boolean') {
        message = { type: enabled ? 'meter_read' : 'meter_stop', version: 1 };
      } else if (path === '/api/media' && ['previous', 'toggle', 'next'].includes(id)) {
        message = { type: 'media_control', version: 1, id };
      } else if (path === '/api/cameras' && enabled === false) {
        message = { type: 'camera_stop', version: 1 };
      } else if (path === '/api/cameras' && enabled === true && typeof id === 'string' && id.length > 0) {
        message = { type: 'camera_read', version: 1, id };
      } else if (path === '/api/displays' && typeof id === 'string' && /^\d{1,10}$/.test(id) &&
                 Number.isInteger(brightness) && brightness >= 0 && brightness <= 100) {
        message = { type: 'display_brightness', version: 1, id, brightness };
      } else if (path === '/api/audio' && ['input', 'output'].includes(direction) && typeof id === 'string' && id.length > 0) {
        message = { type: 'select_audio', version: 1, direction, id };
      } else {
        response.writeHead(400).end();
        return;
      }
    } catch {
      response.writeHead(400).end();
      return;
    }
  } else if (request.method !== 'GET' || path === '/api/meter' || path === '/api/media') {
    response.writeHead(405, { Allow: path === '/api/meter' || path === '/api/media' ? 'POST' : 'GET, POST' }).end();
    return;
  }

  try {
    const body = await queryCompanion(message);
    response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(body);
  } catch {
    response.writeHead(503, { 'Cache-Control': 'no-store' }).end();
  }
}

function streamCamera(request, response, ticket) {
  if (request.method !== 'GET') {
    response.writeHead(405, { Allow: 'GET' }).end();
    return;
  }
  if (request.headers['sec-fetch-site'] && request.headers['sec-fetch-site'] !== 'same-origin') {
    response.writeHead(403).end();
    return;
  }
  const socket = createConnection({ host: '127.0.0.1', port: 5174 });
  socket.setTimeout(3500, () => socket.destroy());
  socket.once('connect', () => socket.write(`${JSON.stringify({ type: 'camera_stream', version: 1, id: ticket })}\n`));
  socket.once('readable', () => {
    if (response.destroyed || socket.readableLength === 0) return;
    response.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=proremote-frame',
      'Cache-Control': 'no-store',
      'Cross-Origin-Resource-Policy': 'same-origin',
    });
    socket.pipe(response);
  });
  socket.on('error', () => socket.destroy());
  socket.once('close', () => {
    if (response.destroyed || response.writableEnded) return;
    if (!response.headersSent) response.writeHead(503, { 'Cache-Control': 'no-store' });
    response.end();
  });
  response.once('close', () => socket.destroy());
}

function publish(event, data) {
  for (const client of clients) client.write(`event: ${event}\ndata: ${data}\n\n`);
}

function build() {
  if (building) {
    pendingBuild = true;
    return;
  }
  building = true;
  const child = spawn('wasm-pack', ['build', '--dev', '--target', 'web', '--out-dir', 'web/pkg'], {
    cwd: fileURLToPath(project),
    stdio: 'inherit',
  });
  child.on('error', (error) => console.error(error.message));
  child.on('close', (code) => {
    building = false;
    status = code === 0 ? '' : 'The Wasm build failed. See the preview server terminal.';
    publish(code === 0 ? 'reload' : 'build-status', status || 'ready');
    if (pendingBuild) {
      pendingBuild = false;
      build();
    }
  });
}

function scheduleBuild() {
  clearTimeout(timer);
  timer = setTimeout(build, 150);
}

const server = createServer(async (request, response) => {
  const path = request.url;
  if (!previewHosts.has(request.headers.host)) {
    response.writeHead(403).end();
    return;
  }
  if (['/api/audio', '/api/meter', '/api/cameras', '/api/media', '/api/displays'].includes(path)) {
    await serveCompanion(request, response, path);
    return;
  }
  const stream = /^\/api\/camera-stream\/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.exec(path);
  if (stream) {
    streamCamera(request, response, stream[1]);
    return;
  }
  if (path === '/reload') {
    response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
    response.write(`event: build-status\ndata: ${status}\n\n`);
    response.write(`event: companion-status\ndata: ${companionStatus}\n\n`);
    clients.add(response);
    response.on('close', () => clients.delete(response));
    return;
  }

  const asset = /^\/pkg\/(?:[\w-]+\/)*[\w.-]+\.(js|wasm)$/.exec(path);
  if (path !== '/' && !asset) {
    response.writeHead(404).end();
    return;
  }

  const contentType = asset ? (asset[1] === 'wasm' ? 'application/wasm' : 'text/javascript') : 'text/html';
  try {
    const body = await readFile(new URL(path === '/' ? 'web/index.html' : `web${path}`, project));
    response.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-store' }).end(body);
  } catch (error) {
    response.writeHead(error.code === 'ENOENT' ? 404 : 500).end();
  }
});

server.on('error', (error) => {
  console.error(`Could not start the Tab5 preview server. ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Tab5 preview at http://127.0.0.1:${port}`);
  for (const directory of ['src', 'ui']) watch(new URL(directory, project), scheduleBuild);
  watch(project, (_, name) => {
    if (name === 'Cargo.toml' || name === 'build.rs') scheduleBuild();
  });
  watch(new URL('web/', project), (_, name) => {
    if (name === 'index.html') publish('reload', 'ready');
  });
  if (process.platform === 'darwin') {
    watchCompanion(new URL('companion/', project), async () => {
      try {
        const reply = await queryCompanion({ type: 'get_audio', version: 1 });
        return JSON.parse(reply).type === 'audio_state';
      } catch { return false; }
    }, message => {
      companionStatus = message;
      publish('companion-status', message);
    });
  }
  build();
});
