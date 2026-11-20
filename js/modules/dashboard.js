/* Dashboard operativo (operador) y gerencial (supervisor / gerencia). Respeta permisos: los datos
 * vienen de la misma API filtrada por visibilidad. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const st = { dias: '30', departamento: '' };
  const PERIODOS = [['7', '7 días'], ['30', '30 días'], ['90', '90 días'], ['0', 'Todo']];

  function kpi(label, valor, opc) {
    opc = opc || {};
    const tag = opc.href ? 'a' : 'div';
    return '<' + tag + ' class="kpi' + (opc.cls ? ' ' + opc.cls : '') + '"' + (opc.href ? ' href="' + opc.href + '"' : '') + '>' +
      '<span class="kpi-top"><span class="kpi-label">' + esc(label) + '</span><span class="kpi-ico" aria-hidden="true">' + ico(opc.icono || 'chart', 18) + '</span></span>' +
      '<b class="kpi-val' + (String(valor).length > 10 ? ' kpi-val-long' : '') + '">' + esc(valor) + '</b>' +
      (opc.nota ? '<small>' + esc(opc.nota) + '</small>' : '') + '</' + tag + '>';
  }
  function filtros(conDepto, estado) {
    const s = estado || st;
    return '<div class="filter-row"><div class="seg seg-sm" role="radiogroup" aria-label="Período">' + PERIODOS.map(p =>
      '<label><input type="radio" name="periodo" value="' + p[0] + '"' + (s.dias === p[0] ? ' checked' : '') + '><span>' + p[1] + '</span></label>').join('') + '</div>' +
      (conDepto ? '<select data-x="depto" aria-label="Departamento"><option value="">Todos los departamentos</option>' + [['COM', 'Comercial'], ['ALM', 'Almacén'], ['LIQ', 'Liquidaciones']].map(d => '<option value="' + d[0] + '"' + (s.departamento === d[0] ? ' selected' : '') + '>' + d[1] + '</option>').join('') + '</select>' : '') + '</div>';
  }
  function enlazarFiltros(el, recargar) {
    el.querySelectorAll('[name="periodo"]').forEach(i => i.addEventListener('change', () => { st.dias = i.value; recargar(); }));
    const d = el.querySelector('[data-x="depto"]');
    if (d) d.addEventListener('change', () => { st.departamento = d.value; recargar(); });
  }

  async function render(el) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'dashboard.gerencial') && !P.puede(u, 'dashboard.operativo')) throw C.noAutorizado();
    const gerencial = P.puede(u, 'dashboard.gerencial');
    APD.app.titulo(u.rol === 'OPERADOR_TRANSPORTES' ? 'Dashboard operativo' : u.rol === 'GERENCIA' ? 'Dashboard gerencial' : 'Dashboard');
    const d = await APD.api.dashboard({ dias: st.dias === '0' ? null : st.dias, departamento: st.departamento });
    const k = d.kpis;
    const periodo = PERIODOS.find(p => p[0] === st.dias)[1];
    const vb = v => '#/bandeja?vista=' + v;
    let h = '<div class="page wide">' +
      '<div class="page-head page-hero"><div><p class="eyebrow">' + (gerencial ? 'Vista gerencial' : 'Vista operativa') + ' · Distrib. y Transp. Cárnico</p><h2>' + (u.rol === 'OPERADOR_TRANSPORTES' ? 'Dashboard operativo' : 'Indicadores de la mesa de servicio') + '</h2>' +
      '<p class="muted">Tickets creados en: ' + esc(periodo.toLowerCase()) + (st.departamento ? ' · ' + esc({ COM: 'Comercial', ALM: 'Almacén', LIQ: 'Liquidaciones' }[st.departamento]) : '') + '</p></div>' + filtros(true) + '</div>' +
      ui.demoNota('Indicadores calculados sobre datos ficticios de demostración; no representan la operación real.');

    if (d.mios && u.rol === 'OPERADOR_TRANSPORTES') {
      h += '<section class="card"><div class="card-head"><h3>' + ico('user-check', 18) + ' Mi trabajo</h3><a class="link" href="#/bandeja?vista=mios">Ver mis asignados</a></div>' +
        '<div class="kpi-grid kpi-grid-5">' +
        kpi('Mis tickets abiertos', F.num(d.mios.abiertos), { href: vb('mios') }) +
        kpi('Vencidos', F.num(d.mios.vencidos), { cls: d.mios.vencidos ? 'kpi-critical' : '', icono: 'alert', href: vb('vencidos') }) +
        kpi('Próximos a vencer', F.num(d.mios.proximos), { cls: d.mios.proximos ? 'kpi-warning' : '', icono: 'clock', href: vb('proximos') }) +
        kpi('Sin asignar en mi alcance', F.num(d.mios.sin_asignar_alcance), { href: vb('sin_asignar') }) +
        kpi('Resueltos por mí', F.num(d.mios.resueltos), { nota: 'en el período' }) + '</div>' +
        (d.mios.cola.length ? '<h4>Siguiente en mi cola (por SLA)</h4><div class="tcard-list">' + d.mios.cola.map(r => C.ticketCard(r)).join('') + '</div>' : '<p class="muted small">No tiene tickets abiertos asignados.</p>') +
        '</section>';
    }

    h += '<div class="kpi-grid">' +
      kpi('Tickets recibidos', F.num(k.total), { icono: 'inbox', href: vb('todos') }) +
      kpi('Nuevos', F.num(k.nuevos), { icono: 'plus', href: vb('nuevos') }) +
      kpi('Pendientes', F.num(k.pendientes), { icono: 'list', nota: k.sin_asignar + ' sin asignar' }) +
      kpi('En proceso', F.num(k.en_proceso), { icono: 'play', href: vb('proceso') }) +
      kpi('En espera', F.num(k.en_espera), { icono: 'pause', href: vb('espera') }) +
      kpi('Resueltos', F.num(k.resueltos), { icono: 'check', nota: 'por confirmar', href: vb('resueltos') }) +
      kpi('Cerrados', F.num(k.cerrados), { icono: 'check-circle', href: vb('cerrados') }) +
      kpi('Vencidos', F.num(k.vencidos), { cls: k.vencidos ? 'kpi-critical' : '', icono: 'alert', nota: k.proximos + ' próximos a vencer', href: vb('vencidos') }) +
      kpi('Cumplimiento SLA', k.cumplimiento == null ? '—' : F.pct(k.cumplimiento), { icono: 'check-circle', nota: 'resolución · ' + k.cumplimiento_base + ' medidos', cls: k.cumplimiento != null && k.cumplimiento < 0.8 ? 'kpi-warning' : '' }) +
      kpi('Prom. primera respuesta', F.duracion(k.prom_respuesta), { icono: 'message', nota: 'horas hábiles' }) +
      kpi('Prom. asignación', F.duracion(k.prom_asignacion), { icono: 'user-check', nota: 'horas hábiles' }) +
      kpi('Prom. resolución', F.duracion(k.prom_resolucion), { icono: 'clock', nota: 'horas hábiles' }) +
      '</div>';

    h += '<div class="chart-grid">' +
      '<section class="card span-2 chart-card"><div class="card-head"><h3>' + ico('trend', 18) + ' Tendencia semanal</h3><span class="muted small">Tickets creados y resueltos por semana</span></div>' +
        ui.lineas(d.tendencia, [{ clave: 'creados', label: 'Creados' }, { clave: 'resueltos', label: 'Resueltos' }], { titulo: 'Tendencia semanal de tickets' }) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('building', 18) + ' Solicitudes por departamento</h3>' + ui.barras(d.por_departamento) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('layers', 18) + ' Tickets por estado</h3>' + ui.barras(d.por_estado) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('flag', 18) + ' Tickets por prioridad</h3>' + ui.barras(d.por_prioridad) + '</section>' +
      '<section class="card chart-card"><h3>' + ico('list', 18) + ' Categorías más solicitadas</h3>' + ui.barras(d.por_categoria) + '</section>' +
      '</div>';

    if (gerencial || u.rol === 'OPERADOR_TRANSPORTES') {
      h += '<section class="card"><div class="card-head"><h3>' + ico('users', 18) + ' Productividad por responsable</h3><span class="muted small">Atendidos = resueltos en el período</span></div>' +
        (d.por_responsable.length ? '<div class="table-wrap"><table class="table"><thead><tr><th>Responsable</th><th class="num">Atendidos</th><th class="num">Pendientes</th><th class="num">Vencidos</th><th class="num">Prom. resolución</th><th>Carga</th></tr></thead><tbody>' +
          d.por_responsable.map(r => {
            const max = Math.max(1, ...d.por_responsable.map(x => x.pendientes));
            return '<tr><td>' + ui.avatar(r.nombre, 'xs') + ' ' + esc(r.nombre) + (!r.disponible ? ' ' + ui.chip('No disponible', 'chip-warn') : '') + (!r.activo ? ' ' + ui.chip('Inactivo', 'chip-muted') : '') + '</td><td class="num">' + r.atendidos + '</td><td class="num">' + r.pendientes + '</td><td class="num">' + (r.vencidos ? '<b class="neg">' + r.vencidos + '</b>' : '0') + '</td><td class="num">' + esc(F.duracion(r.prom_resolucion)) + '</td>' +
              '<td class="load-cell"><span class="hbar-track"><span class="hbar-fill" style="width:' + (r.pendientes / max * 100).toFixed(0) + '%"></span></span></td></tr>';
          }).join('') + '</tbody></table></div>' : '<p class="muted small">Sin datos en el período.</p>') + '</section>';
      const rec = d.recurrentes;
      const lista = (titulo, items) => '<div><h4>' + titulo + '</h4>' + (items.length ? ui.barras(items) : '<p class="muted small">Sin casos repetidos.</p>') + '</div>';
      h += '<section class="card"><div class="card-head"><h3>' + ico('rotate', 18) + ' Casos recurrentes</h3><span class="muted small">2 o más tickets en el período</span></div><div class="chart-grid three">' +
        lista('Clientes', rec.clientes) + lista('Rutas', rec.rutas) + lista('Choferes', rec.choferes) + '</div>' +
        '<p class="help">Un chofer recurrente indica volumen de solicitudes asociadas, no responsabilidad.</p></section>';
    }
    el.innerHTML = h + '</div>';
    enlazarFiltros(el, () => render(el));
  }

  APD.pages.dashboard = { render, kpi, filtros, enlazarFiltros, st };
})();
