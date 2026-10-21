import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { Stepper, NameTag } from "./ui";
import GardenScene from "./GardenScene";
import { gardenImg } from "./gardenLayouts";

const CUR = { leaf_coins: "Leaf Coins", collector_gems: "Collector Gems" };

export default function GardenEditor({ plants, adminOn, profile, reload, place, setStage }) {
  const [data, setData] = useState(null);
  const [gid, setGid] = useState(null);
  const [sel, setSel] = useState(null);
  const [name, setName] = useState("");
  const [desc, setDesc] = useState("");
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [confirm, setConfirm] = useState(null);

  const load = useCallback(async (pick) => {
    const { data: d, error } = await supabase.rpc("get_my_gardens");
    if (error) { setErr(error.message); return; }
    setData(d);
    setGid((cur) => (pick && d.gardens.some((g) => g.id === pick) ? pick : d.gardens.some((g) => g.id === cur) ? cur : d.gardens[0]?.id ?? null));
  }, []);
  useEffect(() => { load(); }, [load]);

  const g = data?.gardens.find((x) => x.id === gid);
  // The name boxes follow whichever garden is open.
  useEffect(() => { if (g) { setName(g.name); setDesc(g.description); } }, [g?.id]);                 // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setSel(null); }, [gid]);

  async function call(fn, args, ok) {
    setErr(""); setMsg("");
    const { error } = await supabase.rpc(fn, args);
    if (error) { setErr(error.message); return false; }
    setMsg(ok);
    await load(); await reload();
    return true;
  }

  async function buy(t) {
    setErr(""); setMsg("");
    const { data: r, error } = await supabase.rpc("buy_garden", { type_id: t.id, req_id: crypto.randomUUID() });
    setConfirm(null);
    if (error) { setErr(error.message); return; }
    setMsg(`${t.name} is yours. Open it above to start placing plants.`);
    await load(r.id); await reload();
  }

  if (!data) return <p className="mute">{err || "Loading…"}</p>;
  if (!g) return <p className="mute">No garden found.</p>;

  const here = plants.filter((p) => p.garden_id === g.id && p.spot);
  const cur = plants.find((p) => p.id === sel);
  const unplaced = plants.filter((p) => !p.spot);
  const elsewhere = plants.filter((p) => p.spot && p.garden_id !== g.id);
  const gname = (id) => data.gardens.find((x) => x.id === id)?.type_name ?? "";

  async function onSpot(spot, q) {
    if (sel) {
      if (q && q.id === sel) { setSel(null); return; }
      setErr(""); setMsg("");
      const r = await place(sel, g.id, spot);
      if (r) { setSel(null); await load(); }
    } else if (q) setSel(q.id);
  }
  const pickable = (p) => (
    <button key={p.id} className={"slot" + (p.id === sel ? " sel" : "")} onClick={() => setSel(p.id === sel ? null : p.id)} aria-label={`Pick ${p.name}`}>
      <img src={`/plants/${p.type}_stage${p.stage}.png`} alt="" style={{ height: 56, width: "auto" }} />
    </button>
  );

  return (
    <div>
      <div className="gswitch" role="tablist" aria-label="Your gardens">
        {data.gardens.map((x) => (
          <button key={x.id} role="tab" aria-selected={x.id === g.id} aria-pressed={x.id === g.id} onClick={() => setGid(x.id)}>
            {x.type_name}<span className="mute"> {x.placed}/{x.spots}</span>{x.is_public && <span title="Public" aria-label="Public"> ●</span>}
          </button>
        ))}
      </div>

      <p className="mute">{sel ? "Now tap a spot to place it." : "Pick a plant below (or one already placed), then tap a spot. Tap the × on a plant to take it off."}</p>
      <GardenScene gardenType={g.garden_type} layout={g.layout} plants={here} selected={cur} onSpot={onSpot} onRemove={async (q) => { setErr(""); setMsg(""); if (await place(q.id, null, null)) { if (sel === q.id) setSel(null); await load(); } }} label={`${g.name} editor`} />

      <div className="tray">
        <span className="mute">Not placed:</span>
        {unplaced.length ? unplaced.map(pickable) : <span className="mute">none</span>}
      </div>
      {elsewhere.length > 0 && (
        <div className="tray">
          <span className="mute">In another garden:</span>
          {elsewhere.map((p) => <span key={p.id} title={gname(p.garden_id)}>{pickable(p)}</span>)}
        </div>
      )}
      {cur && (
        <div className="panel">
          <p><NameTag name={cur.name} rarity={cur.rarity} /> · {cur.cultivar}{cur.tall ? " · tall (needs a medium or large spot)" : ""}</p>
          {cur.spot && <button onClick={async () => { await place(cur.id, null, null); setSel(null); await load(); }}>Take it off its spot</button>}
          {adminOn && <div style={{ marginTop: 8 }}><Stepper p={cur} set={(n) => setStage(cur.id, n)} /></div>}
        </div>
      )}
      {msg && <p role="status">{msg}</p>}
      {err && <p role="alert">{err}</p>}

      <div className="panel left">
        <h2>{g.type_name} settings</h2>
        <label>Garden name<input value={name} maxLength={40} onChange={(e) => setName(e.target.value)} /></label>
        <label>Description<textarea rows={2} maxLength={200} value={desc} onChange={(e) => setDesc(e.target.value)} /></label>
        <div className="row">
          <button className="water" onClick={() => call("update_garden", { gid: g.id, new_name: name, new_description: desc }, "Saved.")}>Save</button>
          <button onClick={() => call("set_garden_public", { gid: g.id, make_public: !g.is_public }, g.is_public ? "This garden is now private." : "This garden is now public.")}>
            {g.is_public ? "Unpublish" : "Publish garden"}
          </button>
        </div>
        <p className="mute">
          {g.is_public ? `Public. Visitors can look and like it (${g.like_count} ${g.like_count === 1 ? "like" : "likes"}), but cannot change anything.` : "Private."}
          {" "}Visitors see every plant you place on a spot. A garden with nothing placed is not listed in the Realm.
        </p>
      </div>

      <div className="panel left">
        <h2>Garden shop</h2>
        {data.types.every((t) => t.owned) ? <p className="mute">You own every garden.</p> : (
          <div className="grid">
            {data.types.filter((t) => !t.owned).map((t) => {
              const bal = profile[t.currency];
              return (
                <div key={t.id} className="plant theme">
                  <img className="gthumb" src={gardenImg(t.id)} alt={`${t.name} preview`} loading="lazy" />
                  <h2>{t.name}</h2>
                  <p className="mute">{t.description}</p>
                  <p className="mute">{t.spots} spots</p>
                  {confirm === t.id ? (
                    <span className="row">
                      <span>Spend {t.cost} {CUR[t.currency]}?</span>
                      <button className="water" onClick={() => buy(t)}>Confirm</button>
                      <button onClick={() => setConfirm(null)}>Cancel</button>
                    </span>
                  ) : (
                    <button disabled={bal < t.cost} onClick={() => setConfirm(t.id)}>
                      {bal < t.cost ? `${t.cost} ${CUR[t.currency]} (you have ${bal})` : `Buy for ${t.cost} ${CUR[t.currency]}`}
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
