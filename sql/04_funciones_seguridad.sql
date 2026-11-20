-- =============================================================================
-- 04_funciones_seguridad.sql — Autorización centralizada
-- Todas las políticas RLS y funciones RPC usan estas funciones: una sola fuente de verdad.
-- El rol y el departamento se leen SIEMPRE del perfil del usuario autenticado (auth.uid()),
-- nunca de valores enviados por el navegador.
-- =============================================================================
begin;

/* ---------- Errores con código estable para el frontend ---------- */
create or replace function app.error(p_codigo text, p_mensaje text)
returns void language plpgsql set search_path = '' as $$   -- volatile a propósito: nunca se pliega en planificación
begin
  -- 42501 = insufficient_privilege; P0001 = validación de negocio; P0002 = no encontrado
  raise exception using
    errcode = case p_codigo when 'NO_AUTORIZADO' then '42501' when 'NO_AUTENTICADO' then '42501' when 'NO_ENCONTRADO' then 'P0002' else 'P0001' end,
    message = p_mensaje,
    hint = p_codigo;
end $$;

create or replace function app.validar(p_condicion boolean, p_mensaje text)
returns void language plpgsql set search_path = '' as $$
begin
  if p_condicion is distinct from true then
    perform app.error('VALIDACION', p_mensaje);
  end if;
end $$;

/* ---------- Permisos ---------- */
create or replace function app.permiso_de(p_usuario uuid, p_permiso text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
           select 1
           from public.perfiles p
           join public.rol_permisos rp on rp.rol_id = p.rol_id
           where p.id = p_usuario and p.activo and rp.permiso_id = p_permiso
             and (rp.solo_departamento is null or rp.solo_departamento = p.departamento_id))
      or exists (
           select 1
           from public.perfil_permisos pp
           join public.perfiles p on p.id = pp.perfil_id
           join public.permisos pe on pe.id = pp.permiso_id and pe.otorgable
           where pp.perfil_id = p_usuario and p.activo and pp.permiso_id = p_permiso)
$$;

create or replace function app.tiene_permiso(p_permiso text)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.permiso_de(auth.uid(), p_permiso)
$$;

create or replace function app.departamento_actual()
returns text language sql stable security definer set search_path = '' as $$
  select departamento_id from public.perfiles where id = auth.uid() and activo
$$;

create or replace function app.rol_de(p_usuario uuid)
returns text language sql stable security definer set search_path = '' as $$
  select rol_id from public.perfiles where id = p_usuario and activo
$$;

create or replace function app.es_transportes(p_usuario uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(app.rol_de(p_usuario) in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES', 'SUPERUSUARIO'), false)
$$;

create or replace function app.en_alcance(p_usuario uuid, p_departamento text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.operador_alcance where perfil_id = p_usuario and departamento_id = p_departamento)
$$;

/** Regla de visibilidad por departamento (sección 3 del documento) */
create or replace function app.puede_ver_departamento_de(p_usuario uuid, p_departamento text)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.permiso_de(p_usuario, 'ticket.ver_todos')
      or (app.permiso_de(p_usuario, 'ticket.ver_departamento')
          and p_departamento = (select departamento_id from public.perfiles where id = p_usuario and activo))
$$;

create or replace function app.puede_ver_departamento(p_departamento text)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.puede_ver_departamento_de(auth.uid(), p_departamento)
$$;

/** Perfil activo del usuario autenticado o error NO_AUTENTICADO */
create or replace function app.actor()
returns public.perfiles language plpgsql stable security definer set search_path = '' as $$
declare v public.perfiles;
begin
  select * into v from public.perfiles where id = auth.uid() and activo;
  if not found then perform app.error('NO_AUTENTICADO', 'Sesión no válida o usuario inactivo.'); end if;
  return v;
end $$;

create or replace function app.exigir(p_permiso text)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.tiene_permiso(p_permiso) then
    perform app.error('NO_AUTORIZADO', 'No autorizado para esta operación.');
  end if;
end $$;

/** Ticket bloqueado para actualizar, solo si el actor puede verlo. Mismo mensaje si no existe (no revela tickets ajenos). */
create or replace function app.ticket_para(p_usuario uuid, p_ticket uuid, p_bloquear boolean default true)
returns public.tickets language plpgsql security definer set search_path = '' as $$
declare v public.tickets;
begin
  if p_bloquear then
    select * into v from public.tickets where id = p_ticket for update;
  else
    select * into v from public.tickets where id = p_ticket;
  end if;
  if not found or not app.puede_ver_departamento_de(p_usuario, v.departamento_id) then
    perform app.error('NO_ENCONTRADO', 'Ticket no encontrado o sin acceso.');
  end if;
  return v;
end $$;

/** Matriz acción × rol × estado (equivalente a js/core/estados.js) */
create or replace function app.accion_permitida(p_usuario uuid, p_ticket public.tickets, p_accion text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_depto text;
  v_gestiona boolean;
  v_triaje boolean;
begin
  if p_ticket.anulado then return false; end if;
  if not exists (select 1 from public.transiciones_estado where accion = p_accion and estado_desde = p_ticket.estado_id) then
    return false;
  end if;
  select departamento_id into v_depto from public.perfiles where id = p_usuario and activo;
  if v_depto is null then return false; end if;
  v_gestiona := app.permiso_de(p_usuario, 'ticket.gestionar_todos')
             or (app.permiso_de(p_usuario, 'ticket.gestionar_asignados') and p_ticket.responsable_id = p_usuario);
  v_triaje := app.permiso_de(p_usuario, 'ticket.triaje') and app.en_alcance(p_usuario, p_ticket.departamento_id);
  return case p_accion
    when 'tomar_revision'       then app.permiso_de(p_usuario, 'ticket.gestionar_todos') or v_triaje
    when 'asignar'              then app.permiso_de(p_usuario, 'ticket.asignar')
    when 'autoasignar'          then not app.permiso_de(p_usuario, 'ticket.asignar') and app.permiso_de(p_usuario, 'ticket.autoasignar') and app.en_alcance(p_usuario, p_ticket.departamento_id)
    when 'reasignar'            then app.permiso_de(p_usuario, 'ticket.asignar')
    when 'iniciar'              then v_gestiona
    when 'espera'               then v_gestiona or (p_ticket.estado_id = 'EN_REVISION' and v_triaje)
    when 'reanudar'             then v_gestiona or (p_ticket.estado_previo = 'EN_REVISION' and v_triaje)
    when 'resolver'             then v_gestiona
    when 'rechazar'             then app.permiso_de(p_usuario, 'ticket.rechazar')
    when 'confirmar'            then app.permiso_de(p_usuario, 'ticket.confirmar') and v_depto = p_ticket.departamento_id
    when 'solicitar_reapertura' then app.permiso_de(p_usuario, 'ticket.solicitar_reapertura') and v_depto = p_ticket.departamento_id
    when 'cerrar'               then app.permiso_de(p_usuario, 'ticket.cerrar')
    when 'reabrir'              then app.permiso_de(p_usuario, 'ticket.reabrir')
    when 'cambiar_prioridad'    then app.permiso_de(p_usuario, 'ticket.prioridad')
    when 'cierre_excepcional'   then app.permiso_de(p_usuario, 'ticket.cierre_excepcional')
    when 'anular'               then app.permiso_de(p_usuario, 'ticket.anular')
    else false
  end;
end $$;

/** Por qué un usuario no puede ser responsable de un ticket (null = elegible) */
create or replace function app.motivo_no_elegible(p_usuario uuid, p_departamento text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p.id is null then 'Usuario inexistente'
    when not p.activo then 'Usuario inactivo'
    when p.rol_id not in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES') then 'No pertenece a Transportes'
    when not p.disponible then 'No disponible'
    when p.rol_id = 'OPERADOR_TRANSPORTES' and not app.en_alcance(p.id, p_departamento) then 'Fuera de su alcance'
  end
  from (select 1) x left join public.perfiles p on p.id = p_usuario
$$;

commit;
