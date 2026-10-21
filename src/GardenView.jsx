import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { stageName } from "./lib";
import { NameTag, Avatar } from "./ui";
import GardenScene from "./GardenScene";

// Read-only: this screen only calls visit_garden (public information) and toggle_garden_like.
export default function GardenView({ id, onBack, onLiked }) {
  const [v, setV] = useState(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase.rpc("visit_garden", { gid: id }).then(({ data, error }) => {
      if (error) setErr(error.message); else setV(data);
    });
  }, [id]);

  async function like() {
    setBusy(true); setErr("");
    const { data, error } = await supabase.rpc("toggle_garden_like", { gid: id });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setV((x) => ({ ...x, liked_by_me: data.liked, like_count: data.like_count }));
    onLiked?.(id, data);
  }

  if (err && !v) return <div><p role="alert">{err}</p><button onClick={onBack}>Back</button></div>;
  if (!v) return <p className="mute">Loading…</p>;

  return (
    <div>
      <button onClick={onBack}>Back</button>
      <h2>{v.name}</h2>
      <p className="mute byline"><Avatar path={v.owner_avatar} v={v.owner_avatar_v} name={v.owner_name} size={28} /> by {v.owner_name} · Level {v.owner_level} · {v.type_name}</p>
      {v.description && <p>{v.description}</p>}
      <div className="row" style={{ margin: "8px 0" }}>
        {v.is_mine
          ? <span className="mute">♥ {v.like_count} {v.like_count === 1 ? "like" : "likes"}</span>
          : <button className={"likebtn" + (v.liked_by_me ? " on" : "")} aria-pressed={v.liked_by_me} disabled={busy} onClick={like}>
              {v.liked_by_me ? "♥ Liked" : "♡ Like"} · {v.like_count}
            </button>}
      </div>
      {err && <p role="alert">{err}</p>}
      <GardenScene gardenType={v.garden_type} layout={v.layout} plants={v.plants} label={`${v.name}, ${v.type_name}`} />
      <h2 style={{ marginTop: 20 }}>On display</h2>
      <ul className="targets">
        {v.plants.map((p) => (
          <li key={p.spot}>
            <span><NameTag name={p.name} rarity={p.rarity} /> <span className="mute">{p.cultivar}</span></span>
            <span className="mute">Stage {p.stage} of {p.max_stage}: {stageName(p)} · {p.care}</span>
          </li>
        ))}
      </ul>
      <h2>Collector profile</h2>
      <p>{v.collector.unique_plants} cultivars collected</p>
      {v.collector.achievements.length > 0 ? (
        <p>{v.collector.achievements.map((a) => <span key={a.name} className="chip r-common" style={{ marginRight: 6 }}><span aria-hidden="true">{a.icon}</span> {a.name}</span>)}</p>
      ) : <p className="mute">No achievements yet.</p>}
    </div>
  );
}
