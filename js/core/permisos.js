/* Matriz centralizada de roles y permisos.
 *
 * IMPORTANTE: en el frontend esta matriz SOLO decide qué opciones mostrar.
 * La autorización real la aplica el backend:
 *   - Prototipo (Fase 2): js/api/mock/mockApi.js vuelve a validar cada operación.
 *   - Producción (Fase 3/4): tablas roles / permisos / rol_permisos / perfil_permisos
 *     + función fn_tiene_permiso() usada por RLS y por las funciones RPC.
 */
(function () {
  'use strict';

  const ROLES = {
    SOLICITANTE: { label: 'Solicitante' },
    SUPERVISOR_LIQUIDACIONES: { label: 'Supervisor de Liquidaciones Crédito y Cobro' },
    OPERADOR_TRANSPORTES: { label: 'Coordinador de Rutas' },
    SUPERVISOR_TRANSPORTES: { label: 'Jefe Transportes Distrib. y Transp. Cárnico' },
    GERENCIA: { label: 'Gerencia' },
    ADMINISTRADOR: { label: 'Administrador' },
    SUPERUSUARIO: { label: 'Super usuario' }
  };

  const PERMISOS = {
    'ticket.crear': 'Crear tickets de su propio departamento',
    'ticket.registro_asistido': 'Registrar tickets en nombre de un solicitante (llamada o mensaje)',
    'ticket.ver_departamento': 'Ver todos los tickets de su departamento',
    'ticket.ver_todos': 'Ver todos los tickets',
    'ticket.comentar_publico': 'Agregar comentarios públicos',
    'ticket.responder_info': 'Responder solicitudes de información',
    'ticket.nota_interna': 'Agregar notas internas',
    'ticket.ver_internas': 'Ver notas internas',
    'evidencia.subir': 'Adjuntar evidencias',
    'ticket.triaje': 'Tomar tickets en revisión (dentro de su alcance)',
    'ticket.autoasignar': 'Asignarse tickets (dentro de su alcance)',
    'ticket.asignar': 'Asignar y reasignar responsables',
    'ticket.prioridad': 'Modificar prioridad',
    'ticket.gestionar_asignados': 'Gestionar los tickets asignados',
    'ticket.gestionar_todos': 'Gestionar todos los tickets',
    'ticket.rechazar': 'Rechazar tickets (con justificación)',
    'ticket.confirmar': 'Confirmar resolución',
    'ticket.solicitar_reapertura': 'Solicitar reapertura',
    'ticket.cerrar': 'Cerrar tickets resueltos',
    'ticket.reabrir': 'Reabrir tickets cerrados o rechazados',
    'ticket.cierre_excepcional': 'Cierre excepcional documentado',
    'ticket.anular': 'Anular tickets (documentado, sin borrado)',
    'financiero.ver': 'Ver información financiera de Liquidaciones',
    'financiero.registrar': 'Registrar movimientos financieros',
    'investigacion.ver_resumen': 'Ver estado y conclusión de investigaciones',
    'investigacion.ver': 'Ver investigaciones completas',
    'investigacion.gestionar': 'Gestionar investigaciones',
    'dashboard.operativo': 'Dashboard operativo',
    'dashboard.gerencial': 'Dashboard gerencial',
    'dashboard.liquidaciones': 'Dashboard de Liquidaciones (tendencias, motivos y choferes)',
    'reporte.departamento': 'Exportar tickets de su departamento',
    'reporte.operativo': 'Reportes operativos (sin información financiera)',
    'reporte.completo': 'Reportes completos',
    'sla.ver': 'Consultar SLA',
    'sla.configurar': 'Configurar SLA, calendario y feriados',
    'auditoria.operativa': 'Consultar auditoría operativa',
    'auditoria.administrativa': 'Consultar auditoría administrativa',
    'admin.usuarios': 'Administrar usuarios, roles y permisos',
    'admin.catalogos': 'Administrar catálogos y configuración'
  };

  const MATRIZ = {
    SOLICITANTE: [
      'ticket.crear', 'ticket.ver_departamento', 'ticket.comentar_publico', 'ticket.responder_info',
      'evidencia.subir', 'ticket.confirmar', 'ticket.solicitar_reapertura',
      'financiero.ver', 'investigacion.ver_resumen', 'reporte.departamento'
    ],
    // Solicitante de Liquidaciones + dashboard y reportes del departamento (todo limitado a LIQ en la base de datos)
    SUPERVISOR_LIQUIDACIONES: [
      'ticket.crear', 'ticket.ver_departamento', 'ticket.comentar_publico', 'ticket.responder_info',
      'evidencia.subir', 'ticket.confirmar', 'ticket.solicitar_reapertura',
      'financiero.ver', 'investigacion.ver_resumen', 'reporte.departamento',
      'dashboard.liquidaciones', 'reporte.operativo', 'reporte.completo'
    ],
    OPERADOR_TRANSPORTES: [
      'ticket.registro_asistido', 'ticket.ver_todos', 'ticket.comentar_publico', 'ticket.nota_interna',
      'ticket.ver_internas', 'evidencia.subir', 'ticket.triaje', 'ticket.autoasignar',
      'ticket.gestionar_asignados', 'dashboard.operativo', 'reporte.operativo', 'sla.ver'
    ],
    SUPERVISOR_TRANSPORTES: [
      'ticket.registro_asistido', 'ticket.ver_todos', 'ticket.comentar_publico', 'ticket.nota_interna',
      'ticket.ver_internas', 'evidencia.subir', 'ticket.triaje', 'ticket.asignar', 'ticket.prioridad',
      'ticket.gestionar_todos', 'ticket.rechazar', 'ticket.cerrar', 'ticket.reabrir',
      'ticket.cierre_excepcional', 'ticket.anular', 'financiero.ver', 'financiero.registrar',
      'investigacion.ver', 'investigacion.gestionar', 'dashboard.operativo', 'dashboard.gerencial', 'dashboard.liquidaciones',
      'reporte.operativo', 'reporte.completo', 'sla.ver', 'auditoria.operativa'
    ],
    GERENCIA: [
      'ticket.ver_todos', 'ticket.ver_internas', 'financiero.ver', 'investigacion.ver',
      'dashboard.gerencial', 'dashboard.liquidaciones', 'reporte.operativo', 'reporte.completo', 'sla.ver'
    ],
    ADMINISTRADOR: [
      'admin.usuarios', 'admin.catalogos', 'sla.ver', 'sla.configurar', 'auditoria.administrativa'
    ]
  };

  // Super usuario: todos los permisos (operación, finanzas, investigaciones, dashboards, reportes, auditoría y administración)
  MATRIZ.SUPERUSUARIO = Object.keys(PERMISOS);

  /** Permisos que solo aplican al solicitante de Liquidaciones */
  const SOLO_LIQUIDACIONES = ['financiero.ver', 'investigacion.ver_resumen'];

  /** Permisos que el Administrador puede otorgar individualmente (siempre auditado) */
  const OTORGABLES = ['financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar'];

  function puede(u, codigo) {
    if (!u || !u.activo) return false;
    // Con base de datos real, el servidor entrega la lista efectiva (fn_mi_perfil): manda sobre la matriz local.
    if (Array.isArray(u.permisos_efectivos)) return u.permisos_efectivos.includes(codigo);
    if (u.rol === 'SOLICITANTE' && SOLO_LIQUIDACIONES.includes(codigo) && u.departamento !== 'LIQ') return false;
    return (MATRIZ[u.rol] || []).includes(codigo) || (u.permisos_extra || []).includes(codigo);
  }
  function enAlcance(u, t) { return (u.alcance || []).includes(t.departamento); }
  function ticketVisible(u, t) {
    if (puede(u, 'ticket.ver_todos')) return true;
    if (puede(u, 'ticket.ver_departamento')) return t.departamento === u.departamento;
    return false;
  }
  function esTransportes(u) { return !!u && (u.rol === 'OPERADOR_TRANSPORTES' || u.rol === 'SUPERVISOR_TRANSPORTES' || u.rol === 'SUPERUSUARIO'); }
  /** Usa el portal del solicitante (crea, consulta y confirma tickets de su departamento) */
  function esSolicitante(u) { return !!u && (u.rol === 'SOLICITANTE' || u.rol === 'SUPERVISOR_LIQUIDACIONES'); }
  /** Nombre visible del rol; el solicitante de Liquidaciones tiene su propio cargo */
  function etiquetaRol(rol, departamento) {
    if (rol === 'SOLICITANTE' && departamento === 'LIQ') return 'Liquidador de Rutas Crédito y Cobro';
    return ROLES[rol] ? ROLES[rol].label : (rol || 'Sin rol');
  }

  APD.permisos = { ROLES, PERMISOS, MATRIZ, OTORGABLES, puede, enAlcance, ticketVisible, esTransportes, esSolicitante, etiquetaRol };
})();
