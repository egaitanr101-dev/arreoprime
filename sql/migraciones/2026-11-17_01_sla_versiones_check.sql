-- =============================================================================
-- Migración 2026-11-17 #01 — Regla de vigencia de versiones de SLA
-- Motivo: el Editor SQL de Supabase ejecuta cada envío en UNA transacción, donde
-- now() es constante. Publicar una versión nueva en la misma transacción en que se
-- creó la anterior dejaba vigente_hasta = vigente_desde y violaba "vigente_hasta > vigente_desde".
-- Solo para proyectos instalados antes de esta fecha (sql/02_tablas.sql ya incluye el cambio).
-- =============================================================================
begin;
alter table public.sla_versiones drop constraint sla_versiones_check;
alter table public.sla_versiones add constraint sla_versiones_check
  check (vigente_hasta is null or vigente_hasta >= vigente_desde);
commit;
