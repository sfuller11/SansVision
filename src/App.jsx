import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import Landing from "./Landing";
import Garden from "./Garden";

export default function App() {
  const [session, setSession] = useState(undefined); // undefined = still checking

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_event, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  if (session === undefined) return <main><p className="mute">Loading…</p></main>;
  return session ? <Garden session={session} /> : <Landing />;
}
