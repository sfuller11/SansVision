import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { sourceLabel } from "./lib";
import { NameTag } from "./ui";

function Tile({ p, onOpen }) {
  return (
    <button className={"tile" + (p.owned ? "" : " locked")} onClick={onOpen} aria-label={p.owned ? p.name : `Unknown ${p.rarity} plant`}>
      {p.owned && p.is_new && <span className="newdot" title="New">New</span>}
      <img className={"tileimg" + (p.owned ? "" : " sil")} src={`/plants/${p.id}_stage${p.owned ? p.stage : p.max_stage}.png`} alt="" draggable={false} />
      {p.owned ? <NameTag name={p.name} rarity={p.rarity} /> : <span className={"nt nt-" + p.rarity}>???</span>}
      {p.owned && p.full_growth && <span className="badge" title="Fully grown">★ Fully grown</span>}
    </button>
  );
}

export default function Collection({ reload, profile }) {
  const [data, setData] = useState(null);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [filter, setFilter] = useState("all");
  const [sel, setSel] = useState(null);
  const [view, setView] = useState(1);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data: d, error } = await supabase.rpc("get_collection");
    if (error) setErr(error.message); else setData(d);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function open(p) {
    setSel(p.id); setConfirm(false); setErr(""); setView(p.owned ? p.stage : 1);
    if (p.owned && p.is_new) {
      await supabase.rpc("mark_plant_seen", { cid: p.id });
      setData((d) => ({ ...d, plants: d.plants.map((x) => (x.id === p.id ? { ...x, is_new: false } : x)) }));
      reload();
    }
  }
  async function unlock(p) {
    if (busy) return;
    setBusy(true); setErr("");
    const { data: r, error } = await supabase.rpc("targeted_unlock", { cid: p.id, req_id: crypto.randomUUID() });
    setBusy(false); setConfirm(false);
    if (error) { setErr(error.message); return; }
    setMsg(`Unlocked ${r.plant.name}!`);
    await Promise.all([load(), reload()]);
  }

  if (!data) return <p className="mute">{err || "Loading…"}</p>;
  const plants = data.plants;
  const ownedCount = plants.filter((p) => p.owned).length;
  const cur = plants.find((p) => p.id === sel);

  if (cur) {
    return (
      <div className="colldetail">
        <button onClick={() => { setSel(null); setMsg(""); }}>Back to Collection</button>
        {err && <p role="alert">{err}</p>}
        {cur.owned ? (
          <>
            <img className="big" src={`/plants/${cur.id}_stage${Math.min(view, cur.stage)}.png`} alt={`${cur.name}, stage ${view}`} style={{ height: cur.tall ? 260 : 160 }} />
            <h2><NameTag name={cur.name} rarity={cur.rarity} /></h2>
            <p><span className={"chip r-" + cur.rarity}>{cur.rarity}</span> {cur.full_growth && <span className="badge">★ Fully grown</span>}</p>
            {cur.plant_name !== cur.name && <p className="mute">Your plant is named {cur.plant_name}</p>}
            <p>{cur.description}</p>
            <div className="stages" role="group" aria-label="Growth stages reached">
              {Array.from({ length: cur.max_stage }, (_, i) => i + 1).map((n) => (
                <button key={n} aria-pressed={Math.min(view, cur.stage) === n} disabled={n > cur.stage} onClick={() => setView(n)} aria-label={`Stage ${n}`}>{n}</button>
              ))}
            </div>
            <p className="mute">Stage {cur.stage} of {cur.max_stage} · Found {new Date(cur.acquired_at).toLocaleDateString()} · {sourceLabel(cur.source)}</p>
          </>
        ) : (
          <>
            <img className="big sil" src={`/plants/${cur.id}_stage${cur.max_stage}.png`} alt="Unknown plant" style={{ height: cur.tall ? 260 : 160 }} />
            <h2><span className={"nt nt-" + cur.rarity}>???</span></h2>
            <p><span className={"chip r-" + cur.rarity}>{cur.rarity}</span></p>
            <p className="mute">You have not found this plant yet.</p>
            <h3>Where to find it</h3>
            <ul className="odds">
              {Object.entries(cur.chances).map(([k, v]) => <li key={k}>{v.name}: about {v.pct}% per discovery</li>)}
            </ul>
            <h3>Unlock it directly</h3>
            {confirm ? (
              <div className="confirm">
                <p>Spend {cur.unlock_cost} Species Rhizomes to unlock this plant?</p>
                <div className="row" style={{ justifyContent: "center" }}>
                  <button className="water" disabled={busy} onClick={() => unlock(cur)}>Yes, unlock</button>
                  <button onClick={() => setConfirm(false)}>Cancel</button>
                </div>
              </div>
            ) : (
              <button className="water" disabled={profile.rhizomes < cur.unlock_cost} onClick={() => setConfirm(true)}>
                Unlock for {cur.unlock_cost} Species Rhizomes
              </button>
            )}
            {profile.rhizomes < cur.unlock_cost && <p className="mute">You have {profile.rhizomes}. Mini-games and duplicates earn Rhizomes.</p>}
          </>
        )}
      </div>
    );
  }

  return (
    <div>
      <p><b>{ownedCount} of {plants.length}</b> plants collected</p>
      {msg && <p role="status">{msg}</p>}
      {err && <p role="alert">{err}</p>}
      <div className="row" role="group" aria-label="Filter" style={{ margin: "8px 0" }}>
        {[["all", "All"], ["owned", "Owned"], ["missing", "Missing"]].map(([k, l]) => <button key={k} aria-pressed={filter === k} onClick={() => setFilter(k)}>{l}</button>)}
      </div>
      {data.rarities.map((r) => {
        const row = plants.filter((p) => p.rarity === r);
        if (!row.length) return null;
        const shown = row.filter((p) => filter === "all" || (filter === "owned") === p.owned);
        if (!shown.length) return null;
        const have = row.filter((p) => p.owned).length;
        return (
          <section key={r} className="collrow">
            <h3><span className={"chip r-" + r}>{r}</span> {have} / {row.length}</h3>
            <div className="meter" title={`${r} collected`}><i style={{ width: `${(have / row.length) * 100}%` }} /></div>
            <div className="tiles">{shown.map((p) => <Tile key={p.id} p={p} onOpen={() => open(p)} />)}</div>
          </section>
        );
      })}
    </div>
  );
}
