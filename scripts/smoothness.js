// Measures how smoothly a page scrolls, for comparing auto-scroll engines.
// Used by smoothness.html, or pasted into the browser console to measure any page.
// Start auto-scroll over the page, hold the pointer still at the speed you want to
// test, then stop. A run ends 1 s after the last wheel event.
// Per run: the wheel events the page received and its scroll position at every frame.
(() => {
  if (window.__scrollSmoothness) return;
  window.__scrollSmoothness = true;

  // The panel lives in a shadow root, so the page's styles do not reach it
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `
<style>
  :host { --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --accent: #0a84ff; --panel: rgba(255,255,255,.96); }
  @media (prefers-color-scheme: dark) {
    :host { --fg: #f5f5f7; --muted: #98989d; --line: #3a3a3c; --panel: rgba(28,28,30,.96); }
  }
  #panel { width: min(560px, calc(100vw - 24px)); max-height: calc(100vh - 24px); overflow: auto; color: var(--fg);
           background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px; box-sizing: border-box;
           font: 13px -apple-system, system-ui, sans-serif; text-align: left; }
  h1 { font-size: 15px; margin: 0 0 6px; }
  p { margin: 4px 0; color: var(--muted); }
  #status { font-weight: 600; color: var(--fg); }
  label, button, input { font: inherit; }
  input { width: 140px; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px; font-variant-numeric: tabular-nums; }
  th, td { text-align: right; padding: 3px 5px; border-bottom: 1px solid var(--line); white-space: nowrap; font-size: 12px; }
  th:first-child, td:first-child { text-align: left; }
  canvas { width: 100%; height: 90px; margin-top: 8px; border: 1px solid var(--line); border-radius: 6px; }
</style>
<div id="panel">
  <h1>Scroll Smoothness</h1>
  <p>Start auto-scroll over the page, hold the pointer still, stop after a few seconds.</p>
  <p><label>Label <input id="label" placeholder="run number"></label>
     <button id="copy">Copy CSV</button> <button id="clear">Clear</button>
     <button id="top">Back to top</button></p>
  <p id="status">Waiting for scrolling…</p>
  <canvas id="chart" width="1080" height="180"></canvas>
  <table><thead><tr>
    <th>label</th><th>px/s</th><th>fps</th><th>moving<br>frames</th><th>longest<br>stall ms</th>
    <th>jitter<br>px</th><th>step<br>CV</th><th>wheel/s</th><th>wheel Δ<br>min–max</th><th>fractional<br>Δ</th>
  </tr></thead><tbody></tbody></table>
</div>`;
  document.body.appendChild(host);
  const $ = id => root.getElementById(id);
  const tbody = root.querySelector('tbody');

  const runs = [];
  let frames = null, wheels = null, lastWheel = 0, scroller = null;

  // The element the wheel scrolls: the nearest scrollable ancestor, else the page
  function scrollerFor(target) {
    for (let el = target; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
      const overflow = getComputedStyle(el).overflowY;
      if ((overflow === 'auto' || overflow === 'scroll') && el.scrollHeight > el.clientHeight) return el;
    }
    return document.scrollingElement || document.documentElement;
  }

  addEventListener('wheel', e => {
    if (host.contains(e.target)) return;
    if (!frames) { frames = []; wheels = []; scroller = scrollerFor(e.target); requestAnimationFrame(frame); }
    wheels.push({ t: e.timeStamp, dy: e.deltaY });
    lastWheel = performance.now();
    $('status').textContent = 'Recording…';
  }, { passive: true, capture: true });

  function frame(t) {
    if (!frames) return;
    frames.push({ t, y: scroller.scrollTop });
    if (performance.now() - lastWheel > 1000) return finish();
    requestAnimationFrame(frame);
  }

  function finish() {
    // Frames from the first to the last wheel event, plus one for the last event to land
    const first = wheels[0].t, last = wheels[wheels.length - 1].t;
    const f = frames.filter(x => x.t >= first && x.t <= last + 50);
    const w = wheels;
    frames = null; wheels = null;
    if (f.length < 30) { $('status').textContent = 'Too short, try again.'; return; }

    const duration = (f[f.length - 1].t - f[0].t) / 1000;
    const steps = f.slice(1).map((x, i) => x.y - f[i].y);
    const speed = Math.abs(f[f.length - 1].y - f[0].y) / duration;

    // Longest run of frames without movement
    let stall = 0, run = 0;
    for (let i = 1; i < f.length; i++) {
      if (Math.abs(f[i].y - f[i - 1].y) < 0.01) { run += f[i].t - f[i - 1].t; stall = Math.max(stall, run); } else run = 0;
    }
    // Jitter: distance from a smooth path, the position averaged over ±100 ms
    let sq = 0, n = 0;
    for (let i = 0; i < f.length; i++) {
      if (f[i].t - f[0].t < 100 || f[f.length - 1].t - f[i].t < 100) continue;
      let sum = 0, k = 0;
      for (let j = i; j >= 0 && f[i].t - f[j].t <= 100; j--) { sum += f[j].y; k++; }
      for (let j = i + 1; j < f.length && f[j].t - f[i].t <= 100; j++) { sum += f[j].y; k++; }
      sq += (f[i].y - sum / k) ** 2; n++;
    }
    const mean = steps.reduce((a, b) => a + Math.abs(b), 0) / steps.length;
    const sd = Math.sqrt(steps.reduce((a, b) => a + (Math.abs(b) - mean) ** 2, 0) / steps.length);
    const deltas = w.map(x => Math.abs(x.dy)).filter(x => x > 0);

    const r = {
      label: ($('label').value || `run ${runs.length + 1}`).replace(/,/g, ' '),
      speed, fps: steps.length / duration,
      moving: steps.filter(s => Math.abs(s) >= 0.01).length / steps.length,
      stall, jitter: n ? Math.sqrt(sq / n) : 0, cv: mean ? sd / mean : 0,
      wheelRate: w.length / ((last - first) / 1000 || 1),
      dmin: deltas.length ? Math.min(...deltas) : 0, dmax: deltas.length ? Math.max(...deltas) : 0,
      fractional: deltas.filter(x => Math.abs(x - Math.round(x)) > 0.001).length / (deltas.length || 1),
      steps,
    };
    runs.push(r);
    render(r);
    $('status').textContent = `Done: ${f.length} frames, ${w.length} wheel events. Waiting for the next run…`;
  }

  function render(r) {
    const row = document.createElement('tr');
    [r.label, r.speed.toFixed(0), r.fps.toFixed(0), (r.moving * 100).toFixed(0) + '%', r.stall.toFixed(0),
     r.jitter.toFixed(2), r.cv.toFixed(2), r.wheelRate.toFixed(0),
     `${r.dmin.toFixed(2)}–${r.dmax.toFixed(2)}`, (r.fractional * 100).toFixed(0) + '%']
      .forEach(v => { const td = document.createElement('td'); td.textContent = v; row.appendChild(td); });
    tbody.appendChild(row);
    drawSteps(r.steps);
  }

  // Pixels moved at each frame of the last run: a smooth scroll is a flat band
  function drawSteps(steps) {
    const c = $('chart'), g = c.getContext('2d');
    const style = getComputedStyle($('panel'));
    g.clearRect(0, 0, c.width, c.height);
    const shown = steps.slice(0, c.width / 3), max = Math.max(1, ...shown.map(Math.abs));
    g.fillStyle = style.getPropertyValue('--accent');
    shown.forEach((s, i) => { const h = Math.abs(s) / max * (c.height - 20); g.fillRect(i * 3, c.height - h, 2, h); });
    g.fillStyle = style.getPropertyValue('--muted');
    g.font = '20px -apple-system, system-ui';
    g.fillText(`pixels per frame, max ${max.toFixed(2)}`, 6, 22);
  }

  $('copy').onclick = () => {
    const head = 'label,px_s,fps,moving_frames,longest_stall_ms,jitter_px,step_cv,wheel_s,wheel_delta_min,wheel_delta_max,fractional_delta';
    const lines = runs.map(r => [r.label, r.speed.toFixed(1), r.fps.toFixed(1), r.moving.toFixed(3), r.stall.toFixed(0),
      r.jitter.toFixed(3), r.cv.toFixed(3), r.wheelRate.toFixed(1), r.dmin.toFixed(3), r.dmax.toFixed(3), r.fractional.toFixed(3)].join(','));
    navigator.clipboard.writeText([head, ...lines].join('\n'));
  };
  $('clear').onclick = () => { runs.length = 0; tbody.innerHTML = ''; };
  $('top').onclick = () => (scroller || document.scrollingElement).scrollTo(0, 0);
})();
