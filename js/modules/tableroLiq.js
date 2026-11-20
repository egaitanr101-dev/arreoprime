/* Dashboard de Liquidaciones (Crédito y Cobro): vista gerencial del departamento.
 * Filtros por mes y por motivo (categoría), tendencia semanal, tickets por motivo y top de choferes
 * involucrados con incidencias y monto. Los datos llegan ya filtrados por permisos (RLS): este
 * tablero nunca muestra información de otros departamentos. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const st = { mes: '', motivo: '' };

  async function render(el) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'dashboard.liquidaciones') || !P.puede(u, 'financiero.ver')) throw C.noAutorizado('Su perfil no tiene acceso al Dashboard de Liquidaciones.');
    APD.app.titulo('Dashboard de Liquidaciones');
    const d = await APD.api.finanzas.dashboard({ mes: st.mes, motivo: st.motivo });
    const k = d.kpis, kpi = APD.pages.dashboard.kpi;
    const mesLabel = st.mes ? (d.filtros.meses.find(m => m.id === st.mes) || {}).label : 'Todos los meses';
    const pct = k.pct_cerrado == null ? '—' : F.pct(k.pct_cerrado);
    const dias = k.prom_resolucion_dias == null ? '—' : (Math.round(k.prom_resolucion_dias * 10) / 10).toString().replace('.', ',') + ' días';

    let h = '<div class="page wide">' +
      '<div class="page-head page-hero"><div><p class="eyebrow">Liquidaciones · Crédito y Cobro</p><h2>Dashboard de Liquidaciones</h2>' +
      '<p class="muted">' + esc(mesLabel) + (st.motivo ? ' · ' + esc(st.motivo) : ' · todos los motivos') + ' · montos en colones (CRC)</p></div>' +
      '<div class="page-actions no-print"><div class="filter-row">' +
      '<select data-x="mes" aria-label="Mes"><option value="">Todos los meses</option>' + d.filtros.meses.map(m => '<option value="' + esc(m.id) + '"' + (m.id === st.mes ? ' selected' : '') + '>' + esc(m.label.charAt(0).toUpperCase() + m.label.slice(1)) + '</option>').join('') + '</select>' +
      '<select data-x="motivo" aria-label="Motivo"><option value="">Todos los motivos</option>' + d.filtros.motivos.map(m => '<option' + (m === st.motivo ? ' selected' : '') + '>' + esc(m) + '</option>').join('') + '</select></div>' +
      (window.XLSX ? '<button type="button" class="btn btn-secondary" data-x="xlsx">' + ico('download', 16) + '<span>Excel</span></button>' : '') +
      '<button type="button" class="btn btn-secondary" data-x="pdf">' + ico('printer', 16) + '<span>PDF</span></button>' +
      (P.puede(u, 'reporte.completo') ? '<a class="btn btn-secondary" href="#/reportes?tipo=incidencias_chofer">' + ico('file', 16) + '<span>Reportes</span></a>' : '') +
      '</div></div>' +
      ui.demoNota('Montos ficticios de demostración.') +
      '<p class="print-only small">ArreoPrime · Dashboard de Liquidaciones · ' + esc(mesLabel) + (st.motivo ? ' · ' + esc(st.motivo) : '') + ' · generado ' + esc(F.fecha(Date.now())) + ' por ' + esc(u.nombre) + '</p>' +

      '<div class="kpi-grid">' +
      kpi('Cantidad de tickets', F.num(k.tickets), { icono: 'inbox', nota: k.abiertos + ' abiertos · ' + k.resueltos + ' resueltos' }) +
      kpi('Faltante reportado', F.crc(k.faltante), { icono: 'coins', nota: k.con_diferencia + ' diferencias' }) +
      kpi('Monto aclarado', F.crc(k.aclarado), { icono: 'check' }) +
      kpi('Monto recuperado', F.crc(k.recuperado), { icono: 'rotate' }) +
      kpi('Monto pendiente', F.crc(k.pendiente), { icono: 'alert', cls: k.pendiente > 0 ? 'kpi-warning' : '', nota: k.inv_abiertas + ' investigaciones abiertas' }) +
      kpi('Sobrante reportado', F.crc(k.sobrante), { icono: 'plus' }) +
      kpi('Faltante cerrado', pct, { icono: 'check-circle', nota: 'aclarado + recuperado' }) +
      kpi('Prom. de resolución', dias, { icono: 'clock', nota: 'creación → resolución' }) +
      '</div>' +

      '<div class="chart-grid">' +
      '<section class="card chart-card"><div class="card-head"><h3>' + ico('trend', 18) + ' Tendencia semanal de tickets</h3><span class="muted small">Creados y resueltos</span></div>' +
        ui.lineas(d.tendencia, [{ clave: 'tickets', label: 'Creados' }, { clave: 'resueltos', label: 'Resueltos' }], { titulo: 'Tendencia semanal de tickets' }) + '</section>' +
      '<section class="card chart-card"><div class="card-head"><h3>' + ico('coins', 18) + ' Monto faltante por semana</h3><span class="muted small">Colones (₡)</span></div>' +
        ui.lineas(d.tendencia, [{ clave: 'monto', label: 'Faltante reportado' }], { titulo: 'Monto faltante por semana', formato: v => F.crcK(v) }) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('list', 18) + ' Tickets por motivo</h3>' + ui.barras(d.por_motivo.map(x => ({ label: x.label, valor: x.tickets }))) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('coins', 18) + ' Monto faltante por motivo</h3>' + ui.barras(d.por_motivo.filter(x => x.monto > 0).map(x => ({ label: x.label, valor: x.monto, extra: x.tickets + (x.tickets === 1 ? ' ticket' : ' tickets') })), { formato: v => F.crcK(v) }) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('layers', 18) + ' Tickets por estado</h3>' + ui.barras(d.por_estado) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('truck', 18) + ' Top de choferes por monto</h3>' + ui.barras(d.top_choferes.filter(x => x.monto > 0).slice(0, 8).map(x => ({ label: x.chofer, valor: x.monto, extra: x.incidencias + (x.incidencias === 1 ? ' incidencia' : ' incidencias') })), { formato: v => F.crcK(v) }) + '</section>' +
      '</div>' +

      '<section class="card table-card"><div class="card-head"><h3>' + ico('users', 18) + ' Top de choferes con incidencias</h3><span class="muted small">Ordenado por monto faltante</span></div>' +
      (d.top_choferes.length ? '<div class="table-wrap"><table class="table"><thead><tr><th>#</th><th>Chofer</th><th class="num">Incidencias</th><th class="num">Monto faltante</th><th class="num">Aclarado</th><th class="num">Recuperado</th><th class="num">Pendiente</th><th class="num">Sobrante</th></tr></thead><tbody>' +
        d.top_choferes.map((x, i) => '<tr><td>' + (i + 1) + '</td><td>' + esc(x.chofer) + '</td><td class="num">' + x.incidencias + '</td><td class="num"><b>' + F.crc(x.monto) + '</b></td><td class="num">' + F.crc(x.aclarado) + '</td><td class="num">' + F.crc(x.recuperado) + '</td>' +
          '<td class="num">' + (x.pendiente > 0 ? '<b class="neg">' + F.crc(x.pendiente) + '</b>' : F.crc(0)) + '</td><td class="num">' + (x.sobrante ? F.crc(x.sobrante) : '—') + '</td></tr>').join('') +
        '</tbody></table></div>' : ui.vacio('users', 'Sin incidencias de choferes con los filtros elegidos')) +
      '<p class="help">' + ico('info', 14) + ' Un chofer en este listado está <b>involucrado</b> en diferencias reportadas; no implica responsabilidad. La atribución solo existe como resultado documentado de una investigación.</p></section>' +
      '</div>';
    el.innerHTML = h;

    el.querySelector('[data-x="mes"]').addEventListener('change', e => { st.mes = e.target.value; render(el); });
    el.querySelector('[data-x="motivo"]').addEventListener('change', e => { st.motivo = e.target.value; render(el); });
    const bx = el.querySelector('[data-x="xlsx"]');
    if (bx) bx.addEventListener('click', async () => {
      try {
        await APD.api.reportes.registrarExportacion('incidencias_chofer', 'XLSX', d.top_choferes.length + d.por_motivo.length + d.tendencia.length);
        exportarExcel(d, mesLabel);
        ui.toast('Excel generado. La exportación quedó registrada en auditoría.');
      } catch (e) { ui.toast(e.message, 'error'); }
    });
    el.querySelector('[data-x="pdf"]').addEventListener('click', async () => {
      try { await APD.api.reportes.registrarExportacion('incidencias_chofer', 'PDF', d.top_choferes.length); } catch (e) { ui.toast(e.message, 'error'); return; }
      window.print();
    });
  }

  /** Un libro con cuatro hojas: resumen, tendencia semanal, motivos y choferes (los números quedan como números) */
  function exportarExcel(d, mesLabel) {
    const X = window.XLSX, k = d.kpis, libro = X.utils.book_new();
    const hoja = (nombre, filas) => { const h = X.utils.aoa_to_sheet(filas); h['!cols'] = filas[0].map(() => ({ wch: 22 })); X.utils.book_append_sheet(libro, h, nombre); };
    hoja('Resumen', [['Indicador', 'Valor'], ['Período', mesLabel], ['Motivo', st.motivo || 'Todos'], ['Cantidad de tickets', k.tickets], ['Tickets abiertos', k.abiertos], ['Tickets resueltos', k.resueltos],
      ['Diferencias', k.con_diferencia], ['Faltante reportado (₡)', k.faltante], ['Aclarado (₡)', k.aclarado], ['Recuperado (₡)', k.recuperado], ['Pendiente (₡)', k.pendiente], ['Sobrante (₡)', k.sobrante],
      ['Faltante cerrado (%)', k.pct_cerrado == null ? '' : Math.round(k.pct_cerrado * 1000) / 10], ['Prom. resolución (días)', k.prom_resolucion_dias == null ? '' : Math.round(k.prom_resolucion_dias * 10) / 10]]);
    hoja('Tendencia semanal', [['Semana (desde)', 'Tickets creados', 'Tickets resueltos', 'Faltante (₡)']].concat(d.tendencia.map(s => [F.fechaISO(s.ini), s.tickets, s.resueltos, s.monto])));
    hoja('Por motivo', [['Motivo', 'Tickets', 'Faltante (₡)']].concat(d.por_motivo.map(x => [x.label, x.tickets, x.monto])));
    hoja('Top choferes', [['Chofer', 'Incidencias', 'Faltantes', 'Monto faltante (₡)', 'Aclarado (₡)', 'Recuperado (₡)', 'Pendiente (₡)', 'Sobrante (₡)']]
      .concat(d.top_choferes.map(x => [x.chofer, x.incidencias, x.faltantes, x.monto, x.aclarado, x.recuperado, x.pendiente, x.sobrante])));
    X.writeFile(libro, 'dashboard_liquidaciones_' + (st.mes || 'todo') + '_' + F.fechaISO(Date.now()) + '.xlsx');
  }

  APD.pages.tableroLiq = { render };
})();
