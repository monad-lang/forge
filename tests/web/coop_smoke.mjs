#!/usr/bin/env node
// Mo Venture co-op (2-player) over the same stub DOM, recording stub WebGL and
// a scripted broker that the existing smoke uses. Staged and run by
// scripts/web-smoke.sh:
//
//   node tests/web/coop_smoke.mjs <app.wasm>
//
// The broker is faked at the two places the page touches it:
//   - `fetch("/api/ws-ticket")` answers `{"ticket":"tkt1","path":"/api/ws/tkt1"}`;
//   - `WebSocket` is a class that records what the page sends and lets this
//     script push frames back.
//
// What it checks, in order:
//   - solo by default: the co-op panel offers Host, and no socket is opened;
//   - Host asks for a ticket, then opens one socket at the ticket's path with
//     the `forge-coop-1` subprotocol;
//   - on open the page sends `hello` first;
//   - a `welcome` as host shows the room code and starts `state` frames at
//     every 4th frame, with integer coordinates inside the wire's bound;
//   - a guest `intent` moves the companion (the discriminator against the
//     follow AI, which would move it toward the player);
//   - `left` ends the session, shows the reason, and stops sending.

import { readFile } from 'node:fs/promises';
import { imports } from '../web.js';
import { host } from '../web_runtime.js';
import { installDocument, body, fail, stub } from './stub_dom.mjs';
import { installGl, glStub } from './stub_gl.mjs';

const path = process.argv[2];
if (!path) {
  console.error('usage: node coop_smoke.mjs <app.wasm>');
  process.exit(2);
}

// ── The scripted broker ─────────────────────────────────────────────

/// The page's origin: what `location.origin` answers in a browser, and what
/// the ticket's path is resolved against.
const ORIGIN = 'http://127.0.0.1:8080';

const broker = { sockets: [], tickets: 0 };

class FakeSocket {
  constructor(url, protocols) {
    this.url = url;
    this.protocols = Array.isArray(protocols) ? protocols : [protocols];
    this.readyState = 0;
    this.sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
    broker.sockets.push(this);
  }

  send(data) {
    this.sent.push(String(data));
  }

  close() {
    this.readyState = 3;
    if (this.onclose) this.onclose({ code: 1000, reason: '', wasClean: true });
  }

  // The script's side of the wire.
  open() {
    this.readyState = 1;
    if (this.onopen) this.onopen({ protocol: 'forge-coop-1' });
  }

  deliver(text) {
    if (this.onmessage) this.onmessage({ data: text });
  }
}

globalThis.WebSocket = FakeSocket;

// `web_runtime.mjs`'s own `beginFetch` calls `globalThis.fetch` and reads the
// body with `arrayBuffer()`, so the stub answers in exactly that shape. The
// page's only fetch is the ticket.
const encoder = new TextEncoder();
globalThis.fetch = async (url) => {
  if (!String(url).endsWith('/api/ws-ticket')) fail(`unexpected fetch: ${url}`);
  broker.tickets += 1;
  const body = encoder.encode(
    JSON.stringify({ ticket: 'tkt1', expires_ms: 999999, path: '/api/ws/tkt1' }));
  return {
    ok: true,
    status: 200,
    headers: { forEach: () => {} },
    arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength),
  };
};

installDocument();
// The page reads `location.origin` to build both the ticket URL and the socket
// URL (the broker answers with a path). The shared stub models `location`
// without an `origin`, so the harness supplies the one a browser always has.
globalThis.location.origin = ORIGIN;
installGl({ dpr: 1, clientWidth: 640, clientHeight: 360 });
glStub.mode = 'webgl2';

// ── Page helpers (the same shape the existing smoke uses) ───────────

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

function nodeText(id) {
  const n = byId(id);
  return n ? n.textContent.trim() : undefined;
}

function hidden(id) {
  const n = byId(id);
  return !n || (n.attrs?.class || []).includes('forge-hidden');
}

/// Click an element through the stub DOM's own event machinery (the existing
/// mo-venture smoke drives its touch buttons the same way).
function click(id) {
  const n = byId(id);
  if (!n) fail(`no #${id} to click`);
  n.fire('click', { button: 0 });
}

let pending = null;
globalThis.requestAnimationFrame = (cb) => { pending = cb; };
let now = 1000;
function frame() {
  if (typeof pending !== 'function') fail('the frame loop is not scheduled');
  const cb = pending;
  pending = null;
  cb(now);
  now += 16;
}
let oakTick = () => {};
const frames = (n) => framesTick(n);

/// One frame plus one tick: the frame lowers the view, the tick folds the
/// queued messages and runs their effects (oak clears the queue as a batch
/// starts, so an effect's own message needs the NEXT tick).
function framesTick(n) {
  for (let i = 0; i < n; i += 1) { frame(); oakTick(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, what, limitMs = 3000) {
  const start = Date.now();
  while (Date.now() - start < limitMs) {
    await sleep(5);
    if (predicate()) return;
  }
  fail(`timed out waiting for ${what}`);
}

/// Frames until `predicate`, so a page that needs a frame or two settles.
async function framesUntil(predicate, what, limit = 40) {
  for (let i = 0; i < limit; i += 1) {
    if (predicate()) return;
    frame();
    oakTick();
    await sleep(1);
  }
  if (!predicate()) fail(`timed out (${limit} frames) waiting for ${what}`);
}

const stateFrames = (sock) =>
  sock.sent.map((t) => { try { return JSON.parse(t); } catch { return { t: '?' }; } })
    .filter((m) => m.t === 'state');

// ── The run ─────────────────────────────────────────────────────────

const bytes = await readFile(path);
const { instance } = await WebAssembly.instantiate(bytes, imports);
host.bind(instance);
host.set_root('#app');
instance.exports.oak_mount();
oakTick = () => instance.exports.oak_tick();
host.start_ticks(instance);
framesTick(2);

// 1. Solo: the panel offers Host, and no socket exists.
if (hidden('coop')) fail('the co-op panel is not on the page');
if (!byId('coop-host')) fail('the solo panel has no Host button');
if (broker.sockets.length !== 0) fail(`a solo page opened ${broker.sockets.length} socket(s)`);
console.log('ok solo: Host offered, no socket opened');

// 2. Host: one ticket, then one socket at the ticket's path. Each effect's
//    message lands on the NEXT frame (oak clears the queue as the batch
//    runs), so the ticket and then the socket need a frame each.
click('coop-host');
await framesUntil(() => broker.tickets >= 1, 'the ticket request', 60);
await framesUntil(() => broker.sockets.length === 1, 'the socket to open', 60);
const sock = broker.sockets[0];
if (sock.url !== 'ws://127.0.0.1:8080/api/ws/tkt1') {
  fail(`socket url "${sock.url}" is not the ticket path on this origin`);
}
if (!sock.protocols.includes('forge-coop-1')) {
  fail(`socket protocols ${JSON.stringify(sock.protocols)} lack forge-coop-1`);
}
console.log(`ok host: one socket at ${sock.url} asking for forge-coop-1`);

// 3. On open, `hello` is the first frame (`web_wasm` opens asynchronously).
sock.open();
await framesUntil(() => sock.sent.length >= 1, 'the hello frame', 60);
let first;
try { first = JSON.parse(sock.sent[0]); } catch { first = null; }
if (!first || first.t !== 'hello') fail(`first frame was ${JSON.stringify(sock.sent[0])}`);
if (first.v !== 1) fail(`hello carries version ${String(first.v)}, not 1`);
console.log('ok hello: the first frame is hello v1');

// 3b. Right after `hello`, a HOST must ask the relay to open a room. Without
//     `create` the relay leaves the connection idle and the host never gets a
//     code -- the failure this check exists for, since the scripted broker
//     below plays `welcome` by hand either way.
await framesUntil(() => sock.sent.length >= 2, 'the create frame', 60);
let second;
try { second = JSON.parse(sock.sent[1]); } catch { second = null; }
if (!second || second.t !== 'create') fail(`after hello a host sent ${JSON.stringify(sock.sent[1])}, want create`);
console.log('ok create: a host opens a room after hello');

// 4. Welcome as host: the code shows, and state frames start.
sock.deliver(JSON.stringify({ t: 'welcome', code: 'ab3d', role: 'host', peer: '' }));
await framesUntil(() => !hidden('coop-code') && (nodeText('coop-code') || '').includes('ab3d'),
  'the room code to show');

const before = sock.sent.length;
frames(9);
const states = stateFrames(sock).slice(0);
const sentStates = sock.sent.slice(before)
  .map((t) => { try { return JSON.parse(t); } catch { return { t: '?' }; } })
  .filter((m) => m.t === 'state');
if (sentStates.length === 0) fail('a host sent no state frames in 9 frames');
if (sentStates.length > 4) fail(`a host sent ${sentStates.length} state frames in 9, want ~2`);
const st = sentStates[0];
for (const k of ['level', 'sparks', 'total', 'falls', 'time']) {
  if (!Number.isInteger(st[k])) fail(`state.${k}=${JSON.stringify(st[k])} is not an integer`);
}
for (const k of ['px', 'py', 'pz', 'cx', 'cy', 'cz']) {
  if (typeof st[k] !== 'number') fail(`state.${k} missing`);
  if (Math.abs(st[k]) > 1000000) fail(`state.${k}=${st[k]} is outside the wire's bound`);
}
console.log(`ok host state: ${JSON.stringify(st)}`);

// 5. A guest intent drives the companion. Compare the companion's pose before
// and after 40 frames of "run +x": the follow AI would pull it toward the
// player instead, so a large +x move is the discriminator.
const lastCompanion = (list) => ({ x: list[list.length - 1].cx, z: list[list.length - 1].cz });
const standing = lastCompanion(stateFrames(sock));
sock.deliver(JSON.stringify({
  t: 'intent', mx: 1000, mz: 0, jp: false, jh: false, dp: false, sp: false, ab: false, sw: false,
}));
frames(40);
const after = stateFrames(sock);
const moved = lastCompanion(after);
if (Math.abs(moved.x - standing.x) < 1 && Math.abs(moved.z - standing.z) < 1) {
  fail(`the companion did not move on a guest intent (${JSON.stringify(standing)} -> ${JSON.stringify(moved)})`);
}
console.log(`ok guest intent: companion ${JSON.stringify(standing)} -> ${JSON.stringify(moved)}`);

// 6. `left` ends the session: the reason shows and sending stops.
sock.deliver(JSON.stringify({ t: 'left', reason: 'the guest left' }));
await framesUntil(() => (nodeText('coop-notice') || '').includes('the guest left'),
  'the left reason to show');
const beforeLeft = sock.sent.length;
frames(8);
const afterLeft = sock.sent.slice(beforeLeft)
  .map((t) => { try { return JSON.parse(t); } catch { return { t: '?' }; } })
  .filter((m) => m.t === 'state');
if (afterLeft.length !== 0) {
  fail(`the host kept sending ${afterLeft.length} state frames after the session ended`);
}
console.log('ok left: session ended, showing the reason, sending stopped');

console.log('coop smoke: all checks passed');
