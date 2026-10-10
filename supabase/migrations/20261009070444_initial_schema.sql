-- FoodScope: Supabase schema (draft v0.1)
-- Paste into the Supabase SQL editor, or save as a migration with the Supabase CLI.
--
-- Part 1 is everything the Sunday MVP needs.
-- Part 2 is commented out: add it after Sunday.
--
-- Access model: the app only ever READS published data with the public anon key.
-- All writes happen in the Supabase dashboard (or with the service-role key in scripts),
-- so nothing in the app can change the research.

-- =====================================================================
-- PART 1: Sunday MVP
-- =====================================================================

-- How an additive is treated in one jurisdiction.
create type regulatory_status as enum (
  'permitted',          -- allowed, no special conditions worth flagging
  'restricted',         -- allowed only in some foods or below a limit
  'warning_required',   -- allowed, but the label must carry a warning (e.g. EU azo dyes)
  'not_permitted',      -- not on the approved list / banned
  'ban_scheduled'       -- currently allowed, ban takes effect on effective_date
);

-- Countries, regions and states the app compares.
create table jurisdictions (
  code        text primary key,          -- 'US', 'US-CA', 'EU', 'UK', 'CA'
  name        text not null,             -- 'United States', 'California', ...
  regulator   text,                      -- 'FDA', 'EFSA / European Commission', ...
  sort_order  int  not null default 0
);

-- One row per additive the app can recognise.
create table additives (
  id             text primary key,               -- slug: 'red-40', 'titanium-dioxide'
  name           text not null,                  -- display name: 'Red 40 (Allura Red AC)'
  e_number       text,                           -- 'E129'
  ins_number     text,                           -- '129'
  category       text,                           -- 'colour', 'flour treatment agent', ...
  synonyms       text[] not null default '{}',   -- lower-case names to find in ingredient text
  off_tags       text[] not null default '{}',   -- Open Food Facts additives_tags, e.g. 'en:e129'
  summary        text,                           -- one-line takeaway for the result card
  explanation    text,                           -- approved long explanation (markdown)
  published      boolean not null default false, -- only published rows reach the app
  last_reviewed  date,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- The status of one additive in one jurisdiction.
create table regulations (
  id                 bigint generated always as identity primary key,
  additive_id        text not null references additives(id) on delete cascade,
  jurisdiction_code  text not null references jurisdictions(code),
  status             regulatory_status not null,
  conditions         text,   -- e.g. 'Warning label required: "May have an adverse effect on activity and attention in children."'
  reason             text,   -- why the regulator decided this, in plain language
  effective_date     date,   -- when the current status took (or takes) effect
  unique (additive_id, jurisdiction_code)
);

-- Every document the research cites.
create table sources (
  id              bigint generated always as identity primary key,
  title           text not null,
  url             text,
  publisher       text,          -- 'EFSA', 'Health Canada', 'FDA', ...
  published_date  date,
  accessed_date   date
);

-- Which sources back an additive's explanation, and optionally a specific regulation row.
create table citations (
  id             bigint generated always as identity primary key,
  additive_id    text   not null references additives(id) on delete cascade,
  source_id      bigint not null references sources(id) on delete cascade,
  regulation_id  bigint references regulations(id) on delete cascade,
  note           text   -- what this source supports, e.g. 'EFSA 2021 genotoxicity opinion'
);

create index on regulations (additive_id);
create index on citations (additive_id);

-- Keep updated_at current.
create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger additives_updated_at
  before update on additives
  for each row execute function set_updated_at();

-- One row per published additive with everything the result card needs,
-- so the app can load the whole catalogue in a single request at launch
-- and match ingredients on the phone.
create view additive_cards
with (security_invoker = true) as
select
  a.id, a.name, a.e_number, a.ins_number, a.category,
  a.synonyms, a.off_tags, a.summary, a.explanation, a.last_reviewed,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'jurisdiction', j.code, 'jurisdiction_name', j.name,
             'status', r.status, 'conditions', r.conditions,
             'reason', r.reason, 'effective_date', r.effective_date)
           order by j.sort_order)
    from regulations r join jurisdictions j on j.code = r.jurisdiction_code
    where r.additive_id = a.id), '[]'::jsonb) as regulations,
  coalesce((
    select jsonb_agg(distinct jsonb_build_object(
             'title', s.title, 'url', s.url, 'publisher', s.publisher))
    from citations c join sources s on s.id = c.source_id
    where c.additive_id = a.id), '[]'::jsonb) as sources
from additives a
where a.published;

-- Row-level security: public read-only, published rows only.
alter table jurisdictions enable row level security;
alter table additives     enable row level security;
alter table regulations   enable row level security;
alter table sources       enable row level security;
alter table citations     enable row level security;

create policy "public read" on jurisdictions for select to anon, authenticated using (true);
create policy "public read published" on additives for select to anon, authenticated using (published);
create policy "public read published" on regulations for select to anon, authenticated
  using (exists (select 1 from additives a where a.id = additive_id and a.published));
create policy "public read" on sources for select to anon, authenticated using (true);
create policy "public read published" on citations for select to anon, authenticated
  using (exists (select 1 from additives a where a.id = additive_id and a.published));

grant select on additive_cards to anon, authenticated;

-- Cache of AI-written product summaries (one Claude call per product, ever).
-- Written only by the summarize-product Edge Function using the service-role key.
create table product_summaries (
  barcode        text primary key,
  product_name   text,
  additive_ids   text[] not null default '{}',   -- the matched additives the summary was built from
  summary        text not null,
  model          text,
  created_at     timestamptz not null default now()
);
alter table product_summaries enable row level security;
create policy "public read" on product_summaries for select to anon, authenticated using (true);

-- Starting jurisdictions (edit to match the countries you choose).
insert into jurisdictions (code, name, regulator, sort_order) values
  ('US',    'United States',  'FDA',                          1),
  ('US-CA', 'California',     'California Legislature',       2),
  ('EU',    'European Union', 'European Commission / EFSA',   3),
  ('UK',    'United Kingdom', 'Food Standards Agency',        4),
  ('CA',    'Canada',         'Health Canada',                5);

-- =====================================================================
-- PART 2: after Sunday (uncomment when needed)
-- =====================================================================

-- -- Cache of products looked up from Open Food Facts / USDA, so repeat scans are instant
-- -- and you can see which barcodes people scan.
-- create table products (
--   barcode          text primary key,
--   name             text,
--   brand            text,
--   image_url        text,
--   ingredients_text text,
--   off_tags         text[] not null default '{}',
--   data_source      text,          -- 'openfoodfacts', 'usda', 'user_photo'
--   fetched_at       timestamptz not null default now()
-- );
--
-- -- "Report a problem" from the app. Anyone can insert; nobody can read through the API.
-- create table reports (
--   id          bigint generated always as identity primary key,
--   barcode     text,
--   additive_id text references additives(id),
--   message     text not null check (length(message) <= 2000),
--   created_at  timestamptz not null default now()
-- );
-- alter table reports enable row level security;
-- create policy "anyone can report" on reports for insert to anon, authenticated with check (true);
--
-- -- Ingredients seen in scans that matched nothing: your research to-do list.
-- create table unmatched_ingredients (
--   ingredient  text primary key,
--   seen_count  int not null default 1,
--   last_seen   timestamptz not null default now()
-- );
--
-- -- Longer research passages for AI retrieval, once there are too many additives to hand-write.
-- create extension if not exists vector;
-- create table research_passages (
--   id           bigint generated always as identity primary key,
--   additive_id  text references additives(id) on delete cascade,
--   source_id    bigint references sources(id),
--   content      text not null,
--   embedding    vector(384)     -- 384 dimensions matches Supabase's gte-small model
-- );
-- create index on research_passages using hnsw (embedding vector_cosine_ops);
--
-- -- Scan history per signed-in user (only if you add accounts).
-- create table scans (
--   id         bigint generated always as identity primary key,
--   user_id    uuid not null references auth.users(id) on delete cascade,
--   barcode    text not null,
--   matched    text[] not null default '{}',
--   scanned_at timestamptz not null default now()
-- );
-- alter table scans enable row level security;
-- create policy "own scans" on scans for all to authenticated
--   using (user_id = auth.uid()) with check (user_id = auth.uid());
