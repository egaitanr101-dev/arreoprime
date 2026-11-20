-- =============================================================================
-- 11_cron.sql — Procesos programados (pg_cron)
-- Requisito: habilitar la extensión pg_cron en Supabase (Database → Extensions).
-- Cada 5 minutos: auto-cierre de resueltos (D-08), alertas de SLA y expiración
-- de evidencias preparadas que nunca se cargaron.
-- Este script es idempotente.
-- =============================================================================
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'apd-procesos';
select cron.schedule('apd-procesos', '*/5 * * * *', $$select app.procesos_programados();$$);
