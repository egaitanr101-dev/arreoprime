/* Reportes y exportaciones. Las filas vienen de la API con los mismos permisos de visibilidad;
 * por eso una exportación nunca contiene datos que el usuario no pueda ver en pantalla. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const st = { tipo: null, dias: '30', departamento: '' };

  async function render(el, r) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'reporte.operativo') && !P.puede(u, 'reporte.completo')) throw C.noAutorizado();
    APD.app.titulo('Reportes');
    const tipos = await APD.api.reportes.tipos();
    if (r.query.tipo && tipos.some(t => t.id === r.query.tipo)) st.tipo = r.query.tipo;
    if (!st.tipo || !tipos.some(t => t.id === st.tipo)) st.tipo = tipos[0].id;
    const rep = await APD.api.reportes.generar(st.tipo, { dias: st.dias === '0' ? null : st.dias, departamento: st.departamento });
    const fmtCelda = (c, v) => (v == null || v === '' ? '<span class="muted">—</span>' : typeof v === 'number' && /monto|aclarado|recuperado|pendiente|diferencia|esperado|recibido/.test(c.clave) ? F.crc(v) : esc(v));

    el.innerHTML = '<div class="page wide">' +
      '<div class="page-head"><div><h2>Reportes</h2><p class="muted">Las exportaciones respetan exactamente sus permisos de visibilidad.</p></div></div>' +
      '<div class="report-layout">' +
      '<nav class="card report-nav" aria-label="Tipos de reporte"><h3>Reportes disponibles</h3>' +
      '<select class="only-mobile" data-x="tipo-m" aria-label="Reporte">' + tipos.map(t => '<option value="' + t.id + '"' + (t.id === st.tipo ? ' selected' : '') + '>' + esc(t.titulo) + '</option>').join('') + '</select>' +
      '<ul class="hide-mobile">' + tipos.map(t => '<li><button type="button" class="report-link' + (t.id === st.tipo ? ' on' : '') + '" data-tipo="' + t.id + '">' + ico(/diferencias|investigaciones/.test(t.id) ? 'coins' : 'file', 16) + '<span>' + esc(t.titulo) + '</span></button></li>').join('') + '</ul></nav>' +
      '<section class="card print-area">' +
      '<div class="report-head"><div><h3>' + esc(rep.titulo) + '</h3><p class="muted small">Generado ' + esc(F.fecha(rep.generado)) + ' por ' + esc(rep.generado_por) + ' · ' + rep.filas.length + ' filas · ' +
      esc(st.dias === '0' ? 'todo el historial' : 'últimos ' + st.dias + ' días') + (st.departamento ? ' · ' + esc({ COM: 'Comercial', ALM: 'Almacén', LIQ: 'Liquidaciones' }[st.departamento]) : '') + '</p></div>' +
      '<div class="report-actions no-print">' +
      APD.pages.dashboard.filtros(true, st).replace('filter-row', 'filter-row compact') +
      (window.XLSX ? '<button type="button" class="btn btn-secondary" data-x="xlsx">' + ico('download', 16) + '<span>Excel</span></button>' : '') +
      '<button type="button" class="btn btn-secondary" data-x="csv">' + ico('download', 16) + '<span>CSV</span></button>' +
      '<button type="button" class="btn btn-secondary" data-x="pdf">' + ico('printer', 16) + '<span>PDF</span></button></div></div>' +
      '<p class="print-only small">ArreoPrime · TRANSPORTES · SERVICIO · LOGÍSTICA · DATOS DE DEMOSTRACIÓN</p>' +
      (rep.filas.length ? '<div class="table-wrap"><table class="table table-report"><thead><tr>' + rep.columnas.map(c => '<th>' + esc(c.label) + '</th>').join('') + '</tr></thead><tbody>' +
        rep.filas.slice(0, 500).map(f => '<tr>' + rep.columnas.map(c => '<td' + (typeof f[c.clave] === 'number' ? ' class="num"' : '') + '>' + fmtCelda(c, f[c.clave]) + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>' +
        (rep.filas.length > 500 ? '<p class="muted small">Vista previa limitada a 500 filas; la exportación incluye todas.</p>' : '')
        : ui.vacio('file', 'Sin datos para este reporte en el período')) +
      '<p class="help no-print">' + ico('info', 14) + ' CSV con separador «;» y codificación UTF-8 (abre directamente en Excel con configuración regional de Costa Rica). Excel (.xlsx) con SheetJS 0.20.3 incluido en la aplicación (D-17). PDF mediante la impresión del navegador.</p>' +
      '</section></div></div>';

    el.querySelectorAll('[data-tipo]').forEach(b => b.addEventListener('click', () => { st.tipo = b.dataset.tipo; render(el, { query: {} }); }));
    const tm = el.querySelector('[data-x="tipo-m"]');
    tm.addEventListener('change', () => { st.tipo = tm.value; render(el, { query: {} }); });
    el.querySelectorAll('[name="periodo"]').forEach(i => i.addEventListener('change', () => { st.dias = i.value; render(el, { query: {} }); }));
    const dep = el.querySelector('[data-x="depto"]');
    if (dep) dep.addEventListener('change', () => { st.departamento = dep.value; render(el, { query: {} }); });
    el.querySelector('[data-x="csv"]').addEventListener('click', async () => {
      try {
        ui.descargar(rep.tipo + '_' + F.fechaISO(Date.now()) + '.csv', ui.aCSV(rep.columnas, rep.filas), 'text/csv;charset=utf-8');
        await APD.api.reportes.registrarExportacion(rep.tipo, 'CSV', rep.filas.length);
        ui.toast('CSV generado (' + rep.filas.length + ' filas). La exportación quedó registrada en auditoría.');
      } catch (e) { ui.toast(e.message, 'error'); }
    });
    const bx = el.querySelector('[data-x="xlsx"]');
    if (bx) bx.addEventListener('click', async () => {
      try {
        await APD.api.reportes.registrarExportacion(rep.tipo, 'XLSX', rep.filas.length);
        APD.ui.descargarExcel(rep.tipo + '_' + F.fechaISO(Date.now()) + '.xlsx', rep.titulo, rep.columnas, rep.filas);
        ui.toast('Excel generado (' + rep.filas.length + ' filas). La exportación quedó registrada en auditoría.');
      } catch (e) { ui.toast(e.message, 'error'); }
    });
    el.querySelector('[data-x="pdf"]').addEventListener('click', async () => {
      try { await APD.api.reportes.registrarExportacion(rep.tipo, 'PDF', rep.filas.length); } catch (e) { ui.toast(e.message, 'error'); return; }
      document.body.classList.add('printing-report');
      window.print();
      setTimeout(() => document.body.classList.remove('printing-report'), 500);
    });
  }

  APD.pages.reportes = { render };
})();
