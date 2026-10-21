import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabaseClient";
import { WaterBalance, VineClimb, GardenSnake } from "./MoreGames";

export const LEAVES = [
  { id: "bantels", name: "Bantel's Sensation" }, { id: "bhitalii", name: "Bhitalii Silver Blue" }, { id: "coppertone", name: "Coppertone" },
  { id: "dark", name: "Dark Pink Bat" }, { id: "cream", name: "Moonshine Splash" }, { id: "marsha", name: "Marsha" },
];
const leafName = (id) => LEAVES.find((l) => l.id === id)?.name ?? "";
const GAMES = [
  { id: "leaf_match", name: "Leaf Match", how: "Flip cards and match all 6 pairs of leaves. Fewer misses, bigger prize.",
    rewards: "20 to 150 Leaf Coins, up to 1 Rhizome" },
  { id: "rhizome_rush", name: "Rhizome Rush", how: "Tap each sprout before it disappears. 10 sprouts, and they get faster. Catch 7 or more for the best prize.",
    rewards: "15 to 40 Leaf Coins, up to 1 Rhizome" },
  { id: "odd_plant_out", name: "Odd Plant Out", how: "Find the one leaf that is different. 10 rounds, the grid grows. Wrong taps cost time.",
    rewards: "20 to 100 Leaf Coins, up to 1 Rhizome" },
  { id: "water_balance", name: "Water Balance", how: "Tap Stop (or press Space) when the marker is inside the green zone. 8 rounds: the zone shrinks and the marker speeds up.",
    rewards: "20 to 100 Leaf Coins, up to 1 Rhizome" },
  { id: "vine_climb", name: "Vine Climb", how: "Steer a growing vine (A and D, arrow keys, drag, or the on-screen arrows) to catch water drops and dodge pests. 45 seconds, 3 hearts.",
    rewards: "20 to 100 Leaf Coins, up to 1 Rhizome" },
  { id: "garden_snake", name: "Garden Snake", how: "Classic snake. Steer with WASD, arrow keys, swipes or the on-screen pad. Eat sprouts to grow, avoid the walls and yourself. 60 seconds.",
    rewards: "20 to 100 Leaf Coins, up to 1 Rhizome" },
  { id: "spinner", name: "Growth Burst Spinner", how: "Spin the wheel. 3 spins a day, one every 8 hours.",
    rewards: "100 to 200 Leaf Coins, up to 2 Rhizomes, with a small chance of 5 Rhizomes or a Gem" },
];
const shuffle = (a) => { const b = [...a]; for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
const reduced = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
const Leaf = ({ id, style, alt = "" }) => <img className="leafimg" src={`/leaves/${id}.png`} alt={alt} style={style} draggable={false} />;

function LeafMatch({ onDone }) {
  const [cards] = useState(() => shuffle([...LEAVES, ...LEAVES].map((l) => l.id)));
  const [open, setOpen] = useState([]);
  const [matched, setMatched] = useState([]);
  const [misses, setMisses] = useState(0);
  const sent = useRef(false);
  useEffect(() => {
    if (matched.length === cards.length && !sent.current) { sent.current = true; onDone({ misses }); }
  }, [matched, cards.length, misses, onDone]);
  function pick(i) {
    if (open.length === 2 || open.includes(i) || matched.includes(i)) return;
    const next = [...open, i];
    setOpen(next);
    if (next.length === 2) {
      if (cards[next[0]] === cards[next[1]]) { setMatched((m) => [...m, ...next]); setOpen([]); }
      else { setMisses((m) => m + 1); setTimeout(() => setOpen([]), 700); }
    }
  }
  return (
    <div>
      <p className="mute">Misses: {misses}</p>
      <div className="gamegrid cols4">
        {cards.map((c, i) => {
          const up = open.includes(i) || matched.includes(i);
          const done = matched.includes(i);
          return (
            <button key={i} className={"cell leafcard" + (done ? " done" : "")} onClick={() => pick(i)} aria-label={up ? leafName(c) : "Hidden card"}>
              {up ? <><Leaf id={c} style={{ maxHeight: 62 }} />{done && <small>{leafName(c)}</small>}</> : "?"}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function RhizomeRush({ onDone }) {
  const [round, setRound] = useState(0);
  const [pos, setPos] = useState(() => Math.floor(Math.random() * 25));
  const [tapped, setTapped] = useState(false);
  const hits = useRef(0);
  useEffect(() => {
    const ms = Math.round(1100 - round * 33);        // 1.1 seconds for the first sprout, about 0.8 for the tenth
    const t = setTimeout(() => {
      if (round >= 9) { onDone({ hits: hits.current }); return; }
      setRound((r) => r + 1);
      setPos((p) => { let n = Math.floor(Math.random() * 25); if (n === p) n = (n + 7) % 25; return n; });
      setTapped(false);
    }, ms);
    return () => clearTimeout(t);
  }, [round, onDone]);
  function tap(i) { if (i === pos && !tapped) { setTapped(true); hits.current += 1; } }
  return (
    <div>
      <p className="mute">Sprout {round + 1} of 10 · caught {hits.current}</p>
      <div className="gamegrid cols5">
        {Array.from({ length: 25 }, (_, i) => (
          <button key={i} className="cell small" onClick={() => tap(i)} aria-label={i === pos && !tapped ? "Sprout" : "Empty"}>
            {i === pos && !tapped ? <img src="/icons/sprout.png" alt="" draggable={false} style={{ width: "80%" }} /> : ""}
          </button>
        ))}
      </div>
    </div>
  );
}

const LOOKALIKES = [["bantels", "marsha"], ["coppertone", "dark"], ["cream", "bantels"], ["bhitalii", "marsha"], ["dark", "marsha"], ["cream", "marsha"]];
function makeRound(r) {
  const n = r < 3 ? 3 : r < 7 ? 4 : 5;                   // the grid grows: 3x3, 4x4, then 5x5
  const ids = LEAVES.map((l) => l.id);
  const [base, odd] = r < 4 ? shuffle(ids).slice(0, 2) : shuffle(LOOKALIKES[Math.floor(Math.random() * LOOKALIKES.length)]);   // later rounds use lookalikes
  const cells = n * n;
  return { n, base, odd, oddAt: Math.floor(Math.random() * cells),
    tilt: Array.from({ length: cells }, () => Math.round(Math.random() * 40 - 20)), flip: Array.from({ length: cells }, () => Math.random() < 0.5) };
}

function OddPlantOut({ onDone }) {
  const [rounds] = useState(() => Array.from({ length: 10 }, (_, r) => makeRound(r)));
  const [round, setRound] = useState(0);
  const [wrong, setWrong] = useState([]);
  const [misses, setMisses] = useState(0);
  const sent = useRef(false);
  const R = rounds[round];
  function tap(i) {
    if (wrong.includes(i) || sent.current) return;
    if (i === R.oddAt) {
      if (round === 9) { sent.current = true; onDone({ misses }); return; }   // the server times the game itself
      setRound(round + 1); setWrong([]);
    } else { setMisses(misses + 1); setWrong([...wrong, i]); }
  }
  return (
    <div>
      <p className="mute">Round {round + 1} of 10 · wrong taps: {misses} (each adds 2 seconds)</p>
      <div className="gamegrid" style={{ gridTemplateColumns: `repeat(${R.n}, 1fr)` }}>
        {Array.from({ length: R.n * R.n }, (_, i) => (
          <button key={round + "-" + i} className={"cell leafcell" + (wrong.includes(i) ? " wrong" : "")} onClick={() => tap(i)} aria-label="Leaf">
            <Leaf id={i === R.oddAt ? R.odd : R.base} style={{ transform: `rotate(${R.tilt[i]}deg) scaleX(${R.flip[i] ? -1 : 1})` }} />
          </button>
        ))}
      </div>
    </div>
  );
}

const SEGMENTS = ["100 coins", "125 coins", "150 coins + 1 Rhizome", "200 coins + 2 Rhizomes", "5 Rhizomes", "1 Collector Gem"];
const SHORT = ["100", "125", "150", "200", "5 rhiz.", "1 gem"];

function Spinner({ spun, canSpin, spin, busy }) {
  const [turn, setTurn] = useState(0);
  const [shown, setShown] = useState(null);
  async function go() {
    const r = await spin();
    if (!r) return;
    if (reduced()) { setShown(r); return; }
    setTurn((t) => t + 360 * 4 + (360 - (r.segment * 60 + 30)) - (t % 360));
    setTimeout(() => setShown(r), 3100);
  }
  const r = shown || spun;
  return (
    <div>
      <div className="wheelwrap" aria-hidden="true">
        <div className="pointer">▼</div>
        <div className="wheel" style={{ transform: `rotate(${turn}deg)` }}>
          {SEGMENTS.map((s, i) => <span key={i} style={{ transform: `rotate(${i * 60 + 30}deg) translateY(-62px)` }}>{SHORT[i]}</span>)}
        </div>
      </div>
      <button className="water" disabled={!canSpin || busy} onClick={go}>Spin</button>
      {r && <p role="status">You won {SEGMENTS[r.segment]}!</p>}
    </div>
  );
}

function Result({ r }) {
  if (r.no_reward) return <p role="status">{r.no_reward === "too_fast" ? "That finished too quickly to count." : "That game timed out."} No reward this time.</p>;
  return (
    <div role="status" className="gameresult">
      <p><b>{r.perfect ? "Perfect! " : "Nice! "}</b>+{r.coins} Leaf Coins{r.rhizomes > 0 ? `, +${r.rhizomes} Species Rhizome${r.rhizomes > 1 ? "s" : ""}` : ""} · +{r.xp} XP</p>
      {r.rush_bonus && <p>Five perfect rounds in a row! +{r.rush_bonus.coins} Leaf Coins, +{r.rush_bonus.rhizomes} Rhizome</p>}
      {r.daily_bonus && <p>Daily streak complete! +{r.daily_bonus.coins} Leaf Coins, +{r.daily_bonus.rhizomes} Rhizome</p>}
      {r.weekly_bonus && <p>Weekly streak! +{r.weekly_bonus.coins} Leaf Coins, +{r.weekly_bonus.rhizomes} Rhizomes, +{r.weekly_bonus.gems} Collector Gem</p>}
    </div>
  );
}

const fmtWait = (iso) => {
  if (!iso) return "";
  const m = Math.max(1, Math.ceil((Date.parse(iso) - Date.now()) / 60000));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
};

export default function Games({ reload }) {
  const [gs, setGs] = useState(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [play, setPlay] = useState(null);      // { game, playId } while a skill game is running
  const [result, setResult] = useState(null);  // { game, r }

  async function refresh() {
    const { data, error } = await supabase.rpc("get_games_state");
    if (error) setErr(error.message); else setGs(data);
  }
  useEffect(() => { refresh(); }, []);

  async function start(game) {
    setErr(""); setResult(null); setBusy(true);
    const { data, error } = await supabase.rpc("start_game", { game, req_id: crypto.randomUUID() });
    setBusy(false);
    if (error) { setErr(error.message); refresh(); return; }
    setPlay({ game, playId: data.play_id });
    refresh();
  }
  const finishRef = useRef(null);
  finishRef.current = async (metrics) => {
    const cur = play; if (!cur) return;
    setPlay(null);
    const { data, error } = await supabase.rpc("finish_game", { play_id: cur.playId, metrics });
    if (error) { setErr(error.message); return; }
    setResult({ game: cur.game, r: data });
    refresh(); reload();
  };
  const onDone = useRef((m) => finishRef.current(m)).current;

  async function spin() {
    setErr(""); setResult(null); setBusy(true);
    const { data, error } = await supabase.rpc("spin", { req_id: crypto.randomUUID() });
    setBusy(false);
    if (error) { setErr(error.message); refresh(); return null; }
    setResult({ game: "spinner", r: data });
    setTimeout(() => { refresh(); reload(); }, reduced() ? 0 : 3200);   // update balances after the wheel stops
    return data;
  }

  if (!gs) return <p className="mute">{err || "Loading…"}</p>;
  const t = gs.today;
  const info = GAMES.find((g) => g.id === play?.game);
  return (
    <div>
      <div className="panel left">
        <h2>Daily streak</h2>
        <p>Finish {t.needed} mini-games today: {Math.min(t.completed, t.needed)} of {t.needed}{t.bonus_paid ? " · bonus earned!" : ` · +${t.bonus.coins} Leaf Coins, +${t.bonus.rhizomes} Rhizome`}</p>
        <div className="meter"><i style={{ width: `${Math.min(100, (t.completed / t.needed) * 100)}%` }} /></div>
        <p className="mute">Streak: {gs.streak.days} day{gs.streak.days === 1 ? "" : "s"} in a row · every {gs.streak.week_days} days: +{gs.streak.weekly.coins} Leaf Coins, +{gs.streak.weekly.rhizomes} Rhizomes, +{gs.streak.weekly.gems} Collector Gem</p>
        <p className="mute">Rhizome Rush perfect rounds in a row: {gs.rush.perfects} of {gs.rush.needed} (bonus +{gs.rush.bonus.coins} Leaf Coins, +{gs.rush.bonus.rhizomes} Rhizome)</p>
      </div>
      {err && <p role="alert">{err}</p>}

      {play ? (
        <div className="panel">
          <h2><img className="gameicon" src={`/icons/${info.id}.png`} alt="" /> {info.name}</h2>
          {play.game === "leaf_match" && <LeafMatch onDone={onDone} />}
          {play.game === "rhizome_rush" && <RhizomeRush onDone={onDone} />}
          {play.game === "odd_plant_out" && <OddPlantOut onDone={onDone} />}
          {play.game === "water_balance" && <WaterBalance onDone={onDone} />}
          {play.game === "vine_climb" && <VineClimb onDone={onDone} />}
          {play.game === "garden_snake" && <GardenSnake onDone={onDone} />}
        </div>
      ) : (
        <>
          {result && result.game !== "spinner" && <div className="panel"><Result r={result.r} /></div>}
          <div className="grid">
            {GAMES.map((g) => {
              const s = gs.games[g.id];
              const out = s.day_left <= 0 ? "No plays left today" : s.hour_left <= 0 ? `Next play in ${fmtWait(s.next_at)}` : null;
              return (
                <div key={g.id} className="plant gamecard">
                  <img className="gameicon big" src={`/icons/${g.id}.png`} alt="" />
                  <h2>{g.name}</h2>
                  <p className="mute">{g.how}</p>
                  <p className="mute">Plays left today: {s.day_left} of {s.daily}{g.id !== "spinner" ? ` · this hour: ${s.hour_left} of ${s.hourly}` : ""}</p>
                  <p>{g.rewards}</p>
                  {g.id === "spinner" ? (
                    <>
                      <Spinner spun={result?.game === "spinner" ? result.r : null} canSpin={!out} spin={spin} busy={busy} />
                      {out && <p className="mute">{out}</p>}
                      {result?.game === "spinner" && result.r.daily_bonus && <p>Daily streak complete! +{result.r.daily_bonus.coins} Leaf Coins, +{result.r.daily_bonus.rhizomes} Rhizome</p>}
                    </>
                  ) : (
                    <>
                      <button className="water" disabled={!!out || busy} onClick={() => start(g.id)}>Play</button>
                      {out && <p className="mute">{out}</p>}
                    </>
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}
