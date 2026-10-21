import { useRef, useState } from "react";
import { AuthCard } from "./Auth";
import GardenScene from "./GardenScene";
import { STAGES } from "./lib";
import { gardenImg } from "./gardenLayouts";

// What a visitor sees before signing in. Everything here is static: no account, no server calls.
const SAMPLE = [
  { spot: "shelf1", type: "marsha", stage: 4, cultivar: "Marsha" },
  { spot: "shelf2", type: "bhitalii", stage: 4, cultivar: "Bhitalli" },
  { spot: "shelf3", type: "assalam", stage: 4, cultivar: "Assalam" },
  { spot: "shelf4", type: "gabriella", stage: 4, cultivar: "Gabriella" },
  { spot: "bench1", type: "sunnystar", stage: 4, cultivar: "Sunny Star" },
  { spot: "bench2", type: "masoniana", stage: 5, cultivar: "Masoniana" },
  { spot: "bench3", type: "bantels", stage: 4, cultivar: "Bantel's Sensation" },
  { spot: "floor1", type: "trifasciata", stage: 20, cultivar: "Trifasciata" },
  { spot: "floor2", type: "coppertone", stage: 5, cultivar: "Coppertone" },
  { spot: "floor3", type: "kismayo", stage: 5, cultivar: "Kismayo" },
].map((p) => ({ ...p, moisture: 100 }));

const GARDENS = [
  ["greenhouse", "Greenhouse", "Free"], ["balcony", "Balcony", "250 coins"], ["greenhouse_night", "Night Greenhouse", "300 coins"],
  ["backyard", "Backyard", "500 coins"], ["autumn_backyard", "Autumn Backyard", "6 gems"], ["rocks", "Rock Garden", "900 coins"],
  ["desert_canyon", "Desert Canyon", "8 gems"], ["zen_courtyard", "Zen Courtyard", "12 gems"],
];
const TIERS = [
  ["common", ["trifasciata", "laurentii", "sunnystar"]], ["uncommon", ["sword", "blackgold", "siamsilver"]],
  ["rare", ["cream", "banded", "kismayo"]], ["epic", ["dark"]], ["legendary", ["coppertone", "kirkiicoral", "bhitaliivar"]],
];
const TALL = { trifasciata: 20, laurentii: 20, blackgold: 20 };   // tall cultivars show their full size 20
const GAMES = [
  ["leaf_match", "Leaf Match"], ["rhizome_rush", "Rhizome Rush"], ["odd_plant_out", "Odd Plant Out"],
  ["water_balance", "Water Balance"], ["vine_climb", "Vine Climb"], ["garden_snake", "Garden Snake"],
];

export default function Landing() {
  const [mode, setMode] = useState("signup");
  const emailRef = useRef(null);
  const go = (m) => {
    setMode(m);
    setTimeout(() => { document.getElementById("join")?.scrollIntoView({ behavior: "smooth", block: "center" }); emailRef.current?.focus({ preventScroll: true }); }, 50);
  };
  return (
    <main className="landing">
      <header className="lbar">
        <b className="logo">Plant Pals</b>
        <button onClick={() => go("signin")}>Sign in</button>
      </header>

      <section className="hero">
        <h1>Collect, grow and show off Sansevieria.</h1>
        <p className="lead">Water your plants, watch them grow through five stages, and arrange them in gardens you can show to other players. Free to play.</p>
        <div className="row" style={{ justifyContent: "center" }}>
          <button className="water bigbtn" onClick={() => go("signup")}>Start growing</button>
          <button className="bigbtn" onClick={() => go("signin")}>Sign in</button>
        </div>
        <div className="herogarden">
          <GardenScene gardenType="greenhouse" layout="greenhouse" plants={SAMPLE} label="Example greenhouse full of plants" />
        </div>
      </section>

      <section>
        <h2>From a cutting to a mature clump</h2>
        <div className="stagestrip">
          {STAGES.map((n, i) => (
            <figure key={n}><img src={`/plants/bantels_stage${Math.min(5, i + 1)}.png`} alt="" loading="lazy" /><figcaption>{i + 1}. {n}</figcaption></figure>
          ))}
        </div>
        <p className="mute">Keep plants watered and they grow while you are away. Boosts and gems speed things up.</p>
      </section>

      <section>
        <h2>Eight gardens to decorate</h2>
        <p className="mute">Start with a greenhouse, then collect more places to put your plants. Every garden has its own spots.</p>
        <div className="gallery">
          {GARDENS.map(([id, name, cost]) => (
            <figure key={id}><img src={gardenImg(id)} alt={`${name} garden`} loading="lazy" /><figcaption>{name} <span className="mute">· {cost}</span></figcaption></figure>
          ))}
        </div>
      </section>

      <section>
        <h2>Over 30 cultivars in five rarities</h2>
        <div className="tiers">
          {TIERS.map(([r, ids]) => (
            <div key={r} className="tier">
              <span className={"chip r-" + r}>{r}</span>
              <div className="tierplants">{ids.map((t) => <img key={t} src={`/plants/${t}_stage${TALL[t] ?? 5}.png`} alt={t} loading="lazy" />)}</div>
            </div>
          ))}
        </div>
        <p className="mute">Discover new plants with Leaf Coins. Duplicates turn into Rhizomes or free growth boosts.</p>
      </section>

      <section>
        <h2>Mini-games with real prizes</h2>
        <div className="gamestrip">
          {GAMES.map(([id, name]) => <figure key={id}><img src={`/icons/${id}.png`} alt="" loading="lazy" /><figcaption>{name}</figcaption></figure>)}
        </div>
        <p className="mute">Play on a keyboard or a phone, plus a daily spinner.</p>
      </section>

      <section className="join">
        <h2>Ready to plant your first Sansevieria?</h2>
        <AuthCard key={mode} startMode={mode} inputRef={emailRef} />
      </section>
    </main>
  );
}
