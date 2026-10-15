// Connexion à la base Supabase.
// Supabase > Project Settings > API : copier "Project URL" et la clé "anon public".
// La clé anon est faite pour être publique : la sécurité est gérée dans schema.sql.
// Tant que ces deux valeurs sont vides, le formulaire tourne en MODE DÉMO (rien n'est enregistré).
window.RESEAU_CONFIG = {
  supabaseUrl: '',
  supabaseAnonKey: '',
};
