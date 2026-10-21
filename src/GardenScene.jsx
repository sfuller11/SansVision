import { LAYOUTS, SIZE_W, gardenImg } from "./gardenLayouts";
import { imgSrc, moodOf } from "./lib";

// One garden picture with its plants standing on named spots. Used by the editor (tap spots) and by visitors (look only).
// plants: anything with { spot, type, stage, cultivar, moisture }.  selected: the plant being placed (or null).
export default function GardenScene({ gardenType, layout, plants, selected = null, onSpot, onRemove, label = "Garden" }) {
  const spots = LAYOUTS[layout] ?? [];
  const edit = !!onSpot;
  return (
    <div className="scene" role="group" aria-label={label}>
      <img className="scenebg" src={gardenImg(gardenType)} alt="" draggable="false" />
      {spots.map((s) => {
        const q = plants.find((p) => p.spot === s.id);
        const w = SIZE_W[s.size] * 100;
        const style = { left: `${s.x * 100}%`, top: `${s.y * 100}%`, width: `${w}%`, marginTop: `${w * 0.0688}%`, zIndex: Math.round(s.y * 1000) };
        const tooTall = !!selected && selected.tall && s.size === "S";
        const pic = q && <img className={"pimg " + moodOf(q)} src={imgSrc(q)} alt={`${q.cultivar}, stage ${q.stage}`} draggable="false" />;
        if (!edit) return <div key={s.id} className="spot static" style={style}>{pic}</div>;
        const cls = "spot" + (q ? "" : " empty") + (selected ? " pick" : "") + (q && selected && q.id === selected.id ? " sel" : "") + (tooTall ? " no" : "");
        const size = s.size === "S" ? "small" : s.size === "M" ? "medium" : "large";
        return (
          <div key={s.id} className={cls} style={style}>
            <button className="spotbtn" disabled={tooTall} onClick={() => onSpot(s.id, q)}
              aria-label={q ? `${q.cultivar}, ${size} spot` : `Empty ${size} spot`}>
              {pic}
              {!q && <span className="marker" aria-hidden="true">+</span>}
            </button>
            {q && onRemove && (
              <button className="x" onClick={() => onRemove(q)} aria-label={`Take ${q.cultivar} off its spot`} title="Take it off">×</button>
            )}
          </div>
        );
      })}
    </div>
  );
}
