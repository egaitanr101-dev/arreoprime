-- =============================================================================
-- SOLO PARA PRUEBAS LOCALES (PostgreSQL sin Supabase). NO ejecutar en Supabase.
-- Simula lo mínimo que Supabase ya trae: roles anon/authenticated/service_role,
-- auth.users, auth.uid(), y las tablas de Storage con RLS activada.
-- Permite ejecutar sql/01…10 y sql/99 sin cambios.
-- =============================================================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;

-- Rol con el que PostgREST se conecta y luego cambia a anon/authenticated según el JWT (igual que en Supabase).
-- Contraseña solo para este entorno local de pruebas.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit password 'local-solo-pruebas';
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;

create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists storage;
grant usage on schema public, auth, storage, extensions to anon, authenticated, service_role;

create table if not exists auth.users (
  instance_id        uuid,
  id                 uuid primary key,
  aud                text,
  role               text,
  email              text unique,
  raw_app_meta_data  jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

-- Igual que la función de Supabase
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);
create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets (id),
  name       text,
  owner      uuid,
  created_at timestamptz default now()
);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
-- Supabase otorga estos privilegios; la RLS decide qué filas
grant select, insert, update, delete on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
