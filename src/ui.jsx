import { stageName, moodOf, imgSrc, avatarUrl } from "./lib";

export function Img({ p, w }) {
  return <img src={imgSrc(p)} alt={`${p.cultivar}, stage ${p.stage}`} className={"pimg " + moodOf(p)} style={{ width: w }} />;
}

export function Stepper({ p, set }) {
  return (
    <div className="row" style={{ justifyContent: "center", alignItems: "center" }}>
      <button disabled={p.stage <= 1} onClick={() => set(p.stage - 1)} aria-label="Previous growth stage">−</button>
      <span>Stage {p.stage} of {p.max_stage}: {stageName(p)}</span>
      <button disabled={p.stage >= p.max_stage} onClick={() => set(p.stage + 1)} aria-label="Next growth stage">+</button>
    </div>
  );
}

export function XpBar({ p }) {
  if (p.xp_needed == null) return <><div className="meter"><i style={{ width: "100%" }} /></div><p className="mute">Max level reached</p></>;
  return (
    <>
      <div className="meter" title="XP to next level"><i style={{ width: `${Math.min(100, (p.xp / p.xp_needed) * 100)}%` }} /></div>
      <p className="mute">XP {p.xp} / {p.xp_needed} to level {p.stage + 1}</p>
    </>
  );
}

// Plant name with a rarity-coloured outline (colours live in styles.css as .nt-<rarity>).
export function NameTag({ name, rarity }) {
  return <span className={"nt nt-" + rarity} title={rarity}>{name}</span>;
}

// Player level and XP toward the next level, shown at the top of the screen.
export function LevelBadge({ profile }) {
  const pct = Math.min(100, (profile.xp / profile.xp_needed) * 100);
  return (
    <div className="levelbadge" aria-label={`Level ${profile.level}, ${profile.xp} of ${profile.xp_needed} experience`}>
      <b>Lv {profile.level}</b>
      <div className="meter" title="XP to next level"><i style={{ width: `${pct}%` }} /></div>
      <span className="mute">{profile.xp} / {profile.xp_needed} XP</span>
    </div>
  );
}

// Profile picture, or the first letter of the name on a coloured circle when none is set.
export function Avatar({ path, v, name = "?", size = 40 }) {
  const url = avatarUrl(path, v);
  return url
    ? <img className="avatar" src={url} alt="" width={size} height={size} style={{ width: size, height: size }} />
    : <span className="avatar ph" aria-hidden="true" style={{ width: size, height: size, fontSize: size * 0.5 }}>{(name[0] || "?").toUpperCase()}</span>;
}
