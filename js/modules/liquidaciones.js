/* Liquidaciones: diferencias financieras e investigaciones.
 * Todos los montos se calculan en la API desde registros únicos (diferencia + libro de movimientos). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const st = { dias: '0' };
  const PERIODOS = [['30', '30 días'], ['90', '90 días'], ['0', 'Todo']];
  const INV = { ABIERTA: 'Abierta', EN_CURSO: 'En curso', EN_ACLARACION: 'En aclaración', CONCLUIDA: 'Concluida', CANCELADA: 'Cancelada' };

  async function render(el) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'financiero.ver')) throw C.noAutorizado('Su perfil no tiene acceso a la información financiera de Liquidaciones.');
    APD.app.titulo(P.esSolicitante(u) ? 'Diferencias e investigaciones' : 'Liquidaciones e investigaciones');
    const d = await APD.api.finanzas.resumen({ dias: st.dias === '0' ? null : st.dias });
    const k = d.kpis;
    const kpi = APD.pages.dashboard.kpi;
    const crcFmt = v => F.crcK(v);
    let h = '<div class="page wide">' +
      '<div class="page-head"><div><h2>Diferencias de liquidación e investigaciones</h2><p class="muted">' + k.casos + ' diferencias registradas · montos en colones (CRC)</p></div>' +
      '<div class="filter-row"><div class="seg seg-sm" role="radiogroup" aria-label="Período">' + PERIODOS.map(p => '<label><input type="radio" name="periodo" value="' + p[0] + '"' + (st.dias === p[0] ? ' checked' : '') + '><span>' + p[1] + '</span></label>').join('') + '</div>' +
      (P.puede(u, 'reporte.completo') ? '<a class="btn btn-secondary" href="#/reportes?tipo=diferencias">' + ico('download', 16) + '<span>Reporte</span></a>' : '') + '</div></div>' +
      ui.demoNota('Montos ficticios. Cada diferencia se cuenta una sola vez; aclarado y recuperado salen del libro de movimientos.') +
      '<div class="kpi-grid">' +
      kpi('Faltante reportado', F.crc(k.faltante_reportado), { icono: 'coins' }) +
      kpi('Bajo investigación', F.crc(k.bajo_investigacion), { nota: k.inv_abiertas + ' investigaciones abiertas' }) +
      kpi('Monto aclarado', F.crc(k.aclarado)) +
      kpi('Monto recuperado', F.crc(k.recuperado)) +
      kpi('Monto pendiente', F.crc(k.pendiente), { cls: k.pendiente > 0 ? 'kpi-warning' : '' }) +
      kpi('Sobrante reportado', F.crc(k.sobrante_reportado)) +
      kpi('Tiempo prom. de investigación', k.prom_investigacion_dias == null ? '—' : (Math.round(k.prom_investigacion_dias * 10) / 10).toString().replace('.', ',') + ' días', { icono: 'clock' }) +
      kpi('Casos', F.num(k.casos)) +
      '</div>' +
      '<p class="help">' + ico('info', 14) + ' Las personas asociadas a una diferencia son <b>involucradas</b>. Que aparezcan en estos indicadores no implica responsabilidad; la atribución solo existe como resultado documentado de una investigación.</p>' +
      '<div class="chart-grid">' +
      '<section class="card"><h3>Faltante por ruta</h3>' + ui.barras(d.por_ruta.slice(0, 8), { formato: crcFmt }) + '</section>' +
      '<section class="card"><h3>Faltante por tipo</h3>' + ui.barras(d.por_tipo.slice(0, 8), { formato: crcFmt }) + '</section>' +
      '<section class="card"><h3>Faltante por chofer involucrado</h3>' + ui.barras(d.por_chofer.slice(0, 8), { formato: crcFmt }) + '</section>' +
      '<section class="card"><h3>Faltante por ayudante involucrado</h3>' + ui.barras(d.por_ayudante.slice(0, 8), { formato: crcFmt }) + '</section>' +
      '</div>';
    if (d.recurrentes.length) h += '<section class="card"><h3>' + ico('rotate', 18) + ' Casos recurrentes (2 o más diferencias)</h3>' + ui.barras(d.recurrentes, { formato: crcFmt }) + '</section>';

    h += '<section class="card table-card"><div class="card-head"><h3>Detalle de diferencias</h3><span class="muted small">Ordenado por saldo pendiente</span></div>' +
      (d.filas.length ? '<div class="table-wrap hide-mobile"><table class="table"><thead><tr><th>Ticket</th><th>Operación</th><th>Ruta</th><th>Chofer</th><th>Ayudante</th><th class="num">Diferencia</th><th class="num">Aclarado</th><th class="num">Recuperado</th><th class="num">Pendiente</th>' + (d.ver_investigacion ? '<th>Investigación</th>' : '') + '</tr></thead><tbody>' +
        d.filas.map(x => '<tr data-id="' + esc(x.ticket_id) + '"><td><a class="tnum" href="#/ticket/' + esc(x.ticket_id) + '">' + esc(x.numero) + '</a><small class="muted block">' + esc(x.categoria) + '</small></td>' +
          '<td>' + esc(x.fecha_operacion ? F.fechaDeISO(x.fecha_operacion) : '—') + '</td><td>' + esc(x.ruta || '—') + '</td><td>' + esc(x.chofer || '—') + '</td><td>' + esc(x.ayudante || '—') + '</td>' +
          '<td class="num">' + F.crc(Math.abs(x.monto_diferencia)) + '<small class="muted block">' + (x.naturaleza === 'FALTANTE' ? 'Faltante' : x.naturaleza === 'SOBRANTE' ? 'Sobrante' : '—') + '</small></td>' +
          (x.naturaleza === 'SOBRANTE'
            ? '<td class="num muted">—</td><td class="num muted">—</td><td class="num">' + ui.chip('Sobrante', 'chip-info') + '</td>'
            : '<td class="num">' + F.crc(x.aclarado) + '</td><td class="num">' + F.crc(x.recuperado) + '</td><td class="num"><b class="' + (x.pendiente > 0 ? 'neg' : '') + '">' + F.crc(x.pendiente) + '</b></td>') +
          (d.ver_investigacion ? '<td>' + (x.inv_estado ? ui.chip(INV[x.inv_estado], 'chip-inv-' + x.inv_estado.toLowerCase()) + (x.inv_resultado ? '<small class="muted block">' + esc(x.inv_resultado) + '</small>' : '') : '—') + '</td>' : '') + '</tr>').join('') +
        '</tbody></table></div>' +
        '<div class="tcard-list only-mobile">' + d.filas.map(x => '<a class="tcard" href="#/ticket/' + esc(x.ticket_id) + '"><div class="tcard-top"><span class="tnum">' + esc(x.numero) + '</span>' + (x.inv_estado ? ui.chip(INV[x.inv_estado], 'chip-inv-' + x.inv_estado.toLowerCase()) : '') + '</div>' +
          '<div class="tcard-title">' + esc(x.categoria) + '</div><div class="tcard-meta">' + esc([x.ruta, x.chofer].filter(Boolean).join(' · ')) + '</div>' +
          '<div class="fin-mini"><span>Diferencia <b>' + F.crc(Math.abs(x.monto_diferencia)) + '</b></span>' + (x.naturaleza === 'SOBRANTE' ? '<span>' + ui.chip('Sobrante', 'chip-info') + '</span>' : '<span>Pendiente <b class="' + (x.pendiente > 0 ? 'neg' : '') + '">' + F.crc(x.pendiente) + '</b></span>') + '</div></a>').join('') + '</div>'
        : ui.vacio('coins', 'Sin diferencias en el período')) + '</section>';

    el.innerHTML = h + '</div>';
    el.querySelectorAll('[name="periodo"]').forEach(i => i.addEventListener('change', () => { st.dias = i.value; render(el); }));
    const tb = el.querySelector('tbody');
    if (tb) tb.addEventListener('click', e => { if (e.target.closest('a')) return; const tr = e.target.closest('tr[data-id]'); if (tr) APD.app.go('#/ticket/' + tr.dataset.id); });
  }

  APD.pages.liquidaciones = { render };
})();
