// Configuração pública do Supabase.
// A publishable key pode ser usada no navegador com RLS habilitado.
const DISTRITO_SUPABASE_URL = "https://zxapsoxexpykpqkapdgj.supabase.co";
const DISTRITO_SUPABASE_PUBLISHABLE_KEY = "sb_publishable_r7vZfpTYJLxTVXg51lCL4Q_se-3ElAt";

window.distritoSupabase = window.supabase.createClient(
  DISTRITO_SUPABASE_URL,
  DISTRITO_SUPABASE_PUBLISHABLE_KEY,
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  },
);
