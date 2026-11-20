/* Migración 2026-11-19_02 — Resolución en un solo paso y nuevos nombres.
 * Incluye también la migración 2026-11-19_01 (no hace falta ejecutarla aparte).
 *
 *   1. «Marcar resuelto» concluye la investigación abierta con el resultado elegido (un solo paso).
 *   2. La investigación sin responsable la gestiona el responsable del ticket; al asignar el ticket, pasa a esa persona.
 *   3. Nombres: el rol se muestra como «Coordinador de Rutas» y el departamento TRA como «Distrib. y Transp. Cárnico».
 *      (Los códigos internos no cambian: OPERADOR_TRANSPORTES y TRA.)
 * Ejecutar una vez en el Editor SQL de Supabase. Es idempotente.
 */
create or replace function public.fn_ticket_acciones(p_ticket uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets := app.ticket_para(v_u.id, p_ticket, false);
  v_inv public.investigaciones;
  v_bloqueo text;
begin
  select * into v_inv from public.investigaciones where ticket_id = v_t.id and estado not in ('CONCLUIDA', 'CANCELADA') limit 1;
  -- Quien gestiona la investigación la concluye al resolver; los demás deben esperar a Supervisión
  if v_inv.id is not null and not app.puede_gestionar_inv(v_u.id, v_inv) then
    v_bloqueo := 'La investigación debe concluirse primero: solicite a Supervisión que la asigne o la concluya';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('codigo', a.accion,
             'bloqueo', case when a.accion = 'resolver' then v_bloqueo end) order by a.accion)
    from (select distinct accion from public.transiciones_estado where estado_desde = v_t.estado_id) a
    where app.accion_permitida(v_u.id, v_t, a.accion)), '[]'::jsonb);
end $$;

create or replace function public.fn_ticket_accion(p_ticket uuid, p_accion text, p jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets;
  v_r public.perfiles;
  v_m public.motivos;
  v_inv public.investigaciones;
  v_txt text;
  v_prev uuid;
  v_hacia text;
  v_prio text;
  v_ver integer;
begin
  v_t := app.ticket_para(v_u.id, p_ticket, true);
  if not app.accion_permitida(v_u.id, v_t, p_accion) then
    perform app.error('TRANSICION_INVALIDA', 'Acción no permitida para su rol o para el estado actual del ticket.');
  end if;
  p := coalesce(p, '{}'::jsonb);

  case p_accion
  when 'tomar_revision' then
    perform app.transicion(v_t.id, 'EN_REVISION', v_u.id, null);
    perform app.notificar(array[v_t.solicitante_id], v_u.id, 'comentario', v_t.id, 'Su solicitud está en revisión');

  when 'asignar', 'autoasignar', 'reasignar' then
    select * into v_r from public.perfiles
     where id = case when p_accion = 'autoasignar' then v_u.id else nullif(p ->> 'responsable_id', '')::uuid end;
    v_txt := app.motivo_no_elegible(v_r.id, v_t.departamento_id);
    perform app.validar(v_txt is null, 'No se puede asignar: ' || coalesce(v_txt, '') || '.');
    v_txt := null;
    if p_accion = 'reasignar' then
      perform app.validar(v_r.id is distinct from v_t.responsable_id, 'Seleccione un responsable diferente al actual.');
      v_txt := app.texto(p ->> 'motivo', 5, 'El motivo de reasignación');
    end if;
    update public.asignaciones set hasta = now() where ticket_id = v_t.id and hasta is null;
    insert into public.asignaciones (ticket_id, responsable_id, asignado_por, tipo, motivo)
    values (v_t.id, v_r.id, v_u.id,
            case when p_accion = 'autoasignar' then 'AUTOASIGNACION' when coalesce((p ->> 'sugerido')::boolean, false) then 'SUGERIDA' else 'MANUAL' end,
            v_txt);
    v_prev := v_t.responsable_id;
    update public.tickets set responsable_id = v_r.id, asignado_at = coalesce(asignado_at, now()) where id = v_t.id;
    perform app.hist(v_t.id, v_u.id, 'ASIGNACION', case when v_prev is null then 'Asignado a ' || v_r.nombre
      else 'Reasignado de ' || (select nombre from public.perfiles where id = v_prev) || ' a ' || v_r.nombre || '. Motivo: ' || v_txt end);
    -- La investigación sin responsable pasa al responsable del ticket (si puede gestionarla)
    if app.permiso_de(v_r.id, 'investigacion.gestionar') then
      update public.investigaciones
         set responsable_id = v_r.id, estado = case when estado = 'ABIERTA' then 'EN_CURSO' else estado end
       where ticket_id = v_t.id and responsable_id is null and estado not in ('CONCLUIDA', 'CANCELADA');
      if found then
        perform app.hist(v_t.id, v_u.id, 'INVESTIGACION', 'Responsable de la investigación: ' || v_r.nombre, 'INTERNO');
      end if;
    end if;
    perform app.transicion(v_t.id, 'ASIGNADO', v_u.id, null);
    perform app.notificar(array[v_r.id], v_u.id, 'asignado', v_t.id, 'Se le asignó: ' || v_t.asunto);
    if v_prev is not null then
      perform app.notificar(array[v_prev], v_u.id, 'reasignado', v_t.id, 'El ticket fue reasignado a ' || v_r.nombre);
    end if;

  when 'iniciar' then
    perform app.transicion(v_t.id, 'EN_PROCESO', v_u.id, null);

  when 'espera' then
    select * into v_m from public.motivos where id = p ->> 'motivo_id' and tipo = 'ESPERA' and activo;
    if not found then perform app.error('VALIDACION', 'Seleccione el motivo de espera.'); end if;
    v_txt := app.texto(p ->> 'detalle', 5, 'El detalle');
    update public.tickets set estado_previo = estado_id, motivo_espera_id = v_m.id where id = v_t.id;
    perform app.transicion(v_t.id, 'EN_ESPERA', v_u.id, 'Motivo: ' || v_m.nombre);
    if v_m.pausa_sla then
      insert into public.sla_pausas (ticket_id, inicio, motivo) values (v_t.id, now(), v_m.id);
    end if;
    if v_m.id = 'INFO_SOLICITANTE' then
      perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'SOLICITUD_INFO', v_txt);
      perform app.notificar(array[v_t.solicitante_id], v_u.id, 'info_requerida', v_t.id, 'Transportes requiere información para continuar');
    else
      perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'COMENTARIO', 'En espera — ' || v_m.nombre || ': ' || v_txt);
    end if;

  when 'reanudar' then
    perform app.cerrar_pausa(v_t.id);
    perform app.transicion(v_t.id, coalesce(v_t.estado_previo, 'EN_PROCESO'), v_u.id, 'Reanudado');
    update public.tickets set estado_previo = null, motivo_espera_id = null where id = v_t.id;

  when 'resolver' then
    select * into v_inv from public.investigaciones where ticket_id = v_t.id and estado not in ('CONCLUIDA', 'CANCELADA');
    if found then
      -- Un solo paso: la resolución concluye la investigación con el resultado elegido
      perform app.validar(app.puede_gestionar_inv(v_u.id, v_inv),
        'La investigación debe concluirse primero: solicite a Supervisión que la asigne o la concluya.');
      perform app.validar(exists (select 1 from public.resultados_investigacion where id = p ->> 'resultado_inv'),
        'Seleccione el resultado de la investigación.');
      v_txt := app.texto(p ->> 'resolucion', 20, 'La resolución');
      update public.investigaciones
         set estado = 'CONCLUIDA', resultado_id = p ->> 'resultado_inv', conclusion = v_txt, fecha_resolucion = now(),
             concluida_por = v_u.id, responsable_id = coalesce(responsable_id, v_u.id)
       where id = v_inv.id;
      perform app.hist(v_t.id, v_u.id, 'INVESTIGACION',
        'Investigación concluida — resultado: ' || (select nombre from public.resultados_investigacion where id = p ->> 'resultado_inv'));
      perform app.auditar(v_u.id, 'OPERATIVA', 'INVESTIGACION_CONCLUIDA', 'Resultado: ' || (p ->> 'resultado_inv'), v_t.id);
    else
      v_txt := app.texto(p ->> 'resolucion', 10, 'La resolución');
    end if;
    update public.tickets set estado_id = 'RESUELTO', resolucion = v_txt, resuelto_at = now() where id = v_t.id;
    perform app.hist(v_t.id, v_u.id, 'ESTADO', app.nombre_estado(v_t.estado_id) || ' → ' || app.nombre_estado('RESUELTO'));
    perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'RESOLUCION', v_txt);
    perform app.notificar(array[v_t.solicitante_id], v_u.id, 'resuelto', v_t.id, 'Su solicitud fue resuelta. Por favor confirme.');

  when 'rechazar' then
    select * into v_m from public.motivos where id = p ->> 'motivo_id' and tipo = 'RECHAZO' and activo;
    if not found then perform app.error('VALIDACION', 'Seleccione el motivo de rechazo.'); end if;
    v_txt := app.texto(p ->> 'justificacion', 10, 'La justificación');
    update public.tickets set estado_id = 'RECHAZADO', motivo_rechazo_id = v_m.id, rechazado_at = now(),
           primera_respuesta_at = coalesce(primera_respuesta_at, now())
     where id = v_t.id;
    perform app.hist(v_t.id, v_u.id, 'ESTADO', app.nombre_estado(v_t.estado_id) || ' → ' || app.nombre_estado('RECHAZADO') || ' · ' || v_m.nombre);
    perform app.cancelar_investigacion(v_t.id, v_u.id, 'ticket rechazado');
    perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'COMENTARIO', 'Solicitud rechazada — ' || v_m.nombre || '. ' || v_txt);
    perform app.notificar(array[v_t.solicitante_id], v_u.id, 'rechazado', v_t.id, 'Su solicitud fue rechazada: ' || v_m.nombre);

  when 'confirmar' then
    update public.tickets set cerrado_at = now() where id = v_t.id;
    perform app.transicion(v_t.id, 'CERRADO', v_u.id, 'Resolución confirmada por el solicitante');
    perform app.notificar(array[v_t.responsable_id], v_u.id, 'cerrado', v_t.id, 'El solicitante confirmó la resolución');

  when 'cerrar' then
    update public.tickets set cerrado_at = now() where id = v_t.id;
    perform app.transicion(v_t.id, 'CERRADO', v_u.id, 'Cerrado por supervisión');
    perform app.notificar(array[v_t.solicitante_id, v_t.responsable_id], v_u.id, 'cerrado', v_t.id, 'El ticket fue cerrado');

  when 'solicitar_reapertura', 'reabrir' then
    v_txt := app.texto(p ->> 'motivo', 5, 'El motivo de reapertura');
    v_hacia := case when p_accion = 'solicitar_reapertura' or v_t.responsable_id is not null then 'EN_PROCESO' else 'EN_REVISION' end;
    if v_t.resuelto_at is not null then   -- el tiempo en que estuvo resuelto no cuenta para el SLA
      insert into public.sla_pausas (ticket_id, inicio, fin, motivo) values (v_t.id, v_t.resuelto_at, now(), 'RESUELTO');
    end if;
    update public.tickets
       set estado_id = v_hacia, resuelto_at = null, cerrado_at = null, rechazado_at = null, resolucion = null,
           cierre_excepcional = false, reaperturas = reaperturas + 1
     where id = v_t.id;
    update public.investigaciones set estado = case when responsable_id is null then 'ABIERTA' else 'EN_CURSO' end
     where ticket_id = v_t.id and estado = 'CANCELADA';
    perform app.hist(v_t.id, v_u.id, 'ESTADO', app.nombre_estado(v_t.estado_id) || ' → ' || app.nombre_estado(v_hacia) || ' · ' ||
      case when p_accion = 'reabrir' then 'Reabierto por supervisión' else 'Reapertura solicitada por el solicitante' end);
    perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'COMENTARIO', 'Reapertura: ' || v_txt);
    perform app.notificar(array[v_t.responsable_id, v_t.solicitante_id] || app.supervisores(), v_u.id, 'reabierto', v_t.id, 'El ticket fue reabierto');

  when 'cambiar_prioridad' then
    v_prio := p ->> 'prioridad';
    perform app.validar(exists (select 1 from public.prioridades where id = v_prio), 'Seleccione una prioridad válida.');
    perform app.validar(v_prio <> v_t.prioridad_id, 'La prioridad seleccionada es la actual.');
    v_txt := app.texto(p ->> 'motivo', 5, 'El motivo');
    update public.tickets set prioridad_id = v_prio where id = v_t.id;
    select version into v_ver from public.ticket_sla where ticket_id = v_t.id;
    if v_ver is not null then   -- recalcula objetivos con la MISMA versión de SLA del ticket
      perform app.sla_snapshot(v_t.id, v_t.categoria_id, v_prio, v_ver);
    end if;
    perform app.hist(v_t.id, v_u.id, 'PRIORIDAD',
      'Prioridad ' || (select nombre from public.prioridades where id = v_t.prioridad_id) || ' → ' ||
      (select nombre from public.prioridades where id = v_prio) || '. Motivo: ' || v_txt);

  when 'cierre_excepcional' then
    v_txt := app.texto(p ->> 'justificacion', 10, 'La justificación');
    perform app.cerrar_pausa(v_t.id);
    perform app.cancelar_investigacion(v_t.id, v_u.id, 'cierre excepcional');
    update public.tickets set cierre_excepcional = true, cerrado_at = now() where id = v_t.id;
    perform app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'COMENTARIO', 'Cierre excepcional: ' || v_txt);
    perform app.transicion(v_t.id, 'CERRADO', v_u.id, 'Cierre excepcional');
    update public.tickets set estado_previo = null, motivo_espera_id = null where id = v_t.id;
    perform app.auditar(v_u.id, 'OPERATIVA', 'CIERRE_EXCEPCIONAL', v_txt, v_t.id);
    perform app.notificar(array[v_t.solicitante_id, v_t.responsable_id], v_u.id, 'cerrado', v_t.id, 'El ticket fue cerrado de forma excepcional');

  when 'anular' then
    v_txt := app.texto(p ->> 'motivo', 5, 'El motivo de anulación');
    perform app.cerrar_pausa(v_t.id);
    update public.tickets set anulado = true, anulado_motivo = v_txt, anulado_por = v_u.id, anulado_at = now() where id = v_t.id;
    perform app.hist(v_t.id, v_u.id, 'ANULADO', 'Ticket anulado (se conserva para trazabilidad). Motivo: ' || v_txt);
    perform app.auditar(v_u.id, 'OPERATIVA', 'ANULACION', v_txt, v_t.id);

  else
    perform app.error('TRANSICION_INVALIDA', 'Acción desconocida.');
  end case;
end $$;

create or replace function app.puede_gestionar_inv(p_usuario uuid, p_inv public.investigaciones)
returns boolean language sql stable security definer set search_path = '' as $$
  -- Supervisión, el responsable de la investigación o, si aún no tiene responsable, el responsable del ticket
  select app.permiso_de(p_usuario, 'investigacion.gestionar')
     and (app.permiso_de(p_usuario, 'ticket.gestionar_todos')
          or p_inv.responsable_id = p_usuario
          or (p_inv.responsable_id is null
              and exists (select 1 from public.tickets t where t.id = p_inv.ticket_id and t.responsable_id = p_usuario)))
$$;

create or replace function public.fn_inv_hallazgo(p_inv uuid, p_texto text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_i public.investigaciones := app.inv_para(v_u.id, p_inv);
  v_id uuid;
begin
  perform app.validar(app.puede_gestionar_inv(v_u.id, v_i), 'Solo el responsable de la investigación o supervisión puede registrar hallazgos.');
  perform app.validar(v_i.estado not in ('CONCLUIDA', 'CANCELADA'), 'La investigación no está abierta.');
  insert into public.investigacion_hallazgos (investigacion_id, texto, autor_id)
  values (v_i.id, app.texto(p_texto, 5, 'El hallazgo'), v_u.id) returning id into v_id;
  update public.investigaciones
     set estado = case when estado = 'ABIERTA' then 'EN_CURSO' else estado end, responsable_id = coalesce(responsable_id, v_u.id)
   where id = v_i.id;
  perform app.hist(v_i.ticket_id, v_u.id, 'INVESTIGACION', 'Hallazgo registrado', 'INTERNO');
  return v_id;
end $$;

create or replace function public.fn_inv_aclaracion(p_inv uuid, p_texto text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_i public.investigaciones := app.inv_para(v_u.id, p_inv);
  v_sol uuid;
begin
  perform app.validar(app.puede_gestionar_inv(v_u.id, v_i), 'No autorizado para gestionar esta investigación.');
  perform app.validar(v_i.estado not in ('CONCLUIDA', 'CANCELADA'), 'La investigación no está abierta.');
  update public.investigaciones set estado = 'EN_ACLARACION', responsable_id = coalesce(responsable_id, v_u.id) where id = v_i.id;
  perform app.comentario_insertar(v_i.ticket_id, v_u.id, 'PUBLICO', 'SOLICITUD_INFO', app.texto(p_texto, 5, 'La solicitud de aclaración'));
  select solicitante_id into v_sol from public.tickets where id = v_i.ticket_id;
  perform app.notificar(array[v_sol], v_u.id, 'info_requerida', v_i.ticket_id, 'Transportes solicita una aclaración para la investigación');
end $$;

create or replace function public.fn_inv_concluir(p_inv uuid, p_resultado text, p_conclusion text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_i public.investigaciones := app.inv_para(v_u.id, p_inv);
  v_txt text;
begin
  perform app.validar(app.puede_gestionar_inv(v_u.id, v_i), 'Solo el responsable de la investigación o supervisión puede concluirla.');
  perform app.validar(v_i.estado not in ('CONCLUIDA', 'CANCELADA'), 'La investigación no está abierta.');
  perform app.validar(exists (select 1 from public.resultados_investigacion where id = p_resultado), 'Seleccione el resultado de la investigación.');
  v_txt := app.texto(p_conclusion, 20, 'La conclusión');
  update public.investigaciones
     set estado = 'CONCLUIDA', resultado_id = p_resultado, conclusion = v_txt, fecha_resolucion = now(), concluida_por = v_u.id,
         responsable_id = coalesce(responsable_id, v_u.id)
   where id = v_i.id;
  perform app.hist(v_i.ticket_id, v_u.id, 'INVESTIGACION',
    'Investigación concluida — resultado: ' || (select nombre from public.resultados_investigacion where id = p_resultado));
  perform app.auditar(v_u.id, 'OPERATIVA', 'INVESTIGACION_CONCLUIDA', 'Resultado: ' || p_resultado, v_i.ticket_id);
end $$;

/* Nombres visibles */
update public.roles set nombre = 'Coordinador de Rutas' where id = 'OPERADOR_TRANSPORTES';
update public.departamentos set nombre = 'Distrib. y Transp. Cárnico' where id = 'TRA';

/* Investigaciones abiertas sin responsable → responsable del ticket */
update public.investigaciones i
   set responsable_id = t.responsable_id,
       estado = case when i.estado = 'ABIERTA' then 'EN_CURSO' else i.estado end
  from public.tickets t
 where t.id = i.ticket_id and i.responsable_id is null and t.responsable_id is not null
   and i.estado not in ('CONCLUIDA', 'CANCELADA')
   and app.permiso_de(t.responsable_id, 'investigacion.gestionar');

/* Verificación: debe devolver true, Coordinador de Rutas y Distrib. y Transp. Cárnico */
select pg_get_functiondef('public.fn_ticket_accion(uuid,text,jsonb)'::regprocedure) like '%resultado_inv%' as resolucion_un_paso,
       (select nombre from public.roles where id = 'OPERADOR_TRANSPORTES') as rol,
       (select nombre from public.departamentos where id = 'TRA') as departamento;