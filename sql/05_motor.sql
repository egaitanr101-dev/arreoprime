-- =============================================================================
-- 05_motor.sql — Motor interno: SLA en horas hábiles, historial, notificaciones,
-- auditoría, saldos financieros y utilidades de reglas de negocio.
-- Funciones del esquema "app": no expuestas por la API.
-- =============================================================================
begin;

/* ---------- Utilidades ---------- */
create or replace function app.texto(p_valor text, p_min integer, p_campo text)
returns text language plpgsql set search_path = '' as $$
declare v text := trim(coalesce(p_valor, ''));
begin
  if char_length(v) < p_min then
    perform app.error('VALIDACION', p_campo || ' es obligatorio (mínimo ' || p_min || ' caracteres).');
  end if;
  if char_length(v) > 4000 then perform app.error('VALIDACION', p_campo || ' es demasiado largo.'); end if;
  return v;
end $$;

create or replace function app.nombre_estado(p_estado text)
returns text language sql stable set search_path = '' as $$
  select nombre from public.estados where id = p_estado
$$;

create or replace function app.catalogo_valido(p_catalogo text, p_valor text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_catalogo
    when 'clientes'  then exists (select 1 from public.clientes where id = p_valor and activo)
    when 'rutas'     then exists (select 1 from public.rutas where id = p_valor and activo)
    when 'choferes'  then exists (select 1 from public.colaboradores where id = p_valor and tipo = 'CHOFER' and activo)
    when 'ayudantes' then exists (select 1 from public.colaboradores where id = p_valor and tipo = 'AYUDANTE' and activo)
    when 'vehiculos' then exists (select 1 from public.vehiculos where id = p_valor and activo)
    when 'bodegas'   then exists (select 1 from public.bodegas where id = p_valor and activo)
    when 'unidades'  then exists (select 1 from public.unidades_medida where id = p_valor and activo)
    else false
  end
$$;

create or replace function app.config_valor(p_clave text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select valor from public.configuracion where clave = p_clave
$$;

/* ---------- Horas hábiles (Costa Rica) ---------- */
create or replace function app.minutos_habiles(p_desde timestamptz, p_hasta timestamptz)
returns numeric language sql stable set search_path = '' as $$
  select case
    when p_desde is null or p_hasta is null or p_hasta <= p_desde then 0::numeric
    else coalesce((
      select sum(greatest(0::numeric, extract(epoch from (
               least(p_hasta, (g.d + c.hora_fin) at time zone 'America/Costa_Rica')
             - greatest(p_desde, (g.d + c.hora_inicio) at time zone 'America/Costa_Rica'))) / 60))
      from generate_series(
             ((p_desde at time zone 'America/Costa_Rica')::date)::timestamp,
             ((p_hasta at time zone 'America/Costa_Rica')::date)::timestamp,
             interval '1 day') as g(d)
      join public.calendario_laboral c on c.dia_semana = extract(dow from g.d)::smallint
      where not exists (select 1 from public.feriados f where f.fecha = g.d::date)
    ), 0)
  end
$$;

/** Días hábiles completos posteriores al día de p_desde, hasta el día de p_hasta inclusive */
create or replace function app.dias_habiles(p_desde timestamptz, p_hasta timestamptz)
returns integer language sql stable set search_path = '' as $$
  select count(*)::integer
  from generate_series(
         ((p_desde at time zone 'America/Costa_Rica')::date + 1)::timestamp,
         ((p_hasta at time zone 'America/Costa_Rica')::date)::timestamp,
         interval '1 day') as g(d)
  join public.calendario_laboral c on c.dia_semana = extract(dow from g.d)::smallint
  where not exists (select 1 from public.feriados f where f.fecha = g.d::date)
$$;

/** Minutos hábiles descontando pausas justificadas del ticket */
create or replace function app.minutos_netos(p_ticket uuid, p_desde timestamptz, p_hasta timestamptz)
returns numeric language sql stable set search_path = '' as $$
  select greatest(0::numeric, app.minutos_habiles(p_desde, p_hasta) - coalesce((
    select sum(app.minutos_habiles(greatest(p.inicio, p_desde), least(coalesce(p.fin, now()), p_hasta)))
    from public.sla_pausas p
    where p.ticket_id = p_ticket), 0))
$$;

/** Copia los objetivos de la versión de SLA (vigente o indicada) al ticket */
create or replace function app.sla_snapshot(p_ticket uuid, p_categoria text, p_prioridad text, p_version integer default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_ver public.sla_versiones;
  v_val public.sla_valores;
begin
  if p_version is null then
    select * into v_ver from public.sla_versiones where vigente_hasta is null;
  else
    select * into v_ver from public.sla_versiones where version = p_version;
  end if;
  if not found then return; end if;   -- sin SLA configurado: el ticket queda "Sin SLA" (no se inventan tiempos)
  select * into v_val from public.sla_valores where version = v_ver.version and prioridad_id = p_prioridad and categoria_id = p_categoria;
  if not found then
    select * into v_val from public.sla_valores where version = v_ver.version and prioridad_id = p_prioridad and categoria_id is null;
  end if;
  if not found then return; end if;
  insert into public.ticket_sla (ticket_id, version, prioridad_id, obj_primera_respuesta, obj_asignacion, obj_resolucion, horas_maximo_atencion, umbral)
  values (p_ticket, v_ver.version, p_prioridad, v_val.minutos_primera_respuesta, v_val.minutos_asignacion, v_val.minutos_resolucion, v_val.horas_maximo_atencion, v_ver.umbral)
  on conflict (ticket_id) do update set
    prioridad_id = excluded.prioridad_id, obj_primera_respuesta = excluded.obj_primera_respuesta,
    obj_asignacion = excluded.obj_asignacion, obj_resolucion = excluded.obj_resolucion,
    horas_maximo_atencion = excluded.horas_maximo_atencion, umbral = excluded.umbral;
end $$;

/** Semáforo SLA del ticket (seguridad del invocador: respeta RLS) */
create or replace function app.sla_evaluar(p_ticket uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  t public.tickets;
  s public.ticket_sla;
  v_finalizado boolean;
  v_pausado boolean;
  v_m jsonb := '{}'::jsonb;
  v_clave text;
  v_obj numeric;
  v_fin_at timestamptz;
  v_congelado numeric;
  v_trans numeric;
  v_pct numeric;
  v_estado text;
  v_rank integer;
  v_mejor integer := 0;
  v_foco jsonb;
  v_global text;
begin
  select * into t from public.tickets where id = p_ticket;
  if not found then return null; end if;
  select * into s from public.ticket_sla where ticket_id = p_ticket;
  if not found then
    return jsonb_build_object('global', 'sin', 'metricas', '{}'::jsonb, 'pausado', false, 'orden', 60000000);
  end if;
  v_finalizado := t.anulado or t.estado_id in ('RECHAZADO', 'CERRADO') or t.cierre_excepcional;
  v_pausado := exists (select 1 from public.sla_pausas where ticket_id = p_ticket and fin is null);

  foreach v_clave in array array['primera_respuesta', 'asignacion', 'resolucion'] loop
    v_obj := case v_clave when 'primera_respuesta' then s.obj_primera_respuesta when 'asignacion' then s.obj_asignacion else s.obj_resolucion end;
    v_fin_at := case v_clave when 'primera_respuesta' then t.primera_respuesta_at when 'asignacion' then t.asignado_at else t.resuelto_at end;
    v_congelado := case v_clave when 'primera_respuesta' then s.min_primera_respuesta when 'asignacion' then s.min_asignacion else s.min_resolucion end;

    if exists (select 1 from public.sla_excepciones e where e.ticket_id = p_ticket and e.metrica = v_clave) then
      v_m := v_m || jsonb_build_object(v_clave, jsonb_build_object('estado', 'exceptuado', 'objetivo', v_obj));
    elsif v_fin_at is null and v_finalizado then
      v_m := v_m || jsonb_build_object(v_clave, jsonb_build_object('estado', 'na', 'objetivo', v_obj, 'excluido', t.cierre_excepcional));
    elsif v_fin_at is not null then
      v_trans := coalesce(v_congelado, app.minutos_netos(p_ticket, t.creado_at, v_fin_at));
      v_estado := case when v_trans <= v_obj then 'cumplido' else 'incumplido' end;
      v_m := v_m || jsonb_build_object(v_clave, jsonb_build_object('estado', v_estado, 'objetivo', v_obj, 'transcurrido', round(v_trans, 1)));
    else
      v_trans := app.minutos_netos(p_ticket, t.creado_at, now());
      v_pct := case when v_obj > 0 then v_trans / v_obj else 0 end;
      v_estado := case when v_pct >= 1 then 'rojo' when v_pct >= s.umbral then 'amarillo' else 'verde' end;
      v_m := v_m || jsonb_build_object(v_clave, jsonb_build_object('estado', v_estado, 'objetivo', v_obj, 'transcurrido', round(v_trans, 1),
                                                                   'restante', round(v_obj - v_trans, 1), 'pausado', v_pausado));
      v_rank := case v_estado when 'rojo' then 3 when 'amarillo' then 2 else 1 end;
      if v_rank > v_mejor or (v_rank = v_mejor and (v_obj - v_trans) < (v_foco ->> 'restante')::numeric) then
        v_mejor := v_rank;
        v_foco := jsonb_build_object('metrica', v_clave, 'estado', v_estado, 'restante', round(v_obj - v_trans, 1));
      end if;
    end if;
  end loop;

  if v_mejor > 0 then v_global := v_foco ->> 'estado';
  elsif exists (select 1 from jsonb_each(v_m) where value ->> 'estado' = 'incumplido') then
    v_global := 'incumplido';
    v_foco := (select jsonb_build_object('metrica', key, 'estado', 'incumplido') from jsonb_each(v_m) where value ->> 'estado' = 'incumplido' limit 1);
  elsif exists (select 1 from jsonb_each(v_m) where value ->> 'estado' = 'cumplido') then v_global := 'cumplido';
  else v_global := 'na';
  end if;

  return jsonb_build_object(
    'global', v_global, 'foco', v_foco, 'metricas', v_m, 'pausado', v_pausado, 'version', s.version,
    'orden', (case v_global when 'rojo' then 0 when 'amarillo' then 1 when 'verde' then 2 when 'incumplido' then 3 when 'cumplido' then 4 else 5 end) * 10000000
             + coalesce((v_foco ->> 'restante')::numeric, 0));
end $$;

/* ---------- Historial, auditoría y notificaciones ---------- */
create or replace function app.hist(p_ticket uuid, p_usuario uuid, p_evento text, p_detalle text, p_visibilidad text default 'PUBLICO')
returns void language sql security definer set search_path = '' as $$
  insert into public.historial_tickets (ticket_id, usuario_id, evento, detalle, visibilidad)
  values (p_ticket, p_usuario, p_evento, p_detalle, p_visibilidad);
$$;

create or replace function app.auditar(p_usuario uuid, p_ambito text, p_accion text, p_detalle text, p_ticket uuid default null, p_datos jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.auditoria (usuario_id, ambito, accion, detalle, ticket_id, datos)
  values (p_usuario, p_ambito, p_accion, p_detalle, p_ticket, p_datos);
$$;

create or replace function app.supervisores()
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(id), '{}') from public.perfiles where activo and rol_id = 'SUPERVISOR_TRANSPORTES'
$$;

/** Inserta notificaciones respetando preferencias; nunca al propio actor ni a usuarios inactivos */
create or replace function app.notificar(p_usuarios uuid[], p_actor uuid, p_evento text, p_ticket uuid, p_texto text)
returns void language sql security definer set search_path = '' as $$
  insert into public.notificaciones (usuario_id, evento, ticket_id, texto)
  select distinct x.u, p_evento, p_ticket, p_texto
  from unnest(p_usuarios) as x(u)
  join public.perfiles p on p.id = x.u and p.activo
  where x.u is distinct from p_actor
    and not exists (select 1 from public.preferencias_notificacion pn
                    where pn.usuario_id = x.u and pn.evento = p_evento and not pn.activo);
$$;

/* ---------- Reglas de ticket ---------- */
create or replace function app.transicion(p_ticket uuid, p_hacia text, p_actor uuid, p_detalle text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_de text;
begin
  select estado_id into v_de from public.tickets where id = p_ticket;
  if v_de = p_hacia then return; end if;
  update public.tickets
     set estado_id = p_hacia,
         primera_respuesta_at = case when v_de = 'NUEVO' and p_actor is not null and app.es_transportes(p_actor)
                                     then coalesce(primera_respuesta_at, now()) else primera_respuesta_at end
   where id = p_ticket;
  perform app.hist(p_ticket, p_actor, 'ESTADO',
    app.nombre_estado(v_de) || ' → ' || app.nombre_estado(p_hacia) || coalesce(' · ' || p_detalle, ''));
end $$;

create or replace function app.comentario_insertar(p_ticket uuid, p_autor uuid, p_visibilidad text, p_tipo text, p_texto text, p_responde_a uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into public.comentarios (ticket_id, autor_id, visibilidad, tipo, texto, responde_a)
  values (p_ticket, p_autor, p_visibilidad, p_tipo, p_texto, p_responde_a)
  returning id into v_id;
  perform app.hist(p_ticket, p_autor,
    case when p_visibilidad = 'INTERNO' then 'NOTA_INTERNA' else p_tipo end,
    case when p_visibilidad = 'INTERNO' then 'Nota interna'
         else case p_tipo when 'SOLICITUD_INFO' then 'Solicitud de información al solicitante'
                          when 'RESPUESTA_INFO' then 'Respuesta del solicitante'
                          when 'RESOLUCION' then 'Resolución documentada'
                          else 'Comentario público' end end,
    p_visibilidad);
  if p_visibilidad = 'PUBLICO' and app.es_transportes(p_autor) then
    update public.tickets set primera_respuesta_at = coalesce(primera_respuesta_at, now()) where id = p_ticket;
  end if;
  return v_id;
end $$;

create or replace function app.cerrar_pausa(p_ticket uuid)
returns void language sql security definer set search_path = '' as $$
  update public.sla_pausas set fin = now() where ticket_id = p_ticket and fin is null;
$$;

create or replace function app.carga(p_usuario uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.tickets t
  join public.estados e on e.id = t.estado_id
  where t.responsable_id = p_usuario and e.abierto and not t.anulado
$$;

/** Solicitud de información pendiente (última solicitud sin respuesta posterior) */
create or replace function app.pendiente_info(p_ticket uuid)
returns uuid language sql stable set search_path = '' as $$
  select c.id
  from public.tickets t
  cross join lateral (
    select id, tipo from public.comentarios
    where ticket_id = t.id and tipo in ('SOLICITUD_INFO', 'RESPUESTA_INFO')
    order by creado_at desc, id desc limit 1) c
  where t.id = p_ticket and not t.anulado and t.estado_id not in ('CERRADO', 'RECHAZADO') and c.tipo = 'SOLICITUD_INFO'
$$;

create or replace function app.cancelar_investigacion(p_ticket uuid, p_actor uuid, p_motivo text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.investigaciones set estado = 'CANCELADA'
   where ticket_id = p_ticket and estado not in ('CONCLUIDA', 'CANCELADA');
  if found then perform app.hist(p_ticket, p_actor, 'INVESTIGACION', 'Investigación cancelada: ' || p_motivo, 'INTERNO'); end if;
end $$;

/** D-21: solo usuarios activos, disponibles, con alcance; si nadie califica, alerta a supervisión */
create or replace function app.asignacion_automatica(p_ticket uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_t public.tickets;
  v_r public.perfiles;
begin
  select * into v_t from public.tickets where id = p_ticket;
  select p.* into v_r from public.perfiles p
   where p.activo and p.rol_id = 'OPERADOR_TRANSPORTES' and app.motivo_no_elegible(p.id, v_t.departamento_id) is null
   order by app.carga(p.id), p.nombre limit 1;
  if not found then
    perform app.notificar(app.supervisores(), null, 'sin_responsable', p_ticket, 'Asignación automática sin candidatos elegibles: requiere asignación manual');
    return;
  end if;
  insert into public.asignaciones (ticket_id, responsable_id, asignado_por, tipo, motivo)
  values (p_ticket, v_r.id, null, 'AUTOMATICA', 'Menor carga entre coordinadores elegibles');
  update public.tickets set responsable_id = v_r.id, asignado_at = coalesce(asignado_at, now()) where id = p_ticket;
  perform app.transicion(p_ticket, 'ASIGNADO', null, 'Asignación automática a ' || v_r.nombre);
  perform app.notificar(array[v_r.id], null, 'asignado', p_ticket, 'Se le asignó automáticamente: ' || v_t.asunto);
end $$;

/* ---------- Finanzas ---------- */
/** Saldos de una diferencia calculados SOLO desde el libro (cada registro se cuenta una vez) */
create or replace function app.saldos_diferencia(p_diferencia uuid)
returns table (base numeric, aclarado numeric, recuperado numeric, ajuste numeric, pendiente numeric)
language sql stable set search_path = '' as $$
  with efectos as (
    select m.tipo, m.monto
    from public.movimientos_financieros m
    where m.diferencia_id = p_diferencia and m.tipo <> 'REVERSION'
    union all
    select o.tipo, -o.monto
    from public.movimientos_financieros r
    join public.movimientos_financieros o on o.id = r.revierte_id
    where r.diferencia_id = p_diferencia
  ), tot as (
    select coalesce(sum(monto) filter (where tipo = 'ACLARACION'), 0)   as a,
           coalesce(sum(monto) filter (where tipo = 'RECUPERACION'), 0) as r,
           coalesce(sum(monto) filter (where tipo = 'AJUSTE'), 0)       as j
    from efectos
  )
  select abs(d.monto_diferencia), tot.a, tot.r, tot.j, abs(d.monto_diferencia) + tot.j - tot.a - tot.r
  from public.liquidacion_diferencias d cross join tot
  where d.id = p_diferencia
$$;

commit;
