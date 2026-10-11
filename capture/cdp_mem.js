// cdp_mem.js <port> <seconds> : record Chrome's memory-infra dumps over DevTools and print how each allocator grows.
const MB = 1048576;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Opens the browser-level DevTools socket; send() resolves with the command's result, onEvent gets the rest.
async function connect(port, onEvent) {
  let version = null;
  for (let i = 0; i < 40 && !version; i++) {
    try { version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch (e) { await sleep(500); }
  }
  if (!version) throw new Error('DevTools port never answered');
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  const pending = new Map();
  let id = 0;
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) {
      const p = pending.get(d.id);
      pending.delete(d.id);
      d.error ? p.rej(new Error(JSON.stringify(d.error))) : p.res(d.result);
    } else onEvent(d);
  };
  await new Promise((r) => (ws.onopen = r));
  const send = (method, params = {}) => new Promise((res, rej) => {
    const i = ++id;
    pending.set(i, { res, rej });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  return { send, close: () => ws.close() };
}

// Records memory-infra for `secs` seconds with a dump every 3 s; returns the trace events and the number of dumps asked for.
async function recordMemoryDumps(port, secs) {
  const events = [];
  let complete = false;
  const cdp = await connect(port, (d) => {
    if (d.method === 'Tracing.dataCollected') events.push(...d.params.value);
    else if (d.method === 'Tracing.tracingComplete') complete = true;
  });
  await cdp.send('Tracing.start', { traceConfig: { recordMode: 'recordUntilFull', includedCategories: ['-*', 'disabled-by-default-memory-infra'] }, transferMode: 'ReportEvents' });
  const t0 = Date.now();
  let requests = 0;
  while ((Date.now() - t0) / 1000 < secs) {
    await sleep(3000);
    try { await cdp.send('Tracing.requestMemoryDump', { deterministic: true, levelOfDetail: 'detailed' }); requests++; } catch (e) { console.log('dump request failed: ' + e.message); }
  }
  await cdp.send('Tracing.end');
  for (let i = 0; i < 60 && !complete; i++) await sleep(250);
  cdp.close();
  return { events, requests };
}

function sizeOf(allocator) {
  const s = allocator && allocator.attrs && (allocator.attrs.effective_size || allocator.attrs.size);
  return s && s.value ? parseInt(s.value, 16) : 0;
}

// Groups the memory-dump events by process; only the GPU process has gpu/shared_images allocators.
function groupByProcess(events) {
  const dumps = events.filter((e) => e.ph === 'v' && e.args && e.args.dumps && e.args.dumps.allocators);
  const byPid = new Map();
  for (const e of dumps) {
    const allocators = e.args.dumps.allocators;
    if (!byPid.has(e.pid)) byPid.set(e.pid, { gpu: false, snaps: [] });
    const rec = byPid.get(e.pid);
    rec.gpu = rec.gpu || Object.keys(allocators).some((k) => k.startsWith('gpu/shared_images'));
    rec.snaps.push({ ts: e.ts, a: allocators });
  }
  return { dumps, byPid };
}

// Top-level (at most two path segments) allocator totals of one snapshot that are larger than 1 MB and start with gpu.
function gpuTotals(snap) {
  return Object.entries(snap.a)
    .filter(([name]) => name.split('/').length <= 2 && name.startsWith('gpu'))
    .map(([name, allocator]) => [name, sizeOf(allocator)])
    .filter(([, size]) => size > MB)
    .map(([name, size]) => `${name}=${(size / MB).toFixed(0)}`)
    .join('  ');
}

function printGpuProcess(pid, rec) {
  rec.snaps.sort((x, y) => x.ts - y.ts);
  const first = rec.snaps[0];
  const last = rec.snaps[rec.snaps.length - 1];
  console.log(`\n== GPU process pid ${pid}: ${rec.snaps.length} dumps over ${((last.ts - first.ts) / 1e6).toFixed(1)} s`);
  const rows = [];
  for (const name of new Set([...Object.keys(first.a), ...Object.keys(last.a)])) {
    const s0 = sizeOf(first.a[name]);
    const s1 = sizeOf(last.a[name]);
    if (s1 !== s0) rows.push({ name, s0, s1, d: s1 - s0 });
  }
  rows.sort((x, y) => y.d - x.d);
  console.log('top growing allocators (MB first -> last, delta):');
  for (const r of rows.slice(0, 18)) {
    console.log(`  ${(r.s0 / MB).toFixed(0).padStart(6)} -> ${(r.s1 / MB).toFixed(0).padStart(6)}  ${(r.d / MB).toFixed(0).padStart(6)}   ${r.name}`);
  }
  console.log('timeline of all gpu/* top-level totals (MB):');
  for (const s of rec.snaps) console.log(`  t=${((s.ts - first.ts) / 1e6).toFixed(1)}s  ${gpuTotals(s)}`);
}

function printReport(events, requests) {
  const { dumps, byPid } = groupByProcess(events);
  console.log(`dump requests: ${requests}, trace events: ${events.length}, memory-dump events: ${dumps.length}, processes with dumps: ${byPid.size}`);
  for (const [pid, rec] of byPid) if (rec.gpu && rec.snaps.length >= 2) printGpuProcess(pid, rec);
}

const [port, secs] = process.argv.slice(2);
if (!port || !secs) { console.log('usage: node cdp_mem.js <port> <seconds>'); process.exit(1); }
recordMemoryDumps(port, +secs)
  .then(({ events, requests }) => { printReport(events, requests); process.exit(0); })
  .catch((e) => { console.log('cdp_mem failed: ' + e.message); process.exit(1); });
