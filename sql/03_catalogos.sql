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
