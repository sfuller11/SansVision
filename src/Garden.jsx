import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "./supabaseClient";
import { moistureLabel, stageName, boostLeft } from "./lib";
import { Img, Stepper, XpBar, NameTag, LevelBadge, Avatar } from "./ui";
import { PlantModal, DuplicateModal, LevelUpModal } from "./Modals";
import Home from "./Home";
import GardenEditor from "./GardenEditor";
import Realm from "./Realm";
import Discover from "./Discover";
import ProfileModal from "./ProfileModal";
import Games from "./Games";
import Shop from "./Shop";

function Card({ p, adminOn, onOpen, onWater, setStage }) {
  const boost = boostLeft(p);
  return (
    <div className="plant">
      <button className="cardopen" onClick={onOpen} aria-label={`Open ${p.name}`}>
        <Img p={p} w={p.tall ? 110 : 140} />
        <h2><NameTag name={p.name} rarity={p.rarity} /></h2>
      </button>
      <p className="mute">{p.cultivar} · {p.rarity}</p>
      <p className="mute">Level {p.stage} of {p.max_stage}: {stageName(p)}</p>
      <XpBar p={p} />
      {boost && <p className="boost">{p.boost_mult}× boost · {boost} left</p>}
      <p className="mute">{moistureLabel(p)} ({Math.round(p.moisture)}%)</p>
      <div className="meter wet" title="Moisture"><i style={{ width: `${p.moisture}%` }} /></div>
      {adminOn && <Stepper p={p} set={setStage} />}
      <div className="acts"><button className="water" onClick={onWater}>Water</button></div>
    </div>
  );
}

export default function Garden() {
  const [st, setSt] = useState(null);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [tab, setTab] = useState("home");
  const [adminOn, setAdminOn] = useState(false);
  const [profileTab, setProfileTab] = useState(null);   // null = closed, or "profile" | "achievements" | "collection"
  const [grant, setGrant] = useState("");
  const [openId, setOpenId] = useState(null);
  const [dupId, setDupId] = useState(null);
  const [modalErr, setModalErr] = useState("");
  const [away, setAway] = useState(null);
  const [visitId, setVisitId] = useState(null);
  const prevReady = useRef(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("get_game_state");
    if (error) { setErr(error.message); return; }
    if (prevReady.current !== null && data.ready_achievements > prevReady.current) setMsg("Achievement complete! Open your profile, then Achievements, to claim your reward.");
    prevReady.current = data.ready_achievements;
    setSt(data);
  }, []);

  // Every change goes through a server function. The browser only asks; the server decides.
  async function act(fn, args, inModal) {
    setErr(""); setMsg(""); setModalErr("");
    const { data, error } = await supabase.rpc(fn, args);
    if (error) { (inModal ? setModalErr : setErr)(error.message); return null; }
    await load();
    return data ?? true;
  }

  useEffect(() => {
    let alive = true;
    (async () => {
      // Order matters: the away summary must be read BEFORE get_game_state records that you have seen the garden.
      const { data: summary } = await supabase.rpc("get_away_summary");
      if (alive && summary) setAway(summary);
      await load();
      const { data } = await supabase.rpc("claim_daily_login");
      if (alive && data?.granted) { setMsg(`Daily reward: +${data.amount} Leaf Coins`); load(); }
    })();
    const t = setInterval(load, 60000);
    return () => { alive = false; clearInterval(t); };
  }, [load]);

  if (!st) return <main><p className="mute">{err || "Loading…"}</p></main>;
  const { profile, daily, plants, catalog, duplicates, boost } = st;
  const owned = new Set(plants.map((p) => p.type));
  const grantable = catalog.filter((c) => !owned.has(c.id));
  const openPlant = plants.find((p) => p.id === openId);
  const dupItem = duplicates.find((d) => d.id === dupId);
  const levelUps = tab === "home" && away ? null : st.level_ups.length ? st.level_ups : null;

  async function closeAway() { setAway(null); if (st.level_ups.length) { setSt((s) => ({ ...s, level_ups: [] })); await supabase.rpc("ack_level_ups"); } }
  async function closeLevel() { setSt((s) => ({ ...s, level_ups: [] })); await supabase.rpc("ack_level_ups"); }
  async function buyBoost(pid, kind, payWith) {
    const r = await act("buy_boost", { pid, kind, pay_with: payWith, req_id: crypto.randomUUID() }, true);
    if (r) setMsg(`${kind === "2x" ? "2×" : "5×"} boost started.`);
  }
  async function skip(pid) {
    const r = await act("skip_stage", { pid, req_id: crypto.randomUUID() }, true);
    if (r) setMsg(`Your plant grew to stage ${r.new_stage}.`);
  }

  async function water(id) {
    const r = await act("water_plant", { pid: id }, openId === id);
    if (r?.care_reward) setMsg(`Daily care complete: +${r.care_amount} Leaf Coins`);
  }
  async function resolve(id, choice) {
    const r = await act("resolve_duplicate", { item_id: id, choice }, true);
    if (!r) return;
    setDupId(null);
    setMsg(choice === "rhizomes" ? `Converted to ${r.rhizomes} Species Rhizomes.` : `Double XP is active on ${r.plant_name}.`);
  }
  const setDup = (id) => { setModalErr(""); setDupId(id); };
  const setOpen = (id) => { setModalErr(""); setOpenId(id); };

  return (
    <main>
      <div className="bar">
        <div>
          <h1>Plant Pals</h1>
          <button className="whoami" onClick={() => setProfileTab("profile")} aria-label={`Open your profile, ${profile.display_name}`}>
            <Avatar path={profile.avatar_path} v={profile.avatar_v} name={profile.display_name} size={44} />
            <span>{profile.display_name}</span>
            {st.ready_achievements + st.new_plants > 0 && <span className="notifdot" title="Something new in your profile" />}
          </button>
          <LevelBadge profile={profile} />
        </div>
        <div className="row">
          {profile.is_admin && <button aria-pressed={adminOn} onClick={() => setAdminOn(!adminOn)}>Admin mode</button>}
          <button onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </div>

      <div className="wallet" aria-label="Currencies">
        <span>Leaf Coins <b>{profile.leaf_coins}</b></span>
        <span>Collector Gems <b>{profile.collector_gems}</b></span>
        <span>Species Rhizomes <b>{profile.rhizomes}</b></span>
      </div>
      {msg && <p role="status">{msg}</p>}
      {err && !["discover", "achievements", "realm", "home"].includes(tab) && <p role="alert">{err}</p>}

      <div className="tabs">
        <button aria-pressed={tab === "home"} onClick={() => setTab("home")}>Home</button>
        <button aria-pressed={tab === "garden"} onClick={() => setTab("garden")}>Plants</button>
        <button aria-pressed={tab === "rooms"} onClick={() => setTab("rooms")}>My Garden</button>
        <button aria-pressed={tab === "realm"} onClick={() => { setVisitId(null); setTab("realm"); }}>Realm</button>
        <button aria-pressed={tab === "discover"} onClick={() => setTab("discover")}>Discovery</button>
        <button aria-pressed={tab === "arcade"} onClick={() => setTab("arcade")}>Arcade</button>
        <button aria-pressed={tab === "shop"} onClick={() => setTab("shop")}>Shop</button>
      </div>

      {adminOn && (
        <div className="panel">
          <p>Admin: grant a plant for testing</p>
          <div className="row" style={{ justifyContent: "center" }}>
            <select value={grant} aria-label="Plant to grant" onChange={(e) => setGrant(e.target.value)}>
              <option value="">Choose a plant</option>
              {grantable.map((c) => <option key={c.id} value={c.id}>{c.name} ({c.rarity})</option>)}
            </select>
            <button className="water" disabled={!grant} onClick={async () => { await act("admin_grant_plant", { catalog_id: grant }); setGrant(""); }}>Grant</button>
          </div>
        </div>
      )}

      {tab === "home" ? (
        <Home st={st} away={away} onCloseAway={closeAway} onOpenAchievements={() => setProfileTab("achievements")} goTab={setTab}
          openGarden={(id) => { setVisitId(id); setTab("realm"); }} />
      ) : tab === "arcade" ? (
        <Games reload={load} />
      ) : tab === "shop" ? (
        <Shop />
      ) : tab === "discover" ? (
        <Discover profile={profile} reload={load} goGarden={() => setTab("garden")} openDuplicate={(id) => { setTab("garden"); setDup(id); }} />
      ) : tab === "realm" ? (
        <Realm key={visitId || "list"} startOpen={visitId} onClosed={() => setVisitId(null)} />
      ) : tab === "rooms" ? (
        <GardenEditor plants={plants} adminOn={adminOn} profile={profile} reload={load}
          place={(id, gid, spot) => act("place_plant", { pid: id, gid, spot_name: spot })}
          setStage={(id, n) => act("admin_set_stage", { pid: id, new_stage: n })} />
      ) : (
        <div>
          {duplicates.length > 0 && (
            <div className="panel left">
              <h2>Inventory: duplicates ({duplicates.length})</h2>
              <p className="mute">Open a duplicate to convert it to Species Rhizomes or boost the plant you already own.</p>
              <div className="row">
                {duplicates.map((d) => (
                  <button key={d.id} className="dupchip" onClick={() => setDup(d.id)}>
                    <img src={`/plants/${d.plant_type}_stage1.png`} alt="" /> {d.cultivar} <span className={"chip r-" + d.rarity}>{d.rarity}</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {plants.length ? (
            <div className="grid">
              {plants.map((p) => (
                <Card key={p.id} p={p} adminOn={adminOn} onOpen={() => setOpen(p.id)} onWater={() => water(p.id)}
                  setStage={(n) => act("admin_set_stage", { pid: p.id, new_stage: n })} />
              ))}
            </div>
          ) : (
            <p className="mute" style={{ marginTop: 24 }}>No plants yet. Open Discovery: you start with 100 Leaf Coins, enough for two Basic Discoveries.</p>
          )}
        </div>
      )}

      {openPlant && (
        <PlantModal p={openPlant} profile={profile} error={modalErr}
          onBuyBoost={(k, pay) => buyBoost(openPlant.id, k, pay)} onSkip={() => skip(openPlant.id)} onClose={() => setOpenId(null)} onWater={() => water(openPlant.id)}
          onRename={(n) => act("rename_plant", { pid: openPlant.id, new_name: n }, true)} />
      )}
      {dupItem && (
        <DuplicateModal item={dupItem} owned={plants.find((p) => p.type === dupItem.plant_type)} hours={boost.hours}
          error={modalErr} onClose={() => setDupId(null)} onResolve={resolve} />
      )}
      {profileTab && <ProfileModal profile={profile} tab={profileTab} onTab={setProfileTab} onClose={() => setProfileTab(null)} reload={load} ready={st.ready_achievements} newPlants={st.new_plants} />}
      {levelUps && <LevelUpModal ups={levelUps} onClose={closeLevel} />}
    </main>
  );
}
