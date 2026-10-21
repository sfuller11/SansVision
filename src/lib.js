import { supabase } from "./supabaseClient";
export const STAGES = ["Cutting", "Young leaves", "Rosette", "First pup", "Mature clump"];
// Plants with 20 sizes spread the same five growth phases across 20 sizes.
export const stageName = (p) => STAGES[Math.min(4, Math.floor(((p.stage - 1) / p.max_stage) * 5))];
// The server calculates moisture. These labels only describe it.
export const moistureLabel = (p) =>
  p.moisture >= 70 ? "Hydrated" : p.moisture >= 35 ? "Healthy" : p.moisture >= 10 ? "Thirsty, growing slowly" : "Very dry, growth paused";
export const moodOf = (p) => (p.moisture >= 35 ? "happy" : p.moisture >= 10 ? "thirsty" : "dry");
export const imgSrc = (p) => `/plants/${p.type}_stage${p.stage}.png`;
// "23h" or "40m" while a double-XP boost is active, otherwise null. Display only: the server decides.
export function boostLeft(p) {
  if (!p.boost_until) return null;
  const ms = Date.parse(p.boost_until) - Date.now();
  if (ms <= 0) return null;
  return ms >= 3600000 ? `${Math.floor(ms / 3600000)}h` : `${Math.max(1, Math.round(ms / 60000))}m`;
}
// "45m", "6.5h", "2d 4h". Display only: the server works out the real numbers.
export function fmtHours(h) {
  if (h == null) return "";
  if (h < 1) return `${Math.max(1, Math.round(h * 60))}m`;
  if (h < 10) return `${Math.round(h * 10) / 10}h`;
  if (h < 48) return `${Math.round(h)}h`;
  return `${Math.floor(h / 24)}d ${Math.round(h % 24)}h`;
}

// Public picture address for a player's avatar (the ?v= number changes when they upload a new one).
export const avatarUrl = (path, v) => (path ? `${supabase.storage.from("avatars").getPublicUrl(path).data.publicUrl}?v=${v ?? 0}` : null);
const TIERS = { basic: "Basic Discovery", selective: "Selective Discovery", collector: "Collector Discovery" };
export function sourceLabel(src) {
  if (!src) return "";
  if (src === "founder") return "Starter plant";
  if (src === "admin") return "Admin grant";
  if (src === "targeted") return "Targeted unlock";
  if (src.startsWith("discovery:")) return TIERS[src.slice(10)] ?? "Discovery";
  return src;
}
