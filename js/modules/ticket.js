/* Detalle y gestión del ticket: Información · Gestión · Conversación · Historial.
 * Las acciones visibles vienen de la API (que valida rol, estado y transición). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, E = APD.estados, S = APD.sla;
  let tabActual = 'info';
  let ultimoId = null;

  const TABS = [['info', 'Información', 'file'], ['gestion', 'Gestión', 'settings'], ['conversacion', 'Conversación', 'message'], ['historial', 'Historial', 'history']];
  const EVENTO_ICONO = { CREADO: 'plus', ESTADO: 'arrow-right', ASIGNACION: 'user-plus', COMENTARIO: 'message', NOTA_INTERNA: 'eye-off', SOLICITUD_INFO: 'help', RESPUESTA_INFO: 'message', EVIDENCIA: 'paperclip', PRIORIDAD: 'flag', RESOLUCION: 'check-circle', ANULADO: 'ban', INVESTIGACION: 'search2', FINANCIERO: 'coins' };
  const INV_ESTADO = { ABIERTA: 'Abierta', EN_CURSO: 'En curso', EN_ACLARACION: 'En aclaración', CONCLUIDA: 'Concluida', CANCELADA: 'Cancelada' };

  async function render(el, r) {
    const id = r.parts[1];
    if (id !== ultimoId) { tabActual = r.query.tab || 'info'; ultimoId = id; }
    const [d, cats] = await Promise.all([APD.api.tickets.obtener(id), APD.api.catalogos()]);
    const u = APD.state.usuario, t = d.ticket;
    APD.app.titulo(t.numero);
    const nCom = d.comentarios.length;
    const volver = P.esSolicitante(u) ? '#/solicitudes' : '#/bandeja';

    el.innerHTML = '<div class="page wide ticket-page">' +
      '<a class="back" href="' + volver + '">' + ico('arrow-left', 16) + '<span>' + (P.esSolicitante(u) ? 'Solicitudes del departamento' : 'Bandeja') + '</span></a>' +
      '<header class="ticket-head card">' +
      '<div class="ticket-head-main"><div class="ticket-ids"><span class="tnum big">' + esc(t.numero) + '</span>' + ui.badgeEstado(t.estado) + ui.badgePrioridad(t.prioridad) +
      (!P.esSolicitante(u) && !t.anulado ? ui.semaforo(t.sla) : '') + (t.anulado ? ui.chip('Anulado', 'chip-muted') : '') + '</div>' +
      '<h2>' + esc(t.asunto) + '</h2>' +
      '<p class="muted small">' + esc(t.depto_nombre) + ' · ' + esc(t.tipo_nombre) + ' · ' + esc(t.categoria_nombre) + ' · Creado ' + esc(F.fecha(t.creado_at)) + ' por ' + esc(t.solicitante_nombre) +
      (t.canal === 'ASISTIDO' ? ' (registro asistido por ' + esc(t.registrado_por_nombre) + ')' : '') + '</p></div>' +
      barraAcciones(d) + '</header>' +
      (t.anulado ? '<div class="alert alert-muted">' + ico('ban', 16) + '<span>Ticket anulado: ' + esc(t.anulado_motivo || '') + '. Se conserva para trazabilidad y no cuenta en indicadores.</span></div>' : '') +
      (d.puede.responder_info ? bloqueRespuesta(d) : '') +
      '<div class="ticket-grid"><div class="ticket-main">' +
      '<div class="tabs" role="tablist">' + TABS.map(x => '<button type="button" role="tab" id="tab-' + x[0] + '" aria-controls="panel-' + x[0] + '" aria-selected="' + (tabActual === x[0]) + '" class="tab' + (tabActual === x[0] ? ' on' : '') + '" data-tab="' + x[0] + '">' + ico(x[2], 16) + '<span>' + x[1] + '</span>' + (x[0] === 'conversacion' && nCom ? '<em>' + nCom + '</em>' : '') + '</button>').join('') + '</div>' +
      '<div class="tab-panel card" role="tabpanel" id="panel-' + tabActual + '" aria-labelledby="tab-' + tabActual + '">' + panel(d, cats, u) + '</div>' +
      '</div><aside class="ticket-side">' + resumen(d, u) + '</aside></div></div>';

    el.querySelectorAll('[data-tab]').forEach(b => b.addEventListener('click', () => { tabActual = b.dataset.tab; render(el, r); }));
    enlazarAcciones(el, d, cats);
    enlazarPanel(el, d, cats);
  }

  /* ---------------- Cabecera y lateral ---------------- */
  function barraAcciones(d) {
    if (!d.acciones.length) return '';
    const prim = d.acciones.filter(a => a.primaria);
    const sec = d.acciones.filter(a => !a.primaria && !a.peligro);
    const visibles = sec.slice(0, 2), resto = d.acciones.length - prim.length - visibles.length;
    return '<div class="ticket-actions">' +
      prim.map(a => '<button type="button" class="btn btn-primary" data-accion="' + a.codigo + '"' + (a.bloqueo ? ' disabled title="' + esc(a.bloqueo) + '"' : '') + '>' + ico(a.icono, 16) + '<span>' + esc(a.label) + '</span></button>').join('') +
      visibles.map(a => '<button type="button" class="btn btn-secondary" data-accion="' + a.codigo + '">' + ico(a.icono, 16) + '<span>' + esc(a.label) + '</span></button>').join('') +
      (resto > 0 ? '<button type="button" class="btn btn-ghost" data-tab="gestion">' + ico('list', 16) + '<span>Más acciones (' + resto + ')</span></button>' : '') +
      (d.acciones.some(a => a.codigo === 'confirmar') ? '<p class="help full">' + ico('info', 14) + '<span>Su solicitud fue resuelta. Si quedó atendida, presione <b>Confirmar y cerrar</b>: el ticket se cierra de inmediato. Si no, use «Solicitar reapertura».</span></p>' : '') +
      (prim.some(a => a.bloqueo) ? '<p class="help full">' + ico('info', 14) + ' ' + esc(prim.find(a => a.bloqueo).bloqueo) + '</p>' : '') + '</div>';
  }

  function resumen(d, u) {
    const t = d.ticket;
    const fila = (k, v) => '<dt>' + k + '</dt><dd>' + v + '</dd>';
    let h = '<section class="card side-card"><h3>Resumen</h3><dl class="dl dl-side">' +
      fila('Solicitante', esc(t.solicitante_nombre) + '<small class="muted block">' + esc(t.depto_nombre) + '</small>') +
      fila('Responsable', t.responsable_nombre ? esc(t.responsable_nombre) + (t.responsable_alerta ? ' ' + ui.chip(t.responsable_alerta, 'chip-warn') : '') : '<span class="muted">Sin asignar</span>') +
      fila('Estado', ui.badgeEstado(t.estado) + (t.motivo_espera_nombre ? '<small class="muted block">' + esc(t.motivo_espera_nombre) + '</small>' : '')) +
      fila('Prioridad', ui.badgePrioridad(t.prioridad) + (t.prioridad !== t.prioridad_sugerida ? '<small class="muted block">Sugerida: ' + ui.PRIORIDADES[t.prioridad_sugerida][0] + '</small>' : '')) +
      fila('Fecha requerida', esc(t.fecha_requerida ? F.fechaDeISO(t.fecha_requerida) : '—')) +
      fila('Creado', esc(F.fecha(t.creado_at))) +
      (t.resuelto_at ? fila('Resuelto', esc(F.fecha(t.resuelto_at))) : '') +
      (t.cerrado_at ? fila('Cerrado', esc(F.fecha(t.cerrado_at)) + (t.cierre_excepcional ? '<small class="muted block">Cierre excepcional</small>' : '')) : '') +
      (t.reaperturas ? fila('Reaperturas', String(t.reaperturas)) : '') +
      '</dl></section>';
    h += '<section class="card side-card"><h3>Avance</h3>' + ui.stepper(t) + '</section>';
    if (!P.esSolicitante(u) && !t.anulado) h += '<section class="card side-card"><h3>SLA <small class="muted">v' + t.sla_version + '</small></h3>' + metricasSla(t.sla) + '</section>';
    return h;
  }

  function metricasSla(sla) {
    return '<ul class="sla-list">' + Object.keys(S.METRICAS).map(k => {
      const m = sla.metricas[k];
      if (!m) return '';
      const pct = m.pct != null ? Math.min(100, m.pct * 100) : 0;
      let detalle;
      if (m.estado === 'na') detalle = m.excluido ? 'Excluido (cierre excepcional)' : 'No aplica';
      else if (m.estado === 'cumplido' || m.estado === 'incumplido') detalle = F.duracion(m.transcurrido) + ' de ' + F.duracion(m.objetivo);
      else detalle = (m.restante >= 0 ? 'Restan ' + F.duracion(m.restante) : 'Vencido hace ' + F.duracion(-m.restante)) + ' · objetivo ' + F.duracion(m.objetivo);
      return '<li><div class="sla-row"><span>' + S.METRICAS[k] + '</span><span class="sla sla-' + m.estado + '"><i class="sla-dot"></i>' + S.SEMAFORO[m.estado] + '</span></div>' +
        (m.estado !== 'na' ? '<div class="meter meter-' + m.estado + '"><span style="width:' + pct.toFixed(0) + '%"></span></div>' : '') +
        '<small class="muted">' + esc(detalle) + (m.pausado ? ' · pausado' : '') + '</small></li>';
    }).join('') + '</ul><p class="help">Tiempos en horas hábiles; las pausas justificadas no cuentan.</p>';
  }

  function bloqueRespuesta(d) {
    const p = d.pendiente_info;
    return '<section class="card info-request">' +
      '<div class="info-request-head">' + ico('help', 20) + '<div><b>Transportes solicita información</b><small class="muted block">' + esc(F.fecha(p.ts)) + '</small></div></div>' +
      '<blockquote>' + esc(p.texto) + '</blockquote>' +
      '<form data-x="responder"><div class="field"><label for="resp_txt">Su respuesta <span class="req">*</span></label><textarea id="resp_txt" name="texto" rows="3" required></textarea></div>' +
      '<div class="composer-foot"><label class="btn btn-ghost sm file-btn">' + ico('paperclip', 14) + '<span>Adjuntar</span><input type="file" multiple hidden data-x="resp-files"></label><span class="muted small" data-x="resp-files-list"></span>' +
      '<button class="btn btn-primary" type="submit">' + ico('send', 16) + '<span>Enviar respuesta</span></button></div></form></section>';
  }

  /* ---------------- Paneles ---------------- */
  function panel(d, cats, u) {
    switch (tabActual) {
      case 'gestion': return panelGestion(d, u);
      case 'conversacion': return panelConversacion(d, cats, u);
      case 'historial': return panelHistorial(d);
      default: return panelInfo(d);
    }
  }

  function panelInfo(d) {
    const t = d.ticket;
    let h = '<h3>Datos de la solicitud</h3><dl class="dl">' +
      '<dt>Departamento</dt><dd>' + esc(t.depto_nombre) + '</dd>' +
      '<dt>Solicitante</dt><dd>' + esc(t.solicitante_nombre) + '</dd>' +
      '<dt>Tipo de gestión</dt><dd>' + esc(t.tipo_nombre) + '</dd>' +
      '<dt>Categoría</dt><dd>' + esc(t.categoria_nombre) + '</dd>' +
      d.campos.map(c => '<dt>' + esc(c.etiqueta) + '</dt><dd>' + esc(c.valor) + '</dd>').join('') +
      '<dt>Descripción</dt><dd class="pre">' + esc(t.descripcion) + '</dd></dl>';
    if (t.resolucion) h += '<div class="resolution"><h4>' + ico('check-circle', 16) + ' Resolución</h4><p class="pre">' + esc(t.resolucion) + '</p></div>';
    if (t.motivo_rechazo_nombre) h += '<div class="alert alert-error">' + ico('x-circle', 16) + '<span>Rechazado: ' + esc(t.motivo_rechazo_nombre) + '. Vea la justificación en la conversación.</span></div>';
    if (d.evidencias.length) h += '<h3>Evidencias</h3>' + listaEvidencias(d.evidencias);
    if (d.financiero) h += seccionFinanciera(d);
    return h;
  }

  function listaEvidencias(evs) {
    return '<ul class="evid-list">' + evs.map(e => '<li class="' + (e.visibilidad === 'INTERNO' ? 'internal' : '') + '">' + ico('paperclip', 16) +
      '<span><b>' + esc(e.nombre) + '</b><small class="muted block">' + F.tamano(e.tamano) + ' · ' + esc(e.subido_por_nombre) + ' · ' + esc(F.fecha(e.ts)) + (e.visibilidad === 'INTERNO' ? ' · interna' : '') + '</small></span>' +
      (APD.api.urlEvidencia
        ? '<button type="button" class="btn btn-ghost sm" data-ev="' + esc(e.ruta) + '">' + ico('download', 14) + '<span>Descargar</span></button>'
        : '<span class="muted small" title="Con Supabase se descarga con una URL firmada de corta duración">' + (APD.api.modo === 'LOCAL' ? 'Sin almacenamiento local' : 'DEMO: sin archivo') + '</span>') +
      '</li>').join('') + '</ul>';
  }
  const idCorto = id => String(id || '').slice(0, 8);

  function seccionFinanciera(d) {
    if (d.financiero.restringido) return '<div class="restricted">' + ico('lock', 18) + '<div><b>Información financiera restringida</b><p class="muted small">Su perfil no tiene el permiso «Ver información financiera». Los montos de Liquidaciones solo son visibles para Liquidaciones y perfiles autorizados.</p></div></div>';
    return '<h3>' + ico('coins', 18) + ' Diferencias financieras</h3>' + d.financiero.diferencias.map(x => {
      const r = x.resumen;
      return '<div class="fin-card">' +
        '<div class="fin-grid">' +
        '<div><small>Monto esperado</small><b>' + F.crc(x.monto_esperado) + '</b></div>' +
        '<div><small>Monto recibido</small><b>' + F.crc(x.monto_recibido) + '</b></div>' +
        '<div><small>Diferencia (esperado − recibido)</small><b class="' + (r.naturaleza === 'FALTANTE' ? 'neg' : '') + '">' + F.crc(Math.abs(x.monto_diferencia)) + '</b><span class="chip">' + (r.naturaleza === 'FALTANTE' ? 'Faltante' : r.naturaleza === 'SOBRANTE' ? 'Sobrante' : 'Sin diferencia') + '</span></div>' +
        '<div><small>Monto reportado</small><b>' + F.crc(x.monto_reportado) + '</b>' + (x.conciliado ? '' : '<span class="chip chip-warn">No concilia</span>') + '</div>' +
        '</div>' +
        (r.naturaleza === 'SOBRANTE'
          ? '<p class="help">' + ico('info', 14) + '<span><b>Sobrante:</b> se recibió más dinero del esperado. Se reporta como sobrante; no queda pendiente de cobro.</span></p>'
          : '<div class="fin-grid fin-saldos">' +
            '<div><small>Aclarado</small><b>' + F.crc(r.aclarado) + '</b></div>' +
            '<div><small>Recuperado</small><b>' + F.crc(r.recuperado) + '</b></div>' +
            '<div><small>Ajustes</small><b>' + F.crc(r.ajuste) + '</b></div>' +
            '<div><small>Pendiente</small><b class="' + (r.pendiente > 0 ? 'neg' : 'pos') + '">' + F.crc(r.pendiente) + '</b></div></div>') +
        '<p class="muted small">' + [x.ruta_nombre && 'Ruta ' + x.ruta_nombre, x.fecha_operacion && 'Operación ' + F.fechaDeISO(x.fecha_operacion), x.num_liquidacion && 'Liquidación ' + x.num_liquidacion, x.medio_pago && 'Medio: ' + x.medio_pago].filter(Boolean).map(esc).join(' · ') + '</p>' +
        '<div class="fin-head"><h4>Libro de movimientos</h4>' + (d.puede.registrar_movimiento ? '<button type="button" class="btn btn-secondary sm" data-mov="' + esc(x.id) + '">' + ico('plus', 14) + '<span>Registrar movimiento</span></button>' : '') + '</div>' +
        (x.movimientos.length ? '<div class="table-wrap"><table class="table table-sm"><thead><tr><th>ID</th><th>Fecha</th><th>Tipo</th><th class="num">Monto</th><th>Registró</th><th>Nota</th></tr></thead><tbody>' +
          x.movimientos.map(m => '<tr class="' + (m.revertido ? 'row-muted' : '') + '"><td class="mono" title="' + esc(m.id) + '">' + esc(idCorto(m.id)) + '</td><td>' + esc(F.fecha(m.ts)) + '</td><td>' + esc(m.tipo.charAt(0) + m.tipo.slice(1).toLowerCase()) + (m.revierte_id ? ' de ' + esc(idCorto(m.revierte_id)) : '') + (m.revertido ? ' ' + ui.chip('Revertido', 'chip-muted') : '') + '</td><td class="num">' + F.crc(m.monto) + '</td><td>' + esc(m.usuario_nombre) + '</td><td>' + esc(m.nota) + '</td></tr>').join('') +
          '</tbody></table></div>' : '<p class="muted small">Sin movimientos. El saldo pendiente es la diferencia reportada.</p>') +
        '<p class="help">Cada movimiento tiene identificador propio y no se edita; las correcciones se registran como reversiones. Los indicadores se calculan desde este libro.</p>' +
        '</div>';
    }).join('');
  }

  function panelGestion(d, u) {
    const t = d.ticket;
    let h = '<h3>Gestión</h3><div class="mgmt-grid">' +
      '<div class="mgmt-item"><small>Responsable</small><b>' + (t.responsable_nombre ? esc(t.responsable_nombre) : 'Sin asignar') + '</b></div>' +
      '<div class="mgmt-item"><small>Estado</small>' + ui.badgeEstado(t.estado) + '</div>' +
      '<div class="mgmt-item"><small>Prioridad</small>' + ui.badgePrioridad(t.prioridad) + '</div>' +
      '<div class="mgmt-item"><small>SLA</small>' + (t.anulado ? '—' : ui.semaforo(t.sla)) + '</div></div>';
    if (d.acciones.length) {
      h += '<h4>Acciones disponibles</h4><div class="action-list">' + d.acciones.map(a => '<button type="button" class="action-row' + (a.peligro ? ' danger' : '') + '" data-accion="' + a.codigo + '"' + (a.bloqueo ? ' disabled' : '') + '>' + ico(a.icono, 18) + '<span><b>' + esc(a.label) + '</b><small>' + esc(a.bloqueo || descripcionAccion(a.codigo)) + '</small></span>' + ico('chevron-right', 16) + '</button>').join('') + '</div>';
    } else {
      h += '<p class="muted">' + (u.rol === 'GERENCIA' ? 'Perfil de consulta: Gerencia no modifica tickets.' : 'No hay acciones disponibles para su rol en el estado actual.') + '</p>';
    }
    if (d.asignaciones && d.asignaciones.length) {
      h += '<h4>Asignaciones</h4><ul class="timeline compact">' + d.asignaciones.map(a => '<li>' + ico('user', 14) + '<span><b>' + esc(a.responsable_nombre) + '</b> · ' + esc(a.tipo.toLowerCase().replace('_', ' ')) + ' por ' + esc(a.asignado_por_nombre) +
        '<small class="muted block">' + esc(F.fecha(a.desde)) + (a.hasta ? ' → ' + esc(F.fecha(a.hasta)) : ' → actual') + (a.motivo ? ' · ' + esc(a.motivo) : '') + '</small></span></li>').join('') + '</ul>';
    }
    if (t.resolucion) h += '<div class="resolution"><h4>' + ico('check-circle', 16) + ' Resolución</h4><p class="pre">' + esc(t.resolucion) + '</p></div>';
    if (d.investigacion) h += seccionInvestigacion(d.investigacion);
    return h;
  }
  function descripcionAccion(c) {
    return {
      tomar_revision: 'Marca el inicio de la revisión y cuenta como primera respuesta.',
      asignar: 'Elegir responsable según carga y alcance.', autoasignar: 'Tomar el ticket bajo su responsabilidad.',
      reasignar: 'Cambiar de responsable con motivo.', iniciar: 'Comenzar la atención.',
      espera: 'Requiere motivo; algunos motivos pausan el SLA.', reanudar: 'Volver al estado anterior.',
      resolver: 'Documentar la resolución; el solicitante podrá confirmarla.', rechazar: 'Requiere motivo y justificación.',
      confirmar: 'Confirma que quedó atendido y cierra el ticket de inmediato.', solicitar_reapertura: 'Indicar por qué no quedó resuelto.',
      cerrar: 'Cerrar un ticket resuelto.', reabrir: 'Reabrir con motivo documentado.',
      cambiar_prioridad: 'Ajustar la prioridad con motivo (queda en historial).', cierre_excepcional: 'Cerrar sin resolución, con justificación auditada.',
      anular: 'Anular sin borrar: se conserva para trazabilidad.'
    }[c] || '';
  }

  function seccionInvestigacion(inv) {
    if (inv.nivel === 'restringido') return '<div class="restricted">' + ico('lock', 18) + '<div><b>Investigación restringida</b><p class="muted small">Su perfil no tiene acceso a las investigaciones de Liquidaciones.</p></div></div>';
    let h = '<div class="inv-card"><div class="fin-head"><h3>' + ico('search2', 18) + ' Investigación</h3><span class="chip chip-inv-' + inv.estado.toLowerCase() + '">' + INV_ESTADO[inv.estado] + '</span></div>';
    if (inv.nivel === 'resumen') {
      return h + '<dl class="dl"><dt>Inicio</dt><dd>' + esc(F.fecha(inv.fecha_inicio)) + '</dd>' +
        (inv.resultado ? '<dt>Resultado</dt><dd><b>' + esc(inv.resultado) + '</b></dd><dt>Conclusión</dt><dd class="pre">' + esc(inv.conclusion) + '</dd><dt>Fecha de resolución</dt><dd>' + esc(F.fecha(inv.fecha_resolucion)) + '</dd>' : '<dt>Avance</dt><dd class="muted">La investigación está en curso. Transportes documentará la conclusión.</dd>') +
        '</dl></div>';
    }
    h += '<p class="help">' + ico('info', 14) + ' Las personas registradas son <b>involucradas</b>, no responsables. La atribución solo existe como resultado de la conclusión documentada.</p>' +
      '<dl class="dl"><dt>Responsable</dt><dd>' + (inv.responsable_nombre ? esc(inv.responsable_nombre) : '<span class="muted">Sin asignar</span>') + '</dd>' +
      '<dt>Inicio</dt><dd>' + esc(F.fecha(inv.fecha_inicio)) + '</dd>' +
      '<dt>Involucrados</dt><dd>' + (inv.involucrados.length ? inv.involucrados.map(x => ui.chip(x.rol + ': ' + x.nombre)).join(' ') : '<span class="muted">No registrados</span>') + '</dd>' +
      (inv.resultado ? '<dt>Resultado</dt><dd><b>' + esc(inv.resultado) + '</b></dd><dt>Conclusión</dt><dd class="pre">' + esc(inv.conclusion) + '</dd><dt>Documentó</dt><dd>' + esc(inv.concluida_por_nombre) + ' · ' + esc(F.fecha(inv.fecha_resolucion)) + '</dd>' : '') +
      '</dl>';
    h += '<h4>Hallazgos</h4>' + (inv.hallazgos.length ? '<ul class="timeline compact">' + inv.hallazgos.map(x => '<li>' + ico('search2', 14) + '<span>' + esc(x.texto) + '<small class="muted block">' + esc(x.autor_nombre) + ' · ' + esc(F.fecha(x.ts)) + '</small></span></li>').join('') + '</ul>' : '<p class="muted small">Sin hallazgos registrados.</p>');
    if (inv.conclusiones_previas && inv.conclusiones_previas.length) h += '<details class="small"><summary>Conclusiones anteriores (' + inv.conclusiones_previas.length + ')</summary>' + inv.conclusiones_previas.map(c => '<p><b>' + esc(c.resultado) + '</b> — ' + esc(c.conclusion) + ' <span class="muted">(' + esc(F.fecha(c.fecha)) + ')</span></p>').join('') + '</details>';
    const botones = [];
    if (inv.estado !== 'CONCLUIDA' && inv.estado !== 'CANCELADA') {
      if (inv.puede_asignar) botones.push(['inv-asignar', 'user-plus', inv.responsable_nombre ? 'Cambiar responsable' : 'Asignar responsable']);
      // La conclusión se registra al marcar el ticket como resuelto; hallazgos y aclaraciones son opcionales
      if (inv.puede_gestionar) {
        botones.push(['inv-hallazgo', 'plus', 'Registrar hallazgo (opcional)'], ['inv-aclaracion', 'help', 'Solicitar aclaración (opcional)']);
        h += '<p class="help">' + ico('check-circle', 14) + ' La investigación se concluye al <b>marcar el ticket como resuelto</b>: ahí se elige el resultado.</p>';
      }
    } else if (inv.estado === 'CONCLUIDA' && inv.puede_reabrir) botones.push(['inv-reabrir', 'rotate', 'Reabrir investigación']);
    if (botones.length) h += '<div class="btn-row">' + botones.map(b => '<button type="button" class="btn btn-secondary sm" data-inv="' + b[0] + '">' + ico(b[1], 14) + '<span>' + b[2] + '</span></button>').join('') + '</div>';
    return h + '</div>';
  }

  function panelConversacion(d, cats, u) {
    let h = '';
    if (P.puede(u, 'ticket.ver_internas')) h += '<p class="help">' + ico('eye-off', 14) + ' Las notas internas se muestran con fondo ámbar y nunca son visibles para el departamento solicitante.</p>';
    h += d.comentarios.length ? '<ol class="thread">' + d.comentarios.map(c => {
      const cls = c.visibilidad === 'INTERNO' ? 'internal' : c.es_transportes ? 'staff' : 'requester';
      const etiqueta = { SOLICITUD_INFO: 'Solicitud de información', RESPUESTA_INFO: 'Respuesta del solicitante', RESOLUCION: 'Resolución' }[c.tipo];
      return '<li class="msg ' + cls + '">' + ui.avatar(c.autor_nombre, 'sm') + '<div class="msg-body"><div class="msg-head"><b>' + esc(c.autor_nombre) + '</b><span class="muted small">' + esc(c.autor_rol) + ' · ' + esc(F.fecha(c.ts)) + '</span>' +
        (c.visibilidad === 'INTERNO' ? '<span class="chip chip-internal">' + ico('eye-off', 12) + 'Nota interna</span>' : '') + (etiqueta ? ui.chip(etiqueta, c.tipo === 'RESOLUCION' ? 'chip-ok' : 'chip-info') : '') + '</div>' +
        '<p class="pre">' + esc(c.texto) + '</p>' + (c.evidencias.length ? '<div class="msg-files">' + c.evidencias.map(e => '<span class="chip">' + ico('paperclip', 12) + esc(e.nombre) + '</span>').join('') + '</div>' : '') + '</div></li>';
    }).join('') + '</ol>' : ui.vacio('message', 'Sin comentarios todavía');
    if (d.puede.comentar_publico || d.puede.nota_interna) {
      const opciones = [];
      if (d.puede.comentar_publico) opciones.push(['PUBLICO', 'Comentario público', 'message']);
      if (d.puede.nota_interna) opciones.push(['INTERNO', 'Nota interna', 'eye-off']);
      h += '<form class="composer" data-x="comentar">' +
        (opciones.length > 1 ? '<div class="seg seg-sm" role="radiogroup" aria-label="Visibilidad">' + opciones.map((o, i) => '<label><input type="radio" name="visibilidad" value="' + o[0] + '"' + (i === 0 ? ' checked' : '') + '><span>' + ico(o[2], 14) + o[1] + '</span></label>').join('') + '</div>' : '<input type="hidden" name="visibilidad" value="' + opciones[0][0] + '">') +
        '<label class="sr-only" for="com_txt">Mensaje</label><textarea id="com_txt" name="texto" rows="3" placeholder="Escriba un comentario…" required></textarea>' +
        '<div class="composer-foot">' +
        (cats.respuestas.length ? '<select data-x="rapida" aria-label="Respuesta rápida"><option value="">Respuesta rápida…</option>' + cats.respuestas.map(r => '<option value="' + esc(r.id) + '">' + esc(r.nombre) + '</option>').join('') + '</select>' : '') +
        (d.puede.adjuntar ? '<label class="btn btn-ghost sm file-btn">' + ico('paperclip', 14) + '<span>Adjuntar</span><input type="file" multiple hidden data-x="com-files"></label><span class="muted small" data-x="com-files-list"></span>' : '') +
        '<button type="submit" class="btn btn-primary">' + ico('send', 16) + '<span>Enviar</span></button></div></form>';
    } else if (u.rol === 'GERENCIA') h += '<p class="muted small">Perfil de consulta: no puede agregar comentarios.</p>';
    else if (E.TERMINALES.includes(d.ticket.estado)) h += '<p class="muted small">El ticket está finalizado y no admite comentarios nuevos.</p>';
    return h;
  }

  function panelHistorial(d) {
    return '<p class="help">Registro inmutable: cada evento guarda usuario, fecha y hora.</p><ol class="timeline">' + d.historial.slice().reverse().map(x =>
      '<li class="' + (x.visibilidad !== 'PUBLICO' ? 'internal' : '') + '">' + ico(EVENTO_ICONO[x.evento] || 'info', 16) + '<span><b>' + esc(x.detalle) + '</b>' +
      '<small class="muted block">' + esc(x.usuario_nombre) + ' · ' + esc(F.fecha(x.ts)) + (x.visibilidad === 'INTERNO' ? ' · interno' : x.visibilidad === 'FINANCIERO' ? ' · financiero' : '') + '</small></span></li>').join('') + '</ol>';
  }

  /* ---------------- Acciones ---------------- */
  function enlazarAcciones(el, d, cats) {
    el.querySelectorAll('[data-accion]').forEach(b => b.addEventListener('click', () => ejecutar(d, cats, b.dataset.accion)));
    const fr = el.querySelector('[data-x="responder"]');
    if (fr) {
      let archivos = [];
      const fi = fr.querySelector('[data-x="resp-files"]');
      fi.addEventListener('change', () => { archivos = Array.from(fi.files).map(f => ({ nombre: f.name, tamano: f.size, tipo: f.type, archivo: f })); fr.querySelector('[data-x="resp-files-list"]').textContent = archivos.map(a => a.nombre).join(', '); });
      fr.addEventListener('submit', async e => {
        e.preventDefault();
        try {
          ui.validarRequeridos(fr);
          await APD.api.tickets.responderInfo(d.ticket.id, fr.texto.value, archivos);
          ui.toast('Respuesta enviada a Transportes');
          APD.app.refresh();
        } catch (err) { ui.toast(err.message, 'error'); }
      });
    }
  }

  async function ejecutar(d, cats, codigo) {
    const a = d.acciones.find(x => x.codigo === codigo);
    if (!a) return;
    const id = d.ticket.id;
    const exito = msg => { ui.toast(msg); APD.app.refresh(); };
    if (codigo === 'asignar' || codigo === 'reasignar') { modalAsignar(id, codigo, () => APD.app.refresh()); return; }
    if (codigo === 'confirmar') { modalConfirmar(d, a); return; }
    if (!a.requiere.length) {
      try { await APD.api.tickets.accion(id, codigo, {}); exito(codigo === 'confirmar' ? 'Ticket cerrado. ¡Gracias por confirmar!' : a.label + ': listo'); } catch (e) { ui.toast(e.message, 'error'); }
      return;
    }
    let cuerpo = '';
    const req = a.requiere;
    if (req.includes('motivo_espera')) cuerpo += '<div class="field"><label for="m_mot">Motivo <span class="req">*</span></label><select id="m_mot" name="motivo_id" required><option value="">Seleccione…</option>' +
      cats.motivos.filter(m => m.tipo === 'ESPERA').map(m => '<option value="' + m.id + '">' + esc(m.nombre) + (m.pausa_sla ? ' — pausa el SLA' : '') + '</option>').join('') + '</select>' +
      '<p class="help">Si elige «Información del solicitante», el detalle se envía como solicitud de información y el ticket se reanuda solo cuando respondan.</p></div>';
    if (req.includes('detalle')) cuerpo += '<div class="field"><label for="m_det">Detalle (visible para el solicitante) <span class="req">*</span></label><textarea id="m_det" name="detalle" rows="3" required></textarea></div>';
    if (req.includes('motivo_rechazo')) cuerpo += '<div class="field"><label for="m_rec">Motivo de rechazo <span class="req">*</span></label><select id="m_rec" name="motivo_id" required><option value="">Seleccione…</option>' + cats.motivos.filter(m => m.tipo === 'RECHAZO').map(m => '<option value="' + m.id + '">' + esc(m.nombre) + '</option>').join('') + '</select></div>';
    if (req.includes('prioridad')) cuerpo += '<div class="field"><label for="m_pri">Nueva prioridad <span class="req">*</span></label><select id="m_pri" name="prioridad" required>' + ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'].map(p => '<option value="' + p + '"' + (p === d.ticket.prioridad ? ' selected' : '') + '>' + ui.PRIORIDADES[p][0] + '</option>').join('') + '</select><p class="help">Los objetivos de SLA se recalculan con la versión de SLA del ticket (v' + d.ticket.sla_version + ').</p></div>';
    if (req.includes('justificacion')) cuerpo += '<div class="field"><label for="m_jus">Justificación <span class="req">*</span></label><textarea id="m_jus" name="justificacion" rows="3" required minlength="10"></textarea></div>';
    if (req.includes('motivo_texto')) cuerpo += '<div class="field"><label for="m_mt">Motivo <span class="req">*</span></label><textarea id="m_mt" name="motivo" rows="3" required></textarea></div>';
    // Un solo paso: si hay investigación abierta, la resolución también la concluye
    const inv = d.investigacion;
    const conInv = codigo === 'resolver' && inv && inv.nivel === 'completo' && inv.puede_gestionar && inv.estado !== 'CONCLUIDA' && inv.estado !== 'CANCELADA';
    if (conInv) cuerpo += '<div class="field"><label for="m_ri">Resultado de la investigación <span class="req">*</span></label><select id="m_ri" name="resultado_inv" required><option value="">Seleccione…</option>' +
      inv.resultados.map(x => '<option>' + esc(x) + '</option>').join('') + '</select>' +
      '<p class="help">Al confirmar se concluye la investigación con este resultado y el texto de la resolución.</p></div>';
    if (req.includes('resolucion')) cuerpo += '<div class="field"><label for="m_res">' + (conInv ? 'Resolución y conclusión (visible para el solicitante, mín. 20 caracteres)' : 'Resolución (visible para el solicitante)') + ' <span class="req">*</span></label><textarea id="m_res" name="resolucion" rows="4" required></textarea>' +
      (cats.respuestas.length ? '<p class="help"><button type="button" class="link" data-rapida="R6">Insertar respuesta rápida «Solucionado»</button></p>' : '') + '</div>';
    // Cierre del faltante: al resolver, el pendiente se clasifica como aclarado y/o recuperado (queda en ₡0)
    const difF = codigo === 'resolver' && d.puede.registrar_movimiento && d.financiero && d.financiero.diferencias
      ? d.financiero.diferencias.find(x => x.resumen.naturaleza === 'FALTANTE' && x.resumen.pendiente > 0) : null;
    if (difF) {
      const pend = difF.resumen.pendiente;
      cuerpo += '<fieldset class="field cierre-dif" data-pend="' + pend + '"><legend>Cierre del faltante de ' + F.crc(pend) + ' <span class="req">*</span></legend>' +
        '<div class="seg">' + [['ACLARADO', 'Aclarado'], ['RECUPERADO', 'Recuperado'], ['MIXTO', 'Parte y parte']].map((o, i) =>
          '<label><input type="radio" name="cierre_tipo" value="' + o[0] + '"' + (i === 0 ? ' checked' : '') + '><span>' + o[1] + '</span></label>').join('') + '</div>' +
        '<p class="help" data-x="cierre-ayuda"></p>' +
        '<div class="form-grid" data-x="cierre-mixto" hidden><div class="field"><label for="m_acl">Monto aclarado</label><div class="input-prefix"><span aria-hidden="true">₡</span><input id="m_acl" type="number" inputmode="decimal" min="0" step="0.01" name="monto_aclarado"></div></div>' +
        '<div class="field"><label>Monto recuperado</label><div class="input-prefix"><span aria-hidden="true">₡</span><input type="text" class="auto" readonly tabindex="-1" data-x="m-rec"></div></div></div>' +
        '<div class="form-grid" data-x="cierre-rec" hidden>' +
        '<div class="field"><label for="m_frec">Forma de recuperación <span class="req">*</span></label><select id="m_frec" name="forma_rec"><option value="">Seleccione…</option>' +
        ['Boleta de rebajo', 'Rebajo de planilla', 'Depósito', 'Efectivo'].map(x => '<option>' + x + '</option>').join('') + '</select></div>' +
        '<div class="field"><label for="m_fecrec">Fecha de recuperación</label><input id="m_fecrec" type="date" name="fecha_rec" value="' + new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10) + '"></div>' +
        '<div class="field full"><label for="m_comp">Comprobante <span class="muted">(opcional)</span></label><input id="m_comp" name="comprobante_rec" maxlength="80" placeholder="N.º de boleta, depósito o recibo"></div></div>' +
        '</fieldset>';
    }
    // Evidencias de la resolución (opcionales): fotos, comprobantes, boletas…
    let archivos = [];
    const conArchivos = codigo === 'resolver' && d.puede.adjuntar;
    if (conArchivos) cuerpo += '<div class="field"><label for="m_ev">Evidencias de la resolución <span class="muted">(opcional)</span></label>' +
      '<input id="m_ev" type="file" multiple accept="image/*,application/pdf,.doc,.docx,.xls,.xlsx" data-x="res-files">' +
      '<ul class="file-list" data-x="res-list"></ul><p class="help">Fotos, comprobantes o boletas que respalden la resolución. Las verá el solicitante junto a la resolución. Máximo 10 MB por archivo.</p></div>';
    ui.modal({
      titulo: a.label, subtitulo: d.ticket.numero + ' · ' + d.ticket.asunto, cuerpo,
      acciones: [{ label: 'Cancelar' }, {
        label: 'Confirmar', clase: a.peligro ? 'btn-danger' : 'btn-primary', icono: a.icono,
        accion: async m => {
          ui.validarRequeridos(m);
          const datos = ui.leerForm(m);
          if (archivos.length) datos.evidencias = archivos;
          if (difF) {
            datos.cierre_dif = { tipo: datos.cierre_tipo, monto_aclarado: datos.monto_aclarado, forma: datos.forma_rec, fecha: datos.fecha_rec, comprobante: datos.comprobante_rec };
            ['cierre_tipo', 'monto_aclarado', 'forma_rec', 'fecha_rec', 'comprobante_rec'].forEach(k => delete datos[k]);
          }
          try { await APD.api.tickets.accion(id, codigo, datos); }
          catch (e) {
            // Si el ticket sí se resolvió y solo fallaron los archivos, se avisa sin bloquear
            if (archivos.length && /quedó resuelto/.test(e.message)) { ui.toast(e.message, 'error'); APD.app.refresh(); return; }
            throw e;
          }
          exito(a.label + ': registrado' + (archivos.length ? ' con ' + archivos.length + (archivos.length === 1 ? ' evidencia' : ' evidencias') : ''));
        }
      }],
      alAbrir: m => {
        const fi = m.querySelector('[data-x="res-files"]');
        if (fi) fi.addEventListener('change', () => {
          Array.from(fi.files).forEach(f => archivos.push({ nombre: f.name, tamano: f.size, tipo: f.type, archivo: f }));
          fi.value = '';
          const lista = m.querySelector('[data-x="res-list"]');
          const pintar = () => {
            lista.innerHTML = archivos.map((x, i) => '<li>' + ico('paperclip', 14) + '<span>' + esc(x.nombre) + ' <small class="muted">' + F.tamano(x.tamano) + '</small></span><button type="button" class="btn-icon sm" data-quitar="' + i + '" aria-label="Quitar ' + esc(x.nombre) + '">' + ico('x', 14) + '</button></li>').join('');
            lista.querySelectorAll('[data-quitar]').forEach(b => b.addEventListener('click', () => { archivos.splice(Number(b.dataset.quitar), 1); pintar(); }));
          };
          pintar();
        });
        const b = m.querySelector('[data-rapida]');
        if (b) b.addEventListener('click', () => { const r = cats.respuestas.find(x => x.id === b.dataset.rapida); m.querySelector('[name="resolucion"]').value = r.texto; });
        // Cierre del faltante: mostrar los campos según la opción
        const fs = m.querySelector('.cierre-dif');
        if (fs) {
          const pend = Number(fs.dataset.pend);
          let tocado = false;
          const sync = () => {
            const tipo = (fs.querySelector('[name="cierre_tipo"]:checked') || {}).value;
            const acl = tipo === 'ACLARADO' ? pend : tipo === 'RECUPERADO' ? 0 : Math.min(pend, Math.max(0, Number(fs.querySelector('[name="monto_aclarado"]').value) || 0));
            const rec = Math.round((pend - acl) * 100) / 100;
            fs.querySelector('[data-x="cierre-mixto"]').hidden = tipo !== 'MIXTO';
            fs.querySelector('[data-x="cierre-rec"]').hidden = rec <= 0;
            fs.querySelector('[name="forma_rec"]').required = rec > 0;
            fs.querySelector('[name="monto_aclarado"]').required = tipo === 'MIXTO';
            fs.querySelector('[data-x="m-rec"]').value = F.crc(rec).replace('₡', '').trim();
            fs.querySelector('[data-x="cierre-ayuda"]').textContent = {
              ACLARADO: 'Se justificó: el faltante no se cobra. Pendiente final: ₡0.',
              RECUPERADO: 'Se cobra al colaborador (boleta de rebajo, planilla, depósito…). Pendiente final: ₡0.',
              MIXTO: 'Indique cuánto se aclaró; el resto se registra como recuperado. Pendiente final: ₡0.'
            }[tipo];
          };
          fs.addEventListener('change', e => { if (e.target.name === 'cierre_tipo') tocado = true; sync(); });
          fs.addEventListener('input', sync);
          // Sugerencia según el resultado: «Error operativo» → recuperado; los demás → aclarado
          const ri = m.querySelector('[name="resultado_inv"]');
          if (ri) ri.addEventListener('change', () => {
            if (tocado) return;
            const v = ri.value === 'Error operativo' ? 'RECUPERADO' : 'ACLARADO';
            fs.querySelector('[name="cierre_tipo"][value="' + v + '"]').checked = true; sync();
          });
          sync();
        }
      }
    });
  }

  /* Confirmar y cerrar: el solicitante puede dejar un comentario y adjuntar evidencias (ambos opcionales) */
  function modalConfirmar(d, a) {
    const id = d.ticket.id;
    let archivos = [];
    const conArchivos = d.puede.adjuntar;
    ui.modal({
      titulo: 'Confirmar y cerrar', subtitulo: d.ticket.numero + ' · ' + d.ticket.asunto,
      cuerpo: '<p class="muted">Al confirmar, el ticket se cierra de inmediato.</p>' +
        '<div class="field"><label for="cf_txt">Comentario <span class="muted">(opcional)</span></label><textarea id="cf_txt" name="texto" rows="3" placeholder="Ej.: Recibido conforme, gracias."></textarea></div>' +
        (conArchivos ? '<div class="field"><label for="cf_ev">Evidencias <span class="muted">(opcional)</span></label>' +
          '<input id="cf_ev" type="file" multiple accept="image/*,application/pdf,.doc,.docx,.xls,.xlsx" data-x="cf-files"><ul class="file-list" data-x="cf-list"></ul>' +
          '<p class="help">Fotos o documentos que respalden la conformidad. Máximo 10 MB por archivo.</p></div>' : ''),
      acciones: [{ label: 'Cancelar' }, {
        label: 'Confirmar y cerrar', clase: 'btn-primary', icono: a.icono,
        accion: async m => {
          const texto = m.querySelector('[name="texto"]').value.trim();
          if (texto && texto.length < 2) throw new Error('Escriba un comentario más completo o déjelo vacío.');
          // Primero el comentario y las evidencias (el ticket aún está abierto), luego el cierre
          if (texto || archivos.length) {
            await APD.api.tickets.comentar(id, { texto: texto || 'Evidencia adjunta al confirmar la resolución.', visibilidad: 'PUBLICO', evidencias: archivos });
          }
          await APD.api.tickets.accion(id, 'confirmar', {});
          ui.toast('Ticket cerrado. ¡Gracias por confirmar!'); APD.app.refresh();
        }
      }],
      alAbrir: m => {
        const fi = m.querySelector('[data-x="cf-files"]');
        if (!fi) return;
        const lista = m.querySelector('[data-x="cf-list"]');
        const pintar = () => {
          lista.innerHTML = archivos.map((x, i) => '<li>' + ico('paperclip', 14) + '<span>' + esc(x.nombre) + ' <small class="muted">' + F.tamano(x.tamano) + '</small></span><button type="button" class="btn-icon sm" data-quitar="' + i + '" aria-label="Quitar ' + esc(x.nombre) + '">' + ico('x', 14) + '</button></li>').join('');
          lista.querySelectorAll('[data-quitar]').forEach(b => b.addEventListener('click', () => { archivos.splice(Number(b.dataset.quitar), 1); pintar(); }));
        };
        fi.addEventListener('change', () => { Array.from(fi.files).forEach(f => archivos.push({ nombre: f.name, tamano: f.size, tipo: f.type, archivo: f })); fi.value = ''; pintar(); });
      }
    });
  }

  async function modalAsignar(id, codigo, alTerminar) {
    let lista;
    try { lista = await APD.api.tickets.responsables(id); } catch (e) { ui.toast(e.message, 'error'); return; }
    const sug = lista.find(x => x.sugerido);
    ui.modal({
      titulo: codigo === 'reasignar' ? 'Reasignar responsable' : 'Asignar responsable', ancho: 'md',
      subtitulo: 'Solo se puede asignar a usuarios activos, disponibles y con alcance sobre el departamento.',
      cuerpo: (sug ? '<div class="alert alert-info">' + ico('zap', 16) + '<span><b>Sugerido:</b> ' + esc(sug.nombre) + ' — ' + esc(sug.razon) + '</span></div>' : '<div class="alert alert-warn">' + ico('alert', 16) + '<span>No hay un responsable sugerido elegible.</span></div>') +
        '<div class="pick-list" role="radiogroup">' + lista.map(x => '<label class="pick' + (x.no_elegible || x.actual ? ' disabled' : '') + '">' +
          '<input type="radio" name="responsable_id" value="' + esc(x.id) + '"' + (x.sugerido ? ' checked' : '') + (x.no_elegible || x.actual ? ' disabled' : '') + ' required>' +
          ui.avatar(x.nombre, 'sm') + '<span class="pick-body"><b>' + esc(x.nombre) + '</b><small>' + esc(x.rol) + ' · ' + x.carga + ' abiertos' + (x.actual ? ' · responsable actual' : '') + '</small></span>' +
          (x.sugerido ? ui.chip('Sugerido', 'chip-ok') : '') + (x.no_elegible ? ui.chip(x.no_elegible, 'chip-muted') : '') + '</label>').join('') + '</div>' +
        (codigo === 'reasignar' ? '<div class="field"><label for="m_ra">Motivo de reasignación <span class="req">*</span></label><textarea id="m_ra" name="motivo" rows="2" required></textarea></div>' : ''),
      acciones: [{ label: 'Cancelar' }, {
        label: codigo === 'reasignar' ? 'Reasignar' : 'Asignar', clase: 'btn-primary', icono: 'user-check',
        accion: async m => {
          ui.validarRequeridos(m);
          const f = ui.leerForm(m);
          f.sugerido = sug && f.responsable_id === sug.id;
          await APD.api.tickets.accion(id, codigo, f);
          ui.toast('Responsable asignado');
          alTerminar && alTerminar();
        }
      }]
    });
  }

  /* ---------------- Paneles: eventos ---------------- */
  function enlazarPanel(el, d, cats) {
    const fc = el.querySelector('[data-x="comentar"]');
    if (fc) {
      let archivos = [];
      const rap = fc.querySelector('[data-x="rapida"]');
      if (rap) rap.addEventListener('change', () => { const r = cats.respuestas.find(x => x.id === rap.value); if (r) { fc.texto.value = r.texto; fc.texto.focus(); } rap.value = ''; });
      const fi = fc.querySelector('[data-x="com-files"]');
      if (fi) fi.addEventListener('change', () => { archivos = Array.from(fi.files).map(f => ({ nombre: f.name, tamano: f.size, tipo: f.type, archivo: f })); fc.querySelector('[data-x="com-files-list"]').textContent = archivos.map(a => a.nombre).join(', '); });
      const sync = () => fc.classList.toggle('is-internal', (fc.querySelector('[name="visibilidad"]:checked') || fc.visibilidad || {}).value === 'INTERNO');
      fc.addEventListener('change', sync); sync();
      fc.addEventListener('submit', async e => {
        e.preventDefault();
        try {
          ui.validarRequeridos(fc);
          const f = ui.leerForm(fc);
          await APD.api.tickets.comentar(d.ticket.id, { texto: f.texto, visibilidad: f.visibilidad, evidencias: archivos });
          ui.toast(f.visibilidad === 'INTERNO' ? 'Nota interna agregada' : 'Comentario publicado');
          APD.app.refresh();
        } catch (err) { ui.toast(err.message, 'error'); }
      });
    }
    el.querySelectorAll('[data-ev]').forEach(b => b.addEventListener('click', async () => {
      try { window.open(await APD.api.urlEvidencia(b.dataset.ev), '_blank', 'noopener'); }
      catch (err) { ui.toast(err.message, 'error'); }
    }));
    el.querySelectorAll('[data-mov]').forEach(b => b.addEventListener('click', () => modalMovimiento(d, b.dataset.mov)));
    el.querySelectorAll('[data-inv]').forEach(b => b.addEventListener('click', () => accionInvestigacion(d, b.dataset.inv)));
  }

  function modalMovimiento(d, difId) {
    const dif = d.financiero.diferencias.find(x => x.id === difId);
    const revertibles = dif.movimientos.filter(m => m.tipo !== 'REVERSION' && !m.revertido);
    const conclu = d.investigacion && d.investigacion.estado === 'CONCLUIDA';
    const tipos = [['ACLARACION', 'Aclaración (monto justificado)'], ['RECUPERACION', 'Recuperación'], ['AJUSTE', 'Ajuste (+/−)'], ['REVERSION', 'Reversión de un movimiento']]
      .filter(t => !conclu || t[0] === 'RECUPERACION' || t[0] === 'REVERSION');
    ui.modal({
      titulo: 'Registrar movimiento financiero', subtitulo: 'Pendiente actual: ' + F.crc(dif.resumen.pendiente),
      cuerpo: '<div class="field"><label for="mv_t">Tipo <span class="req">*</span></label><select id="mv_t" name="tipo" required><option value="">Seleccione…</option>' + tipos.map(t => '<option value="' + t[0] + '">' + t[1] + '</option>').join('') + '</select>' + (conclu ? '<p class="help">Investigación concluida: solo recuperaciones o reversiones.</p>' : '') + '</div>' +
        '<div class="field" data-x="monto"><label for="mv_m">Monto (CRC) <span class="req">*</span></label><div class="input-prefix"><span>₡</span><input id="mv_m" type="number" step="0.01" name="monto"></div></div>' +
        '<div class="field" data-x="rev" hidden><label for="mv_r">Movimiento a revertir <span class="req">*</span></label><select id="mv_r" name="revierte_id"><option value="">Seleccione…</option>' + revertibles.map(m => '<option value="' + esc(m.id) + '">' + esc(idCorto(m.id)) + ' · ' + m.tipo + ' · ' + F.crc(m.monto) + '</option>').join('') + '</select></div>' +
        '<div class="form-grid" data-x="recup" hidden>' +
        '<div class="field"><label for="mv_f">Forma de recuperación <span class="req">*</span></label><input id="mv_f" name="forma" placeholder="Ej.: depósito, deducción autorizada"></div>' +
        '<div class="field"><label for="mv_d">Fecha <span class="req">*</span></label><input id="mv_d" type="date" name="fecha"></div>' +
        '<div class="field full"><label for="mv_c">Comprobante</label><input id="mv_c" name="comprobante" placeholder="Número de depósito o documento"></div>' +
        '<p class="help full">' + ico('info', 14) + ' Registre solo recuperaciones ya autorizadas por el proceso correspondiente (D-19).</p></div>' +
        '<div class="field"><label for="mv_n">Nota / soporte <span class="req">*</span></label><textarea id="mv_n" name="nota" rows="2" required></textarea></div>',
      alAbrir: m => {
        const sel = m.querySelector('[name="tipo"]');
        sel.addEventListener('change', () => {
          const rev = sel.value === 'REVERSION', rec = sel.value === 'RECUPERACION';
          m.querySelector('[data-x="rev"]').hidden = !rev;
          m.querySelector('[data-x="monto"]').hidden = rev;
          m.querySelector('[data-x="recup"]').hidden = !rec;
          m.querySelector('[name="revierte_id"]').required = rev;
          m.querySelector('[name="monto"]').required = !rev;
          m.querySelector('[name="forma"]').required = rec;
          m.querySelector('[name="fecha"]').required = rec;
        });
      },
      acciones: [{ label: 'Cancelar' }, {
        label: 'Registrar', clase: 'btn-primary', icono: 'coins',
        accion: async m => {
          ui.validarRequeridos(m);
          await APD.api.finanzas.movimiento(difId, ui.leerForm(m));
          ui.toast('Movimiento registrado en el libro');
          APD.app.refresh();
        }
      }]
    });
  }

  function accionInvestigacion(d, cual) {
    const inv = d.investigacion;
    const run = async (fn, msg) => { await fn(); ui.toast(msg); APD.app.refresh(); };
    const area = (name, label, min) => '<div class="field"><label for="iv_' + name + '">' + label + ' <span class="req">*</span></label><textarea id="iv_' + name + '" name="' + name + '" rows="3" required' + (min ? ' minlength="' + min + '"' : '') + '></textarea></div>';
    const conf = {
      'inv-asignar': { t: 'Responsable de la investigación', c: '<div class="field"><label for="iv_r">Responsable <span class="req">*</span></label><select id="iv_r" name="responsable_id" required><option value="">Seleccione…</option>' + inv.candidatos.map(x => '<option value="' + x.id + '"' + (x.id === inv.responsable_id ? ' selected' : '') + '>' + esc(x.nombre) + '</option>').join('') + '</select><p class="help">Solo usuarios con permiso para gestionar investigaciones.</p></div>', f: f => APD.api.investigaciones.asignar(inv.id, f.responsable_id), ok: 'Responsable de investigación asignado' },
      'inv-hallazgo': { t: 'Registrar hallazgo', c: area('texto', 'Hallazgo') + '<p class="help">Los hallazgos son internos: Liquidaciones ve solo el estado, el resultado y la conclusión.</p>', f: f => APD.api.investigaciones.hallazgo(inv.id, f.texto), ok: 'Hallazgo registrado' },
      'inv-aclaracion': { t: 'Solicitar aclaración a Liquidaciones', c: area('texto', 'Qué necesita aclarar (visible para el solicitante)'), f: f => APD.api.investigaciones.aclaracion(inv.id, f.texto), ok: 'Aclaración solicitada' },
      'inv-concluir': {
        t: 'Concluir investigación', c: '<div class="field"><label for="iv_res">Resultado <span class="req">*</span></label><select id="iv_res" name="resultado" required><option value="">Seleccione…</option>' + inv.resultados.map(x => '<option>' + esc(x) + '</option>').join('') + '</select></div>' +
          area('conclusion', 'Conclusión documentada (mín. 20 caracteres)', 20) + '<p class="help">Una vez concluida no se edita; solo supervisión puede reabrirla con motivo, y la conclusión anterior se conserva.</p>',
        f: f => APD.api.investigaciones.concluir(inv.id, f), ok: 'Investigación concluida'
      },
      'inv-reabrir': { t: 'Reabrir investigación', c: area('motivo', 'Motivo'), f: f => APD.api.investigaciones.reabrir(inv.id, f.motivo), ok: 'Investigación reabierta' }
    }[cual];
    ui.modal({
      titulo: conf.t, subtitulo: d.ticket.numero, cuerpo: conf.c,
      acciones: [{ label: 'Cancelar' }, { label: 'Confirmar', clase: 'btn-primary', accion: async m => { ui.validarRequeridos(m); await run(() => conf.f(ui.leerForm(m)), conf.ok); } }]
    });
  }

  APD.pages.ticket = { render, modalAsignar };
})();
