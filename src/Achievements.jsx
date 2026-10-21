import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";

const NAMES = { leaf_coins: "Leaf Coins", collector_gems: "Collector Gems", rhizomes: "Species Rhizomes" };
const rewardText = (r) => Object.entries(r).map(([k, v]) => `+${v} ${NAMES[k]}`).join(", ");

export default function Achievements({ reload }) {
  const [list, setList] = useState(null);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("get_achievements");
    if (error) setErr(error.message); else setList(data);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function claim(a) {
    if (busy) return;
    setBusy(true); setErr(""); setMsg("");
    const { data, error } = await supabase.rpc("claim_achievement", { aid: a.id });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    if (data.claimed) setMsg(`${a.name} claimed: ${rewardText(data.rewards)}`);
    await Promise.all([load(), reload()]);
  }

  if (!list) return <p className="mute">{err || "Loading…"}</p>;
  const done = list.filter((a) => a.state === "claimed").length;

  return (
    <div>
      <p className="mute">{done} of {list.length} claimed</p>
      {msg && <p role="status">{msg}</p>}
      {err && <p role="alert">{err}</p>}
      <div className="grid">
        {list.map((a) => (
          <div key={a.id} className={"plant ach " + a.state}>
            <div className="icon" aria-hidden="true">{a.icon}</div>
            <h2>{a.name}</h2>
            <p className="mute">{a.description}</p>
            <div className="meter" title="Progress"><i style={{ width: `${(a.progress / a.target) * 100}%` }} /></div>
            <p className="mute">{a.progress} / {a.target} · Reward: {rewardText(a.rewards).replaceAll("+", "")}</p>
            {a.state === "ready" && <button className="water" disabled={busy} onClick={() => claim(a)}>Claim reward</button>}
            {a.state === "claimed" && <p><b>Claimed</b></p>}
            {a.state === "needs_plants" && <p className="mute">Unlocks when more plants are added to the game.</p>}
            {a.state === "coming_soon" && <p className="mute">Coming with public gardens.</p>}
          </div>
        ))}
      </div>
    </div>
  );
}
