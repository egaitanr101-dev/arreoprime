-- =============================================================================
-- SOLO ENTORNO LOCAL DE PRUEBAS. Usuarios y tickets ficticios para recorrer la
-- aplicación con la base de datos real. Requiere 00 (simulación), 01–10 y 90.
-- Los usuarios coinciden con sql/local/usuarios-prueba.json (tokens del servidor local).
-- Los tickets se crean con las MISMAS funciones RPC que usa la aplicación.
-- =============================================================================
begin;

insert into auth.users (id, email, raw_user_meta_data)
select u.id::uuid, u.correo, jsonb_build_object('nombre', u.nombre)
from (values
  ('10000000-0000-4000-8000-000000000001', 'ana@prueba.invalid', 'Ana Solís (prueba)'),
  ('10000000-0000-4000-8000-000000000002', 'carlos@prueba.invalid', 'Carlos Mora (prueba)'),
  ('10000000-0000-4000-8000-000000000003', 'laura@prueba.invalid', 'Laura Jiménez (prueba)'),
  ('10000000-0000-4000-8000-000000000004', 'diego@prueba.invalid', 'Diego Vargas (prueba)'),
  ('10000000-0000-4000-8000-000000000005', 'maria@prueba.invalid', 'María Rojas (prueba)'),
  ('10000000-0000-4000-8000-000000000006', 'jose@prueba.invalid', 'José Araya (prueba)'),
  ('10000000-0000-4000-8000-000000000007', 'sofia@prueba.invalid', 'Sofía Castro (prueba)'),
  ('10000000-0000-4000-8000-000000000008', 'ricardo@prueba.invalid', 'Ricardo Pérez (prueba)'),
  ('10000000-0000-4000-8000-000000000009', 'andrea@prueba.invalid', 'Andrea Quesada (prueba)'),
  ('10000000-0000-4000-8000-000000000010', 'pablo@prueba.invalid', 'Pablo Méndez (prueba)')
) as u(id, correo, nombre);

update public.perfiles p set rol_id = v.rol, departamento_id = v.dep, activo = true, disponible = v.disp
from (values
  ('10000000-0000-4000-8000-000000000001', 'SOLICITANTE', 'COM', true),
  ('10000000-0000-4000-8000-000000000002', 'SOLICITANTE', 'COM', true),
  ('10000000-0000-4000-8000-000000000003', 'SOLICITANTE', 'ALM', true),
  ('10000000-0000-4000-8000-000000000004', 'SOLICITANTE', 'LIQ', true),
  ('10000000-0000-4000-8000-000000000005', 'OPERADOR_TRANSPORTES', 'TRA', true),
  ('10000000-0000-4000-8000-000000000006', 'OPERADOR_TRANSPORTES', 'TRA', true),
  ('10000000-0000-4000-8000-000000000007', 'SUPERVISOR_TRANSPORTES', 'TRA', true),
  ('10000000-0000-4000-8000-000000000008', 'GERENCIA', 'GER', true),
  ('10000000-0000-4000-8000-000000000009', 'ADMINISTRADOR', 'SIS', true),
  ('10000000-0000-4000-8000-000000000010', 'OPERADOR_TRANSPORTES', 'TRA', false)
) as v(id, rol, dep, disp)
where p.id = v.id::uuid;

insert into public.operador_alcance (perfil_id, departamento_id) values
  ('10000000-0000-4000-8000-000000000005', 'COM'), ('10000000-0000-4000-8000-000000000005', 'ALM'),
  ('10000000-0000-4000-8000-000000000006', 'LIQ'), ('10000000-0000-4000-8000-000000000006', 'COM'),
  ('10000000-0000-4000-8000-000000000010', 'ALM'), ('10000000-0000-4000-8000-000000000010', 'COM');
insert into public.perfil_permisos (perfil_id, permiso_id, otorgado_por)
select '10000000-0000-4000-8000-000000000006', x, '10000000-0000-4000-8000-000000000009'
from unnest(array['financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar']) x;
update public.categorias set responsable_sugerido_id = case departamento_id
  when 'COM' then '10000000-0000-4000-8000-000000000005'::uuid
  when 'LIQ' then '10000000-0000-4000-8000-000000000006'::uuid
  else '10000000-0000-4000-8000-000000000010'::uuid end;

/* ---------- Tickets de ejemplo, creados con las funciones RPC reales ---------- */
-- Ana (Comercial)
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('ej.t1', public.fn_ticket_crear('{"categoria_id":"COM-02","asunto":"Segunda visita — Restaurante La Fogata","descripcion":"El cliente no estaba en la primera visita; solicita volver mañana.","datos":{"cliente":"C-1003","factura":"FE-100200","ruta":"R-101","fecha_solicitada":"2026-11-18","horario":"9:00 – 11:00"}}'::jsonb) ->> 'id', true);
  perform set_config('ej.t2', public.fn_ticket_crear('{"categoria_id":"COM-11","asunto":"Consulta sobre entrega — Súper El Ahorro","descripcion":"Consulta la hora estimada de entrega del pedido.","datos":{"cliente":"C-1001","pedido":"PED-55120"}}'::jsonb) ->> 'id', true);
end $$;
reset role;
-- Laura (Almacén)
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('ej.t3', public.fn_ticket_crear('{"categoria_id":"ALM-05","asunto":"Solicitud de vehículo para traslado","descripcion":"Se requiere camión refrigerado para mover producto a la bodega de despacho.","datos":{"vehiculo":"DEMO-001","fecha_requerida":"2026-11-19","ubicacion":"Andén 3 — Bodega Central"}}'::jsonb) ->> 'id', true);
end $$;
reset role;
-- Diego (Liquidaciones)
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform set_config('ej.t4', public.fn_ticket_crear('{"categoria_id":"LIQ-02","asunto":"Faltante de efectivo — Ruta R-105","descripcion":"El cierre de caja de la ruta muestra un faltante en efectivo.","datos":{"ruta":"R-105","fecha_operacion":"2026-11-14","chofer":"CH-03","ayudante":"AY-02","num_liquidacion":"LQ-25211","tipo_diferencia":"Faltante","medio_pago":"Efectivo","monto_esperado":"1485000","monto_reportado":"148500","monto_recibido":"1336500"}}'::jsonb) ->> 'id', true);
end $$;
reset role;
-- Sofía (Supervisora): revisión y asignaciones
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform public.fn_ticket_accion(current_setting('ej.t1')::uuid, 'tomar_revision', '{}'::jsonb);
  perform public.fn_ticket_comentar(current_setting('ej.t1')::uuid, 'Solicitud recibida. Estamos revisando la información.', 'PUBLICO');
  perform public.fn_ticket_accion(current_setting('ej.t1')::uuid, 'asignar', '{"responsable_id":"10000000-0000-4000-8000-000000000005","sugerido":true}'::jsonb);
  perform public.fn_ticket_comentar(current_setting('ej.t1')::uuid, 'Coordinar con el chofer de la ruta R-101 antes de confirmar.', 'INTERNO');
  perform public.fn_ticket_accion(current_setting('ej.t4')::uuid, 'asignar', '{"responsable_id":"10000000-0000-4000-8000-000000000006"}'::jsonb);
  perform public.fn_inv_asignar((select id from public.investigaciones where ticket_id = current_setting('ej.t4')::uuid), '10000000-0000-4000-8000-000000000006');
end $$;
reset role;
-- María (Operadora): inicia y pide información a Comercial
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform public.fn_ticket_accion(current_setting('ej.t1')::uuid, 'iniciar', '{}'::jsonb);
  perform public.fn_ticket_accion(current_setting('ej.t1')::uuid, 'espera', '{"motivo_id":"INFO_SOLICITANTE","detalle":"Por favor confirme si el cliente puede recibir después de las 14:00 y un teléfono de contacto."}'::jsonb);
end $$;
reset role;
-- José (Operador con permiso financiero): investigación en curso
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  perform public.fn_ticket_accion(current_setting('ej.t4')::uuid, 'iniciar', '{}'::jsonb);
  perform public.fn_inv_hallazgo((select id from public.investigaciones where ticket_id = current_setting('ej.t4')::uuid), 'El cierre de datáfono muestra una transacción duplicada.');
  perform public.fn_movimiento_registrar((select id from public.liquidacion_diferencias where ticket_id = current_setting('ej.t4')::uuid),
    'ACLARACION', 48500, 'Monto respaldado con comprobantes aportados por el chofer.');
end $$;
reset role;

commit;
