-- =============================================================================
-- 98_pruebas_funcionales.sql — Flujos completos (caminos positivos)
-- Requiere 01–10 y 90_datos_demo.sql (calendario y SLA de prueba).
-- Todo termina en ROLLBACK. Cada prueba imprime "OK Fn"; se detiene en "FALLA Fn".
-- =============================================================================
begin;

/* ---------- Usuarios de prueba ---------- */
insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', u.id::uuid, 'authenticated', 'authenticated', u.correo, '{}'::jsonb,
       jsonb_build_object('nombre', u.nombre), now(), now()
from (values
  ('00000000-0000-4000-b000-000000000001', 'ana.f@prueba.invalid', 'Ana Funcional'),
  ('00000000-0000-4000-b000-000000000002', 'carlos.f@prueba.invalid', 'Carlos Funcional'),
  ('00000000-0000-4000-b000-000000000003', 'diego.f@prueba.invalid', 'Diego Funcional'),
  ('00000000-0000-4000-b000-000000000004', 'maria.f@prueba.invalid', 'María Funcional'),
  ('00000000-0000-4000-b000-000000000005', 'jose.f@prueba.invalid', 'José Funcional'),
  ('00000000-0000-4000-b000-000000000006', 'sofia.f@prueba.invalid', 'Sofía Funcional'),
  ('00000000-0000-4000-b000-000000000008', 'admin.f@prueba.invalid', 'Admin Funcional')
) as u(id, correo, nombre);
update public.perfiles p set rol_id = v.rol, departamento_id = v.dep, activo = true
from (values
  ('00000000-0000-4000-b000-000000000001', 'SOLICITANTE', 'COM'), ('00000000-0000-4000-b000-000000000002', 'SOLICITANTE', 'COM'),
  ('00000000-0000-4000-b000-000000000003', 'SOLICITANTE', 'LIQ'), ('00000000-0000-4000-b000-000000000004', 'OPERADOR_TRANSPORTES', 'TRA'),
  ('00000000-0000-4000-b000-000000000005', 'OPERADOR_TRANSPORTES', 'TRA'), ('00000000-0000-4000-b000-000000000006', 'SUPERVISOR_TRANSPORTES', 'TRA'),
  ('00000000-0000-4000-b000-000000000008', 'ADMINISTRADOR', 'SIS')
) as v(id, rol, dep) where p.id = v.id::uuid;
insert into public.operador_alcance values ('00000000-0000-4000-b000-000000000004', 'COM'), ('00000000-0000-4000-b000-000000000005', 'LIQ');
insert into public.perfil_permisos (perfil_id, permiso_id, otorgado_por)
select '00000000-0000-4000-b000-000000000005', x, '00000000-0000-4000-b000-000000000008'
from unnest(array['financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar']) x;

/* ---------- F1. Horas hábiles (calendario DEMO: L-V 07-17, S 07-12; feriado 2026-12-01) ---------- */
do $$ begin
  if app.minutos_habiles('2026-11-16 07:00-06', '2026-11-16 09:00-06') <> 120 then raise exception 'FALLA F1a: lunes 07-09 debe ser 120'; end if;
  if app.minutos_habiles('2026-11-20 16:00-06', '2026-11-23 08:00-06') <> 420 then raise exception 'FALLA F1b: viernes 16:00 → lunes 08:00 debe ser 420 (60 + sábado 300 + 60)'; end if;
  if app.minutos_habiles('2026-11-30 16:00-06', '2026-12-02 08:00-06') <> 120 then raise exception 'FALLA F1c: el feriado no se descontó'; end if;
  if app.minutos_habiles('2026-11-22 08:00-06', '2026-11-22 18:00-06') <> 0 then raise exception 'FALLA F1d: domingo debe ser 0'; end if;
  if app.dias_habiles('2026-11-20 10:00-06', '2026-11-23 10:00-06') <> 2 then raise exception 'FALLA F1e: días hábiles vie→lun debe ser 2'; end if;
  raise notice 'OK F1: horas y días hábiles con calendario, sábado parcial, domingo y feriado';
end $$;

/* ---------- F2. Flujo completo de un ticket de Comercial ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; v_id uuid;
begin
  r := public.fn_ticket_crear('{"categoria_id":"COM-04","asunto":"Cambio de horario funcional","descripcion":"Cliente pide recibir en la tarde",
        "datos":{"cliente":"C-1003","fecha_entrega":"2026-11-18","horario":"14:00 – 16:00","ruta":"R-101"}}'::jsonb);
  v_id := (r ->> 'id')::uuid;
  perform set_config('f.t1', v_id::text, true);
  if r ->> 'estado_id' <> 'NUEVO' or r ->> 'numero' !~ '^TS-\d{4}-\d{6}$' then raise exception 'FALLA F2a: alta incorrecta %', r; end if;
  if (select (sla ->> 'global') from public.v_tickets where id = v_id) is null then raise exception 'FALLA F2b: sin semáforo SLA'; end if;
  if (select cliente_nombre from public.v_tickets where id = v_id) is null then raise exception 'FALLA F2c: la vista no resuelve el cliente'; end if;
  raise notice 'OK F2a: ticket % creado con SLA % y datos resueltos', r ->> 'numero', (select sla ->> 'global' from public.v_tickets where id = v_id);
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := current_setting('f.t1')::uuid; v_resp jsonb;
begin
  if not (public.fn_ticket_acciones(v_id) @> '[{"codigo":"asignar"}]') then raise exception 'FALLA F2d: el supervisor no ve la acción asignar'; end if;
  v_resp := public.fn_responsables_para(v_id);
  if not exists (select 1 from jsonb_array_elements(v_resp) x where x ->> 'id' = '00000000-0000-4000-b000-000000000004' and (x ->> 'sugerido')::boolean) then
    raise exception 'FALLA F2e: María debería ser la sugerida (única operadora elegible con alcance COM): %', v_resp;
  end if;
  perform public.fn_ticket_accion(v_id, 'tomar_revision', '{}'::jsonb);
  perform public.fn_ticket_accion(v_id, 'asignar', '{"responsable_id":"00000000-0000-4000-b000-000000000004","sugerido":true}'::jsonb);
  if (select tipo from public.asignaciones where ticket_id = v_id and hasta is null) <> 'SUGERIDA' then raise exception 'FALLA F2f: tipo de asignación'; end if;
  if (select primera_respuesta_at from public.tickets where id = v_id) is null then raise exception 'FALLA F2g: primera respuesta no marcada'; end if;
  if (select min_primera_respuesta from public.ticket_sla where ticket_id = v_id) is null then raise exception 'FALLA F2h: minutos de primera respuesta no congelados'; end if;
  raise notice 'OK F2b: revisión, responsable sugerido por carga/alcance, asignación y SLA congelado';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := current_setting('f.t1')::uuid;
begin
  perform public.fn_ticket_accion(v_id, 'iniciar', '{}'::jsonb);
  perform public.fn_ticket_accion(v_id, 'espera', '{"motivo_id":"INFO_SOLICITANTE","detalle":"Confirme el teléfono del encargado"}'::jsonb);
  if (select estado_id || '/' || estado_previo from public.tickets where id = v_id) <> 'EN_ESPERA/EN_PROCESO' then raise exception 'FALLA F2i: espera'; end if;
  if not exists (select 1 from public.sla_pausas where ticket_id = v_id and fin is null) then raise exception 'FALLA F2j: no abrió la pausa SLA'; end if;
  if not (select pendiente_info from public.v_tickets where id = v_id) then raise exception 'FALLA F2k: no marca información pendiente'; end if;
  raise notice 'OK F2c: en espera por información del solicitante, con SLA en pausa';
end $$;
reset role;

-- Un COMPAÑERO del mismo departamento responde (visibilidad por departamento)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := current_setting('f.t1')::uuid;
begin
  perform public.fn_ticket_responder_info(v_id, 'Teléfono 2222-0000, encargado Luis');
  if (select estado_id from public.tickets where id = v_id) <> 'EN_PROCESO' then raise exception 'FALLA F2l: no se reanudó automáticamente'; end if;
  if exists (select 1 from public.sla_pausas where ticket_id = v_id and fin is null) then raise exception 'FALLA F2m: la pausa quedó abierta'; end if;
  raise notice 'OK F2d: respuesta de un compañero reanuda el ticket y cierra la pausa (D-07)';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform public.fn_ticket_comentar(current_setting('f.t1')::uuid, 'Coordinado con el chofer', 'INTERNO');
  perform public.fn_ticket_accion(current_setting('f.t1')::uuid, 'resolver', '{"resolucion":"Entrega reprogramada a las 14:30"}'::jsonb);
  if (select min_resolucion from public.ticket_sla where ticket_id = current_setting('f.t1')::uuid) is null then raise exception 'FALLA F2n: resolución no congelada'; end if;
  raise notice 'OK F2e: resuelto con minutos de resolución congelados';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := current_setting('f.t1')::uuid;
begin
  if not exists (select 1 from public.notificaciones where ticket_id = v_id and evento = 'resuelto') then raise exception 'FALLA F2o: Ana no fue notificada'; end if;
  perform public.fn_ticket_accion(v_id, 'solicitar_reapertura', '{"motivo":"El cliente no recibió"}'::jsonb);
  if (select estado_id || '/' || reaperturas from public.tickets where id = v_id) <> 'EN_PROCESO/1' then raise exception 'FALLA F2p: reapertura'; end if;
  if (select min_resolucion from public.ticket_sla where ticket_id = v_id) is not null then raise exception 'FALLA F2q: no se limpió la resolución congelada'; end if;
  if not exists (select 1 from public.sla_pausas where ticket_id = v_id and motivo = 'RESUELTO') then raise exception 'FALLA F2r: el tiempo resuelto no se excluyó del SLA'; end if;
  raise notice 'OK F2f: reapertura del solicitante (el tiempo resuelto no cuenta para el SLA)';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$ begin perform public.fn_ticket_accion(current_setting('f.t1')::uuid, 'resolver', '{"resolucion":"Entregado y confirmado por el cliente"}'::jsonb); end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := current_setting('f.t1')::uuid; n_pub integer; n_tot integer;
begin
  perform public.fn_ticket_accion(v_id, 'confirmar', '{}'::jsonb);
  if (select estado_id from public.tickets where id = v_id) <> 'CERRADO' then raise exception 'FALLA F2s: no cerró'; end if;
  select count(*) into n_pub from public.historial_tickets where ticket_id = v_id;
  perform set_config('f.n_pub', n_pub::text, true);
  if (select sla ->> 'global' from public.v_tickets where id = v_id) not in ('cumplido', 'incumplido') then raise exception 'FALLA F2t: SLA final'; end if;
  raise notice 'OK F2g: confirmado y cerrado; el solicitante ve % eventos públicos', n_pub;
end $$;
reset role;
do $$
declare n integer;
begin
  select count(*) into n from public.historial_tickets where ticket_id = current_setting('f.t1')::uuid;
  if n <= current_setting('f.n_pub')::integer then raise exception 'FALLA F2u: faltan eventos internos en el historial'; end if;
  raise notice 'OK F2h: historial completo con % eventos (incluye internos)', n;
end $$;

/* ---------- F3. Rechazo, reapertura, cierre excepcional, anulación, prioridad ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('f.t2', public.fn_ticket_crear('{"categoria_id":"COM-11","asunto":"Consulta A","descripcion":"Consulta sobre la entrega de ayer","datos":{"cliente":"C-1002"}}'::jsonb) ->> 'id', true);
  perform set_config('f.t3', public.fn_ticket_crear('{"categoria_id":"COM-11","asunto":"Consulta B","descripcion":"Consulta sobre la entrega de hoy","datos":{"cliente":"C-1002"}}'::jsonb) ->> 'id', true);
  perform set_config('f.t4', public.fn_ticket_crear('{"categoria_id":"COM-11","asunto":"Consulta C","descripcion":"Consulta duplicada por error","datos":{"cliente":"C-1002"}}'::jsonb) ->> 'id', true);
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_obj_antes integer; v_obj_despues integer;
begin
  perform public.fn_ticket_accion(current_setting('f.t2')::uuid, 'rechazar', '{"motivo_id":"DUPLICADO","justificacion":"Ya existe una solicitud igual en curso"}'::jsonb);
  if (select estado_id from public.tickets where id = current_setting('f.t2')::uuid) <> 'RECHAZADO' then raise exception 'FALLA F3a'; end if;
  perform public.fn_ticket_accion(current_setting('f.t2')::uuid, 'reabrir', '{"motivo":"No era duplicado"}'::jsonb);
  if (select estado_id from public.tickets where id = current_setting('f.t2')::uuid) <> 'EN_REVISION' then raise exception 'FALLA F3b: reabrir sin responsable debe ir a revisión'; end if;

  perform public.fn_ticket_accion(current_setting('f.t3')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-b000-000000000004"}'::jsonb);
  select obj_resolucion into v_obj_antes from public.ticket_sla where ticket_id = current_setting('f.t3')::uuid;
  perform public.fn_ticket_accion(current_setting('f.t3')::uuid, 'cambiar_prioridad', '{"prioridad":"CRITICA","motivo":"Cliente estratégico"}'::jsonb);
  select obj_resolucion into v_obj_despues from public.ticket_sla where ticket_id = current_setting('f.t3')::uuid;
  if v_obj_despues >= v_obj_antes or v_obj_despues <> 240 then raise exception 'FALLA F3c: objetivos SLA no recalculados (% → %)', v_obj_antes, v_obj_despues; end if;
  perform public.fn_ticket_accion(current_setting('f.t3')::uuid, 'espera', '{"motivo_id":"VEHICULO","detalle":"Sin vehículo refrigerado hoy"}'::jsonb);
  if exists (select 1 from public.sla_pausas where ticket_id = current_setting('f.t3')::uuid) then raise exception 'FALLA F3d: el motivo VEHICULO no debe pausar el SLA'; end if;
  perform public.fn_ticket_accion(current_setting('f.t3')::uuid, 'cierre_excepcional', '{"justificacion":"El cliente canceló el pedido"}'::jsonb);
  if (select estado_id || coalesce(estado_previo, '-') from public.tickets where id = current_setting('f.t3')::uuid) <> 'CERRADO-' then raise exception 'FALLA F3e: cierre excepcional'; end if;
  if (select sla -> 'metricas' -> 'resolucion' ->> 'estado' from public.v_tickets where id = current_setting('f.t3')::uuid) <> 'na' then raise exception 'FALLA F3f: la resolución debe quedar excluida'; end if;

  perform public.fn_ticket_accion(current_setting('f.t4')::uuid, 'anular', '{"motivo":"Creado por error"}'::jsonb);
  if public.fn_ticket_acciones(current_setting('f.t4')::uuid) <> '[]'::jsonb then raise exception 'FALLA F3g: un ticket anulado no debe tener acciones'; end if;
  raise notice 'OK F3: rechazo con justificación, reapertura a revisión, prioridad con SLA recalculado, espera sin pausa, cierre excepcional y anulación';
end $$;
reset role;
do $$ begin
  if (select count(*) from public.auditoria where accion in ('CIERRE_EXCEPCIONAL', 'ANULACION')) < 2 then raise exception 'FALLA F3h: auditoría'; end if;
  raise notice 'OK F3b: cierre excepcional y anulación auditados';
end $$;

/* ---------- F4. Liquidaciones: investigación, conclusión, recuperación ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('f.liq', public.fn_ticket_crear('{"categoria_id":"LIQ-01","asunto":"Diferencia ruta R-105","descripcion":"Diferencia en liquidación de ruta",
    "datos":{"ruta":"R-105","fecha_operacion":"2026-11-12","chofer":"CH-01","ayudante":"AY-01","num_liquidacion":"LQ-1","tipo_diferencia":"Faltante",
             "monto_esperado":"500000","monto_reportado":"60000","monto_recibido":"440000"}}'::jsonb) ->> 'id', true);
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform public.fn_ticket_accion(current_setting('f.liq')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-b000-000000000005"}'::jsonb);
  perform public.fn_inv_asignar((select id from public.investigaciones where ticket_id = current_setting('f.liq')::uuid), '00000000-0000-4000-b000-000000000005');
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000005","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_inv uuid; v_dif uuid; s record;
begin
  select id into v_inv from public.investigaciones where ticket_id = current_setting('f.liq')::uuid;
  select id into v_dif from public.liquidacion_diferencias where ticket_id = current_setting('f.liq')::uuid;
  if (select count(*) from public.investigacion_involucrados where investigacion_id = v_inv) <> 2 then raise exception 'FALLA F4a: involucrados'; end if;
  perform public.fn_ticket_accion(current_setting('f.liq')::uuid, 'iniciar', '{}'::jsonb);
  perform public.fn_inv_hallazgo(v_inv, 'Dos facturas sin sello de recibido');
  perform public.fn_inv_aclaracion(v_inv, 'Favor enviar copia de las facturas 101 y 102');
  if (select estado from public.investigaciones where id = v_inv) <> 'EN_ACLARACION' then raise exception 'FALLA F4b: aclaración'; end if;
  perform public.fn_movimiento_registrar(v_dif, 'ACLARACION', 20000, 'Factura 101 respaldada');
  perform public.fn_inv_concluir(v_inv, 'ERROR_OPERATIVO', 'Se determinó un error operativo en el cobro de la factura 102.');
  begin
    perform public.fn_movimiento_registrar(v_dif, 'ACLARACION', 1000, 'Después de concluir');
    raise exception 'FALLA F4c: aceptó una aclaración con la investigación concluida';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  perform public.fn_movimiento_registrar(v_dif, 'RECUPERACION', 40000, 'Recuperación autorizada', null, 'Depósito del colaborador', 'DEP-77', '2026-11-14');
  select * into s from app.saldos_diferencia(v_dif);
  if (s.base, s.aclarado, s.recuperado, s.pendiente) <> (60000::numeric, 20000::numeric, 40000::numeric, 0::numeric) then raise exception 'FALLA F4d: saldos %', s; end if;
  if (select pendiente from reporting.v_diferencias where diferencia_id = v_dif) <> 0 then raise exception 'FALLA F4e: reporte de diferencias'; end if;
  perform public.fn_ticket_accion(current_setting('f.liq')::uuid, 'resolver', '{"resolucion":"Investigación concluida y monto recuperado"}'::jsonb);
  raise notice 'OK F4: investigación (hallazgo, aclaración, conclusión), aclaración + recuperación = diferencia, resolución habilitada';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if (select resultado_id from public.investigaciones where ticket_id = current_setting('f.liq')::uuid) <> 'ERROR_OPERATIVO' then raise exception 'FALLA F4f: Liquidaciones no ve el resultado'; end if;
  if (select count(*) from public.movimientos_financieros) <> 2 then raise exception 'FALLA F4g: Liquidaciones debe ver los 2 movimientos'; end if;
  raise notice 'OK F4b: Liquidaciones ve resultado y movimientos de su ticket';
end $$;
reset role;

/* ---------- F4c. El operador asignado al ticket gestiona la investigación sin esperar a Supervisión ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('f.liq2', public.fn_ticket_crear('{"categoria_id":"LIQ-01","asunto":"Diferencia ruta R-106","descripcion":"Diferencia en liquidación de ruta",
    "datos":{"ruta":"R-105","fecha_operacion":"2026-11-13","chofer":"CH-01","ayudante":"AY-01","num_liquidacion":"LQ-2","tipo_diferencia":"Faltante",
             "monto_esperado":"100000","monto_reportado":"10000","monto_recibido":"90000"}}'::jsonb) ->> 'id', true);
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  -- Solo se asigna el ticket: la investigación (sin responsable) debe pasar al mismo operador
  perform public.fn_ticket_accion(current_setting('f.liq2')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-b000-000000000005"}'::jsonb);
end $$;
reset role;
do $$ begin
  if (select responsable_id from public.investigaciones where ticket_id = current_setting('f.liq2')::uuid) is distinct from '00000000-0000-4000-b000-000000000005'::uuid
    then raise exception 'FALLA F4h: la investigación no pasó al responsable del ticket'; end if;
  -- Caso de datos previos: investigación sin responsable con el ticket ya asignado
  update public.investigaciones set responsable_id = null where ticket_id = current_setting('f.liq2')::uuid;
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000005","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_inv uuid; v_acc jsonb;
begin
  select id into v_inv from public.investigaciones where ticket_id = current_setting('f.liq2')::uuid;
  perform public.fn_ticket_accion(current_setting('f.liq2')::uuid, 'iniciar', '{}'::jsonb);
  v_acc := public.fn_ticket_acciones(current_setting('f.liq2')::uuid);
  if not exists (select 1 from jsonb_array_elements(v_acc) a where a ->> 'codigo' = 'resolver' and a ->> 'bloqueo' is null)
    then raise exception 'FALLA F4i: resolver debe estar habilitado para quien gestiona la investigación %', v_acc; end if;
  -- Sin resultado no se resuelve
  begin
    perform public.fn_ticket_accion(current_setting('f.liq2')::uuid, 'resolver', '{"resolucion":"Se documentó la diferencia con el chofer"}'::jsonb);
    raise exception 'FALLA F4j: resolvió sin resultado de investigación';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  -- Sin indicar cómo se cierra el faltante no se resuelve
  begin
    perform public.fn_ticket_accion(current_setting('f.liq2')::uuid, 'resolver',
      '{"resultado_inv":"ERROR_OPERATIVO","resolucion":"Se conversó con el chofer y se aplica la boleta de rebajo."}'::jsonb);
    raise exception 'FALLA F4j2: resolvió sin cerrar el faltante';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  -- Un solo paso: resolver concluye la investigación y cierra el faltante (₡4 000 aclarado + ₡6 000 recuperado)
  perform public.fn_ticket_accion(current_setting('f.liq2')::uuid, 'resolver',
    '{"resultado_inv":"ERROR_OPERATIVO","resolucion":"Se conversó con el chofer y se aplica la boleta de rebajo.",
      "cierre_dif":{"tipo":"MIXTO","monto_aclarado":"4000","forma":"Boleta de rebajo","comprobante":"BR-15"}}'::jsonb);
  declare s record; begin
    select * into s from app.saldos_diferencia((select id from public.liquidacion_diferencias where ticket_id = current_setting('f.liq2')::uuid));
    if (s.aclarado, s.recuperado, s.pendiente) <> (4000::numeric, 6000::numeric, 0::numeric) then raise exception 'FALLA F4m: saldos al resolver %', s; end if;
  end;
  if not exists (select 1 from public.recuperaciones r join public.movimientos_financieros m on m.id = r.movimiento_id
                  where m.ticket_id = current_setting('f.liq2')::uuid and r.forma = 'Boleta de rebajo' and r.comprobante = 'BR-15')
    then raise exception 'FALLA F4n: recuperación sin forma/comprobante'; end if;
  if (select (estado, resultado_id, responsable_id) from public.investigaciones where id = v_inv)
     is distinct from ('CONCLUIDA'::text, 'ERROR_OPERATIVO'::text, '00000000-0000-4000-b000-000000000005'::uuid)
    then raise exception 'FALLA F4k: la resolución no concluyó la investigación'; end if;
  if (select estado_id from public.tickets where id = current_setting('f.liq2')::uuid) <> 'RESUELTO'
    then raise exception 'FALLA F4l: el ticket no quedó resuelto'; end if;
  raise notice 'OK F4c: el coordinador asignado resuelve el ticket y concluye la investigación en un solo paso';
end $$;
reset role;

-- Un operador que no es responsable del ticket ni de la investigación no puede concluirla
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000004","role":"authenticated"}', true);
do $$ begin
  if app.puede_gestionar_inv('00000000-0000-4000-b000-000000000004', (select i from public.investigaciones i where ticket_id = current_setting('f.liq')::uuid))
    then raise exception 'FALLA F4k: otro operador puede gestionar la investigación'; end if;
  raise notice 'OK F4d: otro operador no gestiona investigaciones ajenas';
end $$;

/* ---------- F5. Evidencias: preparar → subir → confirmar → leer ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.fn_evidencia_preparar(current_setting('f.t2')::uuid, 'foto.jpg', 2048, 'image/jpeg');
  insert into storage.objects (bucket_id, name, owner) values ('evidencias', r ->> 'ruta', auth.uid());
  perform public.fn_evidencia_confirmar((r ->> 'id')::uuid);
  perform set_config('f.ruta', r ->> 'ruta', true);
  raise notice 'OK F5a: evidencia subida a la ruta reservada y confirmada';
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if (select count(*) from storage.objects where name = current_setting('f.ruta')) <> 1 then raise exception 'FALLA F5b: un compañero de COM debe poder leer la evidencia'; end if;
  raise notice 'OK F5b: compañero del departamento puede descargar (URL firmada)';
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if (select count(*) from storage.objects where name = current_setting('f.ruta')) <> 0 then raise exception 'FALLA F5c: Liquidaciones lee una evidencia de Comercial'; end if;
  raise notice 'OK F5c: otro departamento no puede leer la evidencia';
end $$;
reset role;

/* ---------- F6. Administración y SLA versionado ---------- */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000008","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v integer;
begin
  v := public.fn_sla_nueva_version('[
    {"prioridad_id":"CRITICA","minutos_primera_respuesta":20,"minutos_asignacion":40,"minutos_resolucion":200,"horas_maximo_atencion":24},
    {"prioridad_id":"ALTA","minutos_primera_respuesta":45,"minutos_asignacion":90,"minutos_resolucion":400,"horas_maximo_atencion":48},
    {"prioridad_id":"MEDIA","minutos_primera_respuesta":90,"minutos_asignacion":180,"minutos_resolucion":900,"horas_maximo_atencion":96},
    {"prioridad_id":"BAJA","minutos_primera_respuesta":200,"minutos_asignacion":400,"minutos_resolucion":2000,"horas_maximo_atencion":168},
    {"categoria_id":"COM-11","prioridad_id":"BAJA","minutos_primera_respuesta":100,"minutos_asignacion":200,"minutos_resolucion":1000,"horas_maximo_atencion":120}]'::jsonb,
    0.8, 'Prueba funcional');
  perform set_config('f.ver', v::text, true);
  perform public.fn_admin_usuario_guardar('00000000-0000-4000-b000-000000000004', '{"disponible":false}'::jsonb);
  perform public.fn_feriado_agregar('2027-04-11', 'Juan Santamaría (prueba)');
  raise notice 'OK F6a: nueva versión de SLA %, operadora marcada no disponible, feriado agregado', v;
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('f.t5', public.fn_ticket_crear('{"categoria_id":"COM-11","asunto":"Consulta posterior","descripcion":"Creada después del nuevo SLA","datos":{"cliente":"C-1001"}}'::jsonb) ->> 'id', true);
end $$;
reset role;
do $$ begin
  if (select version from public.ticket_sla where ticket_id = current_setting('f.t2')::uuid) <> 1 then raise exception 'FALLA F6b: el ticket anterior cambió de versión'; end if;
  if (select version || '/' || obj_resolucion from public.ticket_sla where ticket_id = current_setting('f.t5')::uuid) <> current_setting('f.ver') || '/1000' then
    raise exception 'FALLA F6c: el ticket nuevo no tomó la versión nueva ni el valor por categoría';
  end if;
  raise notice 'OK F6b: tickets previos conservan v1; el nuevo usa v% con el valor específico de la categoría', current_setting('f.ver');
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if exists (select 1 from jsonb_array_elements(public.fn_responsables_para(current_setting('f.t5')::uuid)) x
             where x ->> 'id' = '00000000-0000-4000-b000-000000000004' and x ->> 'no_elegible' is null) then
    raise exception 'FALLA F6d: una operadora no disponible aparece como elegible';
  end if;
  raise notice 'OK F6c: usuarios no disponibles quedan fuera de la asignación';
end $$;
reset role;

/* ---------- F7. Procesos programados: auto-cierre y alertas SLA ---------- */
alter table public.tickets disable trigger tickets_inmutables;   -- solo dentro de esta transacción de prueba
update public.tickets set creado_at = now() - interval '7 days' where id = current_setting('f.t5')::uuid;
update public.tickets set estado_id = 'RESUELTO', resolucion = 'Resuelto para prueba', resuelto_at = now() - interval '10 days',
                          responsable_id = '00000000-0000-4000-b000-000000000006', asignado_at = now() - interval '10 days'
 where id = current_setting('f.t2')::uuid;
alter table public.tickets enable trigger tickets_inmutables;
select app.procesos_programados();
do $$ begin
  if (select estado_id from public.tickets where id = current_setting('f.t2')::uuid) <> 'CERRADO' then raise exception 'FALLA F7a: no hubo auto-cierre'; end if;
  if not exists (select 1 from public.notificaciones where ticket_id = current_setting('f.t5')::uuid and evento = 'sla_vencido') then
    raise exception 'FALLA F7b: no se generó la alerta de SLA vencido';
  end if;
  perform app.procesos_programados();
  if (select count(*) from public.notificaciones where ticket_id = current_setting('f.t5')::uuid and evento = 'sla_vencido') <>
     (select count(*) from jsonb_object_keys((select notificado from public.ticket_sla where ticket_id = current_setting('f.t5')::uuid)) k where k like '%:rojo')
     * (select count(*) from public.perfiles where activo and rol_id = 'SUPERVISOR_TRANSPORTES') then
    raise exception 'FALLA F7c: alertas duplicadas al repetir el proceso';
  end if;
  raise notice 'OK F7: auto-cierre a los 3 días hábiles; alertas SLA sin duplicados';
end $$;

/* ---------- F8. Supervisor de Liquidaciones: solo Liquidaciones, dashboard y reportes, sin gestionar ---------- */
insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-b000-000000000009', 'authenticated', 'authenticated', 'superliq.f@prueba.invalid', '{}'::jsonb,
        '{"nombre":"Supervisora Liquidaciones"}'::jsonb, now(), now());
update public.perfiles set rol_id = 'SUPERVISOR_LIQUIDACIONES', departamento_id = 'LIQ', activo = true where id = '00000000-0000-4000-b000-000000000009';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000009","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v jsonb := public.fn_mi_perfil();
begin
  if not (v -> 'permisos') ?& array['dashboard.liquidaciones', 'reporte.completo', 'financiero.ver', 'ticket.crear', 'ticket.confirmar']
    then raise exception 'FALLA F8a: permisos efectivos %', v -> 'permisos'; end if;
  if (v -> 'permisos') ?| array['ticket.ver_todos', 'ticket.gestionar_todos', 'financiero.registrar', 'investigacion.gestionar', 'dashboard.gerencial']
    then raise exception 'FALLA F8b: permisos de más %', v -> 'permisos'; end if;
  if exists (select 1 from public.tickets where departamento_id <> 'LIQ') then raise exception 'FALLA F8c: ve tickets de otros departamentos'; end if;
  if not exists (select 1 from public.tickets where departamento_id = 'LIQ') then raise exception 'FALLA F8d: no ve los tickets de Liquidaciones'; end if;
  if exists (select 1 from reporting.v_diferencias v join public.tickets t on t.id = v.ticket_id where t.departamento_id <> 'LIQ') then raise exception 'FALLA F8e: diferencias ajenas'; end if;
  perform public.fn_exportacion_registrar('Dashboard de Liquidaciones', 'XLSX', 3);
  perform set_config('f.liq4', public.fn_ticket_crear('{"categoria_id":"LIQ-10","asunto":"Viáticos de ruta","descripcion":"Solicitud de viáticos de prueba","datos":{"fecha_operacion":"2026-11-18","chofer":"CH-01"}}'::jsonb) ->> 'id', true);
  begin
    perform public.fn_ticket_accion(current_setting('f.liq4')::uuid, 'tomar_revision', '{}'::jsonb);
    raise exception 'FALLA F8f: gestionó un ticket';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK F8: Supervisor de Liquidaciones ve solo Liquidaciones, tiene dashboard y reportes, crea tickets y no gestiona';
end $$;
reset role;

/* ---------- F9. Super usuario: ve y gestiona todo, incluida la administración ---------- */
insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-b000-000000000010', 'authenticated', 'authenticated', 'super.f@prueba.invalid', '{}'::jsonb,
        '{"nombre":"Super Usuario Prueba"}'::jsonb, now(), now());
update public.perfiles set rol_id = 'SUPERUSUARIO', departamento_id = 'TRA', activo = true where id = '00000000-0000-4000-b000-000000000010';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-000000000010","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v jsonb := public.fn_mi_perfil(); n_perm int;
begin
  select count(*) into n_perm from jsonb_array_elements_text(v -> 'permisos');
  if n_perm <> (select count(*) from public.permisos) then raise exception 'FALLA F9a: tiene % de % permisos', n_perm, (select count(*) from public.permisos); end if;
  if (select count(distinct departamento_id) from public.tickets) < 2 then raise exception 'FALLA F9b: no ve todos los departamentos'; end if;
  if not exists (select 1 from reporting.v_diferencias) then raise exception 'FALLA F9c: no ve las diferencias'; end if;
  if jsonb_array_length(public.fn_admin_usuarios()) < 5 then raise exception 'FALLA F9d: no administra usuarios'; end if;
  perform public.fn_ticket_accion(current_setting('f.liq4')::uuid, 'tomar_revision', '{}'::jsonb);
  raise notice 'OK F9: super usuario con todos los permisos, ve todo, administra y gestiona';
end $$;
reset role;
do $$ begin
  if not app.es_transportes('00000000-0000-4000-b000-000000000010') then raise exception 'FALLA F9e: no cuenta como Transportes'; end if;
  if app.motivo_no_elegible('00000000-0000-4000-b000-000000000010', 'COM') is null then raise exception 'FALLA F9f: el super usuario no debe recibir asignaciones'; end if;
end $$;

do $$ begin raise notice '=== TODAS LAS PRUEBAS FUNCIONALES PASARON ==='; end $$;
rollback;
