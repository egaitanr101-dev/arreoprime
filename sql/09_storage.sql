-- =============================================================================
-- 09_storage.sql — Almacenamiento seguro de evidencias (Supabase Storage)
--
-- • Bucket PRIVADO "evidencias": sin URLs públicas. La descarga se hace con
--   URLs firmadas de corta duración (createSignedUrl), que Storage solo emite si
--   la política SELECT permite leer el objeto.
-- • Ruta obligatoria: {ticket_id}/{evidencia_id}, reservada previamente por
--   fn_evidencia_preparar. Nadie puede subir a rutas arbitrarias.
-- • Lectura: solo si el usuario puede ver la fila de "evidencias" (RLS del ticket,
--   notas internas y estado), es decir, las mismas reglas que en la aplicación.
-- • Sin UPDATE ni DELETE: las evidencias no se reemplazan ni se borran.
-- =============================================================================
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidencias', 'evidencias', false, 10485760, array[
  'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/msword', 'application/vnd.ms-excel', 'text/csv'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Subida: solo a una ruta reservada por el mismo usuario y aún pendiente
create policy evidencias_subir on storage.objects for insert to authenticated with check (
  bucket_id = 'evidencias'
  and exists (
    select 1 from public.evidencias e
    where e.ruta = storage.objects.name
      and e.subido_por = (select auth.uid())
      and e.estado = 'PENDIENTE'
      and e.creado_at > now() - interval '24 hours'
  )
);

-- Lectura / URL firmada: la fila de evidencias debe ser visible para el usuario (RLS)
create policy evidencias_leer on storage.objects for select to authenticated using (
  bucket_id = 'evidencias'
  and exists (select 1 from public.evidencias e where e.ruta = storage.objects.name)
);

-- No se crean políticas UPDATE ni DELETE: quedan denegadas para anon y authenticated.

commit;
