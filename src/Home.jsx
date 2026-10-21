import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { AwayBody } from "./Modals";
import GardenScene from "./GardenScene";
import { gardenImg } from "./gardenLayouts";
import { fmtHours } from "./lib";

const fmtWhen = (iso) => {
  if (!iso) return "";
  const h = (Date.parse(iso) - Date.now()) / 3600000;
  return h <= 0 ? "now" : `in ${fmtHours(h)}`;
};

// The first screen after sign-in: what happened, what is waiting, and one thing to aim for.
export default function Home({ st, away, onCloseAway, onOpenAchievements, goTab, openGarden }) {
  const [g, setG] = useState(undefined);       // featured garden: undefined = loading, null = none
  const [games, setGames] = useState(null);
  const [mine, setMine] = useState(null);
  const [err, setErr] = useState("");
  const [liking, setLiking] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [f, s, m] = await Promise.all([supabase.rpc("get_featured_garden"), supabase.rpc("get_games_state"), supabase.rpc("get_my_gardens")]);
      if (!alive) return;
      if (f.error) setErr(f.error.message); else setG(f.data ?? null);
      if (!s.error) setGames(s.data);
      if (!m.error) setMine(m.data);
    })();
    return () => { alive = false; };
  }, []);

  async function like() {
    setLiking(true);
    const { data, error } = await supabase.rpc("toggle_garden_like", { gid: g.id });
    setLiking(false);
    if (error) { setErr(error.message); return; }
    setG((x) => ({ ...x, liked_by_me: data.liked, like_count: data.like_count }));
  }

  const { profile, daily, level_rewards: lr } = st;
  const toLevel = profile.xp_needed - profile.xp;
  // Next goal: the cheapest garden you can still buy, otherwise the next level.
  const goalGarden = mine?.types?.filter((t) => !t.owned).sort((a, b) => (a.currency === "gems" ? a.cost * 60 : a.cost) - (b.currency === "gems" ? b.cost * 60 : b.cost))[0];
  const have = goalGarden ? (goalGarden.currency === "gems" ? profile.collector_gems : profile.leaf_coins) : 0;
  const unit = goalGarden?.currency === "gems" ? "Collector Gems" : "Leaf Coins";
  const sp = games?.games?.spinner;
  const arcadeLeft = games ? ["leaf_match", "rhizome_rush", "odd_plant_out", "water_balance", "vine_climb", "garden_snake"].reduce((n, k) => n + (games.games[k]?.day_left ?? 0), 0) : null;

  return (
    <div className="home">
      {away && (
        <section className="card awaycard" aria-label="While you were away">
          <h2>While you were away</h2>
          <AwayBody away={away} onOpenAchievements={onOpenAchievements} />
          <button className="water" onClick={onCloseAway}>Got it</button>
        </section>
      )}

      <section className="card">
        <h2>Today</h2>
        <ul className="today">
          <li><span aria-hidden="true">{daily.login_claimed ? "✅" : "⬜"}</span> Daily login reward {daily.login_claimed ? "collected" : "waiting"}</li>
          <li><span aria-hidden="true">{daily.care_claimed ? "✅" : "⬜"}</span> Daily care: {daily.care_claimed ? "done" : "water any plant to earn a reward"}</li>
          {games && (
            <>
              <li><span aria-hidden="true">{games.today.completed >= games.today.needed ? "✅" : "⬜"}</span> Play {games.today.needed} mini-games: {Math.min(games.today.completed, games.today.needed)} of {games.today.needed}</li>
              <li><span aria-hidden="true">🔥</span> Game streak: {games.streak.days} {games.streak.days === 1 ? "day" : "days"} (a {games.streak.week_days}-day streak earns the weekly bonus)</li>
              <li><span aria-hidden="true">🎡</span> Spinner: {sp.day_left} of {sp.daily} spins left today{sp.day_left > 0 && (sp.hour_left > 0 ? " · ready" : sp.next_at ? ` · next ${fmtWhen(sp.next_at)}` : "")}</li>
            </>
          )}
        </ul>
        <div className="row">
          <button onClick={() => goTab("garden")}>Water plants</button>
          <button className="water" onClick={() => goTab("arcade")}>Open the Arcade{arcadeLeft != null ? ` (${arcadeLeft} plays left today)` : ""}</button>
        </div>
      </section>

      <section className="card">
        <h2>Featured garden</h2>
        {g === undefined && <p className="mute">Loading…</p>}
        {g === null && <p className="mute">No public gardens to feature yet. Place a plant in your garden and publish it from My Garden to be the first.</p>}
        {g && (
          <>
            <p className="mute byline">{g.name} by {g.owner_name} · {g.type_name} · ♥ {g.like_count}{g.week_likes > 0 ? ` (${g.week_likes} this week)` : ""}</p>
            <GardenScene gardenType={g.garden_type} layout={g.layout} plants={g.plants} label={`${g.name}, featured garden`} />
            <div className="row" style={{ marginTop: 8 }}>
              <button className="water" onClick={() => openGarden(g.id)}>Visit</button>
              {g.is_mine
                ? <span className="mute">This is yours!</span>
                : <button className={"likebtn" + (g.liked_by_me ? " on" : "")} aria-pressed={g.liked_by_me} disabled={liking} onClick={like}>{g.liked_by_me ? "♥ Liked" : "♡ Like"}</button>}
            </div>
          </>
        )}
        {err && <p role="alert">{err}</p>}
      </section>

      <section className="card">
        <h2>Next goal</h2>
        {goalGarden ? (
          <div className="goal">
            <img src={gardenImg(goalGarden.id)} alt="" loading="lazy" />
            <div>
              <p><b>{goalGarden.name}</b> · {goalGarden.cost} {unit}</p>
              <div className="meter" title="Progress"><i style={{ width: `${Math.min(100, (have / goalGarden.cost) * 100)}%` }} /></div>
              <p className="mute">{have >= goalGarden.cost ? "You can afford it." : `${goalGarden.cost - have} more ${unit} to go.`}</p>
              <button onClick={() => goTab("rooms")}>{have >= goalGarden.cost ? "Buy it in My Garden" : "See My Garden"}</button>
            </div>
          </div>
        ) : null}
        <div className={goalGarden ? "goal2" : ""}>
          <p>Level {profile.level}: <b>{toLevel} XP</b> to level {profile.level + 1}</p>
          <div className="meter"><i style={{ width: `${Math.min(100, (profile.xp / profile.xp_needed) * 100)}%` }} /></div>
          {lr && <p className="mute">Reward: {lr.leaf_coins} Leaf Coins, {lr.rhizomes} Rhizomes{lr.gem_every ? `, and ${lr.gems} Gem every ${lr.gem_every} levels` : ""}</p>}
        </div>
      </section>
    </div>
  );
}
