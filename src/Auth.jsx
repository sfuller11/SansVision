import { useState } from "react";
import { supabase } from "./supabaseClient";

export function AuthCard({ startMode = "signin", inputRef }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState(startMode);
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setMsg("");
    const { data, error } =
      mode === "signin"
        ? await supabase.auth.signInWithPassword({ email, password })
        : await supabase.auth.signUp({ email, password });
    if (error) setMsg(error.message);
    else if (mode === "signup" && !data.session) setMsg("Check your email to confirm your account, then sign in.");
    setBusy(false);
  }

  return (
    <div className="authcard" id="join">
      <form onSubmit={submit}>
        <div className="row" style={{ justifyContent: "center", margin: "16px 0 10px" }}>
          <input ref={inputRef} type="email" required value={email} placeholder="Email" aria-label="Email" onChange={(e) => setEmail(e.target.value)} />
          <input type="password" required minLength={6} value={password} placeholder="Password" aria-label="Password" onChange={(e) => setPassword(e.target.value)} />
          <button className="water" disabled={busy}>{mode === "signin" ? "Sign in" : "Create account"}</button>
        </div>
      </form>
      {msg && <p role="alert">{msg}</p>}
      <button onClick={() => setMode(mode === "signin" ? "signup" : "signin")}>
        {mode === "signin" ? "New here? Create an account" : "Have an account? Sign in"}
      </button>
    </div>
  );
}
