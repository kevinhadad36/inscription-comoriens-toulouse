-- =====================================================================
-- Réseau des Comoriens de Toulouse — schéma de la base (Supabase / Postgres)
-- À coller tel quel dans Supabase > SQL Editor > New query > Run.
-- Le script peut être relancé sans casser l'existant.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Domaines d'activité (liste de référence, modifiable sans toucher au code)
-- ---------------------------------------------------------------------
create table if not exists public.domaines (
  slug   text primary key,
  libelle text not null,
  ordre  int  not null default 100
);

insert into public.domaines (slug, libelle, ordre) values
  ('batiment',      'Bâtiment, travaux, plomberie, électricité', 10),
  ('auto',          'Mécanique, automobile, transport',          20),
  ('cuisine',       'Cuisine, traiteur, plats faits maison',     30),
  ('beaute',        'Coiffure, beauté, couture',                 40),
  ('sante',         'Santé, aide à la personne',                 50),
  ('education',     'Enseignement, soutien scolaire, garde d''enfants', 60),
  ('compta',        'Comptabilité, banque, finance, assurance',  70),
  ('juridique',     'Juridique, administratif, démarches',       80),
  ('informatique',  'Informatique, numérique, développement',    90),
  ('image',         'Graphisme, photo, vidéo, communication',    100),
  ('commerce',      'Commerce, vente, import-export',            110),
  ('evenementiel',  'Événementiel, musique, animation',          120),
  ('immobilier',    'Immobilier, logement',                      130),
  ('tourisme',      'Tourisme, hôtellerie, restauration',        140),
  ('sport',         'Sport, coaching',                           150),
  ('autre',         'Autre',                                     999)
on conflict (slug) do update set libelle = excluded.libelle, ordre = excluded.ordre;

-- ---------------------------------------------------------------------
-- 2. Membres (une ligne = une personne inscrite via le formulaire)
-- ---------------------------------------------------------------------
create table if not exists public.membres (
  id               uuid primary key default gen_random_uuid(),
  cree_le          timestamptz not null default now(),
  modifie_le       timestamptz not null default now(),

  -- Identité
  prenom           text not null check (length(trim(prenom)) between 1 and 80),
  nom              text not null check (length(trim(nom)) between 1 and 80),
  sexe             text not null check (sexe in ('femme', 'homme')),
  -- Soit la date complète, soit seulement l'année : l'âge est recalculé à chaque lecture.
  date_naissance   date,
  annee_naissance  int check (annee_naissance between 1900 and 2100),

  -- Localisation (centre de la commune seulement, jamais l'adresse exacte)
  commune          text not null,
  code_postal      text,
  code_insee       text,
  quartier         text,
  lat              double precision,
  lng              double precision,
  rayon_km         int check (rayon_km in (0, 5, 10, 20, 50)),  -- 0 = sur place uniquement

  -- Activité
  domaine          text not null references public.domaines (slug),
  metier           text not null check (length(trim(metier)) between 1 and 120),
  situation        text check (situation in ('salarie', 'independant', 'etudiant', 'recherche', 'retraite', 'autre')),
  description      text check (length(description) <= 600),
  cherche_stage    boolean not null default false,  -- étudiant / jeune qui cherche stage ou emploi

  -- Contact (jamais affiché publiquement : la mise en relation passe par l'équipe)
  telephone        text,
  email            text,
  whatsapp         boolean not null default false,

  -- Visibilité et consentement
  visibilite       text not null default 'anonyme' check (visibilite in ('public', 'anonyme')),
  consentement     boolean not null check (consentement),
  consentement_le  timestamptz not null default now(),

  -- Modération : rien n'apparaît sur le site avant validation par l'équipe
  statut           text not null default 'en_attente' check (statut in ('en_attente', 'valide', 'refuse')),

  -- Jeton secret remis à la personne pour modifier ou supprimer sa fiche plus tard
  -- (page « modifier mon profil » à construire avec le site)
  jeton_edition    uuid not null default gen_random_uuid() unique,

  constraint naissance_renseignee check (date_naissance is not null or annee_naissance is not null),
  constraint contact_renseigne   check (coalesce(telephone, '') <> '' or coalesce(email, '') <> '')
);

create index if not exists membres_domaine_idx on public.membres (domaine);
create index if not exists membres_statut_idx  on public.membres (statut);
create index if not exists membres_commune_idx on public.membres (code_insee);

-- ---------------------------------------------------------------------
-- 3. Âge calculé automatiquement (jamais stocké, donc toujours à jour)
-- ---------------------------------------------------------------------
create or replace function public.age_membre(m public.membres)
returns int language sql stable as $$
  select case
    when m.date_naissance is not null
      then extract(year from age(current_date, m.date_naissance))::int
    else extract(year from current_date)::int - m.annee_naissance
  end;
$$;

-- ---------------------------------------------------------------------
-- 4. Sécurité (Row Level Security)
--    - Le public (clé "anon") n'a AUCUN accès direct à la table membres.
--    - Il s'inscrit uniquement via la fonction inscrire_membre() ci-dessous,
--      qui force statut = 'en_attente' et renvoie le jeton de modification.
--    - Lecture publique uniquement via la vue annuaire_public (section 5).
-- ---------------------------------------------------------------------
alter table public.membres  enable row level security;
alter table public.domaines enable row level security;

revoke all on public.membres from anon, authenticated;

drop policy if exists "lecture domaines" on public.domaines;
create policy "lecture domaines" on public.domaines
  for select to anon, authenticated using (true);

create or replace function public.inscrire_membre(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  j uuid;
begin
  if coalesce((p->>'consentement')::boolean, false) is not true then
    raise exception 'Consentement obligatoire';
  end if;

  insert into public.membres (
    prenom, nom, sexe, date_naissance, annee_naissance,
    commune, code_postal, code_insee, quartier, lat, lng, rayon_km,
    domaine, metier, situation, description, cherche_stage,
    telephone, email, whatsapp, visibilite, consentement
  ) values (
    trim(p->>'prenom'), trim(p->>'nom'), p->>'sexe',
    nullif(p->>'date_naissance', '')::date, nullif(p->>'annee_naissance', '')::int,
    trim(p->>'commune'), p->>'code_postal', p->>'code_insee', nullif(trim(p->>'quartier'), ''),
    nullif(p->>'lat', '')::double precision, nullif(p->>'lng', '')::double precision,
    coalesce(nullif(p->>'rayon_km', '')::int, 10),
    p->>'domaine', trim(p->>'metier'), nullif(p->>'situation', ''),
    nullif(trim(p->>'description'), ''), coalesce((p->>'cherche_stage')::boolean, false),
    nullif(trim(p->>'telephone'), ''), nullif(lower(trim(p->>'email')), ''),
    coalesce((p->>'whatsapp')::boolean, false),
    coalesce(p->>'visibilite', 'anonyme'), true
  )
  returning jeton_edition into j;

  return j;
end;
$$;

revoke all on function public.inscrire_membre(jsonb) from public;
grant execute on function public.inscrire_membre(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Annuaire public : ce que le site et la carte pourront afficher
--    Pas d'âge, pas de téléphone, pas d'e-mail, pas de date de naissance.
--    Fiches anonymes : ni nom ni prénom.
-- ---------------------------------------------------------------------
create or replace view public.annuaire_public as
select
  m.id,
  case when m.visibilite = 'public' then m.prenom || ' ' || upper(left(m.nom, 1)) || '.' else null end as nom_affiche,
  m.visibilite,
  m.sexe,
  m.commune,
  m.quartier,
  -- coordonnées arrondies (~1 km) pour ne pas pointer un domicile
  round(m.lat::numeric, 2)::double precision as lat,
  round(m.lng::numeric, 2)::double precision as lng,
  m.rayon_km,
  m.domaine,
  d.libelle as domaine_libelle,
  m.metier,
  m.situation,
  m.description,
  m.cherche_stage
from public.membres m
join public.domaines d on d.slug = m.domaine
where m.statut = 'valide';

grant select on public.annuaire_public to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Vue d'administration (équipe uniquement, via le tableau de bord Supabase)
-- ---------------------------------------------------------------------
create or replace view public.membres_admin
with (security_invoker = true) as
select m.*, public.age_membre(m) as age, d.libelle as domaine_libelle
from public.membres m
join public.domaines d on d.slug = m.domaine;

revoke all on public.membres_admin from anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Horodatage des modifications
-- ---------------------------------------------------------------------
create or replace function public.touch_modifie_le()
returns trigger language plpgsql as $$
begin
  new.modifie_le := now();
  return new;
end;
$$;

drop trigger if exists membres_modifie_le on public.membres;
create trigger membres_modifie_le before update on public.membres
  for each row execute function public.touch_modifie_le();
