import { useEffect, useRef, useState } from "react";

// Three skill games. Each one reports a single number to finish_game; the server caps it by real elapsed time
// and works out the prize, so nothing here decides rewards.

const reduced = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
const isTyping = (e) => ["INPUT", "TEXTAREA", "SELECT"].includes(e.target?.tagName);

/* ---------------------------------------------------------------- Water Balance */
const ROUNDS = [
  { w: 0.30, s: 0.7 }, { w: 0.26, s: 0.8 }, { w: 0.22, s: 0.9 }, { w: 0.19, s: 1.0 },
  { w: 0.16, s: 1.1 }, { w: 0.14, s: 1.2 }, { w: 0.12, s: 1.3 }, { w: 0.10, s: 1.4 },
];
const pickZone = (r) => { const w = ROUNDS[r].w; return { w, c: w / 2 + Math.random() * (1 - w) }; };

export function WaterBalance({ onDone }) {
  const [round, setRound] = useState(0);
  const [landed, setLanded] = useState(0);
  const [pos, setPos] = useState(0);
  const [flash, setFlash] = useState(null);
  const [zone, setZone] = useState(() => pickZone(0));
  const live = useRef({ round: 0, landed: 0, zone, start: performance.now(), lock: false, pos: 0, sent: false }).current;

  useEffect(() => {
    let raf;
    const tick = (now) => {
      const p = (((now - live.start) / 1000) * ROUNDS[live.round].s + 0.35) % 2;
      live.pos = p < 1 ? p : 2 - p;
      setPos(live.pos);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [live]);

  function stop() {
    if (live.lock || live.sent) return;
    live.lock = true;
    const hit = Math.abs(live.pos - live.zone.c) <= live.zone.w / 2;
    if (hit) { live.landed += 1; setLanded(live.landed); }
    setFlash(hit ? "hit" : "miss");
    setTimeout(() => {
      if (live.round === ROUNDS.length - 1) { live.sent = true; onDone({ landed: live.landed }); return; }
      live.round += 1; live.zone = pickZone(live.round); live.start = performance.now(); live.lock = false;
      setRound(live.round); setZone(live.zone); setFlash(null);
    }, 650);
  }
  useEffect(() => {
    const onKey = (e) => { if ((e.key === " " || e.key === "Enter") && !isTyping(e)) { e.preventDefault(); stop(); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  return (
    <div>
      <p className="mute">Round {round + 1} of {ROUNDS.length} · landed {landed}</p>
      <div className={"gauge" + (flash ? " " + flash : "")} role="img" aria-label="Moving marker and green target zone">
        <div className="zone" style={{ left: `${(zone.c - zone.w / 2) * 100}%`, width: `${zone.w * 100}%` }} />
        <div className="marker2" style={{ left: `${pos * 100}%` }} />
      </div>
      <p role="status" className="mute" style={{ minHeight: "1.4em" }}>{flash === "hit" ? "Perfect pour!" : flash === "miss" ? "Missed the zone" : "Press Stop (or Space) when the marker is in the green."}</p>
      <button className="water bigbtn" onClick={stop} disabled={!!flash}>Stop</button>
    </div>
  );
}

/* ---------------------------------------------------------------- Vine Climb */
const VW = 300, VH = 440, VINE_SECONDS = 45;

export function VineClimb({ onDone }) {
  const ref = useRef(null);
  const ctl = useRef({ left: false, right: false, dragX: null }).current;
  const [hud, setHud] = useState({ drops: 0, lives: 3, left: VINE_SECONDS, over: false });

  useEffect(() => {
    const cv = ref.current, ctx = cv.getContext("2d");
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    cv.width = VW * dpr; cv.height = VH * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const s = { x: VW / 2, trail: [], items: [], t: 0, spawn: 0.5, drops: 0, lives: 3, inv: 0, over: false, scroll: 0, hudT: 0 };
    const headY = VH - 90;
    let raf, last = performance.now(), timer;
    const finish = () => { if (s.over) return; s.over = true; setHud({ drops: s.drops, lives: s.lives, left: Math.max(0, Math.ceil(VINE_SECONDS - s.t)), over: true }); timer = setTimeout(() => onDone({ drops: s.drops }), 900); };

    function step(dt) {
      s.t += dt;
      if (s.t >= VINE_SECONDS) { finish(); return; }
      const speed = 150 + 70 * (s.t / VINE_SECONDS);
      const dir = (ctl.right ? 1 : 0) - (ctl.left ? 1 : 0);
      if (ctl.dragX != null) { const d = ctl.dragX - s.x; s.x += Math.sign(d) * Math.min(Math.abs(d), 280 * dt); }
      else s.x += dir * 230 * dt;
      s.x = Math.max(18, Math.min(VW - 18, s.x));
      s.scroll = (s.scroll + speed * dt) % 60;
      for (const p of s.trail) p.y += speed * dt;
      s.trail.push({ x: s.x, y: headY });
      while (s.trail.length && s.trail[0].y > VH + 12) s.trail.shift();
      s.spawn -= dt;
      if (s.spawn <= 0) { s.items.push({ x: 24 + Math.random() * (VW - 48), y: -16, pest: Math.random() >= 0.7 }); s.spawn = 0.5 + Math.random() * 0.2; }
      s.inv = Math.max(0, s.inv - dt);
      for (const it of s.items) it.y += speed * dt;
      s.items = s.items.filter((it) => {
        if (it.y > VH + 20) return false;
        if (Math.hypot(it.x - s.x, it.y - headY) < 20) {
          if (!it.pest) { s.drops += 1; return false; }
          if (s.inv <= 0) { s.lives -= 1; s.inv = 1.2; if (s.lives <= 0) finish(); }
          return false;
        }
        return true;
      });
      s.hudT += dt;
      if (s.hudT > 0.1) { s.hudT = 0; setHud({ drops: s.drops, lives: s.lives, left: Math.ceil(VINE_SECONDS - s.t), over: false }); }
    }
    function draw() {
      const g = ctx.createLinearGradient(0, 0, 0, VH); g.addColorStop(0, "#cfe9f6"); g.addColorStop(1, "#e6f4dc");
      ctx.fillStyle = g; ctx.fillRect(0, 0, VW, VH);
      ctx.strokeStyle = "#a07850"; ctx.lineWidth = 4;
      for (const x of [26, VW - 26]) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, VH); ctx.stroke(); }
      ctx.lineWidth = 3;
      for (let y = s.scroll - 60; y < VH; y += 60) { ctx.beginPath(); ctx.moveTo(26, y); ctx.lineTo(VW - 26, y); ctx.stroke(); }
      // vine
      if (s.trail.length > 1) {
        ctx.lineJoin = "round"; ctx.lineCap = "round";
        for (const [w, c] of [[11, "#17302b"], [7, "#46a34a"]]) { ctx.lineWidth = w; ctx.strokeStyle = c; ctx.beginPath(); s.trail.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y))); ctx.stroke(); }
      }
      // items
      for (const it of s.items) {
        if (it.pest) {
          ctx.fillStyle = "#c8453b"; ctx.strokeStyle = "#17302b"; ctx.lineWidth = 2;
          ctx.beginPath(); ctx.ellipse(it.x, it.y, 11, 9, 0, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
          ctx.fillStyle = "#17302b"; ctx.beginPath(); ctx.arc(it.x - 4, it.y - 2, 2, 0, 7); ctx.arc(it.x + 4, it.y + 1, 2, 0, 7); ctx.fill();
          for (const dx of [-8, 0, 8]) { ctx.beginPath(); ctx.moveTo(it.x + dx, it.y + 8); ctx.lineTo(it.x + dx * 1.3, it.y + 14); ctx.stroke(); }
        } else {
          ctx.fillStyle = "#5ea8e6"; ctx.strokeStyle = "#17302b"; ctx.lineWidth = 2;
          ctx.beginPath(); ctx.moveTo(it.x, it.y - 13); ctx.quadraticCurveTo(it.x + 13, it.y + 4, it.x, it.y + 10); ctx.quadraticCurveTo(it.x - 13, it.y + 4, it.x, it.y - 13); ctx.fill(); ctx.stroke();
        }
      }
      // head
      const blink = s.inv > 0 && Math.floor(s.inv * 10) % 2 === 0;
      if (!blink) {
        ctx.fillStyle = "#6fd072"; ctx.strokeStyle = "#17302b"; ctx.lineWidth = 3;
        ctx.beginPath(); ctx.arc(s.x, headY, 11, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
        ctx.beginPath(); ctx.ellipse(s.x + 10, headY - 12, 9, 5, -0.6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
      }
      if (s.over) { ctx.fillStyle = "#17302bcc"; ctx.fillRect(0, VH / 2 - 30, VW, 60); ctx.fillStyle = "#fff"; ctx.font = "700 24px system-ui,sans-serif"; ctx.textAlign = "center"; ctx.fillText(s.lives <= 0 ? "Out of hearts!" : "Time!", VW / 2, VH / 2 + 8); }
    }
    function loop(now) {
      const dt = Math.min(0.05, (now - last) / 1000); last = now;
      if (!s.over) step(dt);
      draw();
      raf = requestAnimationFrame(loop);
    }
    raf = requestAnimationFrame(loop);

    const keyMap = { a: "left", arrowleft: "left", d: "right", arrowright: "right" };
    const kd = (e) => { const k = keyMap[e.key.toLowerCase()]; if (k && !isTyping(e)) { ctl[k] = true; e.preventDefault(); } };
    const ku = (e) => { const k = keyMap[e.key.toLowerCase()]; if (k) ctl[k] = false; };
    window.addEventListener("keydown", kd); window.addEventListener("keyup", ku);
    return () => { cancelAnimationFrame(raf); clearTimeout(timer); window.removeEventListener("keydown", kd); window.removeEventListener("keyup", ku); ctl.left = ctl.right = false; ctl.dragX = null; };
  }, [onDone, ctl]);

  const dragTo = (e) => { const r = ref.current.getBoundingClientRect(); ctl.dragX = ((e.clientX - r.left) / r.width) * VW; };
  const hold = (k, on) => ({
    onPointerDown: (e) => { e.preventDefault(); ctl[k] = true; }, onPointerUp: () => { ctl[k] = false; }, onPointerLeave: () => { ctl[k] = false; }, onPointerCancel: () => { ctl[k] = false; },
  });
  return (
    <div>
      <p className="mute">Water: {hud.drops} · Hearts: {"♥".repeat(Math.max(0, hud.lives))}{"♡".repeat(Math.max(0, 3 - hud.lives))} · {Math.max(0, hud.left)}s</p>
      <canvas ref={ref} className="gamecanvas" style={{ aspectRatio: `${VW}/${VH}` }} aria-label="Vine Climb game board"
        onPointerDown={(e) => { e.currentTarget.setPointerCapture?.(e.pointerId); dragTo(e); }} onPointerMove={(e) => { if (ctl.dragX != null) dragTo(e); }}
        onPointerUp={() => { ctl.dragX = null; }} onPointerCancel={() => { ctl.dragX = null; }} />
      <div className="dpad two">
        <button aria-label="Steer left" {...hold("left")}>◀</button>
        <button aria-label="Steer right" {...hold("right")}>▶</button>
      </div>
      <p className="mute">A / D or arrow keys, drag on the board, or hold the arrows.</p>
    </div>
  );
}

/* ---------------------------------------------------------------- Garden Snake */
const GN = 15, CELL = 22, SNAKE_SECONDS = 60;
const DIRS = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] };

export function GardenSnake({ onDone }) {
  const ref = useRef(null);
  const api = useRef({ turn: () => {} }).current;
  const [hud, setHud] = useState({ food: 0, left: SNAKE_SECONDS, over: false });

  useEffect(() => {
    const cv = ref.current, ctx = cv.getContext("2d");
    const dpr = Math.min(2, window.devicePixelRatio || 1), SZ = GN * CELL;
    cv.width = SZ * dpr; cv.height = SZ * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const mid = Math.floor(GN / 2);
    const s = { body: [{ x: mid, y: mid }, { x: mid - 1, y: mid }, { x: mid - 2, y: mid }], dir: "right", queue: [], food: null, eaten: 0, over: false, t: 0, acc: 0 };
    const place = () => { let p; do { p = { x: Math.floor(Math.random() * GN), y: Math.floor(Math.random() * GN) }; } while (s.body.some((b) => b.x === p.x && b.y === p.y)); s.food = p; };
    place();
    let raf, last = performance.now(), timer;
    const finish = () => { if (s.over) return; s.over = true; setHud({ food: s.eaten, left: Math.max(0, Math.ceil(SNAKE_SECONDS - s.t)), over: true }); timer = setTimeout(() => onDone({ food: s.eaten }), 900); };
    const opposite = { up: "down", down: "up", left: "right", right: "left" };
    api.turn = (d) => {
      const ref0 = s.queue.length ? s.queue[s.queue.length - 1] : s.dir;
      if (d !== ref0 && d !== opposite[ref0] && s.queue.length < 2) s.queue.push(d);
    };
    function tick() {
      if (s.queue.length) s.dir = s.queue.shift();
      const [dx, dy] = DIRS[s.dir], h = s.body[0], n = { x: h.x + dx, y: h.y + dy };
      const ate = s.food && n.x === s.food.x && n.y === s.food.y;
      const body = ate ? s.body : s.body.slice(0, -1);
      if (n.x < 0 || n.y < 0 || n.x >= GN || n.y >= GN || body.some((b) => b.x === n.x && b.y === n.y)) { finish(); return; }
      s.body.unshift(n);
      if (ate) { s.eaten += 1; place(); } else s.body.pop();
    }
    function draw() {
      ctx.fillStyle = "#dff0d2"; ctx.fillRect(0, 0, SZ, SZ);
      ctx.fillStyle = "#cfe6c0";
      for (let y = 0; y < GN; y++) for (let x = 0; x < GN; x++) if ((x + y) % 2) ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
      if (s.food) {
        const fx = s.food.x * CELL + CELL / 2, fy = s.food.y * CELL + CELL / 2;
        ctx.strokeStyle = "#17302b"; ctx.lineWidth = 2; ctx.fillStyle = "#e0a060";
        ctx.beginPath(); ctx.ellipse(fx, fy + 6, 8, 3.5, 0, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
        ctx.fillStyle = "#6fd072"; ctx.beginPath(); ctx.ellipse(fx - 4, fy - 1, 5, 3, -0.6, 0, Math.PI * 2); ctx.ellipse(fx + 4, fy - 1, 5, 3, 0.6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
        ctx.beginPath(); ctx.moveTo(fx, fy + 4); ctx.lineTo(fx, fy - 1); ctx.stroke();
      }
      s.body.forEach((b, i) => {
        ctx.fillStyle = i === 0 ? "#3f9142" : "#6fd072"; ctx.strokeStyle = "#17302b"; ctx.lineWidth = 2;
        ctx.beginPath(); ctx.roundRect(b.x * CELL + 1.5, b.y * CELL + 1.5, CELL - 3, CELL - 3, 6); ctx.fill(); ctx.stroke();
      });
      const h = s.body[0], [dx, dy] = DIRS[s.dir], cx = h.x * CELL + CELL / 2, cy = h.y * CELL + CELL / 2;
      ctx.fillStyle = "#fff";
      for (const o of [-4, 4]) { const ex = cx + (dx ? dx * 3 : o), ey = cy + (dy ? dy * 3 : o); ctx.beginPath(); ctx.arc(ex, ey, 2.4, 0, 7); ctx.fill(); ctx.fillStyle = "#17302b"; ctx.beginPath(); ctx.arc(ex + dx, ey + dy, 1.1, 0, 7); ctx.fill(); ctx.fillStyle = "#fff"; }
      if (s.over) { ctx.fillStyle = "#17302bcc"; ctx.fillRect(0, SZ / 2 - 28, SZ, 56); ctx.fillStyle = "#fff"; ctx.font = "700 22px system-ui,sans-serif"; ctx.textAlign = "center"; ctx.fillText(s.t >= SNAKE_SECONDS ? "Time!" : "Ouch!", SZ / 2, SZ / 2 + 8); }
    }
    function loop(now) {
      const dt = Math.min(0.1, (now - last) / 1000); last = now;
      if (!s.over) {
        s.t += dt; s.acc += dt;
        const every = Math.max(0.075, 0.15 - s.eaten * 0.003);
        while (s.acc >= every && !s.over) { s.acc -= every; tick(); }
        if (s.t >= SNAKE_SECONDS) finish();
        if (Math.floor(s.t * 5) !== s.hudT) { s.hudT = Math.floor(s.t * 5); setHud({ food: s.eaten, left: Math.ceil(SNAKE_SECONDS - s.t), over: false }); }
      }
      draw();
      raf = requestAnimationFrame(loop);
    }
    raf = requestAnimationFrame(loop);

    const keyMap = { w: "up", arrowup: "up", s: "down", arrowdown: "down", a: "left", arrowleft: "left", d: "right", arrowright: "right" };
    const kd = (e) => { const d = keyMap[e.key.toLowerCase()]; if (d && !isTyping(e)) { api.turn(d); e.preventDefault(); } };
    window.addEventListener("keydown", kd);
    return () => { cancelAnimationFrame(raf); clearTimeout(timer); window.removeEventListener("keydown", kd); api.turn = () => {}; };
  }, [onDone, api]);

  const swipe = useRef(null);
  const down = (e) => { swipe.current = { x: e.clientX, y: e.clientY }; e.currentTarget.setPointerCapture?.(e.pointerId); };
  const move = (e) => {
    const s0 = swipe.current; if (!s0) return;
    const dx = e.clientX - s0.x, dy = e.clientY - s0.y;
    if (Math.max(Math.abs(dx), Math.abs(dy)) < 22) return;
    api.turn(Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"));
    swipe.current = { x: e.clientX, y: e.clientY };          // allows a second quick turn in the same swipe
  };
  return (
    <div>
      <p className="mute">Sprouts: {hud.food} · {Math.max(0, hud.left)}s</p>
      <canvas ref={ref} className="gamecanvas snake" aria-label="Garden Snake game board"
        onPointerDown={down} onPointerMove={move} onPointerUp={() => { swipe.current = null; }} onPointerCancel={() => { swipe.current = null; }} />
      <div className="dpad four">
        <span /><button aria-label="Up" onPointerDown={(e) => { e.preventDefault(); api.turn("up"); }}>▲</button><span />
        <button aria-label="Left" onPointerDown={(e) => { e.preventDefault(); api.turn("left"); }}>◀</button>
        <button aria-label="Down" onPointerDown={(e) => { e.preventDefault(); api.turn("down"); }}>▼</button>
        <button aria-label="Right" onPointerDown={(e) => { e.preventDefault(); api.turn("right"); }}>▶</button>
      </div>
      <p className="mute">WASD or arrow keys, swipe on the board, or tap the pad.</p>
    </div>
  );
}
