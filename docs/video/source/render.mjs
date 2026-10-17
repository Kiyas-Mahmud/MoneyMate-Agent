// Renders index.html frame by frame through Chrome DevTools Protocol (Node's built-in WebSocket) into ffmpeg.
//   node render.mjs stills 2,12.5,22.8 out/      -> PNG stills at those times
//   node render.mjs video out.mp4 [fps] [from] [to]
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import path from 'node:path';

const [mode, arg, out, fpsArg, fromArg, toArg] = process.argv.slice(2);
const DIR = path.dirname(new URL(import.meta.url).pathname);
const PORT = 9333 + Math.floor(Math.random() * 500);

const chrome = spawn('google-chrome', ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-sandbox',
  '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080', '--disable-gpu-vsync',
  `--user-data-dir=${DIR}/.chrome`, 'about:blank'], { stdio: 'ignore' });

let target;
for (let i = 0; i < 50 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find(t => t.type === 'page'); }
  catch { await sleep(200); }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, m => m.error ? rej(new Error(m.error.message)) : res(m.result)); ws.send(JSON.stringify({ id: i, method, params })); });

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send('Page.enable');
await send('Page.navigate', { url: `file://${DIR}/index.html` });
await sleep(800);
await send('Runtime.evaluate', { expression: 'window.ready', awaitPromise: true });
await sleep(500);

async function frame(t, format = 'png') {
  await send('Runtime.evaluate', { expression: `render(${t})` });
  const r = await send('Page.captureScreenshot', { format, quality: format === 'jpeg' ? 95 : undefined, optimizeForSpeed: true });
  return Buffer.from(r.data, 'base64');
}

if (mode === 'stills') {
  mkdirSync(out, { recursive: true });
  for (const t of arg.split(',').map(Number)) {
    await frame(t); // warm-up so blur layers settle
    writeFileSync(path.join(out, `t${t.toFixed(2).padStart(6, '0')}.png`), await frame(t));
  }
} else {
  const fps = Number(out || 60), from = Number(fpsArg || 0), to = Number(fromArg || 60);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '14', '-pix_fmt', 'yuv420p', '-tune', 'animation',
    '-movflags', '+faststart', '-r', String(fps), arg], { stdio: ['pipe', 'inherit', 'inherit'] });
  const n = Math.round((to - from) * fps);
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    const buf = await frame(from + i / fps);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 300 === 0) console.log(`frame ${i}/${n}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log(`done ${n} frames in ${((Date.now() - t0) / 1000).toFixed(0)}s -> ${arg}`);
}
ws.close(); chrome.kill();
