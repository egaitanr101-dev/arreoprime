-- =============================================================================
-- 99_pruebas_seguridad.sql — Pruebas positivas y NEGATIVAS por rol
--
-- Ejecutar en un proyecto de DESARROLLO después de 01–11 (no requiere 90).
-- Todo ocurre dentro de una transacción que termina en ROLLBACK: no deja datos.
-- Cada prueba imprime "OK n" (pestaña Messages/Notices). Si una regla falla, el
-- script se detiene con "FALLA n: …".
--
-- Simula usuarios autenticados igual que PostgREST: rol "authenticated" + claims JWT.
-- =============================================================================
begin;

/* ============================ Datos de prueba ============================ */
insert into public.clientes (id, nombre) values ('T-CLI', 'Cliente de prueba') on conflict (id) do nothing;
insert into public.rutas (id, nombre) values ('T-RUT', 'Ruta de prueba') on conflict (id) do nothing;
insert into public.colaboradores (id, nombre, tipo) values ('T-CH', 'Chofer de prueba', 'CHOFER') on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', u.id::uuid, 'authenticated', 'authenticated', u.correo,
       '{}'::jsonb, jsonb_build_object('nombre', u.nombre), now(), now()
from (values
  ('00000000-0000-4000-a000-000000000001', 'ana@prueba.invalid', 'Ana Prueba (COM)'),
  ('00000000-0000-4000-a000-000000000002', 'carlos@prueba.invalid', 'Carlos Prueba (COM)'),
  ('00000000-0000-4000-a000-000000000003', 'diego@prueba.invalid', 'Diego Prueba (LIQ)'),
  ('00000000-0000-4000-a000-000000000004', 'maria@prueba.invalid', 'María Prueba (Operadora)'),
  ('00000000-0000-4000-a000-000000000005', 'jose@prueba.invalid', 'José Prueba (Operador fin.)'),
  ('00000000-0000-4000-a000-000000000006', 'sofia@prueba.invalid', 'Sofía Prueba (Supervisora)'),
  ('00000000-0000-4000-a000-000000000007', 'ger@prueba.invalid', 'Gerencia Prueba'),
  ('00000000-0000-4000-a000-000000000008', 'admin@prueba.invalid', 'Admin Prueba')
) as u(id, correo, nombre);

do $$ begin
  if (select count(*) from public.perfiles where correo like '%@prueba.invalid' and not activo) <> 8 then
    raise exception 'FALLA 0: el alta desde auth.users debe crear perfiles INACTIVOS';
  end if;
  raise notice 'OK 0: perfiles creados inactivos desde Supabase Auth';
end $$;

update public.perfiles p set rol_id = v.rol, departamento_id = v.dep, activo = true
from (values
  ('00000000-0000-4000-a000-000000000001', 'SOLICITANTE', 'COM'),
  ('00000000-0000-4000-a000-000000000002', 'SOLICITANTE', 'COM'),
  ('00000000-0000-4000-a000-000000000003', 'SOLICITANTE', 'LIQ'),
  ('00000000-0000-4000-a000-000000000004', 'OPERADOR_TRANSPORTES', 'TRA'),
  ('00000000-0000-4000-a000-000000000005', 'OPERADOR_TRANSPORTES', 'TRA'),
  ('00000000-0000-4000-a000-000000000006', 'SUPERVISOR_TRANSPORTES', 'TRA'),
  ('00000000-0000-4000-a000-000000000007', 'GERENCIA', 'GER'),
  ('00000000-0000-4000-a000-000000000008', 'ADMINISTRADOR', 'SIS')
) as v(id, rol, dep)
where p.id = v.id::uuid;

insert into public.operador_alcance (perfil_id, departamento_id) values
  ('00000000-0000-4000-a000-000000000004', 'COM'), ('00000000-0000-4000-a000-000000000004', 'ALM'),
  ('00000000-0000-4000-a000-000000000005', 'LIQ');
insert into public.perfil_permisos (perfil_id, permiso_id, otorgado_por)
select '00000000-0000-4000-a000-000000000005', x, '00000000-0000-4000-a000-000000000008'
from unnest(array['financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar']) x;

/* ============================ ANA (Solicitante COM) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.fn_ticket_crear('{"departamento_id":"LIQ","categoria_id":"COM-11","asunto":"Prueba de seguridad",
        "descripcion":"Ticket creado por la suite de pruebas","datos":{"cliente":"T-CLI"}}'::jsonb);
  if r ->> 'departamento_id' <> 'COM' then raise exception 'FALLA 1: el departamento no lo fijó el servidor'; end if;
  perform set_config('prueba.t_com', r ->> 'id', true);
  raise notice 'OK 1: departamento fijado desde el perfil (enviado LIQ → quedó COM), %', r ->> 'numero';
end $$;

do $$ begin
  begin
    perform public.fn_ticket_crear('{"categoria_id":"LIQ-02","asunto":"Intento indebido","descripcion":"Categoría de otro departamento","datos":{}}'::jsonb);
    raise exception 'FALLA 2: permitió usar una categoría de otro departamento';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if;
    raise notice 'OK 2: categoría de otro departamento bloqueada (%)', sqlerrm;
  end;
end $$;

do $$ begin
  begin
    insert into public.tickets (numero) values ('TS-2099-000001');
    raise exception 'FALLA 3: permitió INSERT directo en tickets';
  exception when insufficient_privilege then raise notice 'OK 3: INSERT directo en tickets denegado';
  end;
  begin
    update public.tickets set prioridad_id = 'CRITICA';
    raise exception 'FALLA 3b: permitió UPDATE directo en tickets';
  exception when insufficient_privilege then raise notice 'OK 3b: UPDATE directo en tickets denegado';
  end;
  begin
    delete from public.historial_tickets;
    raise exception 'FALLA 3c: permitió DELETE en historial';
  exception when insufficient_privilege then raise notice 'OK 3c: DELETE en historial denegado';
  end;
end $$;

do $$ begin
  begin
    update public.perfiles set rol_id = 'SUPERVISOR_TRANSPORTES', departamento_id = 'TRA' where id = auth.uid();
    raise exception 'FALLA 4: un usuario modificó su propio rol';
  exception when insufficient_privilege then raise notice 'OK 4: nadie modifica su propio rol desde el navegador';
  end;
  begin
    perform correo from public.perfiles limit 1;
    raise exception 'FALLA 4b: la columna correo es legible';
  exception when insufficient_privilege then raise notice 'OK 4b: correos de otros usuarios no expuestos';
  end;
end $$;

do $$ begin
  begin
    perform public.fn_ticket_accion(current_setting('prueba.t_com')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-a000-000000000004"}'::jsonb);
    raise exception 'FALLA 5: un solicitante asignó un responsable';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if;
    raise notice 'OK 5: solicitante no puede asignar (%)', sqlerrm;
  end;
  begin
    perform public.fn_ticket_comentar(current_setting('prueba.t_com')::uuid, 'Nota interna indebida', 'INTERNO');
    raise exception 'FALLA 5b: un solicitante creó una nota interna';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if;
    raise notice 'OK 5b: solicitante no puede crear notas internas';
  end;
end $$;
reset role;

/* ============================ DIEGO (Solicitante LIQ) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.fn_ticket_crear('{"categoria_id":"LIQ-02","asunto":"Faltante de prueba","descripcion":"Diferencia creada por la suite de pruebas",
        "datos":{"ruta":"T-RUT","fecha_operacion":"2026-11-10","chofer":"T-CH","tipo_diferencia":"Faltante","medio_pago":"Efectivo",
                 "monto_esperado":"100000","monto_reportado":"25000","monto_recibido":"75000"}}'::jsonb);
  perform set_config('prueba.t_liq', r ->> 'id', true);
  if (select monto_diferencia from public.liquidacion_diferencias where ticket_id = (r ->> 'id')::uuid) <> 25000 then
    raise exception 'FALLA 6: la diferencia no se calculó como esperado − recibido';
  end if;
  if (select (datos ? 'monto_esperado') from public.tickets where id = (r ->> 'id')::uuid) then
    raise exception 'FALLA 6b: los montos quedaron en el JSON del ticket';
  end if;
  raise notice 'OK 6: Liquidaciones ve su diferencia (₡25 000) y los montos viven fuera del ticket';
end $$;
reset role;

/* ============================ ANA no ve Liquidaciones ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if exists (select 1 from public.tickets where departamento_id <> 'COM') then raise exception 'FALLA 7: Ana ve tickets de otro departamento'; end if;
  if exists (select 1 from public.v_tickets where id = current_setting('prueba.t_liq')::uuid) then raise exception 'FALLA 7b: la vista expone el ticket LIQ'; end if;
  if exists (select 1 from public.liquidacion_diferencias) then raise exception 'FALLA 7c: Ana ve diferencias financieras'; end if;
  if exists (select 1 from reporting.v_diferencias) then raise exception 'FALLA 7d: el reporte expone diferencias'; end if;
  begin
    perform public.fn_ticket_comentar(current_setting('prueba.t_liq')::uuid, 'Comentario indebido', 'PUBLICO');
    raise exception 'FALLA 7e: Ana comentó un ticket de LIQ';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if;
    raise notice 'OK 7: Comercial no ve ni comenta tickets, montos ni reportes de Liquidaciones (%)', sqlerrm;
  end;
end $$;
reset role;

/* ============================ CARLOS (mismo departamento) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if not exists (select 1 from public.tickets where id = current_setting('prueba.t_com')::uuid) then
    raise exception 'FALLA 8: visibilidad por departamento: Carlos no ve el ticket de Ana';
  end if;
  raise notice 'OK 8: visibilidad por departamento (Carlos ve el ticket de Ana)';
end $$;
reset role;

/* ============================ SOFÍA (Supervisora) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_inv uuid;
begin
  perform public.fn_ticket_accion(current_setting('prueba.t_com')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-a000-000000000004"}'::jsonb);
  perform public.fn_ticket_comentar(current_setting('prueba.t_com')::uuid, 'Nota interna de supervisión', 'INTERNO');
  perform public.fn_ticket_accion(current_setting('prueba.t_liq')::uuid, 'asignar', '{"responsable_id":"00000000-0000-4000-a000-000000000005"}'::jsonb);
  select id into v_inv from public.investigaciones where ticket_id = current_setting('prueba.t_liq')::uuid;
  perform public.fn_inv_asignar(v_inv, '00000000-0000-4000-a000-000000000005');
  begin
    perform public.fn_ticket_accion(current_setting('prueba.t_com')::uuid, 'reasignar',
      '{"responsable_id":"00000000-0000-4000-a000-000000000005","motivo":"Prueba de alcance"}'::jsonb);
    raise exception 'FALLA 9: asignó a un operador fuera de su alcance';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if;
    raise notice 'OK 9: no se asigna fuera de alcance (%)', sqlerrm;
  end;
  if (select estado_id from public.tickets where id = current_setting('prueba.t_com')::uuid) <> 'ASIGNADO' then
    raise exception 'FALLA 9b: estado incorrecto tras asignar';
  end if;
  raise notice 'OK 9b: asignación y nota interna registradas';
end $$;
reset role;

/* ============================ MARÍA (Operadora sin permiso financiero) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if not exists (select 1 from public.tickets where id = current_setting('prueba.t_liq')::uuid) then raise exception 'FALLA 10: María no ve el ticket LIQ'; end if;
  if exists (select 1 from public.liquidacion_diferencias) then raise exception 'FALLA 10b: María ve montos sin permiso financiero'; end if;
  if exists (select 1 from public.investigaciones) then raise exception 'FALLA 10c: María ve investigaciones sin permiso'; end if;
  begin
    perform public.fn_ticket_accion(current_setting('prueba.t_liq')::uuid, 'iniciar', '{}'::jsonb);
    raise exception 'FALLA 10d: María gestionó un ticket ajeno';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  perform public.fn_ticket_accion(current_setting('prueba.t_com')::uuid, 'iniciar', '{}'::jsonb);
  raise notice 'OK 10: operadora ve todos los tickets, no los montos, y solo gestiona los suyos';
end $$;
reset role;

/* ============================ ANA no ve notas internas ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if exists (select 1 from public.comentarios where visibilidad = 'INTERNO') then raise exception 'FALLA 11: notas internas visibles para el solicitante'; end if;
  if exists (select 1 from public.historial_tickets where visibilidad <> 'PUBLICO') then raise exception 'FALLA 11b: historial interno visible'; end if;
  if exists (select 1 from public.asignaciones) then raise exception 'FALLA 11c: asignaciones internas visibles'; end if;
  if (select estado_id from public.v_tickets where id = current_setting('prueba.t_com')::uuid) <> 'EN_PROCESO' then
    raise exception 'FALLA 11d: el solicitante no ve el estado actualizado';
  end if;
  raise notice 'OK 11: notas internas, historial interno y asignaciones ocultos al solicitante';
end $$;
reset role;

/* ============================ JOSÉ (Operador con permiso financiero) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000005","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_dif uuid; v_mov uuid; v_inv uuid;
begin
  select id into v_dif from public.liquidacion_diferencias where ticket_id = current_setting('prueba.t_liq')::uuid;
  if v_dif is null then raise exception 'FALLA 12: José no ve la diferencia con permiso otorgado'; end if;
  perform public.fn_ticket_accion(current_setting('prueba.t_liq')::uuid, 'iniciar', '{}'::jsonb);
  begin
    perform public.fn_movimiento_registrar(v_dif, 'ACLARACION', 30000, 'Excede el pendiente');
    raise exception 'FALLA 12b: aceptó una aclaración mayor al pendiente';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  v_mov := public.fn_movimiento_registrar(v_dif, 'ACLARACION', 10000, 'Comprobante aportado');
  perform public.fn_movimiento_registrar(v_dif, 'REVERSION', null, 'Error de digitación', v_mov);
  begin
    perform public.fn_movimiento_registrar(v_dif, 'REVERSION', null, 'Segunda reversión', v_mov);
    raise exception 'FALLA 12c: permitió revertir dos veces';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  perform public.fn_ticket_comentar(current_setting('prueba.t_liq')::uuid, 'Comentario que no debe alterar montos', 'PUBLICO');
  if (select pendiente from app.saldos_diferencia(v_dif)) <> 25000 then raise exception 'FALLA 12d: saldo pendiente alterado'; end if;
  if (select sum(monto_efectivo) from reporting.v_movimientos where diferencia_id = v_dif) <> 0 then raise exception 'FALLA 12e: el reporte de movimientos no neutraliza la reversión'; end if;
  select id into v_inv from public.investigaciones where ticket_id = current_setting('prueba.t_liq')::uuid;
  perform public.fn_inv_hallazgo(v_inv, 'Hallazgo interno de prueba');
  begin
    perform public.fn_ticket_accion(current_setting('prueba.t_liq')::uuid, 'resolver', '{"resolucion":"Intento de resolver con investigación abierta"}'::jsonb);
    raise exception 'FALLA 12f: resolvió con investigación abierta';
  exception when others then
    if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 12: libro financiero sin negativos ni doble reversión; montos estables; investigación bloquea la resolución';
end $$;
reset role;

/* ============================ DIEGO: resumen de investigación ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if not exists (select 1 from public.investigaciones) then raise exception 'FALLA 13: Liquidaciones no ve el estado de su investigación'; end if;
  if exists (select 1 from public.investigacion_hallazgos) then raise exception 'FALLA 13b: Liquidaciones ve hallazgos internos'; end if;
  if exists (select 1 from public.investigacion_involucrados) then raise exception 'FALLA 13c: Liquidaciones ve involucrados'; end if;
  raise notice 'OK 13: Liquidaciones ve el resumen de la investigación, no los hallazgos';
end $$;
reset role;

/* ============================ GERENCIA (solo lectura) ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000007","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if (select count(*) from public.tickets where id in (current_setting('prueba.t_com')::uuid, current_setting('prueba.t_liq')::uuid)) <> 2 then
    raise exception 'FALLA 14: Gerencia no ve todos los tickets';
  end if;
  begin
    perform public.fn_ticket_comentar(current_setting('prueba.t_com')::uuid, 'Gerencia comentando', 'PUBLICO');
    raise exception 'FALLA 14b: Gerencia pudo comentar';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_ticket_accion(current_setting('prueba.t_com')::uuid, 'cambiar_prioridad', '{"prioridad":"CRITICA","motivo":"Prueba"}'::jsonb);
    raise exception 'FALLA 14c: Gerencia modificó un ticket';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_inv_concluir((select id from public.investigaciones limit 1), 'NO_DETERMINADA', 'Gerencia intentando concluir la investigación');
    raise exception 'FALLA 14d: Gerencia alteró una investigación';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 14: Gerencia consulta todo y no modifica nada';
end $$;
reset role;

/* ============================ ADMINISTRADOR ============================ */
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000008","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if exists (select 1 from public.tickets) then raise exception 'FALLA 15: el Administrador ve tickets por defecto'; end if;
  if exists (select 1 from public.comentarios) then raise exception 'FALLA 15b: el Administrador ve comentarios'; end if;
  begin
    perform public.fn_admin_usuario_guardar(auth.uid(), '{"rol":"SUPERVISOR_TRANSPORTES","departamento":"TRA"}'::jsonb);
    raise exception 'FALLA 15c: el Administrador cambió su propio rol';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_admin_usuario_guardar('00000000-0000-4000-a000-000000000001', '{"rol":"SOLICITANTE","departamento":"TRA"}'::jsonb);
    raise exception 'FALLA 15d: aceptó rol y departamento incoherentes';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_admin_usuario_guardar('00000000-0000-4000-a000-000000000004', '{"activo":false}'::jsonb);
    raise exception 'FALLA 15e: desactivó a un operador con tickets abiertos';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 15: Administrador sin acceso operativo; no cambia su rol; reglas de coherencia activas';
end $$;
reset role;

/* ============================ Storage (archivos) ============================ */
insert into storage.objects (bucket_id, name) values ('evidencias', current_setting('prueba.t_liq') || '/archivo-sin-registro');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.fn_evidencia_preparar(current_setting('prueba.t_liq')::uuid, 'comprobante.pdf', 1024, 'application/pdf');
  perform set_config('prueba.ruta', r ->> 'ruta', true);
  if exists (select 1 from storage.objects where bucket_id = 'evidencias' and name like '%archivo-sin-registro') then
    raise exception 'FALLA 16: un objeto sin registro de evidencia es legible';
  end if;
  raise notice 'OK 16: objetos sin evidencia autorizada no son legibles';
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    insert into storage.objects (bucket_id, name, owner) values ('evidencias', current_setting('prueba.ruta'), auth.uid());
    raise exception 'FALLA 17: Ana subió un archivo a un ticket de Liquidaciones';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_evidencia_preparar(current_setting('prueba.t_liq')::uuid, 'x.pdf', 100, 'application/pdf');
    raise exception 'FALLA 17b: Ana preparó evidencia en un ticket ajeno';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    perform public.fn_evidencia_preparar(current_setting('prueba.t_com')::uuid, 'virus.exe', 100, 'application/x-msdownload');
    raise exception 'FALLA 17c: aceptó un tipo de archivo no permitido';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 17: subida limitada a rutas reservadas, tickets visibles y tipos permitidos';
end $$;
reset role;

/* ============================ Inmutabilidad (incluso para el dueño) ============================ */
do $$ begin
  begin
    update public.historial_tickets set detalle = 'alterado' where ticket_id = current_setting('prueba.t_com')::uuid;
    raise exception 'FALLA 18: el historial fue modificado';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    delete from public.tickets where id = current_setting('prueba.t_com')::uuid;
    raise exception 'FALLA 18b: se borró físicamente un ticket';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  begin
    update public.tickets set departamento_id = 'LIQ' where id = current_setting('prueba.t_com')::uuid;
    raise exception 'FALLA 18c: se cambió el departamento de un ticket';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 18: historial inmutable; sin borrado físico; campos de origen protegidos';
end $$;

/* ============================ Anónimo ============================ */
set local role anon;
do $$ begin
  begin
    perform 1 from public.tickets limit 1;
    raise exception 'FALLA 19: anon puede consultar tickets';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.fn_ticket_crear('{}'::jsonb);
    raise exception 'FALLA 19b: anon puede ejecutar RPC';
  exception when others then if sqlerrm like 'FALLA%' then raise; end if; raise notice '   bloqueado: %', sqlerrm;
  end;
  raise notice 'OK 19: el rol anónimo no accede a datos ni funciones';
end $$;
reset role;

do $$ begin raise notice '=== TODAS LAS PRUEBAS PASARON ==='; end $$;

rollback;
