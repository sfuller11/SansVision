import { createClient } from "@supabase/supabase-js";

// The anon/publishable key is safe in browser code. NEVER put the service_role/secret key here.
export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
);
