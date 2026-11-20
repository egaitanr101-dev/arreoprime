/* Portal de solicitantes: inicio, solicitudes del departamento y consulta de estado. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, E = APD.estados, C = APD.comun;

  /* ---------------- Inicio ---------------- */
  async function inicio(el) {
    const u = APD.state.usuario;
    if (!P.esSolicitante(u)) throw C.noAutorizado();
    APD.app.titulo('Inicio');
    const rows = await APD.api.tickets.listar();
    const abiertos = rows.filter(r => !r.anulado && E.ABIERTOS.includes(r.estado));
    const atencion = rows.filter(r => r.pendiente_info || r.estado === 'RESUELTO');
    el.innerHTML = '<div class="page">' +
      '<section class="hero"><p class="eyebrow">' + esc(u.depto_nombre) + '</p><h2>Hola, ' + esc(u.nombre.split(' ')[0]) + '</h2><p class="muted">¿Qué necesita de Transportes hoy?</p></section>' +
      '<div class="quick-grid">' +
      '<a class="tile tile-primary" href="#/crear">' + ico('plus', 26) + '<b>Crear solicitud</b><span>Tres pasos, menos de un minuto</span></a>' +
      '<a class="tile" href="#/solicitudes">' + ico('list', 26) + '<b>Solicitudes del departamento</b><span>' + abiertos.length + ' abiertas · ' + rows.length + ' en total</span></a>' +
      '<a class="tile" href="#/consultar">' + ico('search', 26) + '<b>Consultar estado</b><span>Por número de ticket, factura o ruta</span></a>' +
      '</div>' +
      (atencion.length ? '<section class="card"><div class="card-head"><h3>' + ico('alert', 18) + ' Requieren atención de su departamento</h3></div><div class="tcard-list">' +
        atencion.slice(0, 6).map(r => C.ticketCard(r, { depto: false })).join('') + '</div></section>' : '') +
      '<section class="card"><div class="card-head"><h3>Actividad reciente</h3><a class="link" href="#/solicitudes">Ver todas</a></div>' +
      (rows.length ? '<div class="tcard-list">' + rows.slice(0, 6).map(r => C.ticketCard(r, { depto: false })).join('') + '</div>' : ui.vacio('inbox', 'Aún no hay solicitudes', 'Cree la primera solicitud de su departamento.')) +
      '</section></div>';
  }

  /* ---------------- Solicitudes del departamento ---------------- */
  const st = { grupo: 'abiertas', mias: true, q: '' };
  const GRUPOS = {
    todas: { label: 'Todas', f: () => true },
    abiertas: { label: 'Abiertas', f: r => E.ABIERTOS.includes(r.estado) },
    atencion: { label: 'Requieren atención', f: r => r.pendiente_info || r.estado === 'RESUELTO' },
    resueltas: { label: 'Resueltas', f: r => r.estado === 'RESUELTO' },
    cerradas: { label: 'Cerradas', f: r => r.estado === 'CERRADO' },
    rechazadas: { label: 'Rechazadas', f: r => r.estado === 'RECHAZADO' }
  };
  async function solicitudes(el) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'ticket.ver_departamento')) throw C.noAutorizado();
    APD.app.titulo('Solicitudes del departamento');
    const rows = await APD.api.tickets.listar();
    const dibujar = () => {
      const n = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
      const base = rows.filter(r => !st.mias || r.solicitante_id === u.id);
      const lista = base.filter(GRUPOS[st.grupo].f).filter(r => !st.q || [r.numero, r.asunto, r.categoria_nombre, r.cliente_nombre, r.ruta_id, r.factura].some(v => n(v).includes(n(st.q))));
      el.innerHTML = '<div class="page">' +
        '<div class="page-head"><div><h2>Solicitudes de ' + esc(u.depto_nombre) + '</h2><p class="muted">Visibilidad por departamento: aquí ve las solicitudes de todos sus compañeros de ' + esc(u.depto_nombre) + '.</p></div>' +
        '<div class="page-actions"><button type="button" class="btn btn-secondary" data-x="csv">' + ico('download', 16) + '<span>Exportar CSV</span></button><a class="btn btn-primary" href="#/crear">' + ico('plus', 16) + '<span>Crear solicitud</span></a></div></div>' +
        '<div class="toolbar"><div class="chips" role="tablist">' + Object.keys(GRUPOS).map(k => {
          const c = base.filter(GRUPOS[k].f).length;
          return '<button type="button" role="tab" class="fchip' + (st.grupo === k ? ' on' : '') + '" data-g="' + k + '" aria-selected="' + (st.grupo === k) + '">' + GRUPOS[k].label + ' <span>' + c + '</span></button>';
        }).join('') + '</div>' +
        '<label class="switch"><input type="checkbox" data-x="mias"' + (st.mias ? ' checked' : '') + '><span>Solo creadas por mí</span></label>' +
        '<div class="search-inline">' + ico('search', 16) + '<input type="search" data-x="q" placeholder="Filtrar por número, asunto, cliente, ruta…" value="' + esc(st.q) + '" aria-label="Filtrar"></div></div>' +
        (lista.length ? '<div class="tcard-list">' + lista.map(r => C.ticketCard(r, { depto: false })).join('') + '</div>' : '<div class="card">' + ui.vacio('inbox', 'No hay solicitudes con estos filtros', st.mias ? 'Desactive «Solo creadas por mí» para ver las de todo el departamento.' : '') + '</div>') +
        '</div>';
      el.querySelectorAll('[data-g]').forEach(b => b.addEventListener('click', () => { st.grupo = b.dataset.g; dibujar(); }));
      el.querySelector('[data-x="mias"]').addEventListener('change', e => { st.mias = e.target.checked; dibujar(); });
      const q = el.querySelector('[data-x="q"]');
      q.addEventListener('input', () => { st.q = q.value; clearTimeout(q._t); q._t = setTimeout(() => { dibujar(); const nq = el.querySelector('[data-x="q"]'); nq.focus(); nq.setSelectionRange(nq.value.length, nq.value.length); }, 250); });
      el.querySelector('[data-x="csv"]').addEventListener('click', async () => {
        try {
          const rep = await APD.api.reportes.generar('historial', {});
          ui.descargar('solicitudes_' + u.departamento.toLowerCase() + '_' + F.fechaISO(Date.now()) + '.csv', ui.aCSV(rep.columnas, rep.filas), 'text/csv;charset=utf-8');
          await APD.api.reportes.registrarExportacion('historial', 'CSV', rep.filas.length);
          ui.toast('Exportación generada (' + rep.filas.length + ' filas, solo ' + u.depto_nombre + ')');
        } catch (e) { ui.toast(e.message, 'error'); }
      });
    };
    dibujar();
  }

  /* ---------------- Consultar estado ---------------- */
  async function consultar(el, r) {
    APD.app.titulo('Consultar estado');
    const q0 = r.query.q || '';
    el.innerHTML = '<div class="page narrow">' +
      '<div class="page-head"><div><h2>Consultar estado</h2><p class="muted">Busque por número de ticket, factura, pedido, ruta o cliente.</p></div></div>' +
      '<form class="card search-big" data-x="f">' + ico('search', 20) + '<input type="search" name="q" value="' + esc(q0) + '" placeholder="Ej.: TS-2026-000123, FE-123456, R-105" aria-label="Buscar" autofocus>' +
      '<button class="btn btn-primary" type="submit">Consultar</button></form><div data-x="res"></div></div>';
    const res = el.querySelector('[data-x="res"]');
    const buscar = async q => {
      if (!q) { res.innerHTML = ''; return; }
      const filas = await APD.api.tickets.buscar(q);
      res.innerHTML = filas.length ? filas.map(t => '<a class="card status-card" href="#/ticket/' + esc(t.id) + '">' +
        '<div class="status-top"><span class="tnum">' + esc(t.numero) + '</span>' + ui.badgeEstado(t.estado) + '</div>' +
        '<h3>' + esc(t.asunto) + '</h3><p class="muted small">' + esc(t.categoria_nombre) + ' · ' + esc(t.depto_nombre) + ' · creado ' + esc(F.fecha(t.creado_at)) + '</p>' +
        ui.stepper(t) +
        '<p class="small">' + (t.responsable_nombre ? 'Responsable: <b>' + esc(t.responsable_nombre) + '</b>' : 'Pendiente de asignación') +
        (t.motivo_espera_nombre ? ' · En espera: ' + esc(t.motivo_espera_nombre) : '') + '</p>' +
        (t.pendiente_info ? '<p class="alert alert-warn">' + ico('help', 16) + '<span>Transportes solicitó información. Abra el ticket para responder.</span></p>' : '') +
        '</a>').join('') : '<div class="card">' + ui.vacio('search', 'Sin resultados', 'Solo se muestran tickets a los que su usuario tiene acceso.') + '</div>';
    };
    el.querySelector('[data-x="f"]').addEventListener('submit', e => { e.preventDefault(); buscar(e.target.q.value.trim()); });
    buscar(q0);
  }

  APD.pages.portal = { render: inicio };
  APD.pages.solicitudes = { render: solicitudes };
  APD.pages.consultar = { render: consultar };
})();
