import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { mkdir, mkdtemp, readdir, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const bundleName = 'Tab5Companion.app';
const binaryPath = 'Contents/MacOS/Tab5Companion';
const isSource = name => /\.(swift|c|h|plist)$/.test(name) || name === 'build.sh';

function run(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { stdio: 'inherit' });
    child.once('error', reject);
    child.once('close', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${executable} beendet (${signal ?? code})`));
    });
  });
}

async function exists(path) {
  try { return await stat(path); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

export function watchCompanion(directory, isReady, notify) {
  const root = fileURLToPath(directory);
  const buildDirectory = join(root, 'build');
  const app = join(buildDirectory, bundleName);
  let debounce;
  let busy = false;
  let pending = false;

  async function launch() {
    await run('/usr/bin/open', ['-g', app]);
    const until = Date.now() + 5500;
    while (Date.now() < until) {
      if (await isReady()) return;
      await delay(250);
    }
    throw new Error('Die Mac-App antwortet nicht auf Port 5174.');
  }

  async function rebuild() {
    await mkdir(buildDirectory, { recursive: true });
    const stage = await mkdtemp(join(buildDirectory, '.dev-'));
    const stagedApp = join(stage, bundleName);
    const backup = join(stage, 'previous.app');
    let hasBackup = false;
    try {
      await run('/bin/sh', [join(root, 'build.sh'), stagedApp]);
      if (pending) return;
      await run(join(stagedApp, binaryPath), ['--quit-running', app]);
      if (await exists(app)) {
        await rename(app, backup);
        hasBackup = true;
      }
      try {
        await rename(stagedApp, app);
        await launch();
      } catch (error) {
        if (hasBackup) {
          if (await exists(app)) {
            await run(join(app, binaryPath), ['--quit-running', app]);
            await rename(app, join(stage, 'failed.app'));
          }
          await rename(backup, app);
          hasBackup = false;
          await launch();
        }
        throw error;
      }
      hasBackup = false;
    } finally {
      if (hasBackup) console.error(`Vorherige Mac-App liegt unter ${backup}`);
      else await rm(stage, { recursive: true, force: true });
    }
  }

  async function refresh() {
    if (busy) return;
    busy = true;
    pending = false;
    let action = 'starten';
    try {
      const binary = await exists(join(app, binaryPath));
      const sources = (await readdir(root)).filter(isSource);
      const mtime = await Promise.all(sources.map(async name => (await exists(join(root, name)))?.mtimeMs ?? 0));
      if (!binary || mtime.some(date => date > binary.mtimeMs)) {
        action = 'neu bauen';
        notify('Mac-App wird gebaut …');
        await rebuild();
      } else if (!(await isReady())) {
        notify('Mac-App wird gestartet …');
        await launch();
      }
      if (!pending) {
        notify('');
        console.log('Pro Remote für die Vorschau bereit.');
      }
    } catch (error) {
      console.error(error.message);
      notify(`Mac-App konnte nicht ${action === 'starten' ? 'gestartet' : 'aktualisiert'} werden. Details im Vorschau-Terminal.`);
    } finally {
      busy = false;
      if (pending) schedule();
    }
  }

  function schedule() {
    pending = true;
    clearTimeout(debounce);
    debounce = setTimeout(refresh, 200);
  }

  const watcher = watch(directory, (_, name) => {
    if (name === null || isSource(name)) schedule();
  });
  watcher.on('error', error => {
    console.error(error.message);
    notify('Swift-Dateien konnten nicht überwacht werden. Details im Vorschau-Terminal.');
  });
  schedule();
}
