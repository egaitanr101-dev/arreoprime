-- =============================================================================
-- 06_rpc.sql — API de escritura (funciones RPC expuestas por PostgREST)
--
-- Regla de arquitectura: el navegador NO tiene INSERT/UPDATE/DELETE sobre ninguna
-- tabla. Toda escritura pasa por estas funciones, que validan sesión, permisos,
-- departamento, estado y transición, y registran historial en la misma transacción.
-- Todas son SECURITY DEFINER con search_path vacío y verifican auth.uid() explícitamente.
-- =============================================================================
begin;

/* =========================== Sesión =========================== */
create or replace function public.fn_mi_perfil()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v public.perfiles := app.actor();
begin
  return jsonb_build_object(
    'id', v.id, 'nombre', v.nombre, 'correo', v.correo, 'rol', v.rol_id, 'departamento', v.departamento_id,
    'depto_nombre', (select nombre from public.departamentos where id = v.departamento_id),
    'activo', v.activo, 'disponible', v.disponible,
    'alcance', coalesce((select jsonb_agg(departamento_id) from public.operador_alcance where perfil_id = v.id), '[]'::jsonb),
    'permisos', coalesce((select jsonb_agg(id order by id) from public.permisos pe where app.permiso_de(v.id, pe.id)), '[]'::jsonb));
end $$;

/* =========================== Crear ticket =========================== */
create or replace function public.fn_ticket_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_sol public.perfiles;
  v_canal text;
  v_cat public.categorias;
  v_tipo text;
  v_asunto text;
  v_desc text;
  v_datos jsonb := '{}'::jsonb;
  v_montos jsonb := '{}'::jsonb;
  r record;
  v_val text;
  v_num numeric;
  v_ok boolean;
  v_anio integer;
  v_n integer;
  v_id uuid;
  v_numero text;
  v_inv uuid;
begin
  if coalesce((p ->> 'asistido')::boolean, false) then
    perform app.exigir('ticket.registro_asistido');
    select * into v_sol from public.perfiles where id = nullif(p ->> 'solicitante_id', '')::uuid and activo and rol_id in ('SOLICITANTE', 'SUPERVISOR_LIQUIDACIONES');
    if not found then perform app.error('VALIDACION', 'Seleccione un solicitante activo de Comercial, Almacén o Liquidaciones.'); end if;
    v_canal := 'ASISTIDO';
  else
    perform app.exigir('ticket.crear');
    v_sol := v_u;
    v_canal := 'PORTAL';
  end if;

  -- El departamento SIEMPRE proviene del perfil del solicitante; se ignora cualquier valor enviado.
  select * into v_cat from public.categorias
   where id = p ->> 'categoria_id' and activo and departamento_id = v_sol.departamento_id;
  if not found then perform app.error('VALIDACION', 'La categoría no corresponde al departamento del solicitante.'); end if;

  v_tipo := coalesce(nullif(p ->> 'tipo_id', ''), v_cat.tipo_gestion_default);
  perform app.validar(exists (select 1 from public.categoria_tipos where categoria_id = v_cat.id and tipo_id = v_tipo),
                      'El tipo de gestión no es válido para esta categoría.');
  v_asunto := trim(coalesce(p ->> 'asunto', ''));
  perform app.validar(char_length(v_asunto) between 5 and 140, 'El asunto debe tener entre 5 y 140 caracteres.');
  v_desc := app.texto(p ->> 'descripcion', 10, 'La descripción');

  for r in
    select cc.campo_clave, cc.obligatorio, cd.etiqueta, cd.tipo, cd.catalogo, cd.opciones, cd.financiero
    from public.categoria_campos cc
    join public.campos_definicion cd on cd.clave = cc.campo_clave
    where cc.categoria_id = v_cat.id
    order by cc.orden
  loop
    v_val := nullif(trim(coalesce(p -> 'datos' ->> r.campo_clave, '')), '');
    if v_val is null then
      perform app.validar(not r.obligatorio, 'El campo "' || r.etiqueta || '" es obligatorio.');
      continue;
    end if;
    if r.tipo in ('crc', 'numero') then
      begin
        v_num := v_val::numeric;
      exception when others then
        v_num := null;
      end;
      perform app.validar(v_num is not null and v_num >= 0, '"' || r.etiqueta || '" debe ser un número igual o mayor que cero.');
      if r.financiero then
        v_montos := v_montos || jsonb_build_object(r.campo_clave, round(v_num, 2));
      else
        v_datos := v_datos || jsonb_build_object(r.campo_clave, v_num);
      end if;
      continue;
    elsif r.tipo = 'catalogo' then
      perform app.validar(app.catalogo_valido(r.catalogo, v_val), 'Valor no válido en "' || r.etiqueta || '".');
    elsif r.tipo = 'opciones' then
      perform app.validar(v_val = any (r.opciones), 'Valor no válido en "' || r.etiqueta || '".');
    elsif r.tipo = 'fecha' then
      begin
        perform v_val::date;
        v_ok := v_val ~ '^\d{4}-\d{2}-\d{2}$';
      exception when others then
        v_ok := false;
      end;
      perform app.validar(v_ok, 'Fecha no válida en "' || r.etiqueta || '".');
    end if;
    v_datos := v_datos || jsonb_build_object(r.campo_clave, v_val);
  end loop;

  perform app.validar(not (v_datos ? 'bodega_origen' and v_datos ->> 'bodega_origen' = v_datos ->> 'bodega_destino'),
                      'La bodega de origen y la de destino deben ser diferentes.');
  if v_montos <> '{}'::jsonb then
    perform app.validar(v_montos ? 'monto_esperado' and v_montos ? 'monto_recibido',
                        'Para registrar la diferencia indique el monto esperado y el recibido.');
  end if;

  -- Consecutivo anual sin huecos: el bloqueo de fila serializa la numeración
  v_anio := extract(year from now() at time zone 'America/Costa_Rica')::integer;
  insert into public.ticket_consecutivos (anio, ultimo) values (v_anio, 1)
  on conflict (anio) do update set ultimo = public.ticket_consecutivos.ultimo + 1
  returning ultimo into v_n;
  v_numero := 'TS-' || v_anio || '-' || lpad(v_n::text, 6, '0');

  insert into public.tickets (numero, departamento_id, solicitante_id, registrado_por, canal, tipo_gestion_id, categoria_id,
                              asunto, descripcion, datos, prioridad_sugerida, prioridad_id,
                              cliente_id, ruta_id, factura, pedido, fecha_requerida)
  values (v_numero, v_sol.departamento_id, v_sol.id, v_u.id, v_canal, v_tipo, v_cat.id,
          v_asunto, v_desc, v_datos, v_cat.prioridad_sugerida, v_cat.prioridad_sugerida,
          v_datos ->> 'cliente', v_datos ->> 'ruta', v_datos ->> 'factura', v_datos ->> 'pedido',
          coalesce(v_datos ->> 'fecha_solicitada', v_datos ->> 'fecha_requerida', v_datos ->> 'fecha_entrega')::date)
  returning id into v_id;

  perform app.sla_snapshot(v_id, v_cat.id, v_cat.prioridad_sugerida);
  perform app.hist(v_id, v_u.id, 'CREADO', case when v_canal = 'ASISTIDO'
    then 'Registrado por ' || v_u.nombre || ' en nombre de ' || v_sol.nombre || ' (registro asistido)'
    else 'Ticket creado desde el portal' end);

  if v_cat.financiero and v_montos <> '{}'::jsonb then
    insert into public.liquidacion_diferencias (ticket_id, num_liquidacion, ruta_id, fecha_operacion, chofer_id, ayudante_id,
                                                factura, tipo_diferencia, medio_pago, monto_esperado, monto_recibido, monto_reportado, creado_por)
    values (v_id, v_datos ->> 'num_liquidacion', v_datos ->> 'ruta', (v_datos ->> 'fecha_operacion')::date,
            v_datos ->> 'chofer', v_datos ->> 'ayudante', v_datos ->> 'factura', v_datos ->> 'tipo_diferencia', v_datos ->> 'medio_pago',
            (v_montos ->> 'monto_esperado')::numeric, (v_montos ->> 'monto_recibido')::numeric, (v_montos ->> 'monto_reportado')::numeric, v_u.id);
  end if;
  if v_cat.genera_investigacion then
    insert into public.investigaciones (ticket_id) values (v_id) returning id into v_inv;
    insert into public.investigacion_involucrados (investigacion_id, colaborador_id, rol)
    select v_inv, x.id, x.rol from (values (v_datos ->> 'chofer', 'Chofer'), (v_datos ->> 'ayudante', 'Ayudante')) as x(id, rol)
    where x.id is not null;
  end if;

  perform app.notificar(app.supervisores(), v_u.id, 'nuevo', v_id,
    'Nuevo ticket de ' || (select nombre from public.departamentos where id = v_sol.departamento_id) || ': ' || v_asunto);
  if coalesce((app.config_valor('asignacion_automatica'))::text::boolean, false) then
    perform app.asignacion_automatica(v_id);
  end if;

  return (select jsonb_build_object('id', t.id, 'numero', t.numero, 'creado_at', t.creado_at, 'departamento_id', t.departamento_id,
                                    'categoria_id', t.categoria_id, 'prioridad_id', t.prioridad_id, 'estado_id', t.estado_id,
                                    'responsable_id', t.responsable_id, 'canal', t.canal)
          from public.tickets t where t.id = v_id);
end $$;

/* =========================== Acciones de estado =========================== */
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
  v_d public.liquidacion_diferencias;
  v_cierre jsonb;
  v_pend numeric;
  v_acl numeric;
  v_rec numeric;
  v_mov uuid;
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
    -- Cierre del faltante: el saldo pendiente se clasifica como aclarado y/o recuperado (queda en ₡0)
    select * into v_d from public.liquidacion_diferencias where ticket_id = v_t.id and monto_diferencia > 0 limit 1 for update;
    if v_d.id is not null and app.permiso_de(v_u.id, 'financiero.registrar') then
      select s.pendiente into v_pend from app.saldos_diferencia(v_d.id) s;
      if v_pend > 0 then
        v_cierre := coalesce(p -> 'cierre_dif', '{}'::jsonb);
        perform app.validar(v_cierre ->> 'tipo' in ('ACLARADO', 'RECUPERADO', 'MIXTO'),
          'Indique cómo se cierra el faltante: aclarado, recuperado o parte de cada uno.');
        v_acl := case v_cierre ->> 'tipo' when 'ACLARADO' then v_pend when 'RECUPERADO' then 0
                 else round(coalesce(nullif(v_cierre ->> 'monto_aclarado', '')::numeric, -1), 2) end;
        perform app.validar(v_acl >= 0 and v_acl <= v_pend, 'El monto aclarado debe estar entre ₡0 y el saldo pendiente.');
        v_rec := v_pend - v_acl;
        if v_acl > 0 then
          insert into public.movimientos_financieros (diferencia_id, ticket_id, tipo, monto, nota, usuario_id)
          values (v_d.id, v_t.id, 'ACLARACION', v_acl, 'Aclarado al resolver el ticket', v_u.id) returning id into v_mov;
          perform app.hist(v_t.id, v_u.id, 'FINANCIERO', 'Movimiento aclaracion por ₡' || to_char(v_acl, 'FM999G999G999G990D00'), 'FINANCIERO');
          perform app.auditar(v_u.id, 'OPERATIVA', 'MOVIMIENTO_FINANCIERO', 'ACLARACION ' || v_acl, v_t.id, jsonb_build_object('movimiento', v_mov));
        end if;
        if v_rec > 0 then
          perform app.validar(char_length(trim(coalesce(v_cierre ->> 'forma', ''))) >= 3, 'Indique la forma de la recuperación.');
          insert into public.movimientos_financieros (diferencia_id, ticket_id, tipo, monto, nota, usuario_id)
          values (v_d.id, v_t.id, 'RECUPERACION', v_rec, 'Recuperado al resolver el ticket', v_u.id) returning id into v_mov;
          insert into public.recuperaciones (movimiento_id, forma, comprobante, fecha)
          values (v_mov, trim(v_cierre ->> 'forma'), nullif(trim(coalesce(v_cierre ->> 'comprobante', '')), ''),
                  coalesce(nullif(v_cierre ->> 'fecha', '')::date, (now() at time zone 'America/Costa_Rica')::date));
          perform app.hist(v_t.id, v_u.id, 'FINANCIERO', 'Movimiento recuperacion por ₡' || to_char(v_rec, 'FM999G999G999G990D00'), 'FINANCIERO');
          perform app.auditar(v_u.id, 'OPERATIVA', 'MOVIMIENTO_FINANCIERO', 'RECUPERACION ' || v_rec, v_t.id, jsonb_build_object('movimiento', v_mov));
        end if;
      end if;
    end if;

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

/* =========================== Conversación =========================== */
create or replace function public.fn_ticket_comentar(p_ticket uuid, p_texto text, p_visibilidad text default 'PUBLICO')
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets := app.ticket_para(v_u.id, p_ticket, false);
  v_vis text := case when upper(coalesce(p_visibilidad, '')) = 'INTERNO' then 'INTERNO' else 'PUBLICO' end;
  v_id uuid;
begin
  perform app.exigir(case v_vis when 'INTERNO' then 'ticket.nota_interna' else 'ticket.comentar_publico' end);
  perform app.validar(not v_t.anulado, 'El ticket está anulado.');
  perform app.validar(not (v_vis = 'PUBLICO' and v_t.estado_id in ('CERRADO', 'RECHAZADO') and not app.es_transportes(v_u.id)),
                      'El ticket está finalizado y no admite comentarios nuevos.');
  v_id := app.comentario_insertar(v_t.id, v_u.id, v_vis, 'COMENTARIO', app.texto(p_texto, 2, 'El comentario'));
  if v_vis = 'PUBLICO' then
    if app.es_transportes(v_u.id) then
      perform app.notificar(array[v_t.solicitante_id], v_u.id, 'comentario', v_t.id, 'Transportes agregó un comentario');
    else
      perform app.notificar(case when v_t.responsable_id is null then app.supervisores() else array[v_t.responsable_id] end,
                            v_u.id, 'comentario', v_t.id, 'El solicitante agregó un comentario');
    end if;
  end if;
  return v_id;
end $$;

create or replace function public.fn_ticket_responder_info(p_ticket uuid, p_texto text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets;
  v_pend uuid;
  v_id uuid;
begin
  perform app.exigir('ticket.responder_info');
  v_t := app.ticket_para(v_u.id, p_ticket, true);
  perform app.validar(v_u.departamento_id = v_t.departamento_id, 'Solo el departamento solicitante puede responder.');
  v_pend := app.pendiente_info(v_t.id);
  perform app.validar(v_pend is not null, 'No hay solicitudes de información pendientes.');
  v_id := app.comentario_insertar(v_t.id, v_u.id, 'PUBLICO', 'RESPUESTA_INFO', app.texto(p_texto, 2, 'La respuesta'), v_pend);
  if v_t.estado_id = 'EN_ESPERA' and v_t.motivo_espera_id = 'INFO_SOLICITANTE' then   -- D-07: reanudación automática
    perform app.cerrar_pausa(v_t.id);
    perform app.transicion(v_t.id, coalesce(v_t.estado_previo, 'EN_PROCESO'), v_u.id, 'Reanudado automáticamente por respuesta del solicitante');
    update public.tickets set estado_previo = null, motivo_espera_id = null where id = v_t.id;
  end if;
  update public.investigaciones set estado = 'EN_CURSO' where ticket_id = v_t.id and estado = 'EN_ACLARACION';
  perform app.notificar(case when v_t.responsable_id is null then app.supervisores() else array[v_t.responsable_id] end,
                        v_u.id, 'respuesta_info', v_t.id, 'El solicitante respondió la solicitud de información');
  return v_id;
end $$;

/* =========================== Evidencias (bucket privado) ===========================
   1) fn_evidencia_preparar → registra la evidencia PENDIENTE y devuelve la ruta autorizada
   2) el navegador sube el archivo a storage (bucket "evidencias") en ESA ruta; la política de Storage lo verifica
   3) fn_evidencia_confirmar → comprueba que el objeto existe y la publica en el ticket            */
create or replace function public.fn_evidencia_preparar(p_ticket uuid, p_nombre text, p_tamano bigint, p_mime text,
                                                        p_visibilidad text default 'PUBLICO', p_comentario uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets := app.ticket_para(v_u.id, p_ticket, false);
  v_vis text := case when upper(coalesce(p_visibilidad, '')) = 'INTERNO' then 'INTERNO' else 'PUBLICO' end;
  v_id uuid := gen_random_uuid();
  v_ruta text;
begin
  perform app.exigir('evidencia.subir');
  if v_vis = 'INTERNO' then perform app.exigir('ticket.nota_interna'); end if;
  perform app.validar(not v_t.anulado, 'El ticket está anulado.');
  perform app.validar(app.es_transportes(v_u.id) or v_t.estado_id not in ('CERRADO', 'RECHAZADO'), 'El ticket está finalizado.');
  perform app.validar(char_length(trim(coalesce(p_nombre, ''))) between 1 and 200, 'Nombre de archivo no válido.');
  perform app.validar(p_tamano > 0 and p_tamano <= 10485760, 'El archivo supera el máximo de 10 MB.');
  perform app.validar(p_mime ~ '^(image/(jpeg|png|webp|heic|heif)|application/pdf|application/vnd\.openxmlformats-officedocument\.(wordprocessingml\.document|spreadsheetml\.sheet)|application/msword|application/vnd\.ms-excel|text/csv)$',
                      'Tipo de archivo no permitido. Use imágenes, PDF u Office.');
  if p_comentario is not null then
    perform app.validar(exists (select 1 from public.comentarios where id = p_comentario and ticket_id = v_t.id and autor_id = v_u.id),
                        'El comentario no corresponde al ticket.');
  end if;
  v_ruta := v_t.id::text || '/' || v_id::text;
  insert into public.evidencias (id, ticket_id, comentario_id, nombre, tamano_bytes, mime, visibilidad, ruta, subido_por)
  values (v_id, v_t.id, p_comentario, trim(p_nombre), p_tamano, p_mime, v_vis, v_ruta, v_u.id);
  return jsonb_build_object('id', v_id, 'bucket', 'evidencias', 'ruta', v_ruta);
end $$;

create or replace function public.fn_evidencia_confirmar(p_evidencia uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_e public.evidencias;
begin
  select * into v_e from public.evidencias where id = p_evidencia and subido_por = v_u.id and estado = 'PENDIENTE' for update;
  if not found then perform app.error('NO_ENCONTRADO', 'Evidencia no encontrada.'); end if;
  perform app.validar(exists (select 1 from storage.objects o where o.bucket_id = 'evidencias' and o.name = v_e.ruta),
                      'El archivo no se ha cargado.');
  update public.evidencias set estado = 'CONFIRMADA', confirmado_at = now() where id = v_e.id;
  perform app.hist(v_e.ticket_id, v_u.id, 'EVIDENCIA', 'Evidencia adjunta: ' || v_e.nombre, v_e.visibilidad);
end $$;

/* =========================== Asignación =========================== */
create or replace function public.fn_responsables_para(p_ticket uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets;
  v_cat public.categorias;
  v_lista jsonb;
  v_sug uuid;
  v_razon text := 'Responsable sugerido para la categoría';
begin
  perform app.exigir('ticket.asignar');
  v_t := app.ticket_para(v_u.id, p_ticket, false);
  select * into v_cat from public.categorias where id = v_t.categoria_id;
  if v_cat.responsable_sugerido_id is not null and app.motivo_no_elegible(v_cat.responsable_sugerido_id, v_t.departamento_id) is null
     and v_cat.responsable_sugerido_id is distinct from v_t.responsable_id then
    v_sug := v_cat.responsable_sugerido_id;
  else
    select p.id into v_sug from public.perfiles p
     where p.activo and p.rol_id = 'OPERADOR_TRANSPORTES' and p.id is distinct from v_t.responsable_id
       and app.motivo_no_elegible(p.id, v_t.departamento_id) is null
     order by app.carga(p.id), p.nombre limit 1;
    v_razon := 'Menor carga entre coordinadores elegibles' || case when v_cat.responsable_sugerido_id is not null then ' (el sugerido de la categoría no está elegible)' else '' end;
  end if;
  select jsonb_agg(x order by (x ->> 'no_elegible') is not null, (x ->> 'carga')::int, x ->> 'nombre') into v_lista
  from (
    select jsonb_build_object('id', p.id, 'nombre', p.nombre, 'rol', r.nombre, 'carga', app.carga(p.id),
                              'disponible', p.disponible, 'activo', p.activo,
                              'no_elegible', app.motivo_no_elegible(p.id, v_t.departamento_id),
                              'actual', p.id = v_t.responsable_id, 'sugerido', p.id = v_sug,
                              'razon', case when p.id = v_sug then v_razon end) as x
    from public.perfiles p join public.roles r on r.id = p.rol_id
    where p.rol_id in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES')
  ) s;
  return coalesce(v_lista, '[]'::jsonb);
end $$;

/* =========================== Investigaciones =========================== */
create or replace function app.inv_para(p_usuario uuid, p_inv uuid)
returns public.investigaciones language plpgsql security definer set search_path = '' as $$
declare v public.investigaciones;
begin
  select * into v from public.investigaciones where id = p_inv for update;
  if not found then perform app.error('NO_ENCONTRADO', 'Investigación no encontrada.'); end if;
  perform app.ticket_para(p_usuario, v.ticket_id, false);
  if not app.permiso_de(p_usuario, 'investigacion.ver') then perform app.error('NO_AUTORIZADO', 'No autorizado para esta operación.'); end if;
  return v;
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

create or replace function public.fn_inv_asignar(p_inv uuid, p_responsable uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_i public.investigaciones := app.inv_para(v_u.id, p_inv);
  v_r public.perfiles;
begin
  perform app.exigir('ticket.asignar');
  perform app.exigir('investigacion.gestionar');
  perform app.validar(v_i.estado not in ('CONCLUIDA', 'CANCELADA'), 'La investigación no está abierta.');
  select * into v_r from public.perfiles where id = p_responsable and activo;
  perform app.validar(v_r.id is not null and app.permiso_de(v_r.id, 'investigacion.gestionar'),
                      'El responsable debe estar activo y tener permiso para gestionar investigaciones.');
  update public.investigaciones set responsable_id = v_r.id, estado = case when estado = 'ABIERTA' then 'EN_CURSO' else estado end where id = v_i.id;
  perform app.hist(v_i.ticket_id, v_u.id, 'INVESTIGACION', 'Responsable de la investigación: ' || v_r.nombre, 'INTERNO');
  perform app.notificar(array[v_r.id], v_u.id, 'asignado', v_i.ticket_id, 'Se le asignó la investigación del ticket');
end $$;

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

create or replace function public.fn_inv_reabrir(p_inv uuid, p_motivo text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_i public.investigaciones := app.inv_para(v_u.id, p_inv);
  v_txt text;
begin
  perform app.exigir('ticket.reabrir');
  perform app.exigir('investigacion.gestionar');
  perform app.validar(v_i.estado = 'CONCLUIDA', 'La investigación no está concluida.');
  perform app.validar(not exists (select 1 from public.tickets where id = v_i.ticket_id and estado_id in ('RESUELTO', 'CERRADO', 'RECHAZADO')),
                      'Reabra primero el ticket para reabrir su investigación.');
  v_txt := app.texto(p_motivo, 5, 'El motivo');
  -- La conclusión anterior se conserva (tabla de solo inserción)
  insert into public.investigacion_conclusiones (investigacion_id, resultado_id, conclusion, concluida_por, concluida_at, reabierta_por, reabierta_at, motivo_reapertura)
  values (v_i.id, v_i.resultado_id, v_i.conclusion, v_i.concluida_por, v_i.fecha_resolucion, v_u.id, now(), v_txt);
  update public.investigaciones
     set estado = 'EN_CURSO', resultado_id = null, conclusion = null, fecha_resolucion = null, concluida_por = null, reaperturas = reaperturas + 1
   where id = v_i.id;
  perform app.hist(v_i.ticket_id, v_u.id, 'INVESTIGACION', 'Investigación reabierta. Motivo: ' || v_txt);
  perform app.auditar(v_u.id, 'OPERATIVA', 'INVESTIGACION_REABIERTA', v_txt, v_i.ticket_id);
end $$;

/* =========================== Libro financiero =========================== */
create or replace function public.fn_movimiento_registrar(p_diferencia uuid, p_tipo text, p_monto numeric, p_nota text,
                                                          p_revierte uuid default null, p_forma text default null,
                                                          p_comprobante text default null, p_fecha date default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_d public.liquidacion_diferencias;
  v_t public.tickets;
  v_o public.movimientos_financieros;
  v_monto numeric;
  v_id uuid;
  v_pend numeric;
begin
  perform app.exigir('financiero.registrar');
  -- Bloqueo de la diferencia: serializa movimientos concurrentes y evita saldos negativos por carrera
  select * into v_d from public.liquidacion_diferencias where id = p_diferencia for update;
  if not found then perform app.error('NO_ENCONTRADO', 'Diferencia no encontrada.'); end if;
  v_t := app.ticket_para(v_u.id, v_d.ticket_id, false);
  perform app.validar(not v_t.anulado, 'El ticket está anulado.');
  perform app.validar(p_tipo in ('ACLARACION', 'RECUPERACION', 'AJUSTE', 'REVERSION'), 'Seleccione el tipo de movimiento.');
  if exists (select 1 from public.investigaciones where ticket_id = v_t.id and estado = 'CONCLUIDA') then
    perform app.validar(p_tipo in ('RECUPERACION', 'REVERSION'), 'La investigación está concluida: solo se admiten recuperaciones o reversiones.');
  end if;
  if p_tipo = 'REVERSION' then
    select * into v_o from public.movimientos_financieros where id = p_revierte and diferencia_id = v_d.id and tipo <> 'REVERSION';
    if not found then perform app.error('VALIDACION', 'Seleccione el movimiento a revertir.'); end if;
    perform app.validar(not exists (select 1 from public.movimientos_financieros where revierte_id = v_o.id), 'Ese movimiento ya fue revertido.');
    v_monto := v_o.monto;
  else
    v_monto := round(p_monto, 2);
    perform app.validar(v_monto is not null and (case when p_tipo = 'AJUSTE' then v_monto <> 0 else v_monto > 0 end),
                        case when p_tipo = 'AJUSTE' then 'El ajuste no puede ser cero.' else 'El monto debe ser mayor que cero.' end);
  end if;
  if p_tipo = 'RECUPERACION' then
    perform app.validar(char_length(trim(coalesce(p_forma, ''))) >= 3 and p_fecha is not null,
                        'Indique la forma y la fecha de la recuperación autorizada.');
  end if;
  insert into public.movimientos_financieros (diferencia_id, ticket_id, tipo, monto, nota, revierte_id, usuario_id)
  values (v_d.id, v_t.id, p_tipo, v_monto, app.texto(p_nota, 5, 'La nota'), case when p_tipo = 'REVERSION' then v_o.id end, v_u.id)
  returning id into v_id;
  if p_tipo = 'RECUPERACION' then
    insert into public.recuperaciones (movimiento_id, forma, comprobante, fecha) values (v_id, trim(p_forma), nullif(trim(p_comprobante), ''), p_fecha);
  end if;
  select pendiente into v_pend from app.saldos_diferencia(v_d.id);
  perform app.validar(v_pend >= 0, 'El movimiento dejaría el saldo pendiente en negativo. Revise el monto.');
  perform app.hist(v_t.id, v_u.id, 'FINANCIERO', 'Movimiento ' || lower(p_tipo) || ' por ₡' || to_char(v_monto, 'FM999G999G999G990D00'), 'FINANCIERO');
  perform app.auditar(v_u.id, 'OPERATIVA', 'MOVIMIENTO_FINANCIERO', p_tipo || ' ' || v_monto, v_t.id, jsonb_build_object('movimiento', v_id));
  return v_id;
end $$;

/* =========================== SLA: excepciones =========================== */
create or replace function public.fn_sla_excepcion(p_ticket uuid, p_metrica text, p_justificacion text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_t public.tickets := app.ticket_para(v_u.id, p_ticket, false);
  v_txt text;
begin
  perform app.exigir('sla.excepcion');
  perform app.validar(p_metrica in ('primera_respuesta', 'asignacion', 'resolucion'), 'Métrica no válida.');
  v_txt := app.texto(p_justificacion, 10, 'La justificación');
  insert into public.sla_excepciones (ticket_id, metrica, justificacion, autorizado_por) values (v_t.id, p_metrica, v_txt, v_u.id);
  perform app.hist(v_t.id, v_u.id, 'SLA', 'Excepción de SLA autorizada (' || p_metrica || '): ' || v_txt, 'INTERNO');
  perform app.auditar(v_u.id, 'OPERATIVA', 'SLA_EXCEPCION', p_metrica || ': ' || v_txt, v_t.id);
end $$;

/* =========================== Notificaciones =========================== */
create or replace function public.fn_notificaciones_marcar_leidas(p_ids bigint[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor(); v_n integer;
begin
  update public.notificaciones set leida = true
   where usuario_id = v_u.id and not leida and (p_ids is null or id = any (p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.fn_preferencias_guardar(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor();
begin
  insert into public.preferencias_notificacion (usuario_id, evento, activo)
  select v_u.id, e.id, coalesce((p ->> e.id)::boolean, true) from public.eventos_notificacion e
  on conflict (usuario_id, evento) do update set activo = excluded.activo;
end $$;

/* =========================== Exportaciones =========================== */
create or replace function public.fn_exportacion_registrar(p_reporte text, p_formato text, p_filas integer)
returns void language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor();
begin
  perform app.validar(app.tiene_permiso('reporte.completo') or app.tiene_permiso('reporte.operativo') or app.tiene_permiso('reporte.departamento'),
                      'No autorizado para exportar.');
  perform app.validar(p_formato in ('CSV', 'XLSX', 'PDF'), 'Formato no válido.');
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'EXPORTACION', coalesce(p_reporte, '?') || ' · ' || p_formato || ' · ' || coalesce(p_filas, 0) || ' filas');
end $$;

/* =========================== Administración =========================== */
create or replace function public.fn_admin_usuarios()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.actor();
  perform app.exigir('admin.usuarios');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nombre', p.nombre, 'correo', p.correo, 'rol', p.rol_id, 'departamento', p.departamento_id,
      'activo', p.activo, 'disponible', p.disponible, 'carga', app.carga(p.id),
      'alcance', coalesce((select jsonb_agg(departamento_id) from public.operador_alcance where perfil_id = p.id), '[]'::jsonb),
      'permisos_extra', coalesce((select jsonb_agg(permiso_id) from public.perfil_permisos where perfil_id = p.id), '[]'::jsonb))
    order by p.nombre) from public.perfiles p), '[]'::jsonb);
end $$;

create or replace function public.fn_admin_usuario_guardar(p_usuario uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_x public.perfiles;
  v_rol text;
  v_dep text;
  v_activo boolean;
  v_antes jsonb;
begin
  perform app.exigir('admin.usuarios');
  perform app.validar(p_usuario is distinct from v_u.id, 'No puede modificar su propio perfil, rol ni permisos.');
  select * into v_x from public.perfiles where id = p_usuario for update;
  if not found then perform app.error('NO_ENCONTRADO', 'Usuario no encontrado.'); end if;
  v_antes := to_jsonb(v_x) || jsonb_build_object(
    'alcance', (select jsonb_agg(departamento_id) from public.operador_alcance where perfil_id = v_x.id),
    'permisos_extra', (select jsonb_agg(permiso_id) from public.perfil_permisos where perfil_id = v_x.id));
  v_rol := coalesce(p ->> 'rol', v_x.rol_id);
  v_dep := coalesce(p ->> 'departamento', v_x.departamento_id);
  v_activo := coalesce((p ->> 'activo')::boolean, v_x.activo);
  if v_activo then
    perform app.validar(exists (select 1 from public.roles where id = v_rol and v_dep = any (departamentos_permitidos)),
                        'El departamento no corresponde al rol seleccionado.');
  end if;
  if v_x.activo and not v_activo then
    perform app.validar(app.carga(v_x.id) = 0, 'El usuario tiene ' || app.carga(v_x.id) || ' ticket(s) abiertos asignados. Reasígnelos antes de desactivarlo.');
  end if;
  update public.perfiles
     set rol_id = v_rol, departamento_id = v_dep, activo = v_activo,
         disponible = coalesce((p ->> 'disponible')::boolean, disponible),
         nombre = coalesce(nullif(trim(p ->> 'nombre'), ''), nombre)
   where id = v_x.id;
  if p ? 'alcance' or v_rol <> 'OPERADOR_TRANSPORTES' then
    delete from public.operador_alcance where perfil_id = v_x.id;
    if v_rol = 'OPERADOR_TRANSPORTES' then
      insert into public.operador_alcance (perfil_id, departamento_id)
      select v_x.id, d from jsonb_array_elements_text(p -> 'alcance') d where d in ('COM', 'ALM', 'LIQ');
    end if;
  end if;
  if p ? 'permisos_extra' then
    perform app.validar(not exists (select 1 from jsonb_array_elements_text(p -> 'permisos_extra') x
                                    where not exists (select 1 from public.permisos where id = x and otorgable)),
                        'Permiso no otorgable.');
    delete from public.perfil_permisos where perfil_id = v_x.id;
    insert into public.perfil_permisos (perfil_id, permiso_id, otorgado_por)
    select v_x.id, x, v_u.id from jsonb_array_elements_text(p -> 'permisos_extra') x;
  end if;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'USUARIO_MODIFICADO', v_x.nombre, null,
    jsonb_build_object('antes', v_antes, 'cambios', p));
end $$;

create or replace function public.fn_admin_categoria_guardar(p_categoria text, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_c public.categorias;
begin
  perform app.exigir('admin.catalogos');
  select * into v_c from public.categorias where id = p_categoria for update;
  if not found then perform app.error('NO_ENCONTRADO', 'Categoría no encontrada.'); end if;
  if p ? 'prioridad_sugerida' then
    perform app.validar(exists (select 1 from public.prioridades where id = p ->> 'prioridad_sugerida'), 'Prioridad no válida.');
  end if;
  if nullif(p ->> 'responsable_sugerido_id', '') is not null then
    perform app.validar(app.es_transportes((p ->> 'responsable_sugerido_id')::uuid), 'El responsable sugerido debe ser de Transportes.');
  end if;
  update public.categorias
     set activo = coalesce((p ->> 'activo')::boolean, activo),
         prioridad_sugerida = coalesce(p ->> 'prioridad_sugerida', prioridad_sugerida),
         responsable_sugerido_id = case when p ? 'responsable_sugerido_id' then nullif(p ->> 'responsable_sugerido_id', '')::uuid else responsable_sugerido_id end
   where id = v_c.id;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'CATEGORIA_MODIFICADA', v_c.nombre || ' (' || v_c.departamento_id || ')', null, p);
end $$;

create or replace function public.fn_admin_config_guardar(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_dias integer;
begin
  perform app.exigir('admin.catalogos');
  if p ? 'asignacion_automatica' then
    update public.configuracion set valor = to_jsonb((p ->> 'asignacion_automatica')::boolean), actualizado_por = v_u.id, actualizado_at = now()
     where clave = 'asignacion_automatica';
  end if;
  if p ? 'auto_cierre_dias' then
    v_dias := (p ->> 'auto_cierre_dias')::integer;
    perform app.validar(v_dias between 1 and 15, 'Los días de auto-cierre deben estar entre 1 y 15.');
    update public.configuracion set valor = to_jsonb(v_dias), actualizado_por = v_u.id, actualizado_at = now() where clave = 'auto_cierre_dias';
  end if;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'CONFIGURACION', 'Parámetros actualizados', null, p);
end $$;

/** Publica una nueva versión de SLA. p_valores: [{categoria_id|null, prioridad_id, minutos_primera_respuesta, minutos_asignacion, minutos_resolucion, horas_maximo_atencion}] */
create or replace function public.fn_sla_nueva_version(p_valores jsonb, p_umbral numeric, p_nota text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles := app.actor();
  v_ver integer;
begin
  perform app.exigir('sla.configurar');
  perform app.validar(jsonb_typeof(p_valores) = 'array', 'Formato de valores no válido.');
  perform app.validar(p_umbral >= 0.5 and p_umbral < 1, 'El umbral de alerta debe estar entre 50 % y 99 %.');
  perform app.validar((select count(distinct x ->> 'prioridad_id') from jsonb_array_elements(p_valores) x
                        where nullif(x ->> 'categoria_id', '') is null) = 4,
                      'Defina los tiempos generales para las cuatro prioridades.');
  update public.sla_versiones set vigente_hasta = now() where vigente_hasta is null;
  select coalesce(max(version), 0) + 1 into v_ver from public.sla_versiones;
  insert into public.sla_versiones (version, umbral, nota, creado_por)
  values (v_ver, p_umbral, app.texto(p_nota, 3, 'La nota de la versión'), v_u.id);
  insert into public.sla_valores (version, categoria_id, prioridad_id, minutos_primera_respuesta, minutos_asignacion, minutos_resolucion, horas_maximo_atencion)
  select v_ver, nullif(x ->> 'categoria_id', ''), x ->> 'prioridad_id',
         (x ->> 'minutos_primera_respuesta')::integer, (x ->> 'minutos_asignacion')::integer,
         (x ->> 'minutos_resolucion')::integer, (x ->> 'horas_maximo_atencion')::integer
  from jsonb_array_elements(p_valores) x;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'SLA_NUEVA_VERSION', 'Versión ' || v_ver || ' vigente. Los tickets existentes conservan su versión.', null, p_valores);
  return v_ver;
end $$;

create or replace function public.fn_calendario_guardar(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor();
begin
  perform app.exigir('sla.configurar');
  perform app.validar(jsonb_typeof(p) = 'array', 'Formato no válido.');
  delete from public.calendario_laboral;
  insert into public.calendario_laboral (dia_semana, hora_inicio, hora_fin)
  select (x ->> 'dia_semana')::smallint, (x ->> 'hora_inicio')::time, (x ->> 'hora_fin')::time from jsonb_array_elements(p) x;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'CALENDARIO', 'Calendario laboral actualizado (los tiempos ya cumplidos no cambian)', null, p);
end $$;

create or replace function public.fn_feriado_agregar(p_fecha date, p_nombre text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor();
begin
  perform app.exigir('sla.configurar');
  perform app.validar(not exists (select 1 from public.feriados where fecha = p_fecha), 'Ese feriado ya existe.');
  insert into public.feriados (fecha, nombre) values (p_fecha, app.texto(p_nombre, 3, 'El nombre'));
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'FERIADO_AGREGADO', p_fecha || ' ' || p_nombre);
end $$;

create or replace function public.fn_feriado_quitar(p_fecha date)
returns void language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles := app.actor();
begin
  perform app.exigir('sla.configurar');
  delete from public.feriados where fecha = p_fecha;
  if not found then perform app.error('NO_ENCONTRADO', 'Feriado no encontrado.'); end if;
  perform app.auditar(v_u.id, 'ADMINISTRATIVA', 'FERIADO_ELIMINADO', p_fecha::text);
end $$;

/* =========================== Procesos programados (pg_cron) =========================== */
create or replace function app.procesos_programados()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
  m record;
  v_dias integer := coalesce((app.config_valor('auto_cierre_dias'))::text::integer, 3);
  v_sla jsonb;
  v_clave text;
begin
  -- 1. Auto-cierre de tickets resueltos sin confirmación (D-08)
  for r in select id, solicitante_id, responsable_id, resuelto_at from public.tickets
           where estado_id = 'RESUELTO' and not anulado for update skip locked loop
    if app.dias_habiles(r.resuelto_at, now()) >= v_dias then
      update public.tickets set cerrado_at = now() where id = r.id;
      perform app.transicion(r.id, 'CERRADO', null, 'Cierre automático: sin confirmación en ' || v_dias || ' días hábiles');
      perform app.notificar(array[r.solicitante_id, r.responsable_id], null, 'cerrado', r.id, 'Cierre automático por falta de confirmación');
    end if;
  end loop;

  -- 2. Alertas de SLA (una por métrica y nivel)
  for r in select t.id, t.responsable_id from public.tickets t join public.estados e on e.id = t.estado_id
           join public.ticket_sla s on s.ticket_id = t.id
           where e.abierto and not t.anulado loop
    v_sla := app.sla_evaluar(r.id);
    for m in select key, value from jsonb_each(v_sla -> 'metricas') where value ->> 'estado' in ('amarillo', 'rojo') loop
      v_clave := m.key || ':' || (m.value ->> 'estado');
      if not exists (select 1 from public.ticket_sla where ticket_id = r.id and notificado ? v_clave) then
        update public.ticket_sla set notificado = notificado || jsonb_build_object(v_clave, now()) where ticket_id = r.id;
        perform app.notificar(case when r.responsable_id is null then app.supervisores() else array[r.responsable_id] end, null,
          case when m.value ->> 'estado' = 'rojo' then 'sla_vencido' else 'sla_proximo' end, r.id,
          (case when m.value ->> 'estado' = 'rojo' then 'SLA vencido: ' else 'Próximo a vencer: ' end) ||
          case m.key when 'primera_respuesta' then 'Primera respuesta' when 'asignacion' then 'Asignación' else 'Resolución' end);
      end if;
    end loop;
  end loop;

  -- 3. Evidencias preparadas pero nunca cargadas
  update public.evidencias set estado = 'EXPIRADA' where estado = 'PENDIENTE' and creado_at < now() - interval '24 hours';
end $$;

commit;
