#!/usr/bin/env node
// Mo Venture (games/mo-venture) over monad's stub DOM and recording stub
// WebGL. Staged and run by scripts/web-smoke.sh:
//
//   node target/web/mo-venture/smoke/mo_venture_smoke.mjs target/web/mo-venture/app.wasm [webgl2|webgl1|none]
//
// It reads the game through its HUD (`data-hud-*` on the canvas: sparks,
// time, falls, message, and Mo's position as "x y z"). Checks, in order:
//   - mount and setup: two programs, three meshes; the HUD appears;
//   - idle: Mo stands still on the start island;
//   - keys: holding W runs Mo into the level (-z); Space jumps and lands;
//   - autopilot: P hands Mo to the route bot, which climbs the stairs and
//     collects sparks without falling;
//   - context loss: a lost frame draws nothing; restore draws again.
//
// The run is kept to about 240 frames: monad's web target has no GC yet
// (PLAN.md gap G13), and the game allocates about 11 MB per frame, so a
// longer run exhausts the 4 GB wasm heap. The whole level is played by the
// native tests (games/mo-venture/src/tests/game_tests.mo) instead.

import { readFile } from 'node:fs/promises';
import { imports } from '../web.js';
import { host } from '../web_runtime.js';
import { installDocument, body, fail } from './stub_dom.mjs';
import { installGl, glStub } from './stub_gl.mjs';

const path = process.argv[2];
const mode = process.argv[3] || 'webgl2';
if (!path) {
  console.error('usage: node mo_venture_smoke.mjs <app.wasm> [webgl2|webgl1|none]');
  process.exit(2);
}

installDocument();
installGl({ dpr: 1, clientWidth: 640, clientHeight: 360 });
glStub.mode = mode;

function byId(id) {
  const walk = (n) => {
    if (n.attrs && n.attrs.id === id) return n;
    for (const c of n.childNodes || []) {
      const found = walk(c);
      if (found) return found;
    }
    return null;
  };
  return walk(body);
}

const bytes = await readFile(path);
const { instance } = await WebAssembly.instantiate(bytes, imports);
host.bind(instance);
host.set_root('#app');
instance.exports.oak_mount();

const canvas = byId('forge');
if (!canvas || canvas.tagName !== 'CANVAS') fail('mount did not create <canvas id="forge">');

if (mode === 'none') {
  const status = byId('forge-status');
  if (!status || !status.textContent.includes('no WebGL context')) {
    fail(`no-WebGL status: ${JSON.stringify(status && status.textContent)}`);
  }
  console.log(`ok: ${path} [none] -> the missing context is reported`);
  process.exit(0);
}

const gl = glStub.contexts[0];
const count = (calls, name) => calls.filter((c) => c[0] === name).length;
if (count(gl.calls, 'linkProgram') !== 2) fail(`setup linked ${count(gl.calls, 'linkProgram')} programs`);
if (count(gl.calls, 'bufferData') !== 6) fail(`setup made ${count(gl.calls, 'bufferData')} bufferData calls, want 6 (3 meshes)`);

let pending = null;
globalThis.requestAnimationFrame = (cb) => { pending = cb; };
host.start_ticks(instance);
let now = 1000;
function frame() {
  if (typeof pending !== 'function') fail('the frame loop is not scheduled');
  const cb = pending;
  pending = null;
  const before = gl.calls.length;
  cb(now);
  now += 16;
  return gl.calls.slice(before);
}
function frames(n) { for (let i = 0; i < n; i++) frame(); }
const hud = (k) => canvas.attrs['data-hud-' + k];
const pos = () => (hud('pos') || '').split(' ').map(Number);

// ── mount ──
const f1 = frame();
if (count(f1, 'drawElements') < 40) fail(`frame 1 drew ${count(f1, 'drawElements')} meshes, want the whole level`);
if (hud('sparks') !== '0/20') fail(`HUD sparks ${JSON.stringify(hud('sparks'))}, want "0/20"`);

// ── idle ──
frames(20);
const [x0, y0, z0] = pos();
if (!(Math.abs(z0 - 1.5) < 0.05 && Math.abs(y0 - 0.71) < 0.05)) fail(`idle Mo at ${hud('pos')}, want about 0 0.71 1.5`);

// ── keys ──
window.fire('keydown', { code: 'KeyW', key: 'w' });
frames(25);
window.fire('keyup', { code: 'KeyW', key: 'w' });
frames(15);
const [, , z1] = pos();
if (!(z1 < z0 - 2.0)) fail(`holding W moved Mo from z ${z0} to ${z1}, want at least 2 units into the level`);

const jump = window.fire('keydown', { code: 'Space', key: ' ' });
if (!jump.defaultPrevented) fail('Space did not have its default (scroll) prevented');
frames(12);
const [, yUp] = pos();
window.fire('keyup', { code: 'Space', key: ' ' });
frames(40);
const [, yDown] = pos();
if (!(yUp > y0 + 0.8)) fail(`Space lifted Mo only to y ${yUp}`);
if (!(Math.abs(yDown - y0) < 0.05)) fail(`after the jump Mo is at y ${yDown}, want back on the ground`);

// ── autopilot ──
const sparksBefore = Number((hud('sparks') || '0/').split('/')[0]);
window.fire('keydown', { code: 'KeyP', key: 'p' });
frame();
window.fire('keyup', { code: 'KeyP', key: 'p' });
frames(110);
const [, yBot, zBot] = pos();
const sparksAfter = Number((hud('sparks') || '0/').split('/')[0]);
if (!(zBot < -6 && yBot > 1.8)) fail(`the autopilot did not climb the stairs (at ${hud('pos')})`);
if (!(sparksAfter >= sparksBefore + 3)) fail(`the autopilot collected ${sparksAfter - sparksBefore} sparks`);
if (hud('falls') !== '0') fail(`the autopilot fell ${hud('falls')} times`);

// ── context loss and restore ──
glStub.lost = true;
if (count(frame(), 'drawElements') !== 0) fail('a lost context was drawn to');
glStub.lost = false;
const back = frame();
if (count(back, 'linkProgram') !== 2 || count(back, 'drawElements') < 30) fail('the restored context did not draw the level');

console.log(`ok: ${path} [${mode}] -> setup, HUD, idle, run, jump, autopilot up the stairs (sparks ${hud('sparks')}), loss + restore`);
