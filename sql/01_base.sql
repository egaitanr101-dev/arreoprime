-- =============================================================================
-- ArreoPrime Desk | TRANSPORTES SERVICE DESK
-- 01_base.sql — Extensiones, esquemas y privilegios por defecto
--
-- Ejecutar como rol "postgres" en el SQL Editor de Supabase, en orden 01 → 11.
-- Luego, solo en desarrollo: 90_datos_demo.sql (opcional) y 99_pruebas_seguridad.sql.
-- Proyecto NUEVO (los scripts no son idempotentes salvo donde se indica).
--
-- Esquemas:
--   public    → tablas, vistas de la aplicación y funciones RPC expuestas por la API
--   app       → funciones internas (autorización, reglas, SLA). NO se expone en la API.
--   reporting → vistas para reportes y Power BI (grano documentado)
-- =============================================================================
begin;

create extension if not exists pg_trgm with schema extensions;   -- búsqueda por texto
create extension if not exists pgcrypto with schema extensions;  -- gen_random_uuid (también nativo en PG13+)

create schema if not exists app;
create schema if not exists reporting;

revoke all on schema app from public;
grant usage on schema app to authenticated;        -- solo para evaluar funciones usadas en políticas RLS
revoke all on schema reporting from public;
grant usage on schema reporting to authenticated;

-- Por defecto, nada nuevo queda accesible para anon/authenticated:
-- cada permiso se otorga explícitamente en 07_rls.sql.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;
alter default privileges in schema reporting revoke all on tables from anon, authenticated;

commit;
