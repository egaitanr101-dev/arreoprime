/* Máquina de estados del ticket: fuente única de transiciones permitidas.
 * Producción: tabla transiciones_estado + RPC fn_ticket_cambiar_estado().
 * Cualquier transición que no esté aquí es rechazada por el backend.
 */
(function () {
  'use strict';
  const P = APD.permisos;

  const ESTADOS = {
    NUEVO: { label: 'Nuevo', cls: 'st-nuevo' },
    EN_REVISION: { label: 'En revisión', cls: 'st-revision' },
    ASIGNADO: { label: 'Asignado', cls: 'st-asignado' },
    EN_PROCESO: { label: 'En proceso', cls: 'st-proceso' },
    EN_ESPERA: { label: 'En espera', cls: 'st-espera' },
    RESUELTO: { label: 'Resuelto', cls: 'st-resuelto' },
    CERRADO: { label: 'Cerrado', cls: 'st-cerrado' },
    RECHAZADO: { label: 'Rechazado', cls: 'st-rechazado' }
  };
  const ORDEN = Object.keys(ESTADOS);
  const ABIERTOS = ['NUEVO', 'EN_REVISION', 'ASIGNADO', 'EN_PROCESO', 'EN_ESPERA'];
  const TERMINALES = ['CERRADO', 'RECHAZADO'];

  const esResponsable = (u, t) => t.responsable_id === u.id;
  const gestionaTodos = u => P.puede(u, 'ticket.gestionar_todos');
  /** Puede gestionar este ticket: supervisor, o operador responsable */
  const gestiona = (u, t) => gestionaTodos(u) || (P.puede(u, 'ticket.gestionar_asignados') && esResponsable(u, t));
  const triaje = (u, t) => P.puede(u, 'ticket.triaje') && P.enAlcance(u, t);
  const mismoDepto = (u, t) => u.departamento === t.departamento;

  const ACCIONES = {
    tomar_revision: {
      label: 'Tomar en revisión', icono: 'eye', desde: ['NUEVO'], hacia: () => 'EN_REVISION',
      puede: (u, t) => gestionaTodos(u) || triaje(u, t)
    },
    asignar: {
      label: 'Asignar responsable', icono: 'user-plus', primaria: true, desde: ['NUEVO', 'EN_REVISION'], hacia: () => 'ASIGNADO',
      requiere: ['responsable'], puede: u => P.puede(u, 'ticket.asignar')
    },
    autoasignar: {
      label: 'Asignármelo', icono: 'user-check', primaria: true, desde: ['NUEVO', 'EN_REVISION'], hacia: () => 'ASIGNADO',
      puede: (u, t) => !P.puede(u, 'ticket.asignar') && P.puede(u, 'ticket.autoasignar') && P.enAlcance(u, t)
    },
    reasignar: {
      label: 'Reasignar', icono: 'users', desde: ['ASIGNADO', 'EN_PROCESO'], hacia: () => 'ASIGNADO',
      requiere: ['responsable', 'motivo_texto'], puede: u => P.puede(u, 'ticket.asignar')
    },
    iniciar: {
      label: 'Iniciar atención', icono: 'play', primaria: true, desde: ['ASIGNADO'], hacia: () => 'EN_PROCESO', puede: gestiona
    },
    espera: {
      label: 'Poner en espera', icono: 'pause', desde: ['EN_REVISION', 'ASIGNADO', 'EN_PROCESO'], hacia: () => 'EN_ESPERA',
      requiere: ['motivo_espera', 'detalle'],
      puede: (u, t) => gestiona(u, t) || (t.estado === 'EN_REVISION' && triaje(u, t))
    },
    reanudar: {
      label: 'Reanudar', icono: 'play', primaria: true, desde: ['EN_ESPERA'], hacia: t => t.estado_previo || 'EN_PROCESO',
      puede: (u, t) => gestiona(u, t) || (t.estado_previo === 'EN_REVISION' && triaje(u, t))
    },
    resolver: {
      label: 'Marcar resuelto', icono: 'check-circle', primaria: true, desde: ['EN_PROCESO'], hacia: () => 'RESUELTO',
      requiere: ['resolucion'], puede: gestiona
    },
    rechazar: {
      label: 'Rechazar', icono: 'x-circle', peligro: true, desde: ['NUEVO', 'EN_REVISION'], hacia: () => 'RECHAZADO',
      requiere: ['motivo_rechazo', 'justificacion'], puede: u => P.puede(u, 'ticket.rechazar')
    },
    confirmar: {
      label: 'Confirmar y cerrar', icono: 'check-circle', primaria: true, desde: ['RESUELTO'], hacia: () => 'CERRADO',
      puede: (u, t) => P.puede(u, 'ticket.confirmar') && mismoDepto(u, t)
    },
    solicitar_reapertura: {
      label: 'Solicitar reapertura', icono: 'rotate', desde: ['RESUELTO'], hacia: () => 'EN_PROCESO',
      requiere: ['motivo_texto'], puede: (u, t) => P.puede(u, 'ticket.solicitar_reapertura') && mismoDepto(u, t)
    },
    cerrar: {
      label: 'Cerrar ticket', icono: 'lock', desde: ['RESUELTO'], hacia: () => 'CERRADO', puede: u => P.puede(u, 'ticket.cerrar')
    },
    reabrir: {
      label: 'Reabrir', icono: 'rotate', desde: ['CERRADO', 'RECHAZADO'], hacia: t => (t.responsable_id ? 'EN_PROCESO' : 'EN_REVISION'),
      requiere: ['motivo_texto'], puede: u => P.puede(u, 'ticket.reabrir')
    },
    cambiar_prioridad: {
      label: 'Cambiar prioridad', icono: 'flag', desde: ABIERTOS.concat(['RESUELTO']), hacia: null,
      requiere: ['prioridad', 'motivo_texto'], puede: u => P.puede(u, 'ticket.prioridad')
    },
    cierre_excepcional: {
      label: 'Cierre excepcional', icono: 'lock', peligro: true, desde: ABIERTOS, hacia: () => 'CERRADO',
      requiere: ['justificacion'], puede: u => P.puede(u, 'ticket.cierre_excepcional')
    },
    anular: {
      label: 'Anular ticket', icono: 'ban', peligro: true, desde: ORDEN, hacia: null,
      requiere: ['motivo_texto'], puede: u => P.puede(u, 'ticket.anular')
    }
  };

  function accionesDisponibles(u, t) {
    if (!u || !t || t.anulado) return [];
    return Object.keys(ACCIONES)
      .filter(k => ACCIONES[k].desde.includes(t.estado) && ACCIONES[k].puede(u, t))
      .map(k => Object.assign({ codigo: k }, ACCIONES[k]));
  }

  /** Paso del flujo CREACIÓN → REVISIÓN → ASIGNACIÓN → ATENCIÓN → RESOLUCIÓN → CIERRE */
  const PASOS = ['Creación', 'Revisión', 'Asignación', 'Atención', 'Resolución', 'Cierre'];
  const PASO_DE = { NUEVO: 0, EN_REVISION: 1, ASIGNADO: 2, EN_PROCESO: 3, RESUELTO: 4, CERRADO: 5, RECHAZADO: 1 };
  function pasoActual(t) {
    if (t.estado === 'EN_ESPERA') return PASO_DE[t.estado_previo] != null ? PASO_DE[t.estado_previo] : 3;
    return PASO_DE[t.estado];
  }

  APD.estados = { ESTADOS, ORDEN, ABIERTOS, TERMINALES, ACCIONES, accionesDisponibles, gestiona, PASOS, pasoActual };
})();
