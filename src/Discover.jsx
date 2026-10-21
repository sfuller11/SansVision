import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { NameTag } from "./ui";

const RARITIES = ["common", "uncommon", "rare", "epic", "legendary"];
const CUR = { leaf_coins: "Leaf Coins", collector_gems: "Collector Gems", rhizomes: "Species Rhizomes" };

export default function Discover({ profile, reload, goGarden, openDuplicate }) {
  const [info, setInfo] = useState(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);
  const [confirm, setConfirm] = useState(null);

  const loadInfo = useCallback(async () => {
    const { data, error } = await supabase.rpc("get_discovery_info");
    if (error) setErr(error.message); else setInfo(data);
  }, []);
  useEffect(() => { loadInfo(); }, [loadInfo]);

  // A fresh request id per click lets the server ignore accidental repeats of the same request.
  async function run(fn, args) {
    if (busy) return;
    setBusy(true); setErr("");
    const { data, error } = await supabase.rpc(fn, { ...args, req_id: crypto.randomUUID() });
    setBusy(false);
    if (error) { setErr(error.message); setConfirm(null); return; }
    setResult(data); setConfirm(null);
    await Promise.all([reload(), loadInfo()]);
  }

  if (!info) return <p className="mute">{err || "Loading…"}</p>;

  if (result) {
    return (
      <div className="plant result" role="status">
        <p className="mute">{result.tier_name}</p>
        <img src={`/plants/${result.plant.id}_stage1.png`} alt={result.plant.name} style={{ width: 150 }} />
        <h2><NameTag name={result.plant.name} rarity={result.rarity} /></h2>
        <p><span className={"chip r-" + result.rarity}>{result.rarity}</span> {result.is_new ? <b>New plant!</b> : <b>Duplicate</b>}</p>
        {!result.is_new && <p>You already own this one. The duplicate is in your inventory: convert it to {result.rhizomes_if_converted} Species Rhizomes, or use it for a Double XP boost on your plant.</p>}
        {result.first_rarity_bonus > 0 && <p>First {result.rarity} discovery: +{result.first_rarity_bonus} Leaf Coins</p>}
        <div className="acts">
          {!result.is_new && result.duplicate_item_id && <button className="water" onClick={() => openDuplicate(result.duplicate_item_id)}>Open duplicate</button>}
          <button className={result.is_new ? "water" : ""} onClick={() => setResult(null)}>Back to discovery</button>
          <button onClick={goGarden}>See my garden</button>
        </div>
      </div>
    );
  }

  return (
    <div>
      {err && <p role="alert">{err}</p>}
      <div className="grid">
        {info.tiers.map((t) => {
          const bal = profile[t.currency];
          const label = t.problem ? "Unavailable" : bal < t.cost ? `Not enough ${CUR[t.currency]}` : "Discover";
          return (
            <div className="plant tier" key={t.id}>
              <h2>{t.name}</h2>
              <p><b>{t.cost}</b> {CUR[t.currency]} <span className="mute">(you have {bal})</span></p>
              <ul className="odds">
                {RARITIES.map((r) => (
                  <li key={r}><span className={"chip r-" + r}>{r}</span> {t.odds[r]}% <span className="mute">· {info.pools[r] || 0} plants</span></li>
                ))}
              </ul>
              <p className="mute">The result is random. Duplicates go to your inventory.</p>
              <button className="water" disabled={busy || !!t.problem || bal < t.cost} onClick={() => run("discover", { tier_id: t.id })}>{label}</button>
            </div>
          );
        })}
      </div>

      <h2 style={{ marginTop: 28 }}>Targeted Discovery</h2>
      <p className="mute">Spend Species Rhizomes to unlock a specific plant you don't own. You have {profile.rhizomes}.</p>
      <ul className="targets">
        {info.targeted.map((c) => (
          <li key={c.id}>
            <span><span className={"chip r-" + c.rarity}>{c.rarity}</span> <NameTag name={c.name} rarity={c.rarity} /></span>
            {c.owned ? <span className="mute">Owned</span> : confirm === c.id ? (
              <span className="row">
                <span>Spend {c.cost} Rhizomes?</span>
                <button className="water" disabled={busy} onClick={() => run("targeted_unlock", { cid: c.id })}>Confirm</button>
                <button onClick={() => setConfirm(null)}>Cancel</button>
              </span>
            ) : (
              <button disabled={busy || profile.rhizomes < c.cost} onClick={() => setConfirm(c.id)}>Unlock for {c.cost}</button>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
