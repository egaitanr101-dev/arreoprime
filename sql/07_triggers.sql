-- =============================================================================
-- 07_triggers.sql — Integridad: inmutabilidad, sin borrado físico, coherencia de
-- perfiles, congelamiento de tiempos SLA y alta de perfiles desde Supabase Auth.
-- Los triggers se ejecutan para TODOS los roles, incluidas las funciones SECURITY DEFINER.
-- =============================================================================
begin;

/* ---------- Marca de actualización ---------- */
create or replace function app.tg_actualizado_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.actualizado_at := now();
  return new;
end $$;
create trigger tickets_actualizado before update on public.tickets for each row execute function app.tg_actualizado_at();
create trigger perfiles_actualizado before update on public.perfiles for each row execute function app.tg_actualizado_at();

/* ---------- Registros inmutables (solo inserción) ---------- */
create or replace function app.tg_inmutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '42501', hint = 'INMUTABLE',
    message = 'Registro protegido: la tabla ' || tg_table_name || ' no admite ' || lower(tg_op) || '.';
end $$;

do $$
declare t text;
begin
  foreach t in array array['historial_tickets', 'auditoria', 'movimientos_financieros', 'recuperaciones', 'comentarios',
                           'investigacion_hallazgos', 'investigacion_conclusiones', 'sla_excepciones', 'liquidacion_diferencias',
                           'investigacion_involucrados'] loop
    execute format('create trigger %I before update or delete on public.%I for each row execute function app.tg_inmutable()',
                   t || '_inmutable', t);
  end loop;
  -- Sin borrado físico (se anulan / desactivan)
  foreach t in array array['tickets', 'perfiles', 'evidencias', 'investigaciones', 'asignaciones', 'categorias',
                           'ticket_sla', 'sla_versiones', 'sla_valores', 'notificaciones'] loop
    execute format('create trigger %I before delete on public.%I for each row execute function app.tg_inmutable()',
                   t || '_sin_borrado', t);
  end loop;
end $$;

-- Los objetivos de una versión de SLA publicada no se modifican
create or replace function app.tg_sla_valores_fijos()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '42501', hint = 'INMUTABLE', message = 'Los valores de una versión de SLA no se editan: publique una versión nueva.';
end $$;
create trigger sla_valores_fijos before update on public.sla_valores for each row execute function app.tg_sla_valores_fijos();

-- De una versión de SLA solo puede cerrarse la vigencia
create or replace function app.tg_sla_version_cierre()
returns trigger language plpgsql set search_path = '' as $$
begin
  if (new.version, new.vigente_desde, new.umbral, new.nota, new.creado_por) is distinct from
     (old.version, old.vigente_desde, old.umbral, old.nota, old.creado_por)
     or old.vigente_hasta is not null then
    raise exception using errcode = '42501', hint = 'INMUTABLE', message = 'Una versión de SLA publicada no se edita.';
  end if;
  return new;
end $$;
create trigger sla_version_cierre before update on public.sla_versiones for each row execute function app.tg_sla_version_cierre();

/* ---------- Campos inmutables del ticket ---------- */
create or replace function app.tg_ticket_inmutables()
returns trigger language plpgsql set search_path = '' as $$
begin
  if (new.id, new.numero, new.departamento_id, new.solicitante_id, new.registrado_por, new.canal, new.categoria_id,
      new.creado_at, new.prioridad_sugerida, new.descripcion, new.datos)
     is distinct from
     (old.id, old.numero, old.departamento_id, old.solicitante_id, old.registrado_por, old.canal, old.categoria_id,
      old.creado_at, old.prioridad_sugerida, old.descripcion, old.datos) then
    raise exception using errcode = '42501', hint = 'INMUTABLE', message = 'Número, departamento, solicitante, categoría y datos originales del ticket no se modifican.';
  end if;
  if old.anulado and not new.anulado then
    raise exception using errcode = '42501', hint = 'INMUTABLE', message = 'Un ticket anulado no se reactiva.';
  end if;
  return new;
end $$;
create trigger tickets_inmutables before update on public.tickets for each row execute function app.tg_ticket_inmutables();

/* ---------- Perfiles: coherencia y protección del propio rol ---------- */
create or replace function app.tg_perfil_validar()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.activo and not exists (select 1 from public.roles r where r.id = new.rol_id and new.departamento_id = any (r.departamentos_permitidos)) then
    raise exception using errcode = 'P0001', hint = 'VALIDACION', message = 'El departamento no corresponde al rol del usuario.';
  end if;
  if tg_op = 'UPDATE' and auth.uid() = new.id
     and (old.rol_id, old.departamento_id, old.activo) is distinct from (new.rol_id, new.departamento_id, new.activo) then
    raise exception using errcode = '42501', hint = 'NO_AUTORIZADO', message = 'Nadie puede modificar su propio rol, departamento o estado.';
  end if;
  if tg_op = 'UPDATE' and new.id <> old.id then
    raise exception using errcode = '42501', hint = 'INMUTABLE', message = 'El identificador del perfil no se modifica.';
  end if;
  return new;
end $$;
create trigger perfiles_validar before insert or update on public.perfiles for each row execute function app.tg_perfil_validar();

create or replace function app.tg_perfil_permiso_validar()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.permisos where id = new.permiso_id and otorgable) then
    raise exception using errcode = 'P0001', hint = 'VALIDACION', message = 'El permiso ' || new.permiso_id || ' no es otorgable individualmente.';
  end if;
  if new.perfil_id = auth.uid() then
    raise exception using errcode = '42501', hint = 'NO_AUTORIZADO', message = 'Nadie puede otorgarse permisos a sí mismo.';
  end if;
  return new;
end $$;
create trigger perfil_permisos_validar before insert or update on public.perfil_permisos for each row execute function app.tg_perfil_permiso_validar();

/* ---------- SLA: congela los minutos al cumplirse cada métrica ----------
   Así, cambios posteriores de calendario o feriados no alteran el histórico. */
create or replace function app.tg_ticket_sla_congelar()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.ticket_sla s set
    min_primera_respuesta = case
      when new.primera_respuesta_at is null then null
      when old.primera_respuesta_at is null then app.minutos_netos(new.id, new.creado_at, new.primera_respuesta_at)
      else s.min_primera_respuesta end,
    min_asignacion = case
      when new.asignado_at is null then null
      when old.asignado_at is null then app.minutos_netos(new.id, new.creado_at, new.asignado_at)
      else s.min_asignacion end,
    min_resolucion = case
      when new.resuelto_at is null then null
      when old.resuelto_at is null then app.minutos_netos(new.id, new.creado_at, new.resuelto_at)
      else s.min_resolucion end
  where s.ticket_id = new.id;
  return null;
end $$;
create trigger tickets_sla_congelar after update of primera_respuesta_at, asignado_at, resuelto_at on public.tickets
  for each row
  when (old.primera_respuesta_at is distinct from new.primera_respuesta_at
     or old.asignado_at is distinct from new.asignado_at
     or old.resuelto_at is distinct from new.resuelto_at)
  execute function app.tg_ticket_sla_congelar();

/* ---------- Alta de perfiles desde Supabase Auth ----------
   El rol y el departamento se toman de raw_app_meta_data, que SOLO puede escribir el
   backend con la service_role (Edge Function de invitación). raw_user_meta_data es
   editable por el usuario y por eso nunca se usa para autorización. */
create or replace function app.tg_nuevo_usuario()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_rol text := new.raw_app_meta_data ->> 'rol';
  v_dep text := new.raw_app_meta_data ->> 'departamento';
  v_ok boolean;
begin
  v_ok := exists (select 1 from public.roles r where r.id = v_rol and v_dep = any (r.departamentos_permitidos));
  insert into public.perfiles (id, nombre, correo, rol_id, departamento_id, activo)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''), new.email),
          lower(new.email),
          case when v_ok then v_rol end,
          case when v_ok then v_dep end,
          false)                      -- siempre inactivo: lo activa el Administrador (fn_admin_usuario_guardar)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger apd_nuevo_usuario after insert on auth.users for each row execute function app.tg_nuevo_usuario();

commit;
