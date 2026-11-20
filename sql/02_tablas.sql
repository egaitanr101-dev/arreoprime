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
