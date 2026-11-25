import { createHmac } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createConnection } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

async function request(message, token) {
  const socket = createConnection({ host: '127.0.0.1', port: 5174 });
  let reply = '';
  socket.setEncoding('utf8');
  socket.setTimeout(2000, () => socket.destroy(new Error('Companion antwortet nicht')));
  socket.once('connect', () => socket.write(`${JSON.stringify({ ...message, version: 1, token })}\n`));
  try {
    for await (const chunk of socket) {
      reply += chunk;
      if (reply.length > 200_000) throw new Error('Companion-Antwort zu groß');
      const end = reply.indexOf('\n');
      if (end === -1) continue;
      const result = JSON.parse(reply.slice(0, end));
      if (result.error) throw new Error(result.error);
      return result;
    }
    throw new Error('Companion-Verbindung beendet');
  } finally {
    socket.destroy();
  }
}

async function waitFor(check, timeout = 12_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const result = await check();
    if (result) return result;
    await delay(250);
  }
  throw new Error('Tab5 hat den Auftrag nicht rechtzeitig abgeschlossen');
}

async function main() {
  const [action, first, second, ...rest] = process.argv.slice(2);
  const wifiModes = ['default', 'awake', 'compatible'];
  const x = Number(first);
  const y = Number(second);
  const valid = rest.length === 0 && (
    (['status', 'lan-rediscover'].includes(action) && first === undefined) ||
    (action === 'tap' && /^\d+$/.test(first) && /^\d+$/.test(second) && x < 1280 && y < 720) ||
    (action === 'screenshot' && first && second === undefined) ||
    (action === 'camera-pattern' && ['on', 'off'].includes(first) && second === undefined) ||
    (action === 'camera-transport' && ['udp', 'tcp'].includes(first) && second === undefined) ||
    (action === 'camera-layout' && ['ppa', 'dma'].includes(first) && second === undefined) ||
    (action === 'camera-fps' && /^([1-9]|[12][0-9]|30)$/.test(first) && second === undefined) ||
    (action === 'wifi-mode' && wifiModes.includes(first) && second === undefined) ||
    (action === 'swipe-metrics' && ['legacy', 'fast', 'cached', 'ppa'].includes(first) && second === undefined)
  );
  if (!valid) throw new Error('Aufruf: node companion/ui-test.mjs status | lan-rediscover | tap X Y | screenshot DATEI.jpg | camera-pattern on|off | camera-transport udp|tcp | camera-layout ppa|dma | camera-fps 1..30 | wifi-mode default|awake|compatible | swipe-metrics legacy|fast|cached|ppa');

  const pair = JSON.parse(await readFile(join(homedir(), 'Library/Application Support/Pro Remote/LAN/pairing.json'), 'utf8'));
  const token = createHmac('sha256', Buffer.from(pair.key)).update('pro-remote-tab5-ui-test-v1').digest('base64');
  const send = (type, fields) => request({ type, ...fields }, token);
  if (['camera-pattern', 'camera-transport', 'camera-layout', 'camera-fps'].includes(action)) {
    await send(`ui_test_${action.replace('-', '_')}`, { id: first });
    return;
  }
  const state = await waitFor(async () => (await send('ui_test_status')).ui_state);
  if (action === 'status') {
    console.log(JSON.stringify(state, null, 2));
    return;
  }
  if (action === 'lan-rediscover') {
    const { id } = await send('ui_test_lan_rediscover');
    const updated = await waitFor(async () => {
      const { ui_state } = await send('ui_test_status');
      return ui_state?.ack === id && ui_state.lan_discoveries > state.lan_discoveries ? ui_state : null;
    }, 19_000);
    console.log(JSON.stringify(updated, null, 2));
    return;
  }
  if (action === 'tap') {
    const { id } = await send('ui_test_tap', { x, y });
    const state = await waitFor(async () => {
      const { ui_state } = await send('ui_test_status');
      return ui_state?.ack === id ? ui_state : null;
    });
    console.log(JSON.stringify(state, null, 2));
    return;
  }
  if (action === 'wifi-mode') {
    if (state.wifi_mode === wifiModes.indexOf(first)) {
      console.log(JSON.stringify(state, null, 2));
      return;
    }
    const { id } = await send('ui_test_wifi_mode', { id: first });
    const updated = await waitFor(async () => {
      const { ui_state } = await send('ui_test_status');
      return ui_state?.ack === id && ui_state.wifi_mode === wifiModes.indexOf(first) ? ui_state : null;
    }, 19_000);
    console.log(JSON.stringify(updated, null, 2));
    return;
  }
  if (action === 'swipe-metrics') {
    const { id } = await send('ui_test_swipe_metrics', { id: first });
    const result = await waitFor(async () => {
      const { ui_state } = await send('ui_test_status');
      return ui_state?.ack === id && ui_state.swipe_metrics ? ui_state : null;
    });
    console.log(JSON.stringify({ page: result.page, ...result.swipe_metrics }, null, 2));
    return;
  }

  const { id } = await send('ui_test_capture');
  const jpeg = await waitFor(async () => (await send('ui_test_image', { id })).jpeg);
  await writeFile(first, Buffer.from(jpeg, 'base64'), { flag: 'wx', mode: 0o600 });
  console.log(first);
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
