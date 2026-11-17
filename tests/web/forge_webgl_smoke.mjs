#!/usr/bin/env node
// The forge web demo (motes/forge-app/src/main.mo) over monad's stub DOM and
// recording stub WebGL. Staged and run by scripts/web-smoke.sh:
//
//   node target/web/smoke/forge_webgl_smoke.mjs target/web/app.wasm [webgl2|webgl1|none]
//
// It drives the REAL loader host (`web_runtime.js`), so forge-webgl's GL
// calls, web_wasm's externs and the JS host are checked against each other.
// Checks, in order:
//   - mount: a <canvas id="forge"> exists; with no WebGL the failure is
//     reported on the page and nothing else happens;
//   - setup: two programs link, four meshes upload (vertex floats = 5 per
//     vertex, 32-bit indices);
//   - a frame: the frame plan's 4 draws become exactly 4 drawElements, with
//     each mesh's index count, after viewport + clear; the floor texture is
//     still loading, so every draw uses the flat program;
//   - the floor image arrives: it is uploaded once and the floor draw binds it;
//   - picking: a click at the centre picks an entity, the empty top-left
//     corner picks nothing (`data-picked`);
//   - input: holding KeyD (a `window` keydown) moves the root cube along
//     the camera's right by speed * dt in the next frame; after keyup it
//     stays put; Space's default (page scroll) is prevented;
//   - orbit camera: an idle frame repeats exactly; a right-drag and the
//     wheel each change the view; the canvas suppresses its context menu;
//   - context loss: a lost frame draws nothing; the frame after restore
//     relinks both programs, re-uploads all meshes, and draws again.

import { readFile } from 'node:fs/promises';
import { imports } from '../web.js';
import { host } from '../web_runtime.js';
import { installDocument, body, fail } from './stub_dom.mjs';
import { installGl, glStub, finishImages } from './stub_gl.mjs';

const path = process.argv[2];
const mode = process.argv[3] || 'webgl2';
if (!path) {
  console.error('usage: node forge_webgl_smoke.mjs <app.wasm> [webgl2|webgl1|none]');
  process.exit(2);
}

installDocument();
installGl({ dpr: 1, clientWidth: 400, clientHeight: 300 });
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

if (glStub.contexts.length !== 1) fail(`expected one context, got ${glStub.contexts.length}`);
const gl = glStub.contexts[0];
const names = (calls) => calls.map((c) => c[0]);
const count = (calls, name) => calls.filter((c) => c[0] === name).length;

// ── setup ──
{
  const setup = gl.calls;
  if (count(setup, 'linkProgram') !== 2) fail(`setup linked ${count(setup, 'linkProgram')} programs`);
  const uploads = setup.filter((c) => c[0] === 'bufferData');
  if (uploads.length !== 8) fail(`setup made ${uploads.length} bufferData calls, want 8 (4 meshes)`);
  const vertexFloats = uploads.filter((c) => c[1] === 0x8892).map((c) => c[2].length).sort((a, b) => a - b);
  // quad 4, box 24, cube 24, cylinder 4*24+4 = 100 vertices; 5 floats each.
  const want = [20, 120, 120, 500];
  if (JSON.stringify(vertexFloats) !== JSON.stringify(want)) {
    fail(`vertex upload sizes ${JSON.stringify(vertexFloats)}, want ${JSON.stringify(want)}`);
  }
  if (count(setup, 'createTexture') !== 1) fail('the floor texture was not created');
}

// ── the frame loop ──
let pending = null;
globalThis.requestAnimationFrame = (cb) => { pending = cb; };
host.start_ticks(instance);
function frame(ts) {
  if (typeof pending !== 'function') fail('the frame loop is not scheduled');
  const cb = pending;
  pending = null;
  const before = gl.calls.length;
  cb(ts);
  return gl.calls.slice(before);
}

const indexCounts = (calls) =>
  calls.filter((c) => c[0] === 'drawElements').map((c) => c[2]).sort((a, b) => a - b);
// quad 6, small box 36, cube 36, cylinder (2n + 2n triangles) * 3 = 288.
const wantCounts = JSON.stringify([6, 36, 36, 288]);

const f1 = frame(1000);
{
  const n = names(f1);
  if (count(f1, 'drawElements') !== 4) fail(`frame 1 drew ${count(f1, 'drawElements')}, want 4`);
  if (JSON.stringify(indexCounts(f1)) !== wantCounts) fail(`frame 1 index counts ${JSON.stringify(indexCounts(f1))}`);
  const vp = n.indexOf('viewport');
  const cl = n.indexOf('clear');
  const firstDraw = n.indexOf('drawElements');
  if (!(vp >= 0 && vp < cl && cl < firstDraw)) fail(`frame 1 order: ${JSON.stringify(n)}`);
  if (count(f1, 'bindTexture') !== 0) fail('a texture was bound before its image loaded');
  // view + projection for each of the two programs, plus one model per draw.
  if (count(f1, 'uniformMatrix4fv') !== 8) fail(`frame 1 set ${count(f1, 'uniformMatrix4fv')} matrices, want 8`);
}

finishImages();
const f2 = frame(1016);
{
  const uploads = f2.filter((c) => c[0] === 'texImage2D');
  if (uploads.length !== 1 || uploads[0][uploads[0].length - 1] !== 'image:forge-floor.png') {
    fail(`the floor image upload: ${JSON.stringify(uploads)}`);
  }
  if (count(f2, 'drawElements') !== 4) fail(`frame 2 drew ${count(f2, 'drawElements')}, want 4`);
  if (count(f2, 'bindTexture') < 2) fail('the textured floor draw did not bind its texture');
}
const f3 = frame(1032);
if (count(f3, 'texImage2D') !== 0) fail('the floor image was uploaded twice');

// ── picking ──
canvas.fire('click', { offsetX: 200, offsetY: 150 });
const centre = canvas.attrs['data-picked'];
if (centre === undefined || Number(centre) < 0) fail(`a centre click picked ${JSON.stringify(centre)}`);
canvas.fire('click', { offsetX: 1, offsetY: 1 });
if (canvas.attrs['data-picked'] !== '-1') fail(`an empty-corner click picked ${canvas.attrs['data-picked']}`);

// ── input ──
// The root cube sits at the origin with identity rotation about x/z, so its
// model matrix's translation is exactly the root's position.
const near = (a, b) => Math.abs(a - b) < 1e-5;
const rootAt = (calls, x, z) =>
  calls.some((c) => c[0] === 'uniformMatrix4fv' && near(c[3][12], x) && near(c[3][13], 0) && near(c[3][14], z));
// The demo's orbit starts at yaw 0.4636; the camera's right is (cos, 0, -sin).
const yaw = 0.4636;
const movedX = 0.625 * Math.cos(yaw);
const movedZ = -0.625 * Math.sin(yaw);
const f4 = frame(1048);
if (!rootAt(f4, 0, 0)) fail('before input: no model matrix at the origin');
window.fire('keydown', { code: 'KeyD', key: 'd' });
// dt clamps to 0.25 s; the demo moves 2.5 units/s.
const f5 = frame(1298);
if (!rootAt(f5, movedX, movedZ)) fail('holding KeyD did not move the root cube along the camera right');
window.fire('keyup', { code: 'KeyD', key: 'd' });
const f6 = frame(1548);
if (!rootAt(f6, movedX, movedZ)) fail('after keyup the root cube kept moving');

// Orbit camera. Frames at the same timestamp have dt = 0, so nothing but
// the camera can change the matrices.
const mats = (calls) => JSON.stringify(calls.filter((c) => c[0] === 'uniformMatrix4fv').map((c) => c[3]));
const idleA = mats(frame(1548));
const idleB = mats(frame(1548));
if (idleA !== idleB) fail('an idle frame changed the matrices');
canvas.fire('pointermove', { offsetX: 100, offsetY: 100, pointerType: 'mouse' });
canvas.fire('pointerdown', { offsetX: 100, offsetY: 100, button: 2, buttons: 2, pointerType: 'mouse' });
canvas.fire('pointermove', { offsetX: 200, offsetY: 100, buttons: 2, pointerType: 'mouse' });
const dragged = mats(frame(1548));
if (dragged === idleB) fail('a right-drag did not move the camera');
canvas.fire('pointerup', { offsetX: 200, offsetY: 100, button: 2, buttons: 0, pointerType: 'mouse' });
const still = mats(frame(1548));
if (still !== dragged) fail('the camera kept moving after the drag ended');
canvas.fire('wheel', { deltaY: 100, deltaMode: 0 });
if (mats(frame(1548)) === still) fail('the wheel did not zoom');
const menu = canvas.fire('contextmenu', { button: 2 });
if (!menu.defaultPrevented) fail('the canvas context menu was not suppressed');
const space = window.fire('keydown', { code: 'Space', key: ' ' });
if (!space.defaultPrevented) fail('Space did not have its default (scroll) prevented');
window.fire('keyup', { code: 'Space', key: ' ' });
canvas.fire('pointermove', { offsetX: 10, offsetY: 10, pointerType: 'mouse' });
canvas.fire('pointerdown', { offsetX: 12, offsetY: 10, button: 0, buttons: 1, pointerType: 'mouse' });
canvas.fire('pointerup', { offsetX: 12, offsetY: 10, button: 0, buttons: 0, pointerType: 'mouse' });
canvas.fire('wheel', { deltaY: 3, deltaMode: 1 });
canvas.fire('pointerleave', { offsetX: 0, offsetY: 0, pointerType: 'mouse' });
window.fire('blur', {});
const f7 = frame(1564);
if (count(f7, 'drawElements') !== 4) fail(`the frame after input events drew ${count(f7, 'drawElements')}`);

// ── context loss and restore ──
glStub.lost = true;
const lostFrame = frame(1580);
if (count(lostFrame, 'drawElements') !== 0) fail('a lost context was drawn to');
glStub.lost = false;
const back = frame(1596);
if (count(back, 'linkProgram') !== 2) fail(`restore relinked ${count(back, 'linkProgram')} programs, want 2`);
if (count(back, 'bufferData') !== 8) fail(`restore re-uploaded ${count(back, 'bufferData')} buffers, want 8`);
if (count(back, 'drawElements') !== 4) fail(`the restored frame drew ${count(back, 'drawElements')}, want 4`);

console.log(`ok: ${path} [${mode}] -> setup, 4 draws/frame, texture upload, picking (centre=${centre}), keyboard move, orbit camera, loss + restore`);
