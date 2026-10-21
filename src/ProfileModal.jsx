import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { Modal } from "./Modals";
import { Avatar, LevelBadge } from "./ui";
import Achievements from "./Achievements";
import Collection from "./Collection";

function ProfileTab({ profile, reload }) {
  const [name, setName] = useState(profile.display_name);
  const [stats, setStats] = useState(null);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => { setName(profile.display_name); }, [profile.display_name]);
  useEffect(() => { supabase.rpc("get_profile_summary").then(({ data }) => setStats(data)); }, []);

  async function saveName() {
    setErr(""); setMsg("");
    const { error } = await supabase.rpc("set_display_name", { new_name: name });
    if (error) { setErr(error.message); return; }
    setMsg("Name saved."); reload();
  }

  // The picture is cropped square, shrunk to 256 px and re-saved as a JPEG in the browser. That also removes any hidden
  // data in the photo (such as location). The database only accepts one small JPEG per player, in their own folder.
  async function onFile(e) {
    const f = e.target.files?.[0]; e.target.value = "";
    if (!f) return;
    setErr(""); setMsg("");
    if (!["image/jpeg", "image/png", "image/webp"].includes(f.type)) { setErr("Choose a JPG, PNG or WebP picture."); return; }
    if (f.size > 8 * 1024 * 1024) { setErr("That picture is too large (8 MB at most)."); return; }
    setBusy(true);
    try {
      const bmp = await createImageBitmap(f);
      const size = 256, c = document.createElement("canvas");
      c.width = c.height = size;
      const ctx = c.getContext("2d");
      ctx.fillStyle = "#ffffff"; ctx.fillRect(0, 0, size, size);
      const side = Math.min(bmp.width, bmp.height);
      ctx.drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, size, size);
      const blob = await new Promise((res) => c.toBlob(res, "image/jpeg", 0.85));
      const { data: { user } } = await supabase.auth.getUser();
      const up = await supabase.storage.from("avatars").upload(`${user.id}/avatar.jpg`, blob, { upsert: true, contentType: "image/jpeg", cacheControl: "300" });
      if (up.error) throw up.error;
      const r = await supabase.rpc("set_avatar");
      if (r.error) throw r.error;
      setMsg("Picture updated."); await reload();
    } catch (x) { setErr(x.message || "Could not upload that picture."); }
    setBusy(false);
  }
  async function removePic() {
    setBusy(true); setErr(""); setMsg("");
    if (profile.avatar_path) await supabase.storage.from("avatars").remove([profile.avatar_path]);
    const { error } = await supabase.rpc("remove_avatar");
    setBusy(false);
    if (error) setErr(error.message); else { setMsg("Picture removed."); reload(); }
  }

  return (
    <div className="profiletab">
      <div className="profilehead">
        <Avatar path={profile.avatar_path} v={profile.avatar_v} name={profile.display_name} size={96} />
        <div>
          <label className="filebtn">
            <input type="file" accept="image/png,image/jpeg,image/webp" onChange={onFile} disabled={busy} />
            <span className="btn">{busy ? "Working…" : profile.avatar_path ? "Change picture" : "Upload picture"}</span>
          </label>
          {profile.avatar_path && <button disabled={busy} onClick={removePic}>Remove picture</button>}
          <p className="mute">Shown on your profile and to people who visit your public garden. Keep it friendly.</p>
        </div>
      </div>
      <label>Display name
        <span className="row">
          <input value={name} maxLength={24} onChange={(e) => setName(e.target.value)} />
          <button className="water" disabled={name.trim() === profile.display_name} onClick={saveName}>Save name</button>
        </span>
      </label>
      {err && <p role="alert">{err}</p>}
      {msg && <p role="status">{msg}</p>}
      <h3>Level</h3>
      <LevelBadge profile={profile} />
      {stats && (
        <>
          <h3>Stats</h3>
          <ul className="stats">
            <li><b>{stats.plants_owned}</b> of {stats.catalog_total} plants collected</li>
            <li><b>{stats.full_growth}</b> fully grown</li>
            <li><b>{stats.games_played}</b> mini-games played</li>
            <li><b>{stats.streak_days}</b> day mini-game streak</li>
            <li>Playing since <b>{new Date(stats.member_since).toLocaleDateString()}</b></li>
          </ul>
        </>
      )}
    </div>
  );
}

export default function ProfileModal({ profile, tab, onTab, onClose, reload, ready, newPlants }) {
  return (
    <Modal label="Your profile" onClose={onClose} large>
      <h2>{profile.display_name}</h2>
      <div className="tabs" role="tablist">
        <button role="tab" aria-pressed={tab === "profile"} onClick={() => onTab("profile")}>Profile</button>
        <button role="tab" aria-pressed={tab === "achievements"} onClick={() => onTab("achievements")}>Achievements{ready > 0 ? ` (${ready})` : ""}</button>
        <button role="tab" aria-pressed={tab === "collection"} onClick={() => onTab("collection")}>Collection{newPlants > 0 ? ` (${newPlants} new)` : ""}</button>
      </div>
      <div className="modalbody">
        {tab === "profile" && <ProfileTab profile={profile} reload={reload} />}
        {tab === "achievements" && <Achievements reload={reload} />}
        {tab === "collection" && <Collection reload={reload} profile={profile} />}
      </div>
    </Modal>
  );
}
