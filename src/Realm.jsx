import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "./supabaseClient";
import GardenView from "./GardenView";
import { Avatar } from "./ui";
import { gardenImg } from "./gardenLayouts";

const SORTS = [["recent", "Recently published"], ["likes", "Most liked"], ["level", "Highest level"]];

export default function Realm({ startOpen = null, onClosed }) {
  const [sort, setSort] = useState("recent");
  const [items, setItems] = useState([]);
  const [more, setMore] = useState(false);
  const [next, setNext] = useState(0);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [open, setOpen] = useState(startOpen);
  const ticket = useRef(0);

  // One page at a time. Changing the sort starts again from the first page; late answers from an old sort are ignored.
  const load = useCallback(async (s, offset) => {
    const mine = ++ticket.current;
    setLoading(true); setErr("");
    const { data, error } = await supabase.rpc("list_public_gardens", { sort: s, page_offset: offset, page_size: 12 });
    if (mine !== ticket.current) return;
    setLoading(false);
    if (error) { setErr(error.message); return; }
    setItems((prev) => (offset ? [...prev, ...data.gardens] : data.gardens));
    setMore(data.has_more); setNext(data.next_offset);
  }, []);
  useEffect(() => { load(sort, 0); }, [load, sort]);

  async function random() {
    setErr("");
    const { data, error } = await supabase.rpc("random_public_garden");
    if (error) setErr(error.message); else setOpen(data);
  }
  async function like(g) {
    setErr("");
    const { data, error } = await supabase.rpc("toggle_garden_like", { gid: g.id });
    if (error) { setErr(error.message); return; }
    setItems((prev) => prev.map((x) => (x.id === g.id ? { ...x, liked_by_me: data.liked, like_count: data.like_count } : x)));
  }
  const patch = (id, d) => setItems((prev) => prev.map((x) => (x.id === id ? { ...x, liked_by_me: d.liked, like_count: d.like_count } : x)));

  if (open) return <GardenView id={open} onBack={() => { setOpen(null); onClosed?.(); }} onLiked={patch} />;

  return (
    <div>
      <div className="row" style={{ marginBottom: 12 }}>
        <button className="water" onClick={random}>Visit a random garden</button>
      </div>
      <div className="sortbar" role="group" aria-label="Sort gardens">
        <span className="mute">Sort by</span>
        {SORTS.map(([id, label]) => <button key={id} aria-pressed={sort === id} onClick={() => setSort(id)}>{label}</button>)}
      </div>
      {err && <p role="alert">{err}</p>}
      {!loading && items.length === 0 && !err && <p className="mute">No public gardens yet. Publish yours from the My Garden tab.</p>}
      <div className="grid">
        {items.map((g) => (
          <div key={g.id} className="plant gcard">
            <button className="cardopen" onClick={() => setOpen(g.id)} aria-label={`Open ${g.name}`}>
              <img className="gthumb" src={gardenImg(g.garden_type)} alt="" loading="lazy" />
              <div className="thumbs">
                {g.preview.map((p, i) => <img key={i} src={`/plants/${p.type}_stage${p.stage}.png`} alt="" />)}
              </div>
              <h2>{g.name}</h2>
              <p className="mute byline"><Avatar path={g.owner_avatar} v={g.owner_avatar_v} name={g.owner_name} size={22} /> by {g.owner_name} · Lv {g.owner_level}</p>
              <p className="mute">{g.cultivars} {g.cultivars === 1 ? "cultivar" : "cultivars"} on display · {g.achievements} achievements</p>
            </button>
            {g.is_mine
              ? <p className="mute">♥ {g.like_count} · yours</p>
              : <button className={"likebtn" + (g.liked_by_me ? " on" : "")} aria-pressed={g.liked_by_me} onClick={() => like(g)} aria-label={`${g.liked_by_me ? "Unlike" : "Like"} ${g.name}`}>
                  {g.liked_by_me ? "♥" : "♡"} {g.like_count}
                </button>}
          </div>
        ))}
      </div>
      {loading && <p className="mute">Loading…</p>}
      {more && !loading && <button style={{ marginTop: 12 }} onClick={() => load(sort, next)}>Load more</button>}
    </div>
  );
}
