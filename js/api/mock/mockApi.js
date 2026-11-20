/* ============================================================================
 * API SIMULADA (MODO DEMO) — "backend" en memoria del prototipo.
 *
 * Objetivo: que el prototipo se comporte como el sistema real, incluyendo las
 * reglas de seguridad. Cada operación vuelve a validar sesión, rol, departamento,
 * estado y transición, igual que harán las funciones RPC y las políticas RLS de
 * PostgreSQL en la Fase 3. No es una conexión a base de datos: los datos viven en
 * memoria y se pierden al recargar la página.
 *
 * La interfaz pública (APD.api.*) es la misma que tendrá la implementación con
 * Supabase; las pantallas no cambian al pasar a producción.
 * ========================================================================== */
(function () {
  'use strict';
  const P = APD.permisos, E = APD.estados, S = APD.sla, F = APD.fmt;
  const DAY = 86400e3;

  class ApiError extends Error {
    constructor(mensaje, codigo) { super(mensaje); this.name = 'ApiError'; this.code = codigo || 'ERROR'; }
  }
  APD.ApiError = ApiError;

  let db = null;
  let sesionId = null;
  let ultimoProceso = 0;

  /* ======================= Utilidades internas ======================= */
  const clone = o => (o == null ? o : JSON.parse(JSON.stringify(o)));
  const round2 = n => Math.round(n * 100) / 100;
  const nid = p => p + '-' + (++db.seqId);
  const U = id => db.usuarios.find(u => u.id === id);
  const nombre = id => (id === 'SYS' ? 'Sistema (proceso automático)' : (U(id) ? U(id).nombre : '—'));
  const cat = id => db.categorias.find(c => c.id === id);
  const lbl = e => E.ESTADOS[e].label;
  let ctxCache = null;
  const ctx = () => ctxCache || (ctxCache = { cal: db.calendario, feriados: new Set(db.feriados.map(f => f.fecha)) });
  const invalidarCtx = () => { ctxCache = null; };
  const supervisores = () => db.usuarios.filter(u => u.rol === 'SUPERVISOR_TRANSPORTES' && u.activo).map(u => u.id);
  const invDe = t => db.investigaciones.find(i => i.ticket_id === t.id);
  const PRI_ORD = { CRITICA: 1, ALTA: 2, MEDIA: 3, BAJA: 4 };
  const SOLICITANTES = ['COM', 'ALM', 'LIQ'];

  const EVENTOS_NOTIF = {
    nuevo: 'Nuevo ticket', asignado: 'Ticket asignado', reasignado: 'Cambio de responsable', comentario: 'Nuevo comentario',
    info_requerida: 'Información requerida', respuesta_info: 'Respuesta del solicitante', sla_proximo: 'Próximo a vencer',
    sla_vencido: 'SLA vencido', resuelto: 'Ticket resuelto', cerrado: 'Ticket cerrado', reabierto: 'Ticket reabierto',
    rechazado: 'Ticket rechazado', sin_responsable: 'Ticket sin responsable'
  };

  function actor() {
    const u = U(sesionId);
    if (!u) throw new ApiError('Sesión no válida. Inicie sesión nuevamente.', 'NO_AUTENTICADO');
    if (!u.activo) throw new ApiError('Usuario inactivo.', 'NO_AUTORIZADO');
    return u;
  }
  function exigir(u, permiso) {
    if (!P.puede(u, permiso)) throw new ApiError('No autorizado para esta operación.', 'NO_AUTORIZADO');
  }
  /** Mismo mensaje para "no existe" y "sin permiso": no revela tickets de otros departamentos */
  function ticketPara(u, id) {
    const t = db.tickets.find(x => x.id === id);
    if (!t || !P.ticketVisible(u, t)) throw new ApiError('Ticket no encontrado o sin acceso.', 'NO_ENCONTRADO');
    return t;
  }
  function validar(cond, msg) { if (!cond) throw new ApiError(msg, 'VALIDACION'); }
  const texto = (v, min, campo) => {
    const s = String(v == null ? '' : v).trim();
    validar(s.length >= min, campo + ' es obligatorio (mínimo ' + min + ' caracteres).');
    validar(s.length <= 4000, campo + ' es demasiado largo.');
    return s;
  };

  function hist(t, uid, ts, evento, detalle, vis) {
    db.historial.push({ id: nid('H'), ticket_id: t.id, ts, usuario_id: uid, evento, detalle, visibilidad: vis || 'PUBLICO' });
  }
  function notificar(uids, actorId, ts, evento, t, txt) {
    Array.from(new Set(uids)).filter(Boolean).forEach(uid => {
      if (uid === actorId) return;
      const u = U(uid);
      if (!u || !u.activo) return;
      if (u.pref_notif && u.pref_notif[evento] === false) return;
      db.notificaciones.push({ id: nid('N'), usuario_id: uid, ts, evento, ticket_id: t ? t.id : null, texto: txt, leida: false });
    });
  }
  function auditar(uid, ts, ambito, accion, detalle, ticketId) {
    db.auditoria.push({ id: nid('A'), ts, usuario_id: uid, ambito, accion, detalle, ticket_id: ticketId || null });
  }
  function slaVigente() { return db.sla_versiones.find(v => v.vigente_hasta == null); }
  function snapshotSla(prio, version) {
    const v = version ? db.sla_versiones.find(x => x.version === version) : slaVigente();
    const x = v.valores[prio];
    return { version: v.version, primera_respuesta: x.primera_respuesta, asignacion: x.asignacion, resolucion: x.resolucion, maximo_horas: x.maximo_horas, umbral: v.umbral };
  }
  function marcarPrimera(t, ts) { if (!t.primera_respuesta_at) t.primera_respuesta_at = ts; }
  function transicion(t, hacia, uid, ts, detalle) {
    const de = t.estado;
    if (de === hacia) return;
    t.estado = hacia;
    hist(t, uid, ts, 'ESTADO', lbl(de) + ' → ' + lbl(hacia) + (detalle ? ' · ' + detalle : ''));
    if (de === 'NUEVO' && uid !== 'SYS') marcarPrimera(t, ts);
  }
  function cancelarInvestigacion(t, u, ts, motivo) {
    const inv = invDe(t);
    if (!inv || inv.estado === 'CONCLUIDA' || inv.estado === 'CANCELADA') return;
    inv.estado = 'CANCELADA';
    hist(t, u.id, ts, 'INVESTIGACION', 'Investigación cancelada: ' + motivo, 'INTERNO');
  }
  function cerrarPausa(t, ts) { (t.pausas || []).forEach(p => { if (p.fin == null) p.fin = ts; }); }
  function carga(uid) { return db.tickets.filter(t => t.responsable_id === uid && !t.anulado && E.ABIERTOS.includes(t.estado)).length; }
  /* Personal asignable de Transportes (el super usuario ve y gestiona todo, pero no recibe asignaciones) */
  const equipoT = x => !!x && (x.rol === 'OPERADOR_TRANSPORTES' || x.rol === 'SUPERVISOR_TRANSPORTES');
  function motivoNoElegible(r, t) {
    if (!r) return 'Usuario inexistente';
    if (!r.activo) return 'Usuario inactivo';
    if (!equipoT(r)) return 'No pertenece a Transportes';
    if (!r.disponible) return 'No disponible';
    if (r.rol === 'OPERADOR_TRANSPORTES' && !r.alcance.includes(t.departamento)) return 'Fuera de su alcance';
    return null;
  }
  function pendienteInfo(t) {
    if (t.anulado || E.TERMINALES.includes(t.estado)) return null;
    const cs = db.comentarios.filter(c => c.ticket_id === t.id && (c.tipo === 'SOLICITUD_INFO' || c.tipo === 'RESPUESTA_INFO'));
    const ult = cs[cs.length - 1];
    return ult && ult.tipo === 'SOLICITUD_INFO' ? ult : null;
  }
  function valorMostrado(clave, v) {
    const def = db.campos[clave];
    if (v == null || v === '') return null;
    if (def.tipo === 'catalogo') { const x = db[def.catalogo].find(i => i.id === v); return x ? x.id + ' · ' + x.nombre : v; }
    if (def.tipo === 'fecha') return F.fechaDeISO(v);
    if (def.tipo === 'crc') return F.crc(v);
    if (def.tipo === 'numero') return F.num(Number(v));
    return String(v);
  }

  /* ======================= Motor de reglas ======================= */

  function crear(u, p, ts) {
    let solicitante = u, canal = 'PORTAL';
    if (p.asistido) {
      exigir(u, 'ticket.registro_asistido');
      solicitante = U(p.solicitante_id);
      validar(solicitante && P.esSolicitante(solicitante) && solicitante.activo, 'Seleccione un solicitante activo de Comercial, Almacén o Liquidaciones.');
      canal = 'ASISTIDO';
    } else exigir(u, 'ticket.crear');

    // El departamento SIEMPRE proviene del perfil del solicitante, nunca del formulario.
    const departamento = solicitante.departamento;
    const c = cat(p.categoria_id);
    validar(c && c.activo && c.departamento === departamento, 'La categoría no corresponde al departamento del solicitante.');
    const tipo = p.tipo_id || c.tipo_default;
    validar(c.tipos_validos.includes(tipo), 'El tipo de gestión no es válido para esta categoría.');
    const asunto = String(p.asunto || '').trim();
    validar(asunto.length >= 5 && asunto.length <= 140, 'El asunto debe tener entre 5 y 140 caracteres.');
    const descripcion = texto(p.descripcion, 10, 'La descripción');

    const entrada = p.datos || {}, datos = {}, montos = {};
    c.campos.forEach(campo => {
      const def = db.campos[campo.clave];
      let v = entrada[campo.clave];
      v = v == null ? '' : String(v).trim();
      if (!v) { validar(!campo.obligatorio, 'El campo "' + def.etiqueta + '" es obligatorio.'); return; }
      if (def.tipo === 'crc' || def.tipo === 'numero') {
        const n = Number(v);
        validar(isFinite(n) && n >= 0, '"' + def.etiqueta + '" debe ser un número igual o mayor que cero.');
        v = def.tipo === 'crc' ? round2(n) : n;
      }
      if (def.tipo === 'catalogo') validar(db[def.catalogo].some(x => x.id === v), 'Valor no válido en "' + def.etiqueta + '".');
      if (def.tipo === 'opciones') validar(def.opciones.includes(v), 'Valor no válido en "' + def.etiqueta + '".');
      if (def.tipo === 'fecha') validar(/^\d{4}-\d{2}-\d{2}$/.test(v), 'Fecha no válida en "' + def.etiqueta + '".');
      if (def.financiero) montos[campo.clave] = v; else datos[campo.clave] = v;
    });
    validar(!(datos.bodega_origen && datos.bodega_origen === datos.bodega_destino), 'La bodega de origen y la de destino deben ser diferentes.');
    const hayMontos = montos.monto_esperado != null || montos.monto_recibido != null || montos.monto_reportado != null;
    if (hayMontos) validar(montos.monto_esperado != null && montos.monto_recibido != null, 'Para registrar la diferencia indique el monto esperado y el recibido.');

    const anio = Number(F.fechaISO(ts).slice(0, 4));
    db.seq[anio] = (db.seq[anio] || 0) + 1;
    const t = {
      id: nid('T'), numero: 'TS-' + anio + '-' + String(db.seq[anio]).padStart(6, '0'),
      departamento, solicitante_id: solicitante.id, registrado_por: u.id, canal,
      tipo_id: tipo, categoria_id: c.id, asunto, descripcion, datos,
      prioridad_sugerida: c.prioridad_sugerida, prioridad: c.prioridad_sugerida,
      estado: 'NUEVO', estado_previo: null, motivo_espera: null, responsable_id: null,
      creado_at: ts, primera_respuesta_at: null, asignado_at: null, resuelto_at: null, cerrado_at: null, rechazado_at: null,
      reaperturas: 0, cierre_excepcional: false, anulado: false, anulado_motivo: null, motivo_rechazo: null, resolucion: null,
      pausas: [], sla_notif: {},
      cliente_id: datos.cliente || null, ruta_id: datos.ruta || null, factura: datos.factura || null, pedido: datos.pedido || null,
      fecha_requerida: datos.fecha_solicitada || datos.fecha_requerida || datos.fecha_entrega || null
    };
    t.sla = snapshotSla(t.prioridad);
    db.tickets.push(t);
    hist(t, u.id, ts, 'CREADO', canal === 'ASISTIDO'
      ? 'Registrado por ' + u.nombre + ' en nombre de ' + solicitante.nombre + ' (registro asistido)'
      : 'Ticket creado desde el portal');

    if (c.financiero && hayMontos) {
      db.diferencias.push({
        id: nid('DF'), ticket_id: t.id, num_liquidacion: datos.num_liquidacion || null, ruta_id: datos.ruta || null,
        fecha_operacion: datos.fecha_operacion || null, chofer_id: datos.chofer || null, ayudante_id: datos.ayudante || null,
        factura: datos.factura || null, tipo_diferencia: datos.tipo_diferencia || null, medio_pago: datos.medio_pago || null,
        monto_esperado: montos.monto_esperado, monto_recibido: montos.monto_recibido,
        monto_reportado: montos.monto_reportado != null ? montos.monto_reportado : null,
        monto_diferencia: round2(montos.monto_esperado - montos.monto_recibido), // D-09: esperado − recibido
        creado_at: ts, creado_por: u.id
      });
    }
    if (c.genera_investigacion) {
      db.investigaciones.push({
        id: nid('IN'), ticket_id: t.id, estado: 'ABIERTA', responsable_id: null, fecha_inicio: ts,
        resultado: null, conclusion: null, fecha_resolucion: null, concluida_por: null, reaperturas: 0, conclusiones_previas: [],
        involucrados: [datos.chofer ? { colaborador_id: datos.chofer, rol: 'Chofer' } : null, datos.ayudante ? { colaborador_id: datos.ayudante, rol: 'Ayudante' } : null].filter(Boolean)
      });
    }
    if ((p.evidencias || []).length) adjuntar(u, t.id, p.evidencias, 'PUBLICO', ts, null);
    notificar(supervisores(), u.id, ts, 'nuevo', t, 'Nuevo ticket de ' + db.departamentos.find(d => d.id === departamento).nombre + ': ' + asunto);
    if (db.config.asignacion_automatica) asignacionAutomatica(t, ts);
    return t;
  }

  /** D-21: solo asigna a usuarios activos, disponibles y con alcance; si nadie califica, avisa al supervisor */
  function asignacionAutomatica(t, ts) {
    const candidatos = db.usuarios.filter(r => r.rol === 'OPERADOR_TRANSPORTES' && !motivoNoElegible(r, t))
      .sort((a, b) => carga(a.id) - carga(b.id));
    if (!candidatos.length) {
      notificar(supervisores(), 'SYS', ts, 'sin_responsable', t, 'Asignación automática sin candidatos elegibles: requiere asignación manual');
      return;
    }
    const r = candidatos[0];
    db.asignaciones.push({ id: nid('AS'), ticket_id: t.id, responsable_id: r.id, asignado_por: 'SYS', tipo: 'AUTOMATICA', desde: ts, hasta: null, motivo: 'Menor carga entre coordinadores elegibles' });
    t.responsable_id = r.id; t.asignado_at = ts;
    transicion(t, 'ASIGNADO', 'SYS', ts, 'Asignación automática a ' + r.nombre);
    notificar([r.id], 'SYS', ts, 'asignado', t, 'Se le asignó automáticamente: ' + t.asunto);
  }

  function accion(u, id, codigo, p, ts) {
    const t = ticketPara(u, id);
    p = p || {};
    const a = E.accionesDisponibles(u, t).find(x => x.codigo === codigo);
    if (!a) throw new ApiError('Acción no permitida para su rol o para el estado actual del ticket.', 'TRANSICION_INVALIDA');
    const destino = a.hacia ? a.hacia(t) : null;

    switch (codigo) {
      case 'tomar_revision':
        transicion(t, 'EN_REVISION', u.id, ts);
        notificar([t.solicitante_id], u.id, ts, 'comentario', t, 'Su solicitud está en revisión');
        break;

      case 'asignar': case 'autoasignar': case 'reasignar': {
        const rid = codigo === 'autoasignar' ? u.id : p.responsable_id;
        const r = U(rid);
        const motivo = motivoNoElegible(r, t);
        validar(!motivo, 'No se puede asignar: ' + (motivo || '') + '.');
        let detalleMotivo = '';
        if (codigo === 'reasignar') {
          validar(rid !== t.responsable_id, 'Seleccione un responsable diferente al actual.');
          detalleMotivo = texto(p.motivo, 5, 'El motivo de reasignación');
        }
        db.asignaciones.filter(x => x.ticket_id === t.id && x.hasta == null).forEach(x => { x.hasta = ts; });
        db.asignaciones.push({ id: nid('AS'), ticket_id: t.id, responsable_id: rid, asignado_por: u.id, tipo: codigo === 'autoasignar' ? 'AUTOASIGNACION' : (p.sugerido ? 'SUGERIDA' : 'MANUAL'), desde: ts, hasta: null, motivo: detalleMotivo || null });
        const previo = t.responsable_id;
        t.responsable_id = rid;
        if (!t.asignado_at) t.asignado_at = ts;
        hist(t, u.id, ts, 'ASIGNACION', previo ? 'Reasignado de ' + nombre(previo) + ' a ' + r.nombre + (detalleMotivo ? '. Motivo: ' + detalleMotivo : '') : 'Asignado a ' + r.nombre);
        // La investigación sin responsable pasa al responsable del ticket (si puede gestionarla)
        const invT = invDe(t);
        if (invT && !invT.responsable_id && invT.estado !== 'CONCLUIDA' && P.puede(r, 'investigacion.gestionar')) {
          invT.responsable_id = rid;
          if (invT.estado === 'ABIERTA') invT.estado = 'EN_CURSO';
          hist(t, u.id, ts, 'INVESTIGACION', 'Responsable de la investigación: ' + r.nombre, 'INTERNO');
        }
        transicion(t, 'ASIGNADO', u.id, ts);
        notificar([rid], u.id, ts, 'asignado', t, 'Se le asignó: ' + t.asunto);
        if (previo) notificar([previo], u.id, ts, 'reasignado', t, 'El ticket fue reasignado a ' + r.nombre);
        break;
      }

      case 'iniciar':
        transicion(t, 'EN_PROCESO', u.id, ts);
        break;

      case 'espera': {
        const m = db.motivos.find(x => x.id === p.motivo_id && x.tipo === 'ESPERA');
        validar(m, 'Seleccione el motivo de espera.');
        const detalle = texto(p.detalle, 5, 'El detalle');
        t.estado_previo = t.estado;
        t.motivo_espera = m.id;
        transicion(t, 'EN_ESPERA', u.id, ts, 'Motivo: ' + m.nombre);
        if (m.pausa_sla) t.pausas.push({ inicio: ts, fin: null, motivo: m.id });
        if (m.id === 'INFO_SOLICITANTE') {
          comentar(u, t.id, { texto: detalle, visibilidad: 'PUBLICO', tipo: 'SOLICITUD_INFO', silencioso: true }, ts);
          notificar([t.solicitante_id], u.id, ts, 'info_requerida', t, 'Transportes requiere información para continuar');
        } else {
          comentar(u, t.id, { texto: 'En espera — ' + m.nombre + ': ' + detalle, visibilidad: 'PUBLICO', silencioso: true }, ts);
        }
        break;
      }

      case 'reanudar':
        cerrarPausa(t, ts);
        transicion(t, destino, u.id, ts, 'Reanudado');
        t.estado_previo = null; t.motivo_espera = null;
        break;

      case 'resolver': {
        // 1. Validaciones (todo o nada, como la transacción del servidor)
        const inv = invDe(t);
        const invAbierta = inv && inv.estado !== 'CONCLUIDA' && inv.estado !== 'CANCELADA';
        if (invAbierta) {
          validar(puedeGestionarInv(u, inv), 'La investigación debe concluirse primero: solicite a Supervisión que la asigne o la concluya.');
          validar(db.resultados.includes(p.resultado_inv), 'Seleccione el resultado de la investigación.');
        }
        const txtRes = texto(p.resolucion, invAbierta ? 20 : 10, 'La resolución');
        const dF = db.diferencias.find(x => x.ticket_id === t.id && x.monto_diferencia > 0);
        let acl = 0, rec = 0, c = {};
        if (dF && P.puede(u, 'financiero.registrar')) {
          const pend = resumenDif(dF).pendiente;
          if (pend > 0) {
            c = p.cierre_dif || {};
            validar(['ACLARADO', 'RECUPERADO', 'MIXTO'].includes(c.tipo), 'Indique cómo se cierra el faltante: aclarado, recuperado o parte de cada uno.');
            acl = c.tipo === 'ACLARADO' ? pend : c.tipo === 'RECUPERADO' ? 0 : round2(c.monto_aclarado === '' || c.monto_aclarado == null ? -1 : Number(c.monto_aclarado));
            validar(isFinite(acl) && acl >= 0 && acl <= pend, 'El monto aclarado debe estar entre ₡0 y el saldo pendiente.');
            rec = round2(pend - acl);
            if (rec > 0) validar(String(c.forma || '').trim().length >= 3, 'Indique la forma de la recuperación.');
          }
        }
        // 2. Cierre del faltante: el saldo pendiente queda en ₡0 (antes de concluir la investigación)
        if (acl > 0) movimiento(u, dF.id, { tipo: 'ACLARACION', monto: acl, nota: 'Aclarado al resolver el ticket' }, ts);
        if (rec > 0) movimiento(u, dF.id, { tipo: 'RECUPERACION', monto: rec, nota: 'Recuperado al resolver el ticket', forma: c.forma, fecha: c.fecha, comprobante: c.comprobante }, ts);
        // 3. Un solo paso: la resolución concluye la investigación con el resultado elegido
        t.resolucion = txtRes;
        if (invAbierta) {
          tomarInv(u, inv);
          inv.resultado = p.resultado_inv; inv.conclusion = t.resolucion; inv.estado = 'CONCLUIDA'; inv.fecha_resolucion = ts; inv.concluida_por = u.id;
          hist(t, u.id, ts, 'INVESTIGACION', 'Investigación concluida — resultado: ' + p.resultado_inv);
          auditar(u.id, ts, 'OPERATIVA', 'INVESTIGACION_CONCLUIDA', 'Resultado: ' + p.resultado_inv, t.id);
        }
        t.resuelto_at = ts;
        const cRes = comentar(u, t.id, { texto: t.resolucion, visibilidad: 'PUBLICO', tipo: 'RESOLUCION', silencioso: true }, ts);
        // Evidencias de la resolución (opcionales), unidas al comentario de resolución
        if ((p.evidencias || []).length) adjuntar(u, t.id, p.evidencias, 'PUBLICO', ts, cRes.id);
        transicion(t, 'RESUELTO', u.id, ts);
        notificar([t.solicitante_id], u.id, ts, 'resuelto', t, 'Su solicitud fue resuelta. Por favor confirme.');
        break;
      }

      case 'rechazar': {
        const m = db.motivos.find(x => x.id === p.motivo_id && x.tipo === 'RECHAZO');
        validar(m, 'Seleccione el motivo de rechazo.');
        const just = texto(p.justificacion, 10, 'La justificación');
        t.motivo_rechazo = m.id; t.rechazado_at = ts;
        cancelarInvestigacion(t, u, ts, 'ticket rechazado');
        comentar(u, t.id, { texto: 'Solicitud rechazada — ' + m.nombre + '. ' + just, visibilidad: 'PUBLICO', silencioso: true }, ts);
        transicion(t, 'RECHAZADO', u.id, ts, m.nombre);
        notificar([t.solicitante_id], u.id, ts, 'rechazado', t, 'Su solicitud fue rechazada: ' + m.nombre);
        break;
      }

      case 'confirmar':
        t.cerrado_at = ts;
        transicion(t, 'CERRADO', u.id, ts, 'Resolución confirmada por el solicitante');
        notificar([t.responsable_id], u.id, ts, 'cerrado', t, 'El solicitante confirmó la resolución');
        break;

      case 'cerrar':
        t.cerrado_at = ts;
        transicion(t, 'CERRADO', u.id, ts, 'Cerrado por supervisión');
        notificar([t.solicitante_id, t.responsable_id], u.id, ts, 'cerrado', t, 'El ticket fue cerrado');
        break;

      case 'solicitar_reapertura': case 'reabrir': {
        const motivo = texto(p.motivo, 5, 'El motivo de reapertura');
        if (t.resuelto_at) t.pausas.push({ inicio: t.resuelto_at, fin: ts, motivo: 'RESUELTO' }); // el tiempo resuelto no cuenta
        t.resuelto_at = null; t.cerrado_at = null; t.rechazado_at = null; t.resolucion = null; t.cierre_excepcional = false;
        t.reaperturas += 1;
        const invR = invDe(t);
        if (invR && invR.estado === 'CANCELADA') invR.estado = invR.responsable_id ? 'EN_CURSO' : 'ABIERTA';
        comentar(u, t.id, { texto: 'Reapertura: ' + motivo, visibilidad: 'PUBLICO', silencioso: true }, ts);
        transicion(t, destino, u.id, ts, codigo === 'reabrir' ? 'Reabierto por supervisión' : 'Reapertura solicitada por el solicitante');
        notificar([t.responsable_id].concat(supervisores()).concat([t.solicitante_id]), u.id, ts, 'reabierto', t, 'El ticket fue reabierto');
        break;
      }

      case 'cambiar_prioridad': {
        validar(PRI_ORD[p.prioridad], 'Seleccione una prioridad válida.');
        validar(p.prioridad !== t.prioridad, 'La prioridad seleccionada es la actual.');
        const motivo = texto(p.motivo, 5, 'El motivo');
        const ant = t.prioridad;
        t.prioridad = p.prioridad;
        t.sla = snapshotSla(t.prioridad, t.sla.version); // conserva la versión de SLA con la que nació el ticket
        hist(t, u.id, ts, 'PRIORIDAD', 'Prioridad ' + APD.ui.PRIORIDADES[ant][0] + ' → ' + APD.ui.PRIORIDADES[p.prioridad][0] + '. Motivo: ' + motivo);
        break;
      }

      case 'cierre_excepcional': {
        const just = texto(p.justificacion, 10, 'La justificación');
        cerrarPausa(t, ts);
        t.cierre_excepcional = true; t.cerrado_at = ts;
        cancelarInvestigacion(t, u, ts, 'cierre excepcional');
        comentar(u, t.id, { texto: 'Cierre excepcional: ' + just, visibilidad: 'PUBLICO', silencioso: true }, ts);
        transicion(t, 'CERRADO', u.id, ts, 'Cierre excepcional');
        auditar(u.id, ts, 'OPERATIVA', 'CIERRE_EXCEPCIONAL', just, t.id);
        notificar([t.solicitante_id, t.responsable_id], u.id, ts, 'cerrado', t, 'El ticket fue cerrado de forma excepcional');
        break;
      }

      case 'anular': {
        const motivo = texto(p.motivo, 5, 'El motivo de anulación');
        cerrarPausa(t, ts);
        t.anulado = true; t.anulado_motivo = motivo;
        hist(t, u.id, ts, 'ANULADO', 'Ticket anulado (se conserva para trazabilidad). Motivo: ' + motivo);
        auditar(u.id, ts, 'OPERATIVA', 'ANULACION', motivo, t.id);
        break;
      }
      default:
        throw new ApiError('Acción desconocida.', 'TRANSICION_INVALIDA');
    }
    return t;
  }

  function comentar(u, id, p, ts) {
    const t = ticketPara(u, id);
    const vis = p.visibilidad === 'INTERNO' ? 'INTERNO' : 'PUBLICO';
    exigir(u, vis === 'INTERNO' ? 'ticket.nota_interna' : 'ticket.comentar_publico');
    validar(!t.anulado, 'El ticket está anulado.');
    validar(!(vis === 'PUBLICO' && E.TERMINALES.includes(t.estado) && !P.esTransportes(u)), 'El ticket está finalizado y no admite comentarios nuevos.');
    const txt = texto(p.texto, 2, 'El comentario');
    const tipo = p.tipo || 'COMENTARIO';
    const c = { id: nid('C'), ticket_id: t.id, autor_id: u.id, ts, visibilidad: vis, tipo, texto: txt };
    db.comentarios.push(c);
    const ev = vis === 'INTERNO' ? 'NOTA_INTERNA' : tipo;
    const det = { COMENTARIO: 'Comentario público', NOTA_INTERNA: 'Nota interna', SOLICITUD_INFO: 'Solicitud de información al solicitante', RESPUESTA_INFO: 'Respuesta del solicitante', RESOLUCION: 'Resolución documentada' }[ev];
    hist(t, u.id, ts, ev, det, vis);
    if (vis === 'PUBLICO' && P.esTransportes(u)) marcarPrimera(t, ts);
    if (!p.silencioso && vis === 'PUBLICO') {
      if (P.esTransportes(u)) notificar([t.solicitante_id], u.id, ts, 'comentario', t, 'Transportes agregó un comentario');
      else notificar(t.responsable_id ? [t.responsable_id] : supervisores(), u.id, ts, 'comentario', t, 'El solicitante agregó un comentario');
    }
    if ((p.evidencias || []).length) adjuntar(u, t.id, p.evidencias, vis, ts, c.id);
    return c;
  }

  function responderInfo(u, id, txt, ts, evidencias) {
    const t = ticketPara(u, id);
    exigir(u, 'ticket.responder_info');
    validar(u.departamento === t.departamento, 'Solo el departamento solicitante puede responder.');
    const pend = pendienteInfo(t);
    validar(pend, 'No hay solicitudes de información pendientes.');
    const c = comentar(u, id, { texto: txt, visibilidad: 'PUBLICO', tipo: 'RESPUESTA_INFO', silencioso: true, evidencias }, ts);
    c.responde_a = pend.id;
    if (t.estado === 'EN_ESPERA' && t.motivo_espera === 'INFO_SOLICITANTE') { // D-07: reanudación automática
      cerrarPausa(t, ts);
      transicion(t, t.estado_previo || 'EN_PROCESO', u.id, ts, 'Reanudado automáticamente por respuesta del solicitante');
      t.estado_previo = null; t.motivo_espera = null;
    }
    const inv = invDe(t);
    if (inv && inv.estado === 'EN_ACLARACION') inv.estado = 'EN_CURSO';
    notificar(t.responsable_id ? [t.responsable_id] : supervisores(), u.id, ts, 'respuesta_info', t, 'El solicitante respondió la solicitud de información');
    return c;
  }

  const TIPOS_PERMITIDOS = /^(image\/|application\/pdf|application\/vnd\.openxmlformats|application\/msword|application\/vnd\.ms-excel|text\/csv|$)/;
  function adjuntar(u, id, archivos, vis, ts, comentarioId) {
    const t = ticketPara(u, id);
    exigir(u, 'evidencia.subir');
    validar(!t.anulado, 'El ticket está anulado.');
    if (vis === 'INTERNO') exigir(u, 'ticket.nota_interna');
    validar(Array.isArray(archivos) && archivos.length, 'Seleccione al menos un archivo.');
    return archivos.map(a => {
      validar(a && a.nombre, 'Archivo no válido.');
      validar(a.tamano <= 10 * 1048576, '"' + a.nombre + '" supera el máximo de 10 MB.');
      validar(TIPOS_PERMITIDOS.test(a.tipo || ''), 'Tipo de archivo no permitido: ' + a.nombre + '. Use imágenes, PDF u Office.');
      const ev = { id: nid('E'), ticket_id: t.id, comentario_id: comentarioId || null, nombre: a.nombre, tamano: a.tamano || 0, tipo: a.tipo || '', visibilidad: vis || 'PUBLICO', subido_por: u.id, ts };
      ev.ruta = 'evidencias/' + t.id + '/' + ev.id; // producción: bucket privado + URL firmada
      db.evidencias.push(ev);
      hist(t, u.id, ts, 'EVIDENCIA', 'Evidencia adjunta: ' + a.nombre, ev.visibilidad);
      return ev;
    });
  }

  /* ---------------- Investigaciones y finanzas ---------------- */
  function invPara(u, invId) {
    const inv = db.investigaciones.find(i => i.id === invId);
    if (!inv) throw new ApiError('Investigación no encontrada.', 'NO_ENCONTRADO');
    const t = ticketPara(u, inv.ticket_id);
    exigir(u, 'investigacion.ver');
    return { inv, t };
  }
  /* Gestiona la investigación: supervisión, su responsable o, si aún no tiene responsable, el responsable del ticket. */
  const puedeGestionarInv = (u, inv) => {
    if (!P.puede(u, 'investigacion.gestionar')) return false;
    if (P.puede(u, 'ticket.gestionar_todos') || inv.responsable_id === u.id) return true;
    const t = db.tickets.find(x => x.id === inv.ticket_id);
    return !inv.responsable_id && !!t && t.responsable_id === u.id;
  };
  /* Quien gestiona una investigación sin responsable queda como responsable. */
  const tomarInv = (u, inv) => { if (!inv.responsable_id) inv.responsable_id = u.id; };

  function invAsignar(u, invId, rid, ts) {
    const { inv, t } = invPara(u, invId);
    exigir(u, 'ticket.asignar'); exigir(u, 'investigacion.gestionar');
    validar(inv.estado !== 'CONCLUIDA', 'La investigación está concluida.');
    const r = U(rid);
    validar(r && r.activo && P.puede(r, 'investigacion.gestionar'), 'El responsable debe estar activo y tener permiso para gestionar investigaciones.');
    inv.responsable_id = rid;
    if (inv.estado === 'ABIERTA') inv.estado = 'EN_CURSO';
    hist(t, u.id, ts, 'INVESTIGACION', 'Responsable de la investigación: ' + r.nombre, 'INTERNO');
    notificar([rid], u.id, ts, 'asignado', t, 'Se le asignó la investigación del ticket');
    return inv;
  }
  function invHallazgo(u, invId, txt, ts) {
    const { inv, t } = invPara(u, invId);
    validar(puedeGestionarInv(u, inv), 'Solo el responsable de la investigación o supervisión puede registrar hallazgos.');
    validar(inv.estado !== 'CONCLUIDA', 'La investigación está concluida.');
    const h = { id: nid('HZ'), investigacion_id: inv.id, texto: texto(txt, 5, 'El hallazgo'), autor_id: u.id, ts };
    db.hallazgos.push(h);
    tomarInv(u, inv);
    if (inv.estado === 'ABIERTA') inv.estado = 'EN_CURSO';
    hist(t, u.id, ts, 'INVESTIGACION', 'Hallazgo registrado', 'INTERNO');
    return h;
  }
  function invAclaracion(u, invId, txt, ts) {
    const { inv, t } = invPara(u, invId);
    validar(puedeGestionarInv(u, inv), 'No autorizado para gestionar esta investigación.');
    validar(inv.estado !== 'CONCLUIDA', 'La investigación está concluida.');
    tomarInv(u, inv);
    inv.estado = 'EN_ACLARACION';
    comentar(u, t.id, { texto: txt, visibilidad: 'PUBLICO', tipo: 'SOLICITUD_INFO', silencioso: true }, ts);
    notificar([t.solicitante_id], u.id, ts, 'info_requerida', t, 'Transportes solicita una aclaración para la investigación');
    return inv;
  }
  function invConcluir(u, invId, p, ts) {
    const { inv, t } = invPara(u, invId);
    validar(puedeGestionarInv(u, inv), 'Solo el responsable de la investigación o supervisión puede concluirla.');
    validar(inv.estado !== 'CONCLUIDA', 'La investigación ya está concluida.');
    validar(db.resultados.includes(p.resultado), 'Seleccione el resultado de la investigación.');
    inv.conclusion = texto(p.conclusion, 20, 'La conclusión');
    tomarInv(u, inv);
    inv.resultado = p.resultado; inv.estado = 'CONCLUIDA'; inv.fecha_resolucion = ts; inv.concluida_por = u.id;
    hist(t, u.id, ts, 'INVESTIGACION', 'Investigación concluida — resultado: ' + p.resultado);
    auditar(u.id, ts, 'OPERATIVA', 'INVESTIGACION_CONCLUIDA', 'Resultado: ' + p.resultado, t.id);
    return inv;
  }
  function invReabrir(u, invId, motivo, ts) {
    const { inv, t } = invPara(u, invId);
    exigir(u, 'ticket.reabrir'); exigir(u, 'investigacion.gestionar');
    validar(inv.estado === 'CONCLUIDA', 'La investigación no está concluida.');
    validar(!['RESUELTO', 'CERRADO', 'RECHAZADO'].includes(t.estado), 'Reabra primero el ticket para reabrir su investigación.');
    const m = texto(motivo, 5, 'El motivo');
    inv.conclusiones_previas.push({ resultado: inv.resultado, conclusion: inv.conclusion, fecha: inv.fecha_resolucion, por: inv.concluida_por });
    inv.estado = 'EN_CURSO'; inv.resultado = null; inv.conclusion = null; inv.fecha_resolucion = null; inv.concluida_por = null; inv.reaperturas += 1;
    hist(t, u.id, ts, 'INVESTIGACION', 'Investigación reabierta. Motivo: ' + m);
    auditar(u.id, ts, 'OPERATIVA', 'INVESTIGACION_REABIERTA', m, t.id);
    return inv;
  }

  /** Saldos de una diferencia calculados SOLO desde el libro de movimientos (sin duplicar montos) */
  function resumenDif(d) {
    const ms = db.movimientos.filter(m => m.diferencia_id === d.id);
    const ef = { ACLARACION: 0, RECUPERACION: 0, AJUSTE: 0 };
    ms.forEach(m => {
      if (m.tipo === 'REVERSION') { const o = ms.find(x => x.id === m.revierte_id); if (o) ef[o.tipo] -= o.monto; }
      else ef[m.tipo] += m.monto;
    });
    const base = Math.abs(d.monto_diferencia);
    return {
      base, aclarado: round2(ef.ACLARACION), recuperado: round2(ef.RECUPERACION), ajuste: round2(ef.AJUSTE),
      pendiente: round2(base + ef.AJUSTE - ef.ACLARACION - ef.RECUPERACION),
      naturaleza: d.monto_diferencia > 0 ? 'FALTANTE' : d.monto_diferencia < 0 ? 'SOBRANTE' : 'SIN_DIFERENCIA'
    };
  }
  function movimiento(u, difId, p, ts) {
    const d = db.diferencias.find(x => x.id === difId);
    if (!d) throw new ApiError('Diferencia no encontrada.', 'NO_ENCONTRADO');
    const t = ticketPara(u, d.ticket_id);
    exigir(u, 'financiero.registrar');
    validar(!t.anulado, 'El ticket está anulado.');
    const tipos = ['ACLARACION', 'RECUPERACION', 'AJUSTE', 'REVERSION'];
    validar(tipos.includes(p.tipo), 'Seleccione el tipo de movimiento.');
    const inv = invDe(t);
    if (inv && inv.estado === 'CONCLUIDA') validar(p.tipo === 'RECUPERACION' || p.tipo === 'REVERSION', 'La investigación está concluida: solo se admiten recuperaciones o reversiones.');
    const nota = texto(p.nota, 5, 'La nota');
    let monto, revierte = null;
    if (p.tipo === 'REVERSION') {
      const o = db.movimientos.find(m => m.id === p.revierte_id && m.diferencia_id === d.id && m.tipo !== 'REVERSION');
      validar(o, 'Seleccione el movimiento a revertir.');
      validar(!db.movimientos.some(m => m.revierte_id === o.id), 'Ese movimiento ya fue revertido.');
      monto = o.monto; revierte = o.id;
    } else {
      monto = round2(Number(p.monto));
      validar(isFinite(monto) && (p.tipo === 'AJUSTE' ? monto !== 0 : monto > 0), p.tipo === 'AJUSTE' ? 'El ajuste no puede ser cero.' : 'El monto debe ser mayor que cero.');
    }
    const mov = { id: nid('MF'), diferencia_id: d.id, ticket_id: t.id, tipo: p.tipo, monto, nota, revierte_id: revierte, usuario_id: u.id, ts };
    db.movimientos.push(mov);
    if (resumenDif(d).pendiente < 0) {
      db.movimientos.pop();
      throw new ApiError('El movimiento dejaría el saldo pendiente en negativo. Revise el monto.', 'VALIDACION');
    }
    hist(t, u.id, ts, 'FINANCIERO', 'Movimiento ' + mov.tipo.toLowerCase() + ' por ' + F.crc(monto), 'FINANCIERO');
    auditar(u.id, ts, 'OPERATIVA', 'MOVIMIENTO_FINANCIERO', mov.tipo + ' ' + F.crc(monto), t.id);
    return mov;
  }

  function autoCerrar(id, ts) {
    const t = db.tickets.find(x => x.id === id);
    if (!t || t.estado !== 'RESUELTO' || t.anulado) return;
    t.cerrado_at = ts;
    transicion(t, 'CERRADO', 'SYS', ts, 'Cierre automático: sin confirmación en ' + db.config.auto_cierre_dias + ' días hábiles');
    notificar([t.solicitante_id, t.responsable_id], 'SYS', ts, 'cerrado', t, 'Cierre automático por falta de confirmación');
  }

  /** Equivale a los trabajos de pg_cron: auto-cierre y alertas de SLA */
  function procesosProgramados(ahora) {
    const c = ctx();
    db.tickets.forEach(t => {
      if (t.anulado) return;
      if (t.estado === 'RESUELTO' && t.resuelto_at && S.diasHabiles(t.resuelto_at, ahora, c) >= db.config.auto_cierre_dias) autoCerrar(t.id, ahora);
      if (!E.ABIERTOS.includes(t.estado)) return;
      const ev = S.evaluar(t, c, ahora);
      Object.values(ev.metricas).forEach(m => {
        if (m.estado !== 'amarillo' && m.estado !== 'rojo') return;
        const k = m.clave + ':' + m.estado;
        if (t.sla_notif[k]) return;
        t.sla_notif[k] = ahora;
        notificar(t.responsable_id ? [t.responsable_id] : supervisores(), 'SYS', ahora, m.estado === 'rojo' ? 'sla_vencido' : 'sla_proximo', t,
          (m.estado === 'rojo' ? 'SLA vencido' : 'Próximo a vencer') + ': ' + S.METRICAS[m.clave]);
      });
    });
  }
  function procesos() {
    const ahora = Date.now();
    if (ahora - ultimoProceso < 30000) return;
    ultimoProceso = ahora;
    procesosProgramados(ahora);
  }

  function renumerar() {
    db.seq = {};
    db.tickets.sort((a, b) => a.creado_at - b.creado_at).forEach(t => {
      const anio = Number(F.fechaISO(t.creado_at).slice(0, 4));
      db.seq[anio] = (db.seq[anio] || 0) + 1;
      t.numero = 'TS-' + anio + '-' + String(db.seq[anio]).padStart(6, '0');
    });
  }

  /* ======================= Proyecciones de lectura ======================= */
  function fila(t, ahora, c) {
    const cl = db.clientes.find(x => x.id === t.cliente_id);
    const ru = db.rutas.find(x => x.id === t.ruta_id);
    const ca = cat(t.categoria_id);
    const sla = S.evaluar(t, c, ahora);
    const fin = t.cerrado_at || t.rechazado_at || ahora;
    const rankSla = { rojo: 0, amarillo: 1, verde: 2, incumplido: 3, cumplido: 4, na: 5, sin: 6 }[sla.global];
    const resp = U(t.responsable_id);
    return {
      id: t.id, numero: t.numero, creado_at: t.creado_at, departamento: t.departamento,
      depto_nombre: db.departamentos.find(d => d.id === t.departamento).nombre,
      solicitante_id: t.solicitante_id, solicitante_nombre: nombre(t.solicitante_id),
      registrado_por_nombre: nombre(t.registrado_por), canal: t.canal,
      tipo_id: t.tipo_id, tipo_nombre: db.tipos.find(x => x.id === t.tipo_id).nombre,
      categoria_id: t.categoria_id, categoria_nombre: ca.nombre, asunto: t.asunto, descripcion: t.descripcion,
      prioridad: t.prioridad, prioridad_sugerida: t.prioridad_sugerida, prioridad_orden: PRI_ORD[t.prioridad],
      estado: t.estado, estado_previo: t.estado_previo,
      motivo_espera_nombre: t.motivo_espera ? db.motivos.find(m => m.id === t.motivo_espera).nombre : null,
      responsable_id: t.responsable_id, responsable_nombre: resp ? resp.nombre : null,
      responsable_alerta: resp ? (!resp.activo ? 'Inactivo' : !resp.disponible ? 'No disponible' : null) : null,
      cliente_id: t.cliente_id, cliente_nombre: cl ? cl.nombre : null, ruta_id: t.ruta_id, ruta_nombre: ru ? ru.nombre : null,
      factura: t.factura, pedido: t.pedido, fecha_requerida: t.fecha_requerida,
      transcurrido_min: Math.round((fin - t.creado_at) / 60000),
      sla, sla_orden: rankSla * 1e7 + (sla.foco && sla.foco.restante != null ? sla.foco.restante : 0),
      primera_respuesta_at: t.primera_respuesta_at, asignado_at: t.asignado_at, resuelto_at: t.resuelto_at,
      cerrado_at: t.cerrado_at, rechazado_at: t.rechazado_at, reaperturas: t.reaperturas,
      cierre_excepcional: t.cierre_excepcional, anulado: t.anulado, anulado_motivo: t.anulado_motivo,
      motivo_rechazo_nombre: t.motivo_rechazo ? db.motivos.find(m => m.id === t.motivo_rechazo).nombre : null,
      resolucion: t.resolucion, pendiente_info: !!pendienteInfo(t),
      tiene_investigacion: !!invDe(t), sla_version: t.sla.version,
      chofer_id: t.datos.chofer || null, ayudante_id: t.datos.ayudante || null
    };
  }

  function listar(u) {
    procesos();
    const ahora = Date.now(), c = ctx();
    return db.tickets.filter(t => P.ticketVisible(u, t)).map(t => fila(t, ahora, c)).sort((a, b) => b.creado_at - a.creado_at);
  }

  function obtener(u, id) {
    procesos();
    const t = ticketPara(u, id);
    const ahora = Date.now(), c = ctx();
    const verInt = P.puede(u, 'ticket.ver_internas'), verFin = P.puede(u, 'financiero.ver');
    const visible = v => v === 'PUBLICO' || (v === 'INTERNO' && verInt) || (v === 'FINANCIERO' && verFin);
    const ca = cat(t.categoria_id);
    const evid = db.evidencias.filter(e => e.ticket_id === t.id && visible(e.visibilidad)).map(e => Object.assign({}, e, { subido_por_nombre: nombre(e.subido_por) }));
    const r = {
      ticket: fila(t, ahora, c),
      campos: ca.campos.filter(x => !db.campos[x.clave].financiero && t.datos[x.clave] != null)
        .map(x => ({ clave: x.clave, etiqueta: db.campos[x.clave].etiqueta, valor: valorMostrado(x.clave, t.datos[x.clave]) })),
      comentarios: db.comentarios.filter(x => x.ticket_id === t.id && visible(x.visibilidad)).map(x => {
        const a = U(x.autor_id);
        return Object.assign({}, x, { autor_nombre: nombre(x.autor_id), autor_rol: a ? P.etiquetaRol(a.rol, a.departamento) : '', es_transportes: P.esTransportes(a), evidencias: evid.filter(e => e.comentario_id === x.id) });
      }),
      evidencias: evid,
      historial: db.historial.filter(h => h.ticket_id === t.id && visible(h.visibilidad)).map(h => Object.assign({}, h, { usuario_nombre: nombre(h.usuario_id) })),
      acciones: E.accionesDisponibles(u, t).map(a => ({
        codigo: a.codigo, label: a.label, icono: a.icono, primaria: !!a.primaria, peligro: !!a.peligro, requiere: a.requiere || [],
        bloqueo: a.codigo === 'resolver' && invDe(t) && !['CONCLUIDA', 'CANCELADA'].includes(invDe(t).estado) && !puedeGestionarInv(u, invDe(t))
          ? 'La investigación debe concluirse primero: solicite a Supervisión que la asigne o la concluya' : null
      })),
      asignaciones: (P.esTransportes(u) || u.rol === 'GERENCIA') ? db.asignaciones.filter(a => a.ticket_id === t.id).map(a => Object.assign({}, a, { responsable_nombre: nombre(a.responsable_id), asignado_por_nombre: nombre(a.asignado_por) })) : null,
      financiero: null, investigacion: null,
      pendiente_info: pendienteInfo(t),
      puede: {
        comentar_publico: P.puede(u, 'ticket.comentar_publico') && !t.anulado && (P.esTransportes(u) || !E.TERMINALES.includes(t.estado)),
        nota_interna: P.puede(u, 'ticket.nota_interna') && !t.anulado,
        adjuntar: P.puede(u, 'evidencia.subir') && !t.anulado && (P.esTransportes(u) || !E.TERMINALES.includes(t.estado)),
        responder_info: P.puede(u, 'ticket.responder_info') && u.departamento === t.departamento && !!pendienteInfo(t),
        registrar_movimiento: P.puede(u, 'financiero.registrar') && !t.anulado
      }
    };
    const difs = db.diferencias.filter(d => d.ticket_id === t.id);
    if (difs.length) {
      r.financiero = verFin ? {
        diferencias: difs.map(d => {
          const movs = db.movimientos.filter(m => m.diferencia_id === d.id);
          return Object.assign({}, d, {
            chofer_nombre: d.chofer_id ? valorMostrado('chofer', d.chofer_id) : null,
            ayudante_nombre: d.ayudante_id ? valorMostrado('ayudante', d.ayudante_id) : null,
            ruta_nombre: d.ruta_id ? valorMostrado('ruta', d.ruta_id) : null,
            conciliado: d.monto_reportado == null || Math.abs(Math.abs(d.monto_diferencia) - d.monto_reportado) < 0.01,
            resumen: resumenDif(d),
            movimientos: movs.map(m => Object.assign({}, m, { usuario_nombre: nombre(m.usuario_id), revertido: movs.some(x => x.revierte_id === m.id) }))
          });
        })
      } : { restringido: true };
    }
    const inv = invDe(t);
    if (inv) {
      if (P.puede(u, 'investigacion.ver')) {
        const puedeAsignar = P.puede(u, 'ticket.asignar') && P.puede(u, 'investigacion.gestionar');
        r.investigacion = Object.assign({}, inv, {
          nivel: 'completo', responsable_nombre: inv.responsable_id ? nombre(inv.responsable_id) : null,
          concluida_por_nombre: inv.concluida_por ? nombre(inv.concluida_por) : null,
          involucrados: inv.involucrados.map(x => ({ rol: x.rol, nombre: valorMostrado(x.rol === 'Chofer' ? 'chofer' : 'ayudante', x.colaborador_id) })),
          hallazgos: db.hallazgos.filter(h => h.investigacion_id === inv.id).map(h => Object.assign({}, h, { autor_nombre: nombre(h.autor_id) })),
          puede_gestionar: puedeGestionarInv(u, inv), puede_asignar: puedeAsignar,
          puede_reabrir: P.puede(u, 'ticket.reabrir') && P.puede(u, 'investigacion.gestionar'),
          candidatos: puedeAsignar ? db.usuarios.filter(x => x.activo && P.puede(x, 'investigacion.gestionar')).map(x => ({ id: x.id, nombre: x.nombre })) : [],
          resultados: db.resultados
        });
      } else if (P.puede(u, 'investigacion.ver_resumen')) {
        r.investigacion = { nivel: 'resumen', estado: inv.estado, resultado: inv.resultado, conclusion: inv.conclusion, fecha_inicio: inv.fecha_inicio, fecha_resolucion: inv.fecha_resolucion };
      } else r.investigacion = { nivel: 'restringido' };
    }
    return r;
  }

  function responsablesPara(u, id) {
    exigir(u, 'ticket.asignar');
    const t = ticketPara(u, id);
    const c = cat(t.categoria_id);
    const lista = db.usuarios.filter(equipoT).map(x => ({
      id: x.id, nombre: x.nombre, rol: P.ROLES[x.rol].label, carga: carga(x.id), disponible: x.disponible, activo: x.activo,
      no_elegible: motivoNoElegible(x, t), actual: x.id === t.responsable_id
    }));
    const elegibles = lista.filter(x => !x.no_elegible && !x.actual);
    let sug = elegibles.find(x => x.id === c.responsable_sugerido_id);
    let razon = 'Responsable sugerido para la categoría';
    if (!sug) {
      sug = elegibles.filter(x => x.rol === P.ROLES.OPERADOR_TRANSPORTES.label).sort((a, b) => a.carga - b.carga)[0];
      razon = 'Menor carga entre coordinadores elegibles' + (c.responsable_sugerido_id ? ' (el sugerido de la categoría no está elegible)' : '');
    }
    if (sug) { sug.sugerido = true; sug.razon = razon; }
    return lista.sort((a, b) => (a.no_elegible ? 1 : 0) - (b.no_elegible ? 1 : 0) || a.carga - b.carga);
  }

  function buscar(u, q) {
    const n = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    const qq = n(q).trim();
    if (qq.length < 2) return [];
    return listar(u).filter(r => [r.numero, r.factura, r.pedido, r.ruta_id, r.ruta_nombre, r.cliente_nombre, r.asunto].some(v => n(v).includes(qq))).slice(0, 20);
  }

  /* ---------------- Dashboard (cálculo compartido en js/api/calculos.js) ---------------- */
  function dashboard(u, f) {
    if (!P.puede(u, 'dashboard.gerencial') && !P.puede(u, 'dashboard.operativo')) throw new ApiError('No autorizado para esta operación.', 'NO_AUTORIZADO');
    return APD.calculos.dashboard(listar(u), db.usuarios.filter(equipoT), u, f,
      { clientes: db.clientes, rutas: db.rutas, choferes: db.choferes });
  }

  /* ---------------- Liquidaciones (cálculo compartido) ---------------- */
  function filasDiferencias(u) {
    const visibles = new Map(listar(u).filter(r => !r.anulado).map(r => [r.id, r]));
    const nom = (col, id) => { if (!id) return null; const x = db[col].find(i => i.id === id); return x ? x.id + ' · ' + x.nombre : id; };
    const verInv = P.puede(u, 'investigacion.ver') || P.puede(u, 'investigacion.ver_resumen');
    const filas = db.diferencias.filter(d => visibles.has(d.ticket_id)).map(d => {
      const t = visibles.get(d.ticket_id), r = resumenDif(d), inv = db.investigaciones.find(i => i.ticket_id === d.ticket_id);
      return {
        id: d.id, ticket_id: d.ticket_id, numero: t.numero, estado_ticket: t.estado, categoria: t.categoria_nombre, creado_at: d.creado_at,
        fecha_operacion: d.fecha_operacion, ruta: nom('rutas', d.ruta_id), ruta_id: d.ruta_id, chofer: nom('choferes', d.chofer_id), ayudante: nom('ayudantes', d.ayudante_id),
        tipo_diferencia: d.tipo_diferencia, medio_pago: d.medio_pago, monto_esperado: d.monto_esperado, monto_recibido: d.monto_recibido,
        monto_reportado: d.monto_reportado, monto_diferencia: d.monto_diferencia, naturaleza: r.naturaleza,
        aclarado: r.aclarado, recuperado: r.recuperado, ajuste: r.ajuste, pendiente: r.pendiente,
        inv_estado: verInv && inv ? inv.estado : null, inv_resultado: verInv && inv ? inv.resultado : null,
        inv_abierta: !!(inv && !['CONCLUIDA', 'CANCELADA'].includes(inv.estado))
      };
    });
    const invs = db.investigaciones.filter(i => visibles.has(i.ticket_id));
    return { filas, invs, verInv };
  }
  function liquidaciones(u, f) {
    exigir(u, 'financiero.ver');
    const d = filasDiferencias(u);
    return APD.calculos.liquidaciones(d.filas, d.invs, f, d.verInv);
  }

  /* ---------------- Reportes (cálculo compartido) ---------------- */
  function tiposReporte(u) { return APD.calculos.tiposReporte(u); }
  function puedeReporte(u, k) { return APD.calculos.puedeReporte(u, k); }
  const REPORTES = APD.calculos.REPORTES;
  function generarReporte(u, tipo, f) {
    validar(REPORTES[tipo], 'Reporte no válido.');
    if (!puedeReporte(u, tipo)) throw new ApiError('No autorizado para este reporte.', 'NO_AUTORIZADO');
    return APD.calculos.reporte(u, tipo, listar(u), f, {
      liquidaciones: () => liquidaciones(u, f),
      investigaciones: () => {
        const vis = new Map(listar(u).map(r => [r.id, r]));
        return db.investigaciones.filter(i => vis.has(i.ticket_id)).map(i => ({
          ticket_id: i.ticket_id, numero: vis.get(i.ticket_id).numero, categoria: vis.get(i.ticket_id).categoria_nombre, estado: i.estado,
          responsable: i.responsable_id ? nombre(i.responsable_id) : null, fecha_inicio: i.fecha_inicio, resultado: i.resultado, fecha_resolucion: i.fecha_resolucion
        }));
      }
    });
  }

  /* ---------------- Notificaciones ---------------- */
  function misNotificaciones(u) {
    return db.notificaciones.filter(n => n.usuario_id === u.id).filter(n => {
      if (!n.ticket_id) return true;
      const t = db.tickets.find(x => x.id === n.ticket_id);
      return t && P.ticketVisible(u, t);
    }).map(n => Object.assign({}, n, { numero: n.ticket_id ? db.tickets.find(x => x.id === n.ticket_id).numero : null, evento_label: EVENTOS_NOTIF[n.evento] || n.evento }))
      .sort((a, b) => b.ts - a.ts);
  }

  /* ---------------- Administración ---------------- */
  const DEPTO_POR_ROL = { OPERADOR_TRANSPORTES: ['TRA'], SUPERVISOR_TRANSPORTES: ['TRA'], GERENCIA: ['GER'], ADMINISTRADOR: ['SIS'], SUPERUSUARIO: ['TRA'], SOLICITANTE: SOLICITANTES, SUPERVISOR_LIQUIDACIONES: ['LIQ'] };
  function validarPerfil(c) {
    validar(P.ROLES[c.rol], 'Rol no válido.');
    validar(DEPTO_POR_ROL[c.rol].includes(c.departamento), 'El departamento no corresponde al rol seleccionado.');
    validar((c.alcance || []).every(a => SOLICITANTES.includes(a)), 'Alcance no válido.');
    validar((c.permisos_extra || []).every(p => P.OTORGABLES.includes(p)), 'Permiso no otorgable.');
  }
  function perfilAdmin(x) {
    return {
      id: x.id, nombre: x.nombre, correo: x.correo, rol: x.rol, rol_label: P.etiquetaRol(x.rol, x.departamento), departamento: x.departamento,
      depto_nombre: db.departamentos.find(d => d.id === x.departamento).nombre, activo: x.activo, disponible: x.disponible,
      alcance: x.alcance.slice(), permisos_extra: x.permisos_extra.slice(), carga: carga(x.id)
    };
  }
  function guardarUsuario(u, id, c, ts) {
    exigir(u, 'admin.usuarios');
    validar(id !== u.id, 'No puede modificar su propio perfil, rol ni permisos.');
    const x = U(id);
    if (!x) throw new ApiError('Usuario no encontrado.', 'NO_ENCONTRADO');
    const nuevo = Object.assign({}, x, c);
    validarPerfil(nuevo);
    if (x.activo && c.activo === false) validar(carga(x.id) === 0, 'El usuario tiene ' + carga(x.id) + ' ticket(s) abiertos asignados. Reasígnelos antes de desactivarlo.');
    const cambios = [];
    ['rol', 'departamento', 'activo', 'disponible'].forEach(k => { if (c[k] !== undefined && c[k] !== x[k]) cambios.push(k + ': ' + x[k] + ' → ' + c[k]); });
    if (c.alcance && c.alcance.join() !== x.alcance.join()) cambios.push('alcance: [' + x.alcance.join(', ') + '] → [' + c.alcance.join(', ') + ']');
    if (c.permisos_extra && c.permisos_extra.join() !== x.permisos_extra.join()) cambios.push('permisos: [' + x.permisos_extra.join(', ') + '] → [' + c.permisos_extra.join(', ') + ']');
    ['rol', 'departamento', 'activo', 'disponible', 'alcance', 'permisos_extra'].forEach(k => { if (c[k] !== undefined) x[k] = c[k]; });
    if (x.rol !== 'OPERADOR_TRANSPORTES') x.alcance = [];
    auditar(u.id, ts, 'ADMINISTRATIVA', 'USUARIO_MODIFICADO', x.nombre + ' — ' + (cambios.join('; ') || 'sin cambios'));
    return perfilAdmin(x);
  }
  function crearUsuario(u, c, ts) {
    exigir(u, 'admin.usuarios');
    const nom = texto(c.nombre, 5, 'El nombre');
    validar(/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c.correo || ''), 'Correo no válido.');
    validar(!db.usuarios.some(x => x.correo.toLowerCase() === c.correo.toLowerCase()), 'Ya existe un usuario con ese correo.');
    const x = { id: 'u' + (++db.seqId), nombre: nom, correo: c.correo.trim(), rol: c.rol, departamento: c.departamento, activo: true, disponible: true, alcance: c.rol === 'OPERADOR_TRANSPORTES' ? (c.alcance || []) : [], permisos_extra: c.permisos_extra || [], pref_notif: {}, nota_demo: 'Creado durante la demostración' };
    validarPerfil(x);
    db.usuarios.push(x);
    auditar(u.id, ts, 'ADMINISTRATIVA', 'USUARIO_INVITADO', nom + ' (' + P.ROLES[x.rol].label + ', ' + x.departamento + ')');
    return perfilAdmin(x);
  }

  /* ======================= Inicialización ======================= */
  const M = {
    get db() { return db; },
    siguienteHabil: ms => S.siguienteHabil(ms, ctx()),
    crear, accion, comentar, responderInfo, adjuntar,
    invAsignar, invHallazgo, invAclaracion, invConcluir, invReabrir,
    movimiento, pendiente: difId => resumenDif(db.diferencias.find(d => d.id === difId)).pendiente,
    autoCerrar, renumerar, procesosProgramados
  };
  function inicializar() {
    const ahora = Date.now();
    db = APD.mockData.catalogos(ahora);
    Object.assign(db, { tickets: [], comentarios: [], evidencias: [], historial: [], asignaciones: [], diferencias: [], movimientos: [], investigaciones: [], hallazgos: [], notificaciones: [], auditoria: [], seq: {}, seqId: 1000 });
    invalidarCtx();
    APD.mockData.poblar(M, ahora);
    ultimoProceso = ahora;
  }
  // La inicialización (generar el escenario DEMO) la dispara js/api/api.js solo en modo DEMO.

  /* ======================= API pública ======================= */
  const conSesion = fn => (...args) => new Promise((resolve, reject) => {
    try { resolve(clone(fn(actor(), ...args))); } catch (e) { reject(e); }
  });
  const perfil = u => ({
    id: u.id, nombre: u.nombre, correo: u.correo, rol: u.rol, departamento: u.departamento,
    depto_nombre: db.departamentos.find(d => d.id === u.departamento).nombre,
    activo: u.activo, disponible: u.disponible, alcance: u.alcance.slice(), permisos_extra: u.permisos_extra.slice()
  });

  APD.apiMock = {
    modo: 'DEMO',
    iniciar: () => { if (!db) inicializar(); },
    sesion: {
      usuariosDemo: async () => clone(db.usuarios.map(u => Object.assign(perfil(u), { nota_demo: u.nota_demo }))),
      iniciar: async id => {
        const u = U(id);
        if (!u) throw new ApiError('Usuario no encontrado.', 'NO_ENCONTRADO');
        if (!u.activo) throw new ApiError('Usuario inactivo: no puede iniciar sesión.', 'NO_AUTORIZADO');
        sesionId = id;
        auditar(id, Date.now(), 'ADMINISTRATIVA', 'INICIO_SESION', u.nombre);
        return clone(perfil(u));
      },
      cerrar: async () => { sesionId = null; },
      actual: async () => (sesionId && U(sesionId) && U(sesionId).activo ? clone(perfil(U(sesionId))) : null)
    },
    catalogos: conSesion(u => {
      const esT = P.esTransportes(u), adm = P.puede(u, 'admin.catalogos');
      return {
        departamentos: db.departamentos, tipos: db.tipos, prioridades: db.prioridades, campos: db.campos,
        categorias: db.categorias.filter(c => adm || (c.activo && (esT || u.rol === 'GERENCIA' || c.departamento === u.departamento))),
        motivos: db.motivos, respuestas: esT ? db.respuestas : [], resultados: db.resultados,
        clientes: db.clientes, rutas: db.rutas, choferes: db.choferes, ayudantes: db.ayudantes, vehiculos: db.vehiculos, bodegas: db.bodegas, unidades: db.unidades,
        solicitantes: P.puede(u, 'ticket.registro_asistido') ? db.usuarios.filter(x => P.esSolicitante(x) && x.activo).map(x => ({ id: x.id, nombre: x.nombre, departamento: x.departamento })) : [],
        responsables: (esT || u.rol === 'GERENCIA') ? db.usuarios.filter(equipoT).map(x => ({ id: x.id, nombre: x.nombre, rol: x.rol, activo: x.activo, disponible: x.disponible, alcance: x.alcance.slice() })) : []
      };
    }),
    tickets: {
      listar: conSesion(u => listar(u)),
      obtener: conSesion((u, id) => obtener(u, id)),
      crear: conSesion((u, p) => fila(crear(u, p, Date.now()), Date.now(), ctx())),
      accion: conSesion((u, id, codigo, p) => { accion(u, id, codigo, p, Date.now()); return true; }),
      comentar: conSesion((u, id, p) => { comentar(u, id, Object.assign({}, p, { tipo: 'COMENTARIO', silencioso: false }), Date.now()); return true; }),
      responderInfo: conSesion((u, id, txt, ev) => { responderInfo(u, id, txt, Date.now(), ev); return true; }),
      adjuntar: conSesion((u, id, archivos, vis) => adjuntar(u, id, archivos, vis, Date.now(), null)),
      responsables: conSesion((u, id) => responsablesPara(u, id)),
      buscar: conSesion((u, q) => buscar(u, q))
    },
    investigaciones: {
      asignar: conSesion((u, id, rid) => invAsignar(u, id, rid, Date.now())),
      hallazgo: conSesion((u, id, txt) => invHallazgo(u, id, txt, Date.now())),
      aclaracion: conSesion((u, id, txt) => invAclaracion(u, id, txt, Date.now())),
      concluir: conSesion((u, id, p) => invConcluir(u, id, p, Date.now())),
      reabrir: conSesion((u, id, m) => invReabrir(u, id, m, Date.now()))
    },
    finanzas: {
      movimiento: conSesion((u, difId, p) => movimiento(u, difId, p, Date.now())),
      resumen: conSesion((u, f) => liquidaciones(u, f)),
      dashboard: conSesion((u, f) => {
        exigir(u, 'dashboard.liquidaciones'); exigir(u, 'financiero.ver');
        return APD.calculos.dashboardLiq(listar(u).filter(t => t.departamento === 'LIQ'), filasDiferencias(u).filas, f);
      })
    },
    dashboard: conSesion((u, f) => dashboard(u, f)),
    reportes: {
      tipos: conSesion(u => tiposReporte(u)),
      generar: conSesion((u, tipo, f) => generarReporte(u, tipo, f)),
      registrarExportacion: conSesion((u, tipo, formato, n) => { validar(puedeReporte(u, tipo), 'No autorizado.'); auditar(u.id, Date.now(), 'ADMINISTRATIVA', 'EXPORTACION', REPORTES[tipo].titulo + ' · ' + formato + ' · ' + n + ' filas'); return true; })
    },
    notificaciones: {
      listar: conSesion(u => misNotificaciones(u)),
      noLeidas: conSesion(u => misNotificaciones(u).filter(n => !n.leida).length),
      marcarLeidas: conSesion((u, ids) => { db.notificaciones.forEach(n => { if (n.usuario_id === u.id && (!ids || ids.includes(n.id))) n.leida = true; }); return true; }),
      preferencias: conSesion(u => ({ eventos: EVENTOS_NOTIF, pref: u.pref_notif })),
      guardarPreferencias: conSesion((u, pref) => {
        const limpio = {};
        Object.keys(EVENTOS_NOTIF).forEach(k => { if (pref[k] === false) limpio[k] = false; });
        u.pref_notif = limpio;
        return true;
      })
    },
    sla: {
      estado: conSesion(u => {
        exigir(u, 'sla.ver');
        const r = { versiones: db.sla_versiones, vigente: slaVigente(), calendario: db.calendario, feriados: db.feriados.slice().sort((a, b) => a.fecha.localeCompare(b.fecha)), puede_configurar: P.puede(u, 'sla.configurar'), riesgo: null };
        if (P.puede(u, 'ticket.ver_todos')) {
          const filas = listar(u).filter(x => !x.anulado && E.ABIERTOS.includes(x.estado));
          r.riesgo = { conteo: { verde: 0, amarillo: 0, rojo: 0, pausado: 0 }, filas: filas.filter(x => x.sla.global === 'rojo' || x.sla.global === 'amarillo').sort((a, b) => a.sla_orden - b.sla_orden) };
          filas.forEach(x => { if (x.sla.pausado) r.riesgo.conteo.pausado++; if (r.riesgo.conteo[x.sla.global] != null) r.riesgo.conteo[x.sla.global]++; });
        }
        return r;
      }),
      nuevaVersion: conSesion((u, valores, umbral, nota) => {
        exigir(u, 'sla.configurar');
        const ahora = Date.now();
        const limpio = {};
        ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'].forEach(p => {
          limpio[p] = {};
          ['primera_respuesta', 'asignacion', 'resolucion', 'maximo_horas'].forEach(k => {
            const n = Number(valores[p] && valores[p][k]);
            validar(Number.isInteger(n) && n > 0, 'Todos los tiempos deben ser enteros mayores que cero.');
            limpio[p][k] = n;
          });
          validar(limpio[p].primera_respuesta <= limpio[p].resolucion, 'La primera respuesta no puede superar el tiempo de resolución (' + p + ').');
        });
        const um = Number(umbral);
        validar(um >= 0.5 && um < 1, 'El umbral de alerta debe estar entre 50 % y 99 %.');
        const actual = slaVigente();
        actual.vigente_hasta = ahora;
        const v = { version: actual.version + 1, vigente_desde: ahora, vigente_hasta: null, creado_por: u.id, umbral: um, nota: String(nota || '').trim() || 'Sin nota', valores: limpio };
        db.sla_versiones.push(v);
        auditar(u.id, ahora, 'ADMINISTRATIVA', 'SLA_NUEVA_VERSION', 'Versión ' + v.version + ' vigente desde ahora. Los tickets existentes conservan su versión.');
        return v;
      }),
      agregarFeriado: conSesion((u, fecha, nom) => {
        exigir(u, 'sla.configurar');
        validar(/^\d{4}-\d{2}-\d{2}$/.test(fecha || ''), 'Fecha no válida.');
        validar(!db.feriados.some(f => f.fecha === fecha), 'Ese feriado ya existe.');
        db.feriados.push({ fecha, nombre: texto(nom, 3, 'El nombre') });
        invalidarCtx();
        auditar(u.id, Date.now(), 'ADMINISTRATIVA', 'FERIADO_AGREGADO', fecha + ' ' + nom);
        return true;
      }),
      quitarFeriado: conSesion((u, fecha) => {
        exigir(u, 'sla.configurar');
        const i = db.feriados.findIndex(f => f.fecha === fecha);
        validar(i >= 0, 'Feriado no encontrado.');
        db.feriados.splice(i, 1);
        invalidarCtx();
        auditar(u.id, Date.now(), 'ADMINISTRATIVA', 'FERIADO_ELIMINADO', fecha);
        return true;
      })
    },
    admin: {
      usuarios: conSesion(u => { exigir(u, 'admin.usuarios'); return db.usuarios.map(perfilAdmin); }),
      guardarUsuario: conSesion((u, id, c) => guardarUsuario(u, id, c, Date.now())),
      crearUsuario: conSesion((u, c) => crearUsuario(u, c, Date.now())),
      departamentos: conSesion(u => { exigir(u, 'admin.catalogos'); return db.departamentos.map(d => Object.assign({}, d, { usuarios: db.usuarios.filter(x => x.departamento === d.id).length })); }),
      categoriaActiva: conSesion((u, id, activo) => {
        exigir(u, 'admin.catalogos');
        const c = cat(id);
        validar(c, 'Categoría no encontrada.');
        c.activo = !!activo;
        auditar(u.id, Date.now(), 'ADMINISTRATIVA', 'CATEGORIA_' + (activo ? 'ACTIVADA' : 'DESACTIVADA'), c.nombre + ' (' + c.departamento + ')');
        return true;
      }),
      config: conSesion(u => { exigir(u, 'admin.catalogos'); return db.config; }),
      guardarConfig: conSesion((u, c) => {
        exigir(u, 'admin.catalogos');
        const dias = Number(c.auto_cierre_dias);
        validar(Number.isInteger(dias) && dias >= 1 && dias <= 15, 'Los días de auto-cierre deben estar entre 1 y 15.');
        const antes = JSON.stringify(db.config);
        db.config.asignacion_automatica = !!c.asignacion_automatica;
        db.config.auto_cierre_dias = dias;
        auditar(u.id, Date.now(), 'ADMINISTRATIVA', 'CONFIGURACION', antes + ' → ' + JSON.stringify(db.config));
        return db.config;
      }),
      auditoria: conSesion(u => {
        const adm = P.puede(u, 'auditoria.administrativa'), op = P.puede(u, 'auditoria.operativa');
        if (!adm && !op) throw new ApiError('No autorizado para esta operación.', 'NO_AUTORIZADO');
        return db.auditoria.filter(a => adm || a.ambito === 'OPERATIVA').map(a => Object.assign({}, a, {
          usuario_nombre: nombre(a.usuario_id), numero: a.ticket_id ? (db.tickets.find(t => t.id === a.ticket_id) || {}).numero : null
        })).sort((a, b) => b.ts - a.ts);
      })
    },
    demo: {
      reiniciar: async () => { const s = sesionId; inicializar(); sesionId = U(s) && U(s).activo ? s : null; return true; }
    }
  };
})();
