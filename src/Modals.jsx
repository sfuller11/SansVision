import { useEffect, useRef, useState } from "react";
import { stageName, moistureLabel, boostLeft, fmtHours } from "./lib";
import { Img, XpBar, NameTag } from "./ui";

export function Modal({ label, onClose, children, large }) {
  const closeRef = useRef(null);
  useEffect(() => {
    closeRef.current?.focus();
    const onKey = (e) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="backdrop" onClick={onClose}>
      <div className={"modal" + (large ? " large" : "")} role="dialog" aria-modal="true" aria-label={label} onClick={(e) => e.stopPropagation()}>
        <button className="close" ref={closeRef} onClick={onClose} aria-label="Close">×</button>
        {children}
      </div>
    </div>
  );
}

const rewardText = (r = {}) =>
  [r.leaf_coins && `+${r.leaf_coins} Leaf Coins`, r.rhizomes && `+${r.rhizomes} Species Rhizomes`, r.collector_gems && `+${r.collector_gems} Collector Gem`]
    .filter(Boolean).join(" · ");

export function PlantModal({ p, profile, onClose, onRename, onWater, onBuyBoost, onSkip, error }) {
  const [view, setView] = useState(p.stage);
  const [name, setName] = useState(p.name);
  const [confirmSkip, setConfirmSkip] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => { setName(p.name); }, [p.name]);
  useEffect(() => { setView(p.stage); }, [p.stage]);
  const shown = Math.min(view, p.stage);
  const boost = boostLeft(p);
  const full = p.stage >= p.max_stage;
  const run = async (fn) => { setBusy(true); await fn(); setBusy(false); setConfirmSkip(false); };
  return (
    <Modal label={`${p.name} details`} onClose={onClose}>
      <img className="big" src={`/plants/${p.type}_stage${shown}.png`} alt={`${p.cultivar}, stage ${shown}`} style={{ height: p.tall ? 260 : 150 }} />
      <h2><NameTag name={p.name} rarity={p.rarity} /></h2>
      <p className="mute">{p.cultivar} · <span className={"chip r-" + p.rarity}>{p.rarity}</span></p>
      <p><b>Stage {shown}: {stageName({ stage: shown, max_stage: p.max_stage })}</b>{shown < p.stage ? " (earlier stage)" : " (current)"}</p>
      <div className="stages" role="group" aria-label="Growth stages">
        {Array.from({ length: p.max_stage }, (_, i) => i + 1).map((n) => (
          <button key={n} aria-pressed={shown === n} disabled={n > p.stage} onClick={() => setView(n)} aria-label={`Stage ${n}`}>{n}</button>
        ))}
      </div>
      <p>Level {p.stage} of {p.max_stage}</p>
      <XpBar p={p} />
      {!full && <p className="mute">Next level in about {fmtHours(p.eta_hours)} (while well watered)</p>}
      {boost && <p className="boost">{p.boost_mult}× growth boost · {boost} left</p>}
      <p className="mute">{moistureLabel(p)} ({Math.round(p.moisture)}%)</p>
      <div className="meter wet"><i style={{ width: `${p.moisture}%` }} /></div>

      {!full && (
        <div className="shop">
          {boost ? <p className="mute">A boost is already active on this plant.</p> : ["2x", "5x"].map((k) => {
            const c = p.boost_costs[k];
            return (
              <div key={k} className="boostrow">
                <b>{k === "2x" ? "2×" : "5×"} boost · {c.hours}h</b>
                <button className="water" disabled={busy || profile.leaf_coins < c.coins} onClick={() => run(() => onBuyBoost(k, "leaf_coins"))}>
                  Buy {k === "2x" ? "2×" : "5×"} Boost ({c.coins} Leaf Coins)
                </button>
                <button className="water" disabled={busy || profile.rhizomes < c.rhizomes} onClick={() => run(() => onBuyBoost(k, "rhizomes"))}>
                  Buy {k === "2x" ? "2×" : "5×"} Boost ({c.rhizomes} Rhizomes)
                </button>
              </div>
            );
          })}
          {confirmSkip ? (
            <div className="confirm" role="alertdialog" aria-label="Confirm skip">
              <p>Spend {p.skip_cost} Collector Gems to {p.tall ? "jump to the next growth phase" : "grow to the next stage now"}?</p>
              <div className="row" style={{ justifyContent: "center" }}>
                <button className="water" disabled={busy} onClick={() => run(onSkip)}>Yes, skip</button>
                <button onClick={() => setConfirmSkip(false)}>Cancel</button>
              </div>
            </div>
          ) : (
            <button disabled={busy || profile.collector_gems < p.skip_cost} onClick={() => setConfirmSkip(true)}>
              {p.tall ? "Skip to next phase" : "Skip Stage"} ({p.skip_cost} gems)
            </button>
          )}
        </div>
      )}

      <label>Plant name
        <span className="row">
          <input value={name} maxLength={24} onChange={(e) => setName(e.target.value)} />
          <button className="water" disabled={name.trim() === p.name} onClick={() => onRename(name)}>Save name</button>
        </span>
      </label>
      {error && <p role="alert">{error}</p>}
      <div className="acts"><button className="water" onClick={onWater}>Water</button></div>
    </Modal>
  );
}

export function DuplicateModal({ item, owned, hours, onClose, onResolve, error }) {
  const [busy, setBusy] = useState(false);
  async function pick(choice) { setBusy(true); await onResolve(item.id, choice); setBusy(false); }
  return (
    <Modal label="Duplicate plant" onClose={onClose}>
      <img className="big" src={`/plants/${item.plant_type}_stage1.png`} alt={item.cultivar} style={{ height: 130 }} />
      <h2>Duplicate: {item.cultivar}</h2>
      <p><span className={"chip r-" + item.rarity}>{item.rarity}</span></p>
      <p>You already own this plant. Choose what to do with the duplicate:</p>
      <div className="choices">
        <button className="water" disabled={busy} onClick={() => pick("rhizomes")}>Convert to {item.rhizomes} Species Rhizomes</button>
        <button className="water" disabled={busy || !owned} onClick={() => pick("double_xp")}>
          Free 2× growth boost for {hours} hours{owned ? ` on ${owned.name}` : ""}
        </button>
      </div>
      <p className="mute">A boost cannot be added to a plant that already has one.</p>
      {error && <p role="alert">{error}</p>}
      <button onClick={onClose}>Decide later</button>
    </Modal>
  );
}

function Confetti() {
  const colors = ["#f7d98a", "#a9cdf2", "#b8e0b0", "#d3b8f2", "#f2a9a9"];
  return (
    <div className="confetti" aria-hidden="true">
      {Array.from({ length: 28 }, (_, i) => (
        <i key={i} style={{ left: `${(i * 37) % 100}%`, background: colors[i % colors.length], animationDelay: `${(i % 7) * 0.12}s`, animationDuration: `${1.6 + (i % 5) * 0.25}s` }} />
      ))}
    </div>
  );
}

// ups = the unseen level-ups from the server (one or several)
export function LevelUpModal({ ups, onClose }) {
  const last = ups[ups.length - 1];
  const total = ups.reduce((a, u) => ({
    leaf_coins: a.leaf_coins + (u.rewards.leaf_coins || 0), rhizomes: a.rhizomes + (u.rewards.rhizomes || 0), collector_gems: a.collector_gems + (u.rewards.collector_gems || 0),
  }), { leaf_coins: 0, rhizomes: 0, collector_gems: 0 });
  return (
    <Modal label="Level up" onClose={onClose}>
      <Confetti />
      <h2 className="pop">Level Up!</h2>
      <p className="pop">You reached Level {last.level}.</p>
      <p>{rewardText(total)}</p>
      <button className="water" onClick={onClose}>Great!</button>
    </Modal>
  );
}

export function AwayBody({ away, onOpenAchievements }) {
  const mins = away.away_minutes;
  const when = mins >= 1440 ? `${Math.floor(mins / 1440)} day(s)` : mins >= 60 ? `${Math.floor(mins / 60)} hour(s)` : `${mins} minutes`;
  return (
    <>
      <p className="mute">About {when}</p>
      <div className="away">
        {away.grown.length > 0 && (
          <section><h3>Growth</h3>
            <ul>{away.grown.map((g, i) => (
              <li key={i}><img src={`/plants/${g.type}_stage${g.to}.png`} alt="" /> <NameTag name={g.name} rarity={g.rarity} /> grew from stage {g.from} to {g.to} of {g.max_stage}</li>
            ))}</ul>
          </section>
        )}
        {away.levels.length > 0 && (
          <section><h3>Levels</h3>
            <ul>{away.levels.map((l) => <li key={l.level}>You reached <b>Level {l.level}</b> ({rewardText(l.rewards)})</li>)}</ul>
          </section>
        )}
        {away.achievements.length > 0 && (
          <section><h3>Achievements</h3>
            <ul>{away.achievements.map((a) => <li key={a.name}><span aria-hidden="true">{a.icon}</span> {a.name} is ready to claim</li>)}</ul>
            {onOpenAchievements && <button onClick={onOpenAchievements}>Open Achievements</button>}
          </section>
        )}
        {away.boosts_ended.length > 0 && (
          <section><h3>Boosts</h3>
            <ul>{away.boosts_ended.map((b, i) => <li key={i}>The {b.mult}× boost on {b.name} ended</li>)}</ul>
          </section>
        )}
        {away.needs_water.length > 0 && (
          <section><h3>Needs water</h3>
            <p>{away.needs_water.map((n) => n.name).join(", ")}</p>
          </section>
        )}
      </div>
    </>
  );
}

export function AwayModal({ away, onClose, onOpenAchievements }) {
  return (
    <Modal label="While you were away" onClose={onClose}>
      <h2>While you were away</h2>
      <AwayBody away={away} onOpenAchievements={onOpenAchievements} />
      <button className="water" onClick={onClose}>Back to the garden</button>
    </Modal>
  );
}
