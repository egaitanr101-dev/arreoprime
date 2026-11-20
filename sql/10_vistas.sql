-- =============================================================================
-- 10_vistas.sql — Vistas de la aplicación y de reportes / Power BI
--
-- Todas usan security_invoker = true: se ejecutan con los permisos de quien consulta,
-- por lo que la RLS se aplica igual que en las tablas. Un reporte o exportación no
-- puede contener filas que el usuario no pueda ver.
--
-- Grano (1 fila = …) documentado en cada vista para evitar duplicar montos:
-- nunca se unen dos tablas de hechos entre sí antes de agregar.
-- =============================================================================
begin;

/* ============ Vista principal de la aplicación (bandeja, portal, búsqueda) ============
   Grano: 1 fila por ticket visible para el usuario. */
create view public.v_tickets with (security_invoker = true) as
select
  t.id, t.numero, t.departamento_id, d.nombre as depto_nombre,
  t.solicitante_id, ps.nombre as solicitante_nombre, t.registrado_por, pr.nombre as registrado_por_nombre, t.canal,
  t.tipo_gestion_id, tg.nombre as tipo_nombre, t.categoria_id, c.nombre as categoria_nombre,
  t.asunto, t.descripcion, t.datos,
  t.prioridad_id, t.prioridad_sugerida, p.orden as prioridad_orden,
  t.estado_id, e.nombre as estado_nombre, e.orden as estado_orden, t.estado_previo,
  t.motivo_espera_id, me.nombre as motivo_espera_nombre,
  t.responsable_id, re.nombre as responsable_nombre,
  case when re.id is null then null when not re.activo then 'Inactivo' when not re.disponible then 'No disponible' end as responsable_alerta,
  t.cliente_id, cl.nombre as cliente_nombre, t.ruta_id, ru.nombre as ruta_nombre, t.factura, t.pedido, t.fecha_requerida,
  t.creado_at, t.primera_respuesta_at, t.asignado_at, t.resuelto_at, t.cerrado_at, t.rechazado_at,
  t.resolucion, t.motivo_rechazo_id, mr.nombre as motivo_rechazo_nombre,
  t.reaperturas, t.cierre_excepcional, t.anulado, t.anulado_motivo,
  round(extract(epoch from (coalesce(t.cerrado_at, t.rechazado_at, now()) - t.creado_at)) / 60)::integer as transcurrido_min,
  app.sla_evaluar(t.id) as sla,
  app.pendiente_info(t.id) is not null as pendiente_info,
  exists (select 1 from public.investigaciones i where i.ticket_id = t.id) as tiene_investigacion
from public.tickets t
join public.departamentos d on d.id = t.departamento_id
join public.tipos_gestion tg on tg.id = t.tipo_gestion_id
join public.categorias c on c.id = t.categoria_id
join public.prioridades p on p.id = t.prioridad_id
join public.estados e on e.id = t.estado_id
left join public.perfiles ps on ps.id = t.solicitante_id
left join public.perfiles pr on pr.id = t.registrado_por
left join public.perfiles re on re.id = t.responsable_id
left join public.motivos me on me.id = t.motivo_espera_id
left join public.motivos mr on mr.id = t.motivo_rechazo_id
left join public.clientes cl on cl.id = t.cliente_id
left join public.rutas ru on ru.id = t.ruta_id;

grant select on public.v_tickets to authenticated;

/* ============================== Esquema reporting ============================== */

-- Grano: 1 fila por ticket (sin textos libres). Hechos de conteo y tiempos.
create view reporting.v_tickets with (security_invoker = true) as
select
  t.id as ticket_id, t.numero, t.departamento_id, t.categoria_id, t.tipo_gestion_id, t.prioridad_id, t.estado_id,
  t.canal, t.solicitante_id, t.responsable_id, t.cliente_id, t.ruta_id,
  (t.datos ->> 'chofer') as chofer_id, (t.datos ->> 'ayudante') as ayudante_id,
  t.creado_at, (t.creado_at at time zone 'America/Costa_Rica')::date as fecha_creacion,
  t.primera_respuesta_at, t.asignado_at, t.resuelto_at, t.cerrado_at, t.rechazado_at,
  t.reaperturas, t.cierre_excepcional, t.anulado,
  e.abierto as esta_abierto,
  s.version as sla_version,
  (app.sla_evaluar(t.id) ->> 'global') as sla_estado_global
from public.tickets t
join public.estados e on e.id = t.estado_id
left join public.ticket_sla s on s.ticket_id = t.id;

-- Grano: 1 fila por ticket × métrica SLA. Medida: % cumplimiento = cumplidos / (cumplidos + incumplidos).
create view reporting.v_sla_metricas with (security_invoker = true) as
select t.id as ticket_id, t.departamento_id, t.prioridad_id, t.categoria_id, t.responsable_id,
       (t.creado_at at time zone 'America/Costa_Rica')::date as fecha_creacion,
       m.key as metrica, m.value ->> 'estado' as estado,
       (m.value ->> 'objetivo')::numeric as objetivo_min, (m.value ->> 'transcurrido')::numeric as transcurrido_min,
       (m.value ->> 'estado') in ('cumplido', 'incumplido') as medida_finalizada
from public.tickets t
cross join lateral jsonb_each(app.sla_evaluar(t.id) -> 'metricas') as m
where not t.anulado;

-- Grano: 1 fila por evento de historial.
create view reporting.v_historial with (security_invoker = true) as
select h.id as evento_id, h.ticket_id, h.ts, (h.ts at time zone 'America/Costa_Rica')::date as fecha,
       h.usuario_id, h.evento, h.detalle, h.visibilidad
from public.historial_tickets h;

-- Grano: 1 fila por diferencia. Saldos calculados desde el libro (cada movimiento cuenta una vez).
create view reporting.v_diferencias with (security_invoker = true) as
select d.id as diferencia_id, d.ticket_id, t.numero, t.categoria_id, t.estado_id as estado_ticket,
       d.num_liquidacion, d.ruta_id, d.fecha_operacion, d.chofer_id, d.ayudante_id, d.tipo_diferencia, d.medio_pago,
       d.monto_esperado, d.monto_recibido, d.monto_reportado, d.monto_diferencia,
       case when d.monto_diferencia > 0 then 'FALTANTE' when d.monto_diferencia < 0 then 'SOBRANTE' else 'SIN_DIFERENCIA' end as naturaleza,
       s.aclarado, s.recuperado, s.ajuste, s.pendiente,
       i.estado as investigacion_estado, i.resultado_id as investigacion_resultado,
       d.creado_at
from public.liquidacion_diferencias d
join public.tickets t on t.id = d.ticket_id
cross join lateral app.saldos_diferencia(d.id) as s
left join public.investigaciones i on i.ticket_id = d.ticket_id
where not t.anulado;

-- Grano: 1 fila por movimiento. Para sumar por tipo use tipo_efectivo y monto_efectivo
-- (una reversión resta del tipo que revierte).
create view reporting.v_movimientos with (security_invoker = true) as
select m.id as movimiento_id, m.diferencia_id, m.ticket_id, m.tipo, m.monto, m.revierte_id,
       coalesce(o.tipo, m.tipo) as tipo_efectivo,
       case when m.tipo = 'REVERSION' then -o.monto else m.monto end as monto_efectivo,
       m.usuario_id, m.creado_at, (m.creado_at at time zone 'America/Costa_Rica')::date as fecha
from public.movimientos_financieros m
left join public.movimientos_financieros o on o.id = m.revierte_id;

-- Grano: 1 fila por investigación.
create view reporting.v_investigaciones with (security_invoker = true) as
select i.id as investigacion_id, i.ticket_id, t.numero, t.categoria_id, i.estado, i.responsable_id, i.fecha_inicio,
       i.resultado_id, i.fecha_resolucion, i.concluida_por, i.reaperturas,
       case when i.fecha_resolucion is not null then round(extract(epoch from (i.fecha_resolucion - i.fecha_inicio)) / 86400, 2) end as dias_investigacion
from public.investigaciones i
join public.tickets t on t.id = i.ticket_id
where not t.anulado;

-- Grano: 1 fila por usuario de Transportes. Carga actual.
create view reporting.v_carga_responsable with (security_invoker = true) as
select p.id as responsable_id, p.nombre, p.rol_id, p.activo, p.disponible,
       count(t.id) filter (where e.abierto) as tickets_abiertos,
       count(t.id) filter (where t.resuelto_at is not null) as tickets_resueltos
from public.perfiles p
left join public.tickets t on t.responsable_id = p.id and not t.anulado
left join public.estados e on e.id = t.estado_id
where p.rol_id in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES')
group by p.id, p.nombre, p.rol_id, p.activo, p.disponible;

grant select on all tables in schema reporting to authenticated;

/* ============================== Rol de Power BI ==============================
   Power BI se conecta con un usuario de base de datos (no pasa por Supabase Auth),
   por lo que se le da acceso de solo lectura al nivel de Gerencia, explícito y limitado.
   Activar el inicio de sesión manualmente (fuera del control de versiones):
     alter role powerbi_lector with login password '<contraseña fuerte>';
   No tiene acceso a comentarios, evidencias, hallazgos ni notificaciones. */
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'powerbi_lector') then
    create role powerbi_lector nologin;
  end if;
end $$;
grant usage on schema reporting, public, app to powerbi_lector;
grant select on all tables in schema reporting to powerbi_lector;
grant execute on function app.sla_evaluar(uuid), app.minutos_habiles(timestamptz, timestamptz),
                          app.minutos_netos(uuid, timestamptz, timestamptz), app.saldos_diferencia(uuid) to powerbi_lector;
grant select (id, nombre, rol_id, departamento_id, activo, disponible) on public.perfiles to powerbi_lector;
do $$
declare t text;
begin
  foreach t in array array['tickets', 'ticket_sla', 'sla_pausas', 'sla_excepciones', 'historial_tickets', 'liquidacion_diferencias',
                           'movimientos_financieros', 'investigaciones', 'estados', 'departamentos', 'categorias', 'tipos_gestion',
                           'prioridades', 'clientes', 'rutas', 'colaboradores', 'resultados_investigacion', 'calendario_laboral',
                           'feriados', 'perfiles'] loop
    if t <> 'perfiles' then execute format('grant select on public.%I to powerbi_lector', t); end if;
    execute format('create policy powerbi_lectura on public.%I for select to powerbi_lector using (true)', t);
  end loop;
end $$;

commit;
