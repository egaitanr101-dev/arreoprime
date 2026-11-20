/* Piezas compartidas entre pantallas: tarjeta de ticket, campos dinámicos y formatos de catálogo. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos;

  function etiquetaCatalogo(cats, catalogo, id) {
    const x = (cats[catalogo] || []).find(i => i.id === id);
    return x ? x.id + ' · ' + x.nombre : (id || '');
  }
  function mostrarValor(cats, def, v) {
    if (v == null || v === '') return '—';
    if (def.tipo === 'catalogo') return etiquetaCatalogo(cats, def.catalogo, v);
    if (def.tipo === 'fecha') return F.fechaDeISO(v);
    if (def.tipo === 'crc') return F.crc(v);
    return String(v);
  }

  /** Control de formulario para un campo dinámico de categoría */
  function campoHTML(cats, clave, obligatorio, valor) {
    const def = cats.campos[clave];
    const id = 'f_' + clave;
    const req = obligatorio ? ' required' : '';
    const v = valor == null ? '' : valor;
    let control;
    switch (def.tipo) {
      case 'catalogo':
        control = '<select id="' + id + '" name="' + clave + '"' + req + '><option value="">Seleccione…</option>' +
          (cats[def.catalogo] || []).map(o => '<option value="' + esc(o.id) + '"' + (o.id === v ? ' selected' : '') + '>' + esc(o.id + ' · ' + o.nombre) + '</option>').join('') + '</select>';
        break;
      case 'opciones':
        control = '<select id="' + id + '" name="' + clave + '"' + req + '><option value="">Seleccione…</option>' +
          def.opciones.map(o => '<option' + (o === v ? ' selected' : '') + '>' + esc(o) + '</option>').join('') + '</select>';
        break;
      case 'fecha':
        control = '<input type="date" id="' + id + '" name="' + clave + '" value="' + esc(v) + '"' + req + '>';
        break;
      case 'numero':
        control = '<input type="number" inputmode="numeric" min="0" step="any" id="' + id + '" name="' + clave + '" value="' + esc(v) + '"' + req + '>';
        break;
      case 'crc':
        control = '<div class="input-prefix"><span aria-hidden="true">₡</span><input type="number" inputmode="decimal" min="0" step="0.01" id="' + id + '" name="' + clave + '" value="' + esc(v) + '"' + req + '></div>';
        break;
      case 'textarea':
        control = '<textarea id="' + id + '" name="' + clave + '" rows="2"' + req + '>' + esc(v) + '</textarea>';
        break;
      default:
        control = '<input type="text" id="' + id + '" name="' + clave + '" value="' + esc(v) + '"' + (def.placeholder ? ' placeholder="' + esc(def.placeholder) + '"' : '') + req + '>';
    }
    return '<div class="field' + (def.tipo === 'textarea' ? ' full' : '') + '"><label for="' + id + '">' + esc(def.etiqueta) + (obligatorio ? ' <span class="req">*</span>' : '') + '</label>' + control +
      (def.ayuda ? '<p class="help">' + esc(def.ayuda) + '</p>' : '') + '</div>';
  }

  /** Tarjeta compacta de ticket (portal, móvil, listas) */
  function ticketCard(r, opc) {
    opc = opc || {};
    const u = APD.state.usuario;
    const verSla = P.esTransportes(u) || u.rol === 'GERENCIA';
    const avisos = [];
    if (r.anulado) avisos.push(ui.chip('Anulado', 'chip-muted'));
    if (r.pendiente_info) avisos.push('<span class="chip chip-warn">' + ico('help', 12) + 'Requiere respuesta</span>');
    if (r.estado === 'RESUELTO' && P.esSolicitante(u)) avisos.push('<span class="chip chip-ok">' + ico('check', 12) + 'Por confirmar</span>');
    return '<a class="tcard" href="#/ticket/' + esc(r.id) + '">' +
      '<div class="tcard-top"><span class="tnum">' + esc(r.numero) + '</span>' + ui.badgeEstado(r.estado) + '</div>' +
      '<div class="tcard-title">' + esc(r.asunto) + '</div>' +
      '<div class="tcard-meta">' + esc(r.categoria_nombre) + (opc.depto !== false ? ' · ' + esc(r.depto_nombre) : '') + ' · ' + esc(F.relativo(r.creado_at)) + '</div>' +
      '<div class="tcard-foot">' + ui.badgePrioridad(r.prioridad) +
      (r.responsable_nombre ? '<span class="muted small">' + ico('user', 12) + ' ' + esc(r.responsable_nombre) + '</span>' : '<span class="muted small">Sin asignar</span>') +
      (verSla && !r.anulado ? ui.semaforo(r.sla, true) : '') + avisos.join('') + '</div></a>';
  }

  function noAutorizado(msg) { return Object.assign(new Error(msg || 'Su rol no tiene acceso a esta sección.'), { code: 'NO_AUTORIZADO' }); }

  APD.comun = { etiquetaCatalogo, mostrarValor, campoHTML, ticketCard, noAutorizado };
})();
