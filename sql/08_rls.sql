-- =============================================================================
-- 08_rls.sql — Privilegios y políticas Row Level Security
--
-- Modelo:
--   • anon: sin acceso a nada.
--   • authenticated: solo SELECT, filtrado por RLS. Ninguna política INSERT/UPDATE/DELETE:
--     las escrituras pasan exclusivamente por las funciones RPC (06_rpc.sql).
--   • Las funciones de autorización se envuelven en (select …) para que PostgreSQL
--     las evalúe una sola vez por consulta y no por fila.
-- =============================================================================
begin;

/* ---------- 1. Partir de cero ---------- */
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema app from public, anon, authenticated;

/* ---------- 2. RLS activado en TODAS las tablas del esquema public ---------- */
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

/* ---------- 3. Catálogos y datos maestros: lectura para usuarios autenticados ---------- */
do $$
declare t text;
begin
  foreach t in array array['departamentos', 'roles', 'permisos', 'rol_permisos', 'tipos_gestion', 'prioridades', 'estados',
                           'transiciones_estado', 'motivos', 'respuestas_rapidas', 'resultados_investigacion', 'eventos_notificacion',
                           'campos_definicion', 'categorias', 'categoria_tipos', 'categoria_campos', 'configuracion',
                           'clientes', 'rutas', 'vehiculos', 'colaboradores', 'bodegas', 'unidades_medida',
                           'sla_versiones', 'sla_valores', 'calendario_laboral', 'feriados'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy lectura_autenticados on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;

/* ---------- 4. Perfiles (columnas sensibles como el correo no se exponen) ---------- */
grant select (id, nombre, rol_id, departamento_id, activo, disponible) on public.perfiles to authenticated;
create policy perfiles_lectura on public.perfiles for select to authenticated using (
  id = (select auth.uid())
  or (select app.tiene_permiso('ticket.ver_todos'))
  or (select app.tiene_permiso('admin.usuarios'))
  or departamento_id = (select app.departamento_actual())
  or rol_id in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES', 'SUPERUSUARIO')
);

grant select on public.operador_alcance to authenticated;
create policy alcance_lectura on public.operador_alcance for select to authenticated using (
  perfil_id = (select auth.uid()) or (select app.tiene_permiso('ticket.ver_todos')) or (select app.tiene_permiso('admin.usuarios'))
);

grant select on public.perfil_permisos to authenticated;
create policy perfil_permisos_lectura on public.perfil_permisos for select to authenticated using (
  perfil_id = (select auth.uid()) or (select app.tiene_permiso('admin.usuarios'))
);

/* ---------- 5. Tickets: visibilidad por departamento ---------- */
grant select on public.tickets to authenticated;
create policy tickets_visibilidad on public.tickets for select to authenticated using (
  (select app.tiene_permiso('ticket.ver_todos'))
  or ((select app.tiene_permiso('ticket.ver_departamento')) and departamento_id = (select app.departamento_actual()))
);

-- Tablas hijas: heredan la visibilidad del ticket (la subconsulta aplica la RLS de tickets)
grant select on public.ticket_sla, public.sla_pausas to authenticated;
create policy ticket_sla_lectura on public.ticket_sla for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id));
create policy sla_pausas_lectura on public.sla_pausas for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id));

grant select on public.sla_excepciones, public.asignaciones to authenticated;
create policy sla_excepciones_lectura on public.sla_excepciones for select to authenticated using (
  (select app.tiene_permiso('ticket.ver_todos')) and exists (select 1 from public.tickets t where t.id = ticket_id));
create policy asignaciones_lectura on public.asignaciones for select to authenticated using (
  (select app.tiene_permiso('ticket.ver_todos')) and exists (select 1 from public.tickets t where t.id = ticket_id));

-- Notas internas: NUNCA visibles para solicitantes
grant select on public.comentarios to authenticated;
create policy comentarios_lectura on public.comentarios for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id)
  and (visibilidad = 'PUBLICO' or (select app.tiene_permiso('ticket.ver_internas')))
);

grant select on public.evidencias to authenticated;
create policy evidencias_lectura on public.evidencias for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id)
  and (visibilidad = 'PUBLICO' or (select app.tiene_permiso('ticket.ver_internas')))
  and (estado = 'CONFIRMADA' or subido_por = (select auth.uid()))
);

grant select on public.historial_tickets to authenticated;
create policy historial_lectura on public.historial_tickets for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id)
  and (visibilidad = 'PUBLICO'
       or (visibilidad = 'INTERNO' and (select app.tiene_permiso('ticket.ver_internas')))
       or (visibilidad = 'FINANCIERO' and (select app.tiene_permiso('financiero.ver'))))
);

/* ---------- 6. Información financiera (restringida) ---------- */
grant select on public.liquidacion_diferencias, public.movimientos_financieros, public.recuperaciones to authenticated;
create policy diferencias_lectura on public.liquidacion_diferencias for select to authenticated using (
  (select app.tiene_permiso('financiero.ver')) and exists (select 1 from public.tickets t where t.id = ticket_id));
create policy movimientos_lectura on public.movimientos_financieros for select to authenticated using (
  (select app.tiene_permiso('financiero.ver')) and exists (select 1 from public.tickets t where t.id = ticket_id));
create policy recuperaciones_lectura on public.recuperaciones for select to authenticated using (
  exists (select 1 from public.movimientos_financieros m where m.id = movimiento_id));

/* ---------- 7. Investigaciones ---------- */
grant select on public.investigaciones, public.investigacion_involucrados, public.investigacion_hallazgos,
                public.investigacion_conclusiones to authenticated;
-- Resumen (estado, resultado, conclusión): Liquidaciones y perfiles con acceso completo
create policy investigaciones_lectura on public.investigaciones for select to authenticated using (
  ((select app.tiene_permiso('investigacion.ver')) or (select app.tiene_permiso('investigacion.ver_resumen')))
  and exists (select 1 from public.tickets t where t.id = ticket_id));
-- Detalle interno (hallazgos, involucrados, conclusiones previas): solo acceso completo
create policy involucrados_lectura on public.investigacion_involucrados for select to authenticated using (
  (select app.tiene_permiso('investigacion.ver')) and exists (select 1 from public.investigaciones i where i.id = investigacion_id));
create policy hallazgos_lectura on public.investigacion_hallazgos for select to authenticated using (
  (select app.tiene_permiso('investigacion.ver')) and exists (select 1 from public.investigaciones i where i.id = investigacion_id));
create policy conclusiones_lectura on public.investigacion_conclusiones for select to authenticated using (
  (select app.tiene_permiso('investigacion.ver')) and exists (select 1 from public.investigaciones i where i.id = investigacion_id));

/* ---------- 8. Notificaciones, preferencias y auditoría ---------- */
grant select on public.notificaciones, public.preferencias_notificacion to authenticated;
create policy notificaciones_propias on public.notificaciones for select to authenticated using (usuario_id = (select auth.uid()));
create policy preferencias_propias on public.preferencias_notificacion for select to authenticated using (usuario_id = (select auth.uid()));

grant select on public.auditoria to authenticated;
create policy auditoria_lectura on public.auditoria for select to authenticated using (
  (select app.tiene_permiso('auditoria.administrativa'))
  or (ambito = 'OPERATIVA' and (select app.tiene_permiso('auditoria.operativa')))
);

-- ticket_consecutivos: RLS activado y sin políticas ni privilegios → inaccesible desde la API.

/* ---------- 9. Funciones ejecutables por usuarios autenticados ---------- */
-- Usadas por políticas y vistas (solo lectura, sin efectos)
grant execute on function app.tiene_permiso(text), app.departamento_actual(), app.puede_ver_departamento(text),
                          app.sla_evaluar(uuid), app.minutos_habiles(timestamptz, timestamptz),
                          app.minutos_netos(uuid, timestamptz, timestamptz), app.saldos_diferencia(uuid),
                          app.pendiente_info(uuid) to authenticated;

-- API RPC
grant execute on function
  public.fn_mi_perfil(),
  public.fn_ticket_crear(jsonb),
  public.fn_ticket_acciones(uuid),
  public.fn_ticket_accion(uuid, text, jsonb),
  public.fn_ticket_comentar(uuid, text, text),
  public.fn_ticket_responder_info(uuid, text),
  public.fn_evidencia_preparar(uuid, text, bigint, text, text, uuid),
  public.fn_evidencia_confirmar(uuid),
  public.fn_responsables_para(uuid),
  public.fn_inv_asignar(uuid, uuid),
  public.fn_inv_hallazgo(uuid, text),
  public.fn_inv_aclaracion(uuid, text),
  public.fn_inv_concluir(uuid, text, text),
  public.fn_inv_reabrir(uuid, text),
  public.fn_movimiento_registrar(uuid, text, numeric, text, uuid, text, text, date),
  public.fn_sla_excepcion(uuid, text, text),
  public.fn_notificaciones_marcar_leidas(bigint[]),
  public.fn_preferencias_guardar(jsonb),
  public.fn_exportacion_registrar(text, text, integer),
  public.fn_admin_usuarios(),
  public.fn_admin_usuario_guardar(uuid, jsonb),
  public.fn_admin_categoria_guardar(text, jsonb),
  public.fn_admin_config_guardar(jsonb),
  public.fn_sla_nueva_version(jsonb, numeric, text),
  public.fn_calendario_guardar(jsonb),
  public.fn_feriado_agregar(date, text),
  public.fn_feriado_quitar(date)
to authenticated;

commit;
