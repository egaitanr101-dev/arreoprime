-- =============================================================================
-- ArreoPrime Desk - INSTALACION COMPLETA EN SUPABASE (generado desde sql/01..11)
-- Requisito previo: habilitar la extension pg_cron (Database > Extensions).
-- Ejecutar UNA sola vez en un proyecto nuevo, desde el SQL Editor.
-- No modificar este archivo: se regenera a partir de los scripts numerados.
-- =============================================================================

-- >>>>>>>>>>>>>>>>>>>> 01_base.sql <<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- ArreoPrime Desk | TRANSPORTES SERVICE DESK
-- 01_base.sql — Extensiones, esquemas y privilegios por defecto
--
-- Ejecutar como rol "postgres" en el SQL Editor de Supabase, en orden 01 → 11.
-- Luego, solo en desarrollo: 90_datos_demo.sql (opcional) y 99_pruebas_seguridad.sql.
-- Proyecto NUEVO (los scripts no son idempotentes salvo donde se indica).
--
-- Esquemas:
--   public    → tablas, vistas de la aplicación y funciones RPC expuestas por la API
--   app       → funciones internas (autorización, reglas, SLA). NO se expone en la API.
--   reporting → vistas para reportes y Power BI (grano documentado)
-- =============================================================================
begin;

create extension if not exists pg_trgm with schema extensions;   -- búsqueda por texto
create extension if not exists pgcrypto with schema extensions;  -- gen_random_uuid (también nativo en PG13+)

create schema if not exists app;
create schema if not exists reporting;

revoke all on schema app from public;
grant usage on schema app to authenticated;        -- solo para evaluar funciones usadas en políticas RLS
revoke all on schema reporting from public;
grant usage on schema reporting to authenticated;

-- Por defecto, nada nuevo queda accesible para anon/authenticated:
-- cada permiso se otorga explícitamente en 07_rls.sql.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;
alter default privileges in schema reporting revoke all on tables from anon, authenticated;

commit;


-- >>>>>>>>>>>>>>>>>>>> 02_tablas.sql <<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 02_tablas.sql — Modelo relacional normalizado
-- Convenciones: snake_case en español, timestamptz (UTC; se presenta en America/Costa_Rica),
-- montos numeric(14,2) en CRC, sin borrado físico de registros operativos.
-- =============================================================================
begin;

/* ---------------------------------------------------------------------------
   1. Organización, roles y permisos
   --------------------------------------------------------------------------- */
create table public.departamentos (
  id          text primary key check (id ~ '^[A-Z]{3}$'),
  nombre      text not null unique,
  tipo        text not null check (tipo in ('SOLICITANTE', 'RECEPTOR', 'CONSULTA', 'ADMINISTRACION')),
  activo      boolean not null default true
);
comment on table public.departamentos is 'COM, ALM, LIQ (solicitantes), TRA (receptor único), GER, SIS.';

create table public.roles (
  id                       text primary key,
  nombre                   text not null unique,
  departamentos_permitidos text[] not null   -- coherencia rol ↔ departamento
);

create table public.permisos (
  id          text primary key,                -- p. ej. 'ticket.crear'
  descripcion text not null,
  otorgable   boolean not null default false   -- puede concederse a un usuario puntual (perfil_permisos)
);

create table public.rol_permisos (
  rol_id            text not null references public.roles (id),
  permiso_id        text not null references public.permisos (id),
  solo_departamento text references public.departamentos (id), -- p. ej. financiero.ver solo para SOLICITANTE de LIQ
  primary key (rol_id, permiso_id)
);

create table public.perfiles (
  id              uuid primary key references auth.users (id) on delete restrict,
  nombre          text not null check (char_length(trim(nombre)) >= 3),
  correo          text not null unique,
  rol_id          text references public.roles (id),
  departamento_id text references public.departamentos (id),
  activo          boolean not null default false,
  disponible      boolean not null default true,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  constraint perfil_activo_completo check (not activo or (rol_id is not null and departamento_id is not null))
);
comment on table public.perfiles is 'Perfil autorizado. Rol y departamento solo cambian vía fn_admin_usuario_guardar; nunca desde el navegador.';
create index perfiles_rol_idx on public.perfiles (rol_id) where activo;

create table public.operador_alcance (
  perfil_id       uuid not null references public.perfiles (id),
  departamento_id text not null references public.departamentos (id) check (departamento_id in ('COM', 'ALM', 'LIQ')),
  primary key (perfil_id, departamento_id)
);
comment on table public.operador_alcance is 'Departamentos cuyos tickets puede tomar en revisión / autoasignarse un operador (C-05).';

create table public.perfil_permisos (
  perfil_id    uuid not null references public.perfiles (id),
  permiso_id   text not null references public.permisos (id),
  otorgado_por uuid not null references public.perfiles (id),
  otorgado_at  timestamptz not null default now(),
  primary key (perfil_id, permiso_id)
);

/* ---------------------------------------------------------------------------
   2. Catálogos
   --------------------------------------------------------------------------- */
create table public.tipos_gestion (
  id     text primary key,
  nombre text not null unique,
  orden  smallint not null
);

create table public.prioridades (
  id     text primary key check (id in ('CRITICA', 'ALTA', 'MEDIA', 'BAJA')),
  nombre text not null unique,
  orden  smallint not null unique
);

create table public.estados (
  id       text primary key,
  nombre   text not null unique,
  orden    smallint not null unique,
  abierto  boolean not null,
  terminal boolean not null
);

create table public.transiciones_estado (
  accion        text not null,
  estado_desde  text not null references public.estados (id),
  estado_hacia  text references public.estados (id),  -- null = acción sin cambio de estado o destino calculado
  descripcion   text,
  primary key (accion, estado_desde)
);
comment on table public.transiciones_estado is 'Fuente única de transiciones válidas. fn_ticket_accion rechaza cualquier combinación ausente.';

create table public.motivos (
  id        text primary key,
  tipo      text not null check (tipo in ('ESPERA', 'RECHAZO')),
  nombre    text not null,
  pausa_sla boolean not null default false,
  activo    boolean not null default true,
  unique (tipo, nombre)
);

create table public.respuestas_rapidas (
  id     text primary key,
  nombre text not null unique,
  texto  text not null,
  orden  smallint not null default 0,
  activo boolean not null default true
);

create table public.resultados_investigacion (
  id     text primary key,
  nombre text not null unique,
  orden  smallint not null
);

create table public.eventos_notificacion (
  id     text primary key,
  nombre text not null
);

create table public.campos_definicion (
  clave       text primary key,
  etiqueta    text not null,
  tipo        text not null check (tipo in ('texto', 'textarea', 'fecha', 'numero', 'crc', 'catalogo', 'opciones')),
  catalogo    text check (catalogo in ('clientes', 'rutas', 'choferes', 'ayudantes', 'vehiculos', 'bodegas', 'unidades')),
  opciones    text[],
  financiero  boolean not null default false,
  placeholder text,
  ayuda       text,
  check ((tipo = 'catalogo') = (catalogo is not null)),
  check ((tipo = 'opciones') = (opciones is not null))
);

create table public.categorias (
  id                      text primary key,
  departamento_id         text not null references public.departamentos (id),
  nombre                  text not null,
  tipo_gestion_default    text not null references public.tipos_gestion (id),
  prioridad_sugerida      text not null references public.prioridades (id),
  responsable_sugerido_id uuid references public.perfiles (id),
  requiere_aprobacion     boolean not null default false,
  genera_investigacion    boolean not null default false,
  financiero              boolean not null default false,
  activo                  boolean not null default true,
  orden                   smallint not null default 0,
  unique (departamento_id, nombre)
);

create table public.categoria_tipos (
  categoria_id text not null references public.categorias (id),
  tipo_id      text not null references public.tipos_gestion (id),
  primary key (categoria_id, tipo_id)
);

create table public.categoria_campos (
  categoria_id text not null references public.categorias (id),
  campo_clave  text not null references public.campos_definicion (clave),
  obligatorio  boolean not null default false,
  orden        smallint not null,
  primary key (categoria_id, campo_clave)
);

create table public.configuracion (
  clave          text primary key,
  valor          jsonb not null,
  descripcion    text,
  actualizado_por uuid references public.perfiles (id),
  actualizado_at timestamptz not null default now()
);

/* ---------------------------------------------------------------------------
   3. Datos maestros (sin datos reales: carga inicial pendiente, D-18)
   --------------------------------------------------------------------------- */
create table public.clientes (
  id     text primary key,
  nombre text not null,
  activo boolean not null default true
);
create table public.rutas (
  id     text primary key,
  nombre text not null,
  activo boolean not null default true
);
create table public.vehiculos (
  id          text primary key,           -- placa
  descripcion text not null,
  activo      boolean not null default true
);
create table public.colaboradores (
  id     text primary key,
  nombre text not null,
  tipo   text not null check (tipo in ('CHOFER', 'AYUDANTE', 'OTRO')),
  activo boolean not null default true
);
comment on table public.colaboradores is 'Choferes y ayudantes. No son usuarios del sistema.';
create table public.bodegas (
  id     text primary key,
  nombre text not null,
  activo boolean not null default true
);
create table public.unidades_medida (
  id     text primary key,
  nombre text not null,
  activo boolean not null default true
);

/* ---------------------------------------------------------------------------
   4. SLA (versionado; nada se edita, se publica una versión nueva)
   --------------------------------------------------------------------------- */
create table public.sla_versiones (
  version       integer primary key,
  vigente_desde timestamptz not null default now(),
  vigente_hasta timestamptz,
  umbral        numeric(3, 2) not null check (umbral >= 0.50 and umbral < 1),
  nota          text not null,
  creado_por    uuid references public.perfiles (id),
  creado_at     timestamptz not null default now(),
  -- ">=" y no ">": publicar dos versiones en la misma transacción (mismo now()) debe ser válido
  constraint sla_versiones_check check (vigente_hasta is null or vigente_hasta >= vigente_desde)
);
create unique index sla_una_vigente on public.sla_versiones ((true)) where vigente_hasta is null;

create table public.sla_valores (
  id                         bigint generated always as identity primary key,
  version                    integer not null references public.sla_versiones (version),
  categoria_id               text references public.categorias (id),  -- null = valor general de la prioridad
  prioridad_id               text not null references public.prioridades (id),
  minutos_primera_respuesta  integer not null check (minutos_primera_respuesta > 0),
  minutos_asignacion         integer not null check (minutos_asignacion > 0),
  minutos_resolucion         integer not null check (minutos_resolucion > 0),
  horas_maximo_atencion      integer not null check (horas_maximo_atencion > 0),
  check (minutos_primera_respuesta <= minutos_resolucion)
);
create unique index sla_valores_unicos on public.sla_valores (version, coalesce(categoria_id, '*'), prioridad_id);

create table public.calendario_laboral (
  dia_semana  smallint primary key check (dia_semana between 0 and 6),  -- 0 = domingo
  hora_inicio time not null,
  hora_fin    time not null,
  check (hora_fin > hora_inicio)
);
comment on table public.calendario_laboral is 'Día sin fila = sin atención. Hora local de Costa Rica.';

create table public.feriados (
  fecha  date primary key,
  nombre text not null
);

/* ---------------------------------------------------------------------------
   5. Tickets
   --------------------------------------------------------------------------- */
create table public.ticket_consecutivos (
  anio   integer primary key,
  ultimo integer not null check (ultimo > 0)
);
comment on table public.ticket_consecutivos is 'Consecutivo anual sin huecos (bloqueo de fila en fn_ticket_crear).';

create table public.tickets (
  id                   uuid primary key default gen_random_uuid(),
  numero               text not null unique check (numero ~ '^TS-[0-9]{4}-[0-9]{6}$'),
  departamento_id      text not null references public.departamentos (id),
  solicitante_id       uuid not null references public.perfiles (id),
  registrado_por       uuid not null references public.perfiles (id),
  canal                text not null check (canal in ('PORTAL', 'ASISTIDO')),
  tipo_gestion_id      text not null references public.tipos_gestion (id),
  categoria_id         text not null references public.categorias (id),
  asunto               text not null check (char_length(asunto) between 5 and 140),
  descripcion          text not null check (char_length(descripcion) between 10 and 4000),
  datos                jsonb not null default '{}'::jsonb check (jsonb_typeof(datos) = 'object'),
  prioridad_sugerida   text not null references public.prioridades (id),
  prioridad_id         text not null references public.prioridades (id),
  estado_id            text not null default 'NUEVO' references public.estados (id),
  estado_previo        text references public.estados (id),
  motivo_espera_id     text references public.motivos (id),
  responsable_id       uuid references public.perfiles (id),
  cliente_id           text references public.clientes (id),
  ruta_id              text references public.rutas (id),
  factura              text,
  pedido               text,
  fecha_requerida      date,
  creado_at            timestamptz not null default now(),
  primera_respuesta_at timestamptz,
  asignado_at          timestamptz,
  resuelto_at          timestamptz,
  cerrado_at           timestamptz,
  rechazado_at         timestamptz,
  resolucion           text,
  motivo_rechazo_id    text references public.motivos (id),
  reaperturas          integer not null default 0 check (reaperturas >= 0),
  cierre_excepcional   boolean not null default false,
  anulado              boolean not null default false,
  anulado_motivo       text,
  anulado_por          uuid references public.perfiles (id),
  anulado_at           timestamptz,
  actualizado_at       timestamptz not null default now(),
  check (not anulado or (anulado_motivo is not null and anulado_por is not null and anulado_at is not null)),
  check (estado_id <> 'RECHAZADO' or motivo_rechazo_id is not null),
  check (estado_id <> 'EN_ESPERA' or (motivo_espera_id is not null and estado_previo is not null)),
  check (estado_id not in ('ASIGNADO', 'EN_PROCESO') or responsable_id is not null),
  check (estado_id <> 'RESUELTO' or (resuelto_at is not null and resolucion is not null))
);
create index tickets_depto_fecha_idx on public.tickets (departamento_id, creado_at desc);
create index tickets_estado_idx on public.tickets (estado_id) where not anulado;
create index tickets_responsable_idx on public.tickets (responsable_id) where not anulado;
create index tickets_cliente_idx on public.tickets (cliente_id);
create index tickets_ruta_idx on public.tickets (ruta_id);
create index tickets_factura_idx on public.tickets (factura);
create index tickets_solicitante_idx on public.tickets (solicitante_id);
create index tickets_asunto_trgm on public.tickets using gin (asunto extensions.gin_trgm_ops);

create table public.ticket_sla (
  ticket_id                 uuid primary key references public.tickets (id),
  version                   integer not null references public.sla_versiones (version),
  prioridad_id              text not null references public.prioridades (id),
  obj_primera_respuesta     integer not null,
  obj_asignacion            integer not null,
  obj_resolucion            integer not null,
  horas_maximo_atencion     integer not null,
  umbral                    numeric(3, 2) not null,
  min_primera_respuesta     numeric(12, 2),   -- se congela al cumplirse (conserva el histórico)
  min_asignacion            numeric(12, 2),
  min_resolucion            numeric(12, 2),
  notificado                jsonb not null default '{}'::jsonb
);
comment on table public.ticket_sla is 'Snapshot del SLA vigente al crear el ticket. Cambiar la política no altera tickets existentes.';

create table public.sla_pausas (
  id        bigint generated always as identity primary key,
  ticket_id uuid not null references public.tickets (id),
  inicio    timestamptz not null,
  fin       timestamptz,
  motivo    text not null,
  check (fin is null or fin >= inicio)
);
create index sla_pausas_ticket_idx on public.sla_pausas (ticket_id);
create unique index sla_pausa_abierta_unica on public.sla_pausas (ticket_id) where fin is null;

create table public.sla_excepciones (
  id             bigint generated always as identity primary key,
  ticket_id      uuid not null references public.tickets (id),
  metrica        text not null check (metrica in ('primera_respuesta', 'asignacion', 'resolucion')),
  justificacion  text not null check (char_length(justificacion) >= 10),
  autorizado_por uuid not null references public.perfiles (id),
  creado_at      timestamptz not null default now(),
  unique (ticket_id, metrica)
);

create table public.asignaciones (
  id             bigint generated always as identity primary key,
  ticket_id      uuid not null references public.tickets (id),
  responsable_id uuid not null references public.perfiles (id),
  asignado_por   uuid references public.perfiles (id),   -- null = asignación automática
  tipo           text not null check (tipo in ('MANUAL', 'SUGERIDA', 'AUTOASIGNACION', 'AUTOMATICA')),
  motivo         text,
  desde          timestamptz not null default now(),
  hasta          timestamptz
);
create index asignaciones_ticket_idx on public.asignaciones (ticket_id);

create table public.comentarios (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid not null references public.tickets (id),
  autor_id    uuid not null references public.perfiles (id),
  visibilidad text not null check (visibilidad in ('PUBLICO', 'INTERNO')),
  tipo        text not null check (tipo in ('COMENTARIO', 'SOLICITUD_INFO', 'RESPUESTA_INFO', 'RESOLUCION')),
  texto       text not null check (char_length(texto) between 2 and 4000),
  responde_a  uuid references public.comentarios (id),
  creado_at   timestamptz not null default now(),
  check (visibilidad = 'PUBLICO' or tipo = 'COMENTARIO')
);
create index comentarios_ticket_idx on public.comentarios (ticket_id, creado_at);

create table public.evidencias (
  id            uuid primary key default gen_random_uuid(),
  ticket_id     uuid not null references public.tickets (id),
  comentario_id uuid references public.comentarios (id),
  nombre        text not null check (char_length(nombre) between 1 and 200),
  tamano_bytes  bigint not null check (tamano_bytes > 0 and tamano_bytes <= 10485760),
  mime          text not null,
  visibilidad   text not null check (visibilidad in ('PUBLICO', 'INTERNO')),
  ruta          text not null unique,     -- {ticket_id}/{evidencia_id} dentro del bucket privado "evidencias"
  estado        text not null default 'PENDIENTE' check (estado in ('PENDIENTE', 'CONFIRMADA', 'EXPIRADA')),
  subido_por    uuid not null references public.perfiles (id),
  creado_at     timestamptz not null default now(),
  confirmado_at timestamptz
);
create index evidencias_ticket_idx on public.evidencias (ticket_id);

create table public.historial_tickets (
  id          bigint generated always as identity primary key,
  ticket_id   uuid not null references public.tickets (id),
  ts          timestamptz not null default now(),
  usuario_id  uuid references public.perfiles (id),      -- null = proceso automático
  evento      text not null,
  detalle     text not null,
  visibilidad text not null check (visibilidad in ('PUBLICO', 'INTERNO', 'FINANCIERO'))
);
create index historial_ticket_idx on public.historial_tickets (ticket_id, ts);
comment on table public.historial_tickets is 'Solo inserción. Protegido por trigger contra UPDATE/DELETE.';

/* ---------------------------------------------------------------------------
   6. Liquidaciones: diferencias, libro de movimientos, investigaciones
   --------------------------------------------------------------------------- */
create table public.liquidacion_diferencias (
  id               uuid primary key default gen_random_uuid(),
  ticket_id        uuid not null references public.tickets (id),
  num_liquidacion  text,
  ruta_id          text references public.rutas (id),
  fecha_operacion  date,
  chofer_id        text references public.colaboradores (id),
  ayudante_id      text references public.colaboradores (id),
  factura          text,
  tipo_diferencia  text check (tipo_diferencia in ('Faltante', 'Sobrante', 'Documental')),
  medio_pago       text check (medio_pago in ('Efectivo', 'Datáfono', 'Transferencia', 'Depósito', 'Cheque', 'No aplica')),
  monto_esperado   numeric(14, 2) not null check (monto_esperado >= 0),
  monto_recibido   numeric(14, 2) not null check (monto_recibido >= 0),
  monto_reportado  numeric(14, 2) check (monto_reportado >= 0),
  monto_diferencia numeric(14, 2) generated always as (monto_esperado - monto_recibido) stored, -- D-09
  creado_por       uuid not null references public.perfiles (id),
  creado_at        timestamptz not null default now()
);
create index diferencias_ticket_idx on public.liquidacion_diferencias (ticket_id);
create index diferencias_chofer_idx on public.liquidacion_diferencias (chofer_id);
create index diferencias_ruta_idx on public.liquidacion_diferencias (ruta_id);
comment on column public.liquidacion_diferencias.monto_diferencia is 'Positivo = faltante; negativo = sobrante. Es el saldo inicial; nunca se suma desde otras tablas.';

create table public.movimientos_financieros (
  id            uuid primary key default gen_random_uuid(),
  diferencia_id uuid not null references public.liquidacion_diferencias (id),
  ticket_id     uuid not null references public.tickets (id),
  tipo          text not null check (tipo in ('ACLARACION', 'RECUPERACION', 'AJUSTE', 'REVERSION')),
  monto         numeric(14, 2) not null check (monto <> 0),
  nota          text not null check (char_length(nota) >= 5),
  revierte_id   uuid unique references public.movimientos_financieros (id),  -- unique: no se revierte dos veces
  usuario_id    uuid not null references public.perfiles (id),
  creado_at     timestamptz not null default now(),
  check ((tipo = 'REVERSION') = (revierte_id is not null)),
  check (tipo = 'AJUSTE' or monto > 0)
);
create index movimientos_diferencia_idx on public.movimientos_financieros (diferencia_id);
comment on table public.movimientos_financieros is 'Libro inmutable. Cada movimiento tiene identificador propio; las correcciones son reversiones.';

create table public.recuperaciones (
  movimiento_id uuid primary key references public.movimientos_financieros (id),
  forma         text not null,
  comprobante   text,
  fecha         date not null
);
comment on table public.recuperaciones is 'Detalle de recuperaciones autorizadas fuera del sistema (D-19). El sistema registra; no decide.';

create table public.investigaciones (
  id               uuid primary key default gen_random_uuid(),
  ticket_id        uuid not null unique references public.tickets (id),
  estado           text not null default 'ABIERTA' check (estado in ('ABIERTA', 'EN_CURSO', 'EN_ACLARACION', 'CONCLUIDA', 'CANCELADA')),
  responsable_id   uuid references public.perfiles (id),
  fecha_inicio     timestamptz not null default now(),
  resultado_id     text references public.resultados_investigacion (id),
  conclusion       text,
  fecha_resolucion timestamptz,
  concluida_por    uuid references public.perfiles (id),
  reaperturas      integer not null default 0,
  check (estado <> 'CONCLUIDA' or (resultado_id is not null and conclusion is not null and fecha_resolucion is not null and concluida_por is not null))
);

create table public.investigacion_involucrados (
  investigacion_id uuid not null references public.investigaciones (id),
  colaborador_id   text not null references public.colaboradores (id),
  rol              text not null,
  primary key (investigacion_id, colaborador_id)
);
comment on table public.investigacion_involucrados is 'Personas involucradas. Involucrado NO implica responsable.';

create table public.investigacion_hallazgos (
  id               uuid primary key default gen_random_uuid(),
  investigacion_id uuid not null references public.investigaciones (id),
  texto            text not null check (char_length(texto) >= 5),
  autor_id         uuid not null references public.perfiles (id),
  creado_at        timestamptz not null default now()
);

create table public.investigacion_conclusiones (
  id               bigint generated always as identity primary key,
  investigacion_id uuid not null references public.investigaciones (id),
  resultado_id     text not null references public.resultados_investigacion (id),
  conclusion       text not null,
  concluida_por    uuid not null references public.perfiles (id),
  concluida_at     timestamptz not null,
  reabierta_por    uuid references public.perfiles (id),
  reabierta_at     timestamptz,
  motivo_reapertura text
);
comment on table public.investigacion_conclusiones is 'Conclusiones anteriores conservadas al reabrir una investigación.';

/* ---------------------------------------------------------------------------
   7. Notificaciones y auditoría
   --------------------------------------------------------------------------- */
create table public.notificaciones (
  id         bigint generated always as identity primary key,
  usuario_id uuid not null references public.perfiles (id),
  evento     text not null references public.eventos_notificacion (id),
  ticket_id  uuid references public.tickets (id),
  texto      text not null,
  leida      boolean not null default false,
  creado_at  timestamptz not null default now()
);
create index notificaciones_usuario_idx on public.notificaciones (usuario_id, leida, creado_at desc);

create table public.preferencias_notificacion (
  usuario_id uuid not null references public.perfiles (id),
  evento     text not null references public.eventos_notificacion (id),
  activo     boolean not null,
  primary key (usuario_id, evento)
);

create table public.auditoria (
  id         bigint generated always as identity primary key,
  ts         timestamptz not null default now(),
  usuario_id uuid references public.perfiles (id),
  ambito     text not null check (ambito in ('OPERATIVA', 'ADMINISTRATIVA')),
  accion     text not null,
  detalle    text not null,
  ticket_id  uuid references public.tickets (id),
  datos      jsonb
);
create index auditoria_ts_idx on public.auditoria (ts desc);

commit;


-- >>>>>>>>>>>>>>>>>>>> 03_catalogos.sql <<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 03_catalogos.sql — Catálogos definidos en el documento de requerimientos
-- NO incluye: tiempos SLA, calendario laboral, feriados ni datos maestros
-- (clientes, rutas, colaboradores…). Esos valores los define la organización
-- (D-15, D-18); para pruebas existe 90_datos_demo.sql.
-- =============================================================================
begin;

insert into public.departamentos (id, nombre, tipo) values
  ('COM', 'Comercial', 'SOLICITANTE'),
  ('ALM', 'Almacén', 'SOLICITANTE'),
  ('LIQ', 'Liquidaciones', 'SOLICITANTE'),
  ('TRA', 'Distrib. y Transp. Cárnico', 'RECEPTOR'),
  ('GER', 'Gerencia', 'CONSULTA'),
  ('SIS', 'Sistemas', 'ADMINISTRACION');

insert into public.roles (id, nombre, departamentos_permitidos) values
  ('SOLICITANTE', 'Solicitante', array['COM', 'ALM', 'LIQ']),
  ('SUPERVISOR_LIQUIDACIONES', 'Supervisor de Liquidaciones Crédito y Cobro', array['LIQ']),
  ('OPERADOR_TRANSPORTES', 'Coordinador de Rutas', array['TRA']),
  ('SUPERVISOR_TRANSPORTES', 'Jefe Transportes Distrib. y Transp. Cárnico', array['TRA']),
  ('GERENCIA', 'Gerencia', array['GER']),
  ('ADMINISTRADOR', 'Administrador', array['SIS']),
  ('SUPERUSUARIO', 'Super usuario', array['TRA']);

insert into public.permisos (id, descripcion, otorgable) values
  ('ticket.crear', 'Crear tickets de su propio departamento', false),
  ('ticket.registro_asistido', 'Registrar tickets en nombre de un solicitante', false),
  ('ticket.ver_departamento', 'Ver todos los tickets de su departamento', false),
  ('ticket.ver_todos', 'Ver todos los tickets', false),
  ('ticket.comentar_publico', 'Agregar comentarios públicos', false),
  ('ticket.responder_info', 'Responder solicitudes de información', false),
  ('ticket.nota_interna', 'Agregar notas internas', false),
  ('ticket.ver_internas', 'Ver notas internas', false),
  ('evidencia.subir', 'Adjuntar evidencias', false),
  ('ticket.triaje', 'Tomar tickets en revisión dentro de su alcance', false),
  ('ticket.autoasignar', 'Asignarse tickets dentro de su alcance', false),
  ('ticket.asignar', 'Asignar y reasignar responsables', false),
  ('ticket.prioridad', 'Modificar prioridad', false),
  ('ticket.gestionar_asignados', 'Gestionar los tickets asignados', false),
  ('ticket.gestionar_todos', 'Gestionar todos los tickets', false),
  ('ticket.rechazar', 'Rechazar tickets con justificación', false),
  ('ticket.confirmar', 'Confirmar resolución', false),
  ('ticket.solicitar_reapertura', 'Solicitar reapertura', false),
  ('ticket.cerrar', 'Cerrar tickets resueltos', false),
  ('ticket.reabrir', 'Reabrir tickets cerrados o rechazados', false),
  ('ticket.cierre_excepcional', 'Cierre excepcional documentado', false),
  ('ticket.anular', 'Anular tickets sin borrado físico', false),
  ('sla.excepcion', 'Autorizar excepciones de SLA', false),
  ('financiero.ver', 'Ver información financiera de Liquidaciones', true),
  ('financiero.registrar', 'Registrar movimientos financieros', true),
  ('investigacion.ver_resumen', 'Ver estado y conclusión de investigaciones', false),
  ('investigacion.ver', 'Ver investigaciones completas', true),
  ('investigacion.gestionar', 'Gestionar investigaciones', true),
  ('dashboard.operativo', 'Dashboard operativo', false),
  ('dashboard.gerencial', 'Dashboard gerencial', false),
  ('dashboard.liquidaciones', 'Dashboard de Liquidaciones (tendencias, motivos y choferes)', false),
  ('reporte.departamento', 'Exportar tickets de su departamento', false),
  ('reporte.operativo', 'Reportes operativos sin información financiera', false),
  ('reporte.completo', 'Reportes completos', false),
  ('sla.ver', 'Consultar SLA', false),
  ('sla.configurar', 'Configurar SLA, calendario y feriados', false),
  ('auditoria.operativa', 'Consultar auditoría operativa', false),
  ('auditoria.administrativa', 'Consultar auditoría administrativa', false),
  ('admin.usuarios', 'Administrar usuarios, roles y permisos', false),
  ('admin.catalogos', 'Administrar catálogos y configuración', false);

insert into public.rol_permisos (rol_id, permiso_id, solo_departamento)
select 'SOLICITANTE', p, case when p in ('financiero.ver', 'investigacion.ver_resumen') then 'LIQ' end
from unnest(array['ticket.crear', 'ticket.ver_departamento', 'ticket.comentar_publico', 'ticket.responder_info',
  'evidencia.subir', 'ticket.confirmar', 'ticket.solicitar_reapertura', 'financiero.ver', 'investigacion.ver_resumen',
  'reporte.departamento']) p
union all
-- Supervisor de Liquidaciones: como el solicitante de LIQ + dashboard y reportes; todo limitado a LIQ
select 'SUPERVISOR_LIQUIDACIONES', p, 'LIQ'
from unnest(array['ticket.crear', 'ticket.ver_departamento', 'ticket.comentar_publico', 'ticket.responder_info',
  'evidencia.subir', 'ticket.confirmar', 'ticket.solicitar_reapertura', 'financiero.ver', 'investigacion.ver_resumen',
  'reporte.departamento', 'dashboard.liquidaciones', 'reporte.operativo', 'reporte.completo']) p
union all
select 'OPERADOR_TRANSPORTES', p, null
from unnest(array['ticket.registro_asistido', 'ticket.ver_todos', 'ticket.comentar_publico', 'ticket.nota_interna',
  'ticket.ver_internas', 'evidencia.subir', 'ticket.triaje', 'ticket.autoasignar', 'ticket.gestionar_asignados',
  'dashboard.operativo', 'reporte.operativo', 'sla.ver']) p
union all
select 'SUPERVISOR_TRANSPORTES', p, null
from unnest(array['ticket.registro_asistido', 'ticket.ver_todos', 'ticket.comentar_publico', 'ticket.nota_interna',
  'ticket.ver_internas', 'evidencia.subir', 'ticket.triaje', 'ticket.asignar', 'ticket.prioridad', 'ticket.gestionar_todos',
  'ticket.rechazar', 'ticket.cerrar', 'ticket.reabrir', 'ticket.cierre_excepcional', 'ticket.anular', 'sla.excepcion',
  'financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar', 'dashboard.operativo',
  'dashboard.gerencial', 'dashboard.liquidaciones', 'reporte.operativo', 'reporte.completo', 'sla.ver', 'auditoria.operativa']) p
union all
select 'GERENCIA', p, null
from unnest(array['ticket.ver_todos', 'ticket.ver_internas', 'financiero.ver', 'investigacion.ver', 'dashboard.gerencial',
  'dashboard.liquidaciones', 'reporte.operativo', 'reporte.completo', 'sla.ver']) p
union all
select 'ADMINISTRADOR', p, null
from unnest(array['admin.usuarios', 'admin.catalogos', 'sla.ver', 'sla.configurar', 'auditoria.administrativa']) p;

-- Super usuario: todos los permisos, sin límite de departamento
insert into public.rol_permisos (rol_id, permiso_id, solo_departamento)
select 'SUPERUSUARIO', id, null from public.permisos;

insert into public.tipos_gestion (id, nombre, orden) values
  ('SOL', 'Solicitud', 1), ('REQ', 'Requerimiento', 2), ('INC', 'Incidencia', 3), ('REC', 'Reclamo', 4),
  ('COO', 'Coordinación', 5), ('CON', 'Consulta', 6), ('URG', 'Urgencia operativa', 7);

insert into public.prioridades (id, nombre, orden) values
  ('CRITICA', 'Crítica', 1), ('ALTA', 'Alta', 2), ('MEDIA', 'Media', 3), ('BAJA', 'Baja', 4);

insert into public.estados (id, nombre, orden, abierto, terminal) values
  ('NUEVO', 'Nuevo', 1, true, false),
  ('EN_REVISION', 'En revisión', 2, true, false),
  ('ASIGNADO', 'Asignado', 3, true, false),
  ('EN_PROCESO', 'En proceso', 4, true, false),
  ('EN_ESPERA', 'En espera', 5, true, false),
  ('RESUELTO', 'Resuelto', 6, false, false),
  ('CERRADO', 'Cerrado', 7, false, true),
  ('RECHAZADO', 'Rechazado', 8, false, true);

insert into public.transiciones_estado (accion, estado_desde, estado_hacia, descripcion) values
  ('tomar_revision', 'NUEVO', 'EN_REVISION', 'Inicio de revisión (primera respuesta)'),
  ('asignar', 'NUEVO', 'ASIGNADO', null), ('asignar', 'EN_REVISION', 'ASIGNADO', null),
  ('autoasignar', 'NUEVO', 'ASIGNADO', null), ('autoasignar', 'EN_REVISION', 'ASIGNADO', null),
  ('reasignar', 'ASIGNADO', 'ASIGNADO', null), ('reasignar', 'EN_PROCESO', 'ASIGNADO', 'El nuevo responsable confirma el inicio'),
  ('iniciar', 'ASIGNADO', 'EN_PROCESO', null),
  ('espera', 'EN_REVISION', 'EN_ESPERA', null), ('espera', 'ASIGNADO', 'EN_ESPERA', null), ('espera', 'EN_PROCESO', 'EN_ESPERA', null),
  ('reanudar', 'EN_ESPERA', null, 'Vuelve al estado previo'),
  ('resolver', 'EN_PROCESO', 'RESUELTO', null),
  ('rechazar', 'NUEVO', 'RECHAZADO', null), ('rechazar', 'EN_REVISION', 'RECHAZADO', null),
  ('confirmar', 'RESUELTO', 'CERRADO', 'Confirmación del solicitante'),
  ('solicitar_reapertura', 'RESUELTO', 'EN_PROCESO', null),
  ('cerrar', 'RESUELTO', 'CERRADO', null),
  ('reabrir', 'CERRADO', null, 'EN_PROCESO si tiene responsable; si no, EN_REVISION'),
  ('reabrir', 'RECHAZADO', null, 'EN_PROCESO si tiene responsable; si no, EN_REVISION'),
  ('cierre_excepcional', 'NUEVO', 'CERRADO', null), ('cierre_excepcional', 'EN_REVISION', 'CERRADO', null),
  ('cierre_excepcional', 'ASIGNADO', 'CERRADO', null), ('cierre_excepcional', 'EN_PROCESO', 'CERRADO', null),
  ('cierre_excepcional', 'EN_ESPERA', 'CERRADO', null);
insert into public.transiciones_estado (accion, estado_desde, estado_hacia, descripcion)
select 'cambiar_prioridad', e, null, 'Sin cambio de estado'
from unnest(array['NUEVO', 'EN_REVISION', 'ASIGNADO', 'EN_PROCESO', 'EN_ESPERA', 'RESUELTO']) e
union all
select 'anular', id, null, 'Marca de anulación; se conserva el estado' from public.estados;

insert into public.motivos (id, tipo, nombre, pausa_sla) values
  ('INFO_SOLICITANTE', 'ESPERA', 'Información del solicitante', true),
  ('TERCERO', 'ESPERA', 'Depende de un tercero (cliente o proveedor)', true),
  ('PROGRAMADO', 'ESPERA', 'Programado para una fecha posterior', true),
  ('VEHICULO', 'ESPERA', 'Disponibilidad de vehículo', false),
  ('INTERNO', 'ESPERA', 'Coordinación interna de Transportes', false),
  ('FUERA_ALCANCE', 'RECHAZO', 'Fuera del alcance de Transportes', false),
  ('DUPLICADO', 'RECHAZO', 'Ticket duplicado', false),
  ('INFO_INSUF', 'RECHAZO', 'Información insuficiente', false),
  ('NO_PROCEDE', 'RECHAZO', 'No procede según política', false);

insert into public.respuestas_rapidas (id, nombre, texto, orden) values
  ('R1', 'Solicitud recibida', 'Solicitud recibida. La estamos revisando y le informaremos el avance.', 1),
  ('R2', 'En revisión', 'Su solicitud está en revisión por el equipo de Transportes.', 2),
  ('R3', 'Información adicional requerida', 'Para continuar necesitamos información adicional. Por favor indíquenos: ', 3),
  ('R4', 'Asignado para atención', 'Su solicitud fue asignada a un responsable de Transportes para su atención.', 4),
  ('R5', 'En proceso', 'Estamos trabajando en su solicitud. Le avisaremos al completarla.', 5),
  ('R6', 'Solucionado', 'La solicitud fue atendida. Por favor confirme la resolución.', 6),
  ('R7', 'Cerrado', 'El ticket se cierra. Gracias por utilizar la mesa de servicio de Transportes.', 7);

insert into public.resultados_investigacion (id, nombre, orden) values
  ('JUSTIFICADA', 'Diferencia justificada', 1), ('PENDIENTE_ACLARACION', 'Pendiente de aclaración', 2),
  ('ERROR_DOCUMENTAL', 'Error documental', 3), ('ERROR_OPERATIVO', 'Error operativo', 4),
  ('OTRO_PROCESO', 'Atribuible a otro proceso', 5), ('NO_DETERMINADA', 'No determinada', 6), ('ESCALADO', 'Escalado', 7);

insert into public.eventos_notificacion (id, nombre) values
  ('nuevo', 'Nuevo ticket'), ('asignado', 'Ticket asignado'), ('reasignado', 'Cambio de responsable'),
  ('comentario', 'Nuevo comentario'), ('info_requerida', 'Información requerida'), ('respuesta_info', 'Respuesta del solicitante'),
  ('sla_proximo', 'Próximo a vencer'), ('sla_vencido', 'SLA vencido'), ('resuelto', 'Ticket resuelto'),
  ('cerrado', 'Ticket cerrado'), ('reabierto', 'Ticket reabierto'), ('rechazado', 'Ticket rechazado'),
  ('sin_responsable', 'Ticket sin responsable');

insert into public.configuracion (clave, valor, descripcion) values
  ('asignacion_automatica', 'false', 'D-21: desactivada por defecto'),
  ('auto_cierre_dias', '3', 'D-08: días hábiles para cerrar automáticamente un ticket resuelto sin confirmación');

/* ---------------- Campos dinámicos ---------------- */
insert into public.campos_definicion (clave, etiqueta, tipo, catalogo, opciones, financiero, placeholder, ayuda) values
  ('cliente', 'Cliente', 'catalogo', 'clientes', null, false, null, null),
  ('pedido', 'Número de pedido', 'texto', null, null, false, 'PED-00000', null),
  ('factura', 'Número de factura', 'texto', null, null, false, 'FE-000000', null),
  ('ruta', 'Ruta', 'catalogo', 'rutas', null, false, null, null),
  ('fecha_entrega', 'Fecha de entrega', 'fecha', null, null, false, null, null),
  ('fecha_solicitada', 'Fecha solicitada', 'fecha', null, null, false, null, null),
  ('horario', 'Horario requerido', 'texto', null, null, false, 'Ej.: 8:00 – 10:00', null),
  ('direccion', 'Dirección o ubicación', 'textarea', null, null, false, null, null),
  ('chofer', 'Chofer', 'catalogo', 'choferes', null, false, null, null),
  ('bodega_origen', 'Bodega de origen', 'catalogo', 'bodegas', null, false, null, null),
  ('bodega_destino', 'Bodega de destino', 'catalogo', 'bodegas', null, false, null, null),
  ('codigo_producto', 'Código de producto', 'texto', null, null, false, 'P-0000', null),
  ('producto', 'Descripción del producto', 'texto', null, null, false, null, null),
  ('cantidad', 'Cantidad', 'numero', null, null, false, null, null),
  ('unidad', 'Unidad de medida', 'catalogo', 'unidades', null, false, null, null),
  ('fecha_requerida', 'Fecha requerida', 'fecha', null, null, false, null, null),
  ('vehiculo', 'Vehículo requerido', 'catalogo', 'vehiculos', null, false, null, null),
  ('ubicacion', 'Ubicación', 'texto', null, null, false, null, null),
  ('responsable_mov', 'Responsable en sitio', 'texto', null, null, false, null, null),
  ('fecha_operacion', 'Fecha de operación', 'fecha', null, null, false, null, null),
  ('ayudante', 'Ayudante', 'catalogo', 'ayudantes', null, false, null, null),
  ('num_liquidacion', 'Número de liquidación', 'texto', null, null, false, 'LQ-00000', null),
  ('tipo_diferencia', 'Tipo de diferencia', 'opciones', null, array['Faltante', 'Sobrante', 'Documental'], false, null, null),
  ('medio_pago', 'Medio de pago', 'opciones', null, array['Efectivo', 'Datáfono', 'Transferencia', 'Depósito', 'Cheque', 'No aplica'], false, null, null),
  ('monto_esperado', 'Monto esperado', 'crc', null, null, true, null, null),
  ('monto_reportado', 'Monto reportado (diferencia)', 'crc', null, null, true, null, 'Monto que Liquidaciones reporta como diferencia; se concilia contra el cálculo.'),
  ('monto_recibido', 'Monto recibido', 'crc', null, null, true, null, null);

/* ---------------- Categorías (revisar campos obligatorios y prioridad sugerida: C-10) ---------------- */
create temporary table _cat (id text, dep text, nombre text, tipo text, prio text, inv boolean, fin boolean, orden int, campos text[]) on commit drop;
insert into _cat values
  ('COM-01', 'COM', 'Entrega extraordinaria', 'SOL', 'ALTA', false, false, 1, array['cliente*', 'pedido', 'factura', 'fecha_solicitada*', 'horario', 'direccion*']),
  ('COM-02', 'COM', 'Segunda visita', 'SOL', 'MEDIA', false, false, 2, array['cliente*', 'factura*', 'ruta', 'fecha_solicitada*', 'horario']),
  ('COM-03', 'COM', 'Reprogramación de entrega', 'SOL', 'MEDIA', false, false, 3, array['cliente*', 'pedido', 'factura', 'fecha_entrega*', 'fecha_solicitada*', 'horario']),
  ('COM-04', 'COM', 'Cambio de horario', 'SOL', 'MEDIA', false, false, 4, array['cliente*', 'ruta', 'fecha_entrega*', 'horario*']),
  ('COM-05', 'COM', 'Retiro de producto', 'REQ', 'MEDIA', false, false, 5, array['cliente*', 'factura*', 'fecha_solicitada*', 'direccion']),
  ('COM-06', 'COM', 'Atención especial a cliente', 'REQ', 'MEDIA', false, false, 6, array['cliente*', 'fecha_solicitada', 'horario', 'direccion']),
  ('COM-07', 'COM', 'Problemas durante la entrega', 'INC', 'ALTA', false, false, 7, array['cliente*', 'factura', 'ruta*', 'fecha_entrega*', 'chofer']),
  ('COM-08', 'COM', 'Incidencia con chofer', 'INC', 'ALTA', false, false, 8, array['ruta*', 'chofer*', 'fecha_entrega*', 'cliente']),
  ('COM-09', 'COM', 'Reclamo de cliente', 'REC', 'ALTA', false, false, 9, array['cliente*', 'factura', 'ruta', 'fecha_entrega']),
  ('COM-10', 'COM', 'Transporte adicional', 'REQ', 'MEDIA', false, false, 10, array['cliente', 'fecha_solicitada*', 'horario', 'direccion*']),
  ('COM-11', 'COM', 'Consulta sobre entrega', 'CON', 'BAJA', false, false, 11, array['cliente*', 'pedido', 'factura', 'ruta']),
  ('COM-12', 'COM', 'Otros', 'SOL', 'MEDIA', false, false, 12, array['cliente', 'ruta']),
  ('ALM-01', 'ALM', 'Movimiento entre bodegas', 'COO', 'MEDIA', false, false, 1, array['bodega_origen*', 'bodega_destino*', 'codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'fecha_requerida*']),
  ('ALM-02', 'ALM', 'Traslado de producto', 'REQ', 'MEDIA', false, false, 2, array['bodega_origen*', 'ubicacion*', 'producto*', 'cantidad*', 'unidad*', 'fecha_requerida*', 'vehiculo']),
  ('ALM-03', 'ALM', 'Recolección de mercancía', 'REQ', 'MEDIA', false, false, 3, array['ubicacion*', 'producto*', 'cantidad', 'unidad', 'fecha_requerida*', 'responsable_mov']),
  ('ALM-04', 'ALM', 'Devolución', 'SOL', 'MEDIA', false, false, 4, array['bodega_destino*', 'codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'ubicacion']),
  ('ALM-05', 'ALM', 'Solicitud de vehículo', 'REQ', 'ALTA', false, false, 5, array['vehiculo', 'fecha_requerida*', 'ubicacion*', 'responsable_mov']),
  ('ALM-06', 'ALM', 'Apoyo de transporte', 'SOL', 'MEDIA', false, false, 6, array['fecha_requerida*', 'ubicacion*', 'responsable_mov']),
  ('ALM-07', 'ALM', 'Coordinación de carga', 'COO', 'MEDIA', false, false, 7, array['bodega_origen*', 'vehiculo', 'fecha_requerida*', 'responsable_mov']),
  ('ALM-08', 'ALM', 'Coordinación de descarga', 'COO', 'MEDIA', false, false, 8, array['bodega_destino*', 'vehiculo', 'fecha_requerida*', 'responsable_mov']),
  ('ALM-09', 'ALM', 'Diferencias relacionadas con transporte', 'INC', 'ALTA', false, false, 9, array['codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'vehiculo', 'fecha_requerida']),
  ('ALM-10', 'ALM', 'Movimientos internos', 'COO', 'BAJA', false, false, 10, array['bodega_origen*', 'bodega_destino*', 'producto*', 'cantidad', 'unidad']),
  ('ALM-11', 'ALM', 'Otros', 'SOL', 'MEDIA', false, false, 11, array['ubicacion']),
  ('LIQ-01', 'LIQ', 'Diferencias de liquidación de rutas', 'INC', 'ALTA', true, true, 1, array['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion*', 'tipo_diferencia*', 'medio_pago', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-02', 'LIQ', 'Faltantes o sobrantes de dinero', 'INC', 'ALTA', true, true, 2, array['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion', 'tipo_diferencia*', 'medio_pago*', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-03', 'LIQ', 'Diferencias entre facturas y hoja de ruta', 'INC', 'MEDIA', true, true, 3, array['ruta*', 'fecha_operacion*', 'chofer', 'num_liquidacion', 'factura*', 'tipo_diferencia', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-04', 'LIQ', 'Diferencias en cobros en efectivo', 'INC', 'ALTA', true, true, 4, array['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion', 'factura', 'tipo_diferencia*', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-05', 'LIQ', 'Diferencias de datáfono', 'INC', 'MEDIA', true, true, 5, array['ruta*', 'fecha_operacion*', 'chofer*', 'num_liquidacion', 'factura', 'tipo_diferencia*', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-06', 'LIQ', 'Comprobantes de depósitos pendientes', 'REQ', 'MEDIA', false, false, 6, array['ruta*', 'fecha_operacion*', 'chofer*', 'num_liquidacion*', 'medio_pago']),
  ('LIQ-07', 'LIQ', 'Documentación faltante', 'REQ', 'MEDIA', false, false, 7, array['ruta*', 'fecha_operacion*', 'chofer', 'num_liquidacion', 'factura']),
  ('LIQ-08', 'LIQ', 'Rendición de cuentas', 'REQ', 'MEDIA', false, false, 8, array['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion*']),
  ('LIQ-09', 'LIQ', 'Diferencias de combustible', 'INC', 'MEDIA', true, true, 9, array['ruta*', 'fecha_operacion*', 'chofer*', 'tipo_diferencia*', 'monto_esperado*', 'monto_reportado*', 'monto_recibido*']),
  ('LIQ-10', 'LIQ', 'Viáticos', 'SOL', 'BAJA', false, true, 10, array['ruta', 'fecha_operacion*', 'chofer*', 'ayudante', 'monto_esperado', 'monto_reportado', 'monto_recibido']),
  ('LIQ-11', 'LIQ', 'Incumplimiento en entrega de documentación', 'INC', 'MEDIA', false, false, 11, array['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion']),
  ('LIQ-12', 'LIQ', 'Investigación de movimientos de choferes y ayudantes', 'INC', 'ALTA', true, true, 12, array['ruta', 'fecha_operacion*', 'chofer', 'ayudante', 'tipo_diferencia', 'monto_esperado', 'monto_reportado', 'monto_recibido']),
  ('LIQ-13', 'LIQ', 'Otros', 'SOL', 'MEDIA', false, false, 13, array['ruta', 'fecha_operacion']);

insert into public.categorias (id, departamento_id, nombre, tipo_gestion_default, prioridad_sugerida, genera_investigacion, financiero, orden)
select id, dep, nombre, tipo, prio, inv, fin, orden from _cat;

insert into public.categoria_tipos (categoria_id, tipo_id)
select id, tipo from _cat
union
select id, 'URG' from _cat;

insert into public.categoria_campos (categoria_id, campo_clave, obligatorio, orden)
select c.id, replace(x.campo, '*', ''), x.campo like '%*', x.ord::smallint
from _cat c, unnest(c.campos) with ordinality as x(campo, ord);

commit;


-- >>>>>>>>>>>>>>>>>>>> 04_funciones_seguridad.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 05_motor.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 06_rpc.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 07_triggers.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 08_rls.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 09_storage.sql <<<<<<<<<<<<<<<<<<<<
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


-- >>>>>>>>>>>>>>>>>>>> 10_vistas.sql <<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 10_vistas.sql — Vistas de la aplicación y de reportes / Power BI
--
-- Todas usan security_invoker = true: se ejecutan con los permisos de quien consulta,
-- por lo que la RLS se aplica igual que en las tablas. Un reporte o exportación no
-- puede contener filas que el usuario no pueda ver.
--
-- Grano (1 fila = …) documentado en cada vista para evitar duplicar montos:
-- nunca se unen dos tablas de hechos entre sí antes de agregar.
-- =============================================================================
begin;

/* ============ Vista principal de la aplicación (bandeja, portal, búsqueda) ============
   Grano: 1 fila por ticket visible para el usuario. */
create view public.v_tickets with (security_invoker = true) as
select
  t.id, t.numero, t.departamento_id, d.nombre as depto_nombre,
  t.solicitante_id, ps.nombre as solicitante_nombre, t.registrado_por, pr.nombre as registrado_por_nombre, t.canal,
  t.tipo_gestion_id, tg.nombre as tipo_nombre, t.categoria_id, c.nombre as categoria_nombre,
  t.asunto, t.descripcion, t.datos,
  t.prioridad_id, t.prioridad_sugerida, p.orden as prioridad_orden,
  t.estado_id, e.nombre as estado_nombre, e.orden as estado_orden, t.estado_previo,
  t.motivo_espera_id, me.nombre as motivo_espera_nombre,
  t.responsable_id, re.nombre as responsable_nombre,
  case when re.id is null then null when not re.activo then 'Inactivo' when not re.disponible then 'No disponible' end as responsable_alerta,
  t.cliente_id, cl.nombre as cliente_nombre, t.ruta_id, ru.nombre as ruta_nombre, t.factura, t.pedido, t.fecha_requerida,
  t.creado_at, t.primera_respuesta_at, t.asignado_at, t.resuelto_at, t.cerrado_at, t.rechazado_at,
  t.resolucion, t.motivo_rechazo_id, mr.nombre as motivo_rechazo_nombre,
  t.reaperturas, t.cierre_excepcional, t.anulado, t.anulado_motivo,
  round(extract(epoch from (coalesce(t.cerrado_at, t.rechazado_at, now()) - t.creado_at)) / 60)::integer as transcurrido_min,
  app.sla_evaluar(t.id) as sla,
  app.pendiente_info(t.id) is not null as pendiente_info,
  exists (select 1 from public.investigaciones i where i.ticket_id = t.id) as tiene_investigacion
from public.tickets t
join public.departamentos d on d.id = t.departamento_id
join public.tipos_gestion tg on tg.id = t.tipo_gestion_id
join public.categorias c on c.id = t.categoria_id
join public.prioridades p on p.id = t.prioridad_id
join public.estados e on e.id = t.estado_id
left join public.perfiles ps on ps.id = t.solicitante_id
left join public.perfiles pr on pr.id = t.registrado_por
left join public.perfiles re on re.id = t.responsable_id
left join public.motivos me on me.id = t.motivo_espera_id
left join public.motivos mr on mr.id = t.motivo_rechazo_id
left join public.clientes cl on cl.id = t.cliente_id
left join public.rutas ru on ru.id = t.ruta_id;

grant select on public.v_tickets to authenticated;

/* ============================== Esquema reporting ============================== */

-- Grano: 1 fila por ticket (sin textos libres). Hechos de conteo y tiempos.
create view reporting.v_tickets with (security_invoker = true) as
select
  t.id as ticket_id, t.numero, t.departamento_id, t.categoria_id, t.tipo_gestion_id, t.prioridad_id, t.estado_id,
  t.canal, t.solicitante_id, t.responsable_id, t.cliente_id, t.ruta_id,
  (t.datos ->> 'chofer') as chofer_id, (t.datos ->> 'ayudante') as ayudante_id,
  t.creado_at, (t.creado_at at time zone 'America/Costa_Rica')::date as fecha_creacion,
  t.primera_respuesta_at, t.asignado_at, t.resuelto_at, t.cerrado_at, t.rechazado_at,
  t.reaperturas, t.cierre_excepcional, t.anulado,
  e.abierto as esta_abierto,
  s.version as sla_version,
  (app.sla_evaluar(t.id) ->> 'global') as sla_estado_global
from public.tickets t
join public.estados e on e.id = t.estado_id
left join public.ticket_sla s on s.ticket_id = t.id;

-- Grano: 1 fila por ticket × métrica SLA. Medida: % cumplimiento = cumplidos / (cumplidos + incumplidos).
create view reporting.v_sla_metricas with (security_invoker = true) as
select t.id as ticket_id, t.departamento_id, t.prioridad_id, t.categoria_id, t.responsable_id,
       (t.creado_at at time zone 'America/Costa_Rica')::date as fecha_creacion,
       m.key as metrica, m.value ->> 'estado' as estado,
       (m.value ->> 'objetivo')::numeric as objetivo_min, (m.value ->> 'transcurrido')::numeric as transcurrido_min,
       (m.value ->> 'estado') in ('cumplido', 'incumplido') as medida_finalizada
from public.tickets t
cross join lateral jsonb_each(app.sla_evaluar(t.id) -> 'metricas') as m
where not t.anulado;

-- Grano: 1 fila por evento de historial.
create view reporting.v_historial with (security_invoker = true) as
select h.id as evento_id, h.ticket_id, h.ts, (h.ts at time zone 'America/Costa_Rica')::date as fecha,
       h.usuario_id, h.evento, h.detalle, h.visibilidad
from public.historial_tickets h;

-- Grano: 1 fila por diferencia. Saldos calculados desde el libro (cada movimiento cuenta una vez).
create view reporting.v_diferencias with (security_invoker = true) as
select d.id as diferencia_id, d.ticket_id, t.numero, t.categoria_id, t.estado_id as estado_ticket,
       d.num_liquidacion, d.ruta_id, d.fecha_operacion, d.chofer_id, d.ayudante_id, d.tipo_diferencia, d.medio_pago,
       d.monto_esperado, d.monto_recibido, d.monto_reportado, d.monto_diferencia,
       case when d.monto_diferencia > 0 then 'FALTANTE' when d.monto_diferencia < 0 then 'SOBRANTE' else 'SIN_DIFERENCIA' end as naturaleza,
       s.aclarado, s.recuperado, s.ajuste, s.pendiente,
       i.estado as investigacion_estado, i.resultado_id as investigacion_resultado,
       d.creado_at
from public.liquidacion_diferencias d
join public.tickets t on t.id = d.ticket_id
cross join lateral app.saldos_diferencia(d.id) as s
left join public.investigaciones i on i.ticket_id = d.ticket_id
where not t.anulado;

-- Grano: 1 fila por movimiento. Para sumar por tipo use tipo_efectivo y monto_efectivo
-- (una reversión resta del tipo que revierte).
create view reporting.v_movimientos with (security_invoker = true) as
select m.id as movimiento_id, m.diferencia_id, m.ticket_id, m.tipo, m.monto, m.revierte_id,
       coalesce(o.tipo, m.tipo) as tipo_efectivo,
       case when m.tipo = 'REVERSION' then -o.monto else m.monto end as monto_efectivo,
       m.usuario_id, m.creado_at, (m.creado_at at time zone 'America/Costa_Rica')::date as fecha
from public.movimientos_financieros m
left join public.movimientos_financieros o on o.id = m.revierte_id;

-- Grano: 1 fila por investigación.
create view reporting.v_investigaciones with (security_invoker = true) as
select i.id as investigacion_id, i.ticket_id, t.numero, t.categoria_id, i.estado, i.responsable_id, i.fecha_inicio,
       i.resultado_id, i.fecha_resolucion, i.concluida_por, i.reaperturas,
       case when i.fecha_resolucion is not null then round(extract(epoch from (i.fecha_resolucion - i.fecha_inicio)) / 86400, 2) end as dias_investigacion
from public.investigaciones i
join public.tickets t on t.id = i.ticket_id
where not t.anulado;

-- Grano: 1 fila por usuario de Transportes. Carga actual.
create view reporting.v_carga_responsable with (security_invoker = true) as
select p.id as responsable_id, p.nombre, p.rol_id, p.activo, p.disponible,
       count(t.id) filter (where e.abierto) as tickets_abiertos,
       count(t.id) filter (where t.resuelto_at is not null) as tickets_resueltos
from public.perfiles p
left join public.tickets t on t.responsable_id = p.id and not t.anulado
left join public.estados e on e.id = t.estado_id
where p.rol_id in ('OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES')
group by p.id, p.nombre, p.rol_id, p.activo, p.disponible;

grant select on all tables in schema reporting to authenticated;

/* ============================== Rol de Power BI ==============================
   Power BI se conecta con un usuario de base de datos (no pasa por Supabase Auth),
   por lo que se le da acceso de solo lectura al nivel de Gerencia, explícito y limitado.
   Activar el inicio de sesión manualmente (fuera del control de versiones):
     alter role powerbi_lector with login password '<contraseña fuerte>';
   No tiene acceso a comentarios, evidencias, hallazgos ni notificaciones. */
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'powerbi_lector') then
    create role powerbi_lector nologin;
  end if;
end $$;
grant usage on schema reporting, public, app to powerbi_lector;
grant select on all tables in schema reporting to powerbi_lector;
grant execute on function app.sla_evaluar(uuid), app.minutos_habiles(timestamptz, timestamptz),
                          app.minutos_netos(uuid, timestamptz, timestamptz), app.saldos_diferencia(uuid) to powerbi_lector;
grant select (id, nombre, rol_id, departamento_id, activo, disponible) on public.perfiles to powerbi_lector;
do $$
declare t text;
begin
  foreach t in array array['tickets', 'ticket_sla', 'sla_pausas', 'sla_excepciones', 'historial_tickets', 'liquidacion_diferencias',
                           'movimientos_financieros', 'investigaciones', 'estados', 'departamentos', 'categorias', 'tipos_gestion',
                           'prioridades', 'clientes', 'rutas', 'colaboradores', 'resultados_investigacion', 'calendario_laboral',
                           'feriados', 'perfiles'] loop
    if t <> 'perfiles' then execute format('grant select on public.%I to powerbi_lector', t); end if;
    execute format('create policy powerbi_lectura on public.%I for select to powerbi_lector using (true)', t);
  end loop;
end $$;

commit;


-- >>>>>>>>>>>>>>>>>>>> 11_cron.sql <<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 11_cron.sql — Procesos programados (pg_cron)
-- Requisito: habilitar la extensión pg_cron en Supabase (Database → Extensions).
-- Cada 5 minutos: auto-cierre de resueltos (D-08), alertas de SLA y expiración
-- de evidencias preparadas que nunca se cargaron.
-- Este script es idempotente.
-- =============================================================================
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'apd-procesos';
select cron.schedule('apd-procesos', '*/5 * * * *', $$select app.procesos_programados();$$);


