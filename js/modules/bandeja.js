/* Bandeja central de Transportes (también consulta de solo lectura para Gerencia). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, E = APD.estados, C = APD.comun;

  // Orden pensado para que lo crítico (prioridad, estado, SLA, responsable) quede siempre a la vista.
  const COLS = [
    { k: 'numero', label: 'Ticket', fijo: true },
    { k: 'asunto', label: 'Asunto / categoría' },
    { k: 'depto_nombre', label: 'Departamento' },
    { k: 'prioridad', label: 'Prioridad', sort: 'prioridad_orden' },
    { k: 'estado', label: 'Estado', sort: 'estado_orden' },
    { k: 'sla', label: 'SLA', sort: 'sla_orden' },
    { k: 'responsable_nombre', label: 'Responsable' },
    { k: 'creado_at', label: 'Creado' },
    { k: 'transcurrido_min', label: 'Tiempo' },
    { k: 'fecha_requerida', label: 'Requerida' },
    { k: 'solicitante_nombre', label: 'Solicitante' },
    { k: 'categoria_nombre', label: 'Categoría', oculta: true },
    { k: 'tipo_nombre', label: 'Tipo de gestión', oculta: true }
  ];
  const abierto = r => E.ABIERTOS.includes(r.estado);
  const VISTAS = {
    todos: { label: 'Todos', f: () => true },
    mios: { label: 'Mis asignados', f: (r, u) => r.responsable_id === u.id && !E.TERMINALES.includes(r.estado), solo: 'transportes' },
    nuevos: { label: 'Nuevos', f: r => r.estado === 'NUEVO' },
    sin_asignar: { label: 'Sin asignar', f: r => !r.responsable_id && abierto(r) },
    revision: { label: 'En revisión', f: r => r.estado === 'EN_REVISION' },
    asignados: { label: 'Asignados', f: r => r.estado === 'ASIGNADO' },
    proceso: { label: 'En proceso', f: r => r.estado === 'EN_PROCESO' },
    espera: { label: 'En espera', f: r => r.estado === 'EN_ESPERA' },
    proximos: { label: 'Próximos a vencer', f: r => r.sla.global === 'amarillo' },
    vencidos: { label: 'Vencidos', f: r => r.sla.global === 'rojo' },
    resueltos: { label: 'Resueltos', f: r => r.estado === 'RESUELTO' },
    cerrados: { label: 'Cerrados', f: r => r.estado === 'CERRADO' },
    rechazados: { label: 'Rechazados', f: r => r.estado === 'RECHAZADO' }
  };
  const FILTROS_VACIOS = { departamento: '', categoria: '', prioridad: '', responsable: '', estado: '', tipo: '', ruta: '', cliente: '', desde: '', hasta: '', anulados: false };
  const st = { vista: 'todos', q: '', f: Object.assign({}, FILTROS_VACIOS), orden: { k: 'creado_at', dir: -1 }, pagina: 1, porPagina: 20, avanzado: false };

  function columnasVisibles() {
    try {
      const g = JSON.parse(localStorage.getItem('apd.bandeja.columnas') || 'null');
      if (Array.isArray(g)) return COLS.filter(c => c.fijo || g.includes(c.k));
    } catch (e) { /* preferencia no disponible */ }
    return COLS.filter(c => !c.oculta);
  }
  function guardarColumnas(keys) { try { localStorage.setItem('apd.bandeja.columnas', JSON.stringify(keys)); } catch (e) { /* modo privado */ } }

  function slaCorto(sla) {
    if (!sla) return '';
    const f = sla.foco;
    let txt = APD.sla.SEMAFORO[sla.global];
    if (f && f.restante != null) txt = f.restante >= 0 ? F.duracion(f.restante) : '+' + F.duracion(-f.restante);
    return '<span class="sla sla-' + sla.global + '" title="' + esc(APD.sla.SEMAFORO[sla.global] + ' — ' + APD.sla.textoFoco(sla)) + '"><i class="sla-dot"></i><span>' + esc(txt) + '</span>' + (sla.pausado ? ico('pause', 12) : '') + '</span>';
  }

  function celda(c, r, u) {
    switch (c.k) {
      case 'numero': return '<a class="tnum" href="#/ticket/' + esc(r.id) + '">' + esc(r.numero) + '</a>' + (r.pendiente_info ? ' <span title="Esperando respuesta del solicitante">' + ico('help', 14) + '</span>' : '') + (r.anulado ? ' ' + ui.chip('Anulado', 'chip-muted') : '');
      case 'creado_at': return '<span title="' + esc(F.fecha(r.creado_at)) + '">' + esc(F.fechaCorta(r.creado_at)) + '<small class="muted block">' + esc(F.hora(r.creado_at)) + '</small></span>';
      case 'solicitante_nombre': return '<span class="trunc trunc-sm" title="' + esc(r.solicitante_nombre) + '">' + esc(r.solicitante_nombre) + '</span>' + (r.canal === 'ASISTIDO' ? '<small class="muted block" title="Registro asistido por ' + esc(r.registrado_por_nombre) + '">' + ico('user-check', 12) + ' asistido</small>' : '');
      case 'asunto': return '<span class="trunc" title="' + esc(r.asunto) + '">' + esc(r.asunto) + '</span><small class="muted trunc" title="' + esc(r.tipo_nombre + ' · ' + r.categoria_nombre) + '">' + esc(r.categoria_nombre) + '</small>';
      case 'prioridad': return ui.badgePrioridad(r.prioridad);
      case 'responsable_nombre':
        if (!r.responsable_nombre) {
          return P.puede(u, 'ticket.asignar') && abierto(r) && !r.anulado
            ? '<button type="button" class="btn btn-ghost sm" data-asignar="' + esc(r.id) + '">' + ico('user-plus', 14) + '<span>Asignar</span></button>'
            : '<span class="muted">Sin asignar</span>';
        }
        return '<span class="trunc trunc-sm" title="' + esc(r.responsable_nombre) + '">' + esc(r.responsable_nombre) + '</span>' + (r.responsable_alerta && abierto(r) ? ui.chip(r.responsable_alerta, 'chip-warn') : '');
      case 'estado': return ui.badgeEstado(r.estado) + (r.motivo_espera_nombre ? '<small class="muted block">' + esc(r.motivo_espera_nombre) + '</small>' : '');
      case 'transcurrido_min': return esc(F.duracion(r.transcurrido_min));
      case 'fecha_requerida': return esc(r.fecha_requerida ? F.fechaDeISO(r.fecha_requerida) : '—');
      case 'sla': return r.anulado ? '<span class="muted">—</span>' : slaCorto(r.sla);
      default: return esc(r[c.k] == null ? '—' : r[c.k]);
    }
  }

  async function render(el, r) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'ticket.ver_todos')) throw C.noAutorizado();
    const vista = VISTAS[r.query.vista] ? r.query.vista : 'todos';
    if (r.query.q !== undefined) st.q = r.query.q;
    else if (vista !== st.vista) st.q = '';
    if (vista !== st.vista) st.pagina = 1;
    st.vista = vista;
    const [rows, cats] = await Promise.all([APD.api.tickets.listar(), APD.api.catalogos()]);
    rows.forEach(x => { x.estado_orden = E.ORDEN.indexOf(x.estado); });
    const esT = P.esTransportes(u);
    APD.app.titulo(u.rol === 'GERENCIA' ? 'Consulta de tickets' : VISTAS[vista].label === 'Todos' ? 'Bandeja central' : VISTAS[vista].label);

    function filtrar() {
      const n = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
      const q = n(st.q).trim(), f = st.f;
      const desde = f.desde ? F.desdeFechaCR(f.desde) : null, hasta = f.hasta ? F.desdeFechaCR(f.hasta) + 86400e3 : null;
      return rows.filter(x => (f.anulados || !x.anulado))
        .filter(x => !f.departamento || x.departamento === f.departamento)
        .filter(x => !f.categoria || x.categoria_id === f.categoria)
        .filter(x => !f.prioridad || x.prioridad === f.prioridad)
        .filter(x => !f.responsable || (f.responsable === '__none' ? !x.responsable_id : x.responsable_id === f.responsable))
        .filter(x => !f.estado || x.estado === f.estado)
        .filter(x => !f.tipo || x.tipo_id === f.tipo)
        .filter(x => !f.ruta || x.ruta_id === f.ruta)
        .filter(x => !f.cliente || x.cliente_id === f.cliente)
        .filter(x => (desde == null || x.creado_at >= desde) && (hasta == null || x.creado_at < hasta))
        .filter(x => !q || [x.numero, x.asunto, x.cliente_nombre, x.cliente_id, x.ruta_id, x.ruta_nombre, x.factura, x.pedido, x.solicitante_nombre, x.categoria_nombre, x.descripcion].some(v => n(v).includes(q)));
    }

    function dibujar() {
      const base = filtrar();
      const lista = base.filter(x => VISTAS[st.vista].f(x, u));
      const k = COLS.find(c => c.k === st.orden.k);
      const sk = (k && k.sort) || st.orden.k;
      lista.sort((a, b) => {
        const va = a[sk], vb = b[sk];
        if (va == null && vb == null) return 0;
        if (va == null) return 1;
        if (vb == null) return -1;
        return (va > vb ? 1 : va < vb ? -1 : 0) * st.orden.dir;
      });
      const paginas = Math.max(1, Math.ceil(lista.length / st.porPagina));
      st.pagina = Math.min(st.pagina, paginas);
      const pag = lista.slice((st.pagina - 1) * st.porPagina, st.pagina * st.porPagina);
      const cols = columnasVisibles();
      const nFiltros = Object.keys(FILTROS_VACIOS).filter(x => st.f[x]).length;
      const chips = Object.keys(VISTAS).filter(v => !(VISTAS[v].solo === 'transportes' && !esT));

      let carga = '';
      if (st.vista === 'sin_asignar' && P.puede(u, 'ticket.asignar')) {
        const ops = cats.responsables.filter(x => x.activo);
        const max = Math.max(1, ...ops.map(o => rows.filter(x => x.responsable_id === o.id && abierto(x) && !x.anulado).length));
        carga = '<section class="card"><div class="card-head"><h3>' + ico('users', 18) + ' Carga de trabajo actual</h3><span class="muted small">Tickets abiertos por responsable</span></div><div class="load-grid">' +
          ops.map(o => {
            const n = rows.filter(x => x.responsable_id === o.id && abierto(x) && !x.anulado).length;
            return '<div class="load-item">' + ui.avatar(o.nombre, 'sm') + '<div class="load-body"><div class="load-top"><b>' + esc(o.nombre) + '</b><span>' + n + '</span></div>' +
              '<div class="hbar-track"><span class="hbar-fill" style="width:' + (n / max * 100).toFixed(0) + '%"></span></div>' +
              '<small class="muted">' + (o.rol === 'SUPERVISOR_TRANSPORTES' ? 'Supervisión' : 'Alcance: ' + (o.alcance.join(', ') || '—')) + (o.disponible ? '' : ' · <b class="warn-text">No disponible</b>') + '</small></div></div>';
          }).join('') + '</div></section>';
      }

      el.innerHTML = '<div class="page wide">' +
        '<div class="page-head"><div><h2>' + esc(u.rol === 'GERENCIA' ? 'Consulta de tickets' : 'Bandeja central de Transportes') + '</h2>' +
        '<p class="muted">' + lista.length + ' ticket' + (lista.length === 1 ? '' : 's') + ' · Comercial, Almacén y Liquidaciones' + (u.rol === 'GERENCIA' ? ' · solo lectura' : '') + '</p></div>' +
        '<div class="page-actions">' + (P.puede(u, 'ticket.registro_asistido') ? '<a class="btn btn-secondary" href="#/crear">' + ico('plus', 16) + '<span>Registro asistido</span></a>' : '') + '</div></div>' +
        carga +
        '<div class="chips scroll-x" role="tablist" aria-label="Filtros rápidos">' + chips.map(v => {
          const n = base.filter(x => VISTAS[v].f(x, u)).length;
          return '<a role="tab" class="fchip' + (v === st.vista ? ' on' : '') + (v === 'vencidos' && n ? ' fchip-danger' : v === 'proximos' && n ? ' fchip-warn' : '') + '" href="#/bandeja?vista=' + v + '" aria-selected="' + (v === st.vista) + '">' + VISTAS[v].label + ' <span>' + n + '</span></a>';
        }).join('') + '</div>' +
        '<div class="toolbar">' +
        '<div class="search-inline grow">' + ico('search', 16) + '<input type="search" data-x="q" value="' + esc(st.q) + '" placeholder="Número, cliente, ruta, factura, solicitante o palabra clave" aria-label="Buscar en la bandeja"></div>' +
        '<button type="button" class="btn btn-secondary' + (st.avanzado ? ' on' : '') + '" data-x="avanzado" aria-expanded="' + st.avanzado + '">' + ico('filter', 16) + '<span>Filtros' + (nFiltros ? ' (' + nFiltros + ')' : '') + '</span></button>' +
        '<button type="button" class="btn btn-secondary hide-mobile" data-x="columnas">' + ico('columns', 16) + '<span>Columnas</span></button></div>' +
        (st.avanzado ? panelFiltros(cats) : '') +
        '<div class="card table-card">' +
        (pag.length ? '<div class="table-wrap hide-mobile"><table class="table"><thead><tr>' + cols.map(c => {
          const on = st.orden.k === c.k;
          return '<th scope="col"' + (on ? ' aria-sort="' + (st.orden.dir > 0 ? 'ascending' : 'descending') + '"' : '') + '><button type="button" class="th-sort' + (on ? ' on' : '') + '" data-sort="' + c.k + '">' + c.label + (on ? '<span class="sort-ic' + (st.orden.dir > 0 ? ' asc' : '') + '">' + ico('chevron-down', 12) + '</span>' : '') + '</button></th>';
        }).join('') + '</tr></thead><tbody>' +
          pag.map(x => '<tr data-id="' + esc(x.id) + '" class="' + (x.sla.global === 'rojo' && !x.anulado ? 'row-danger' : '') + (x.anulado ? ' row-muted' : '') + '">' + cols.map(c => '<td class="c-' + c.k + '">' + celda(c, x, u) + '</td>').join('') + '</tr>').join('') +
          '</tbody></table></div>' +
          '<div class="tcard-list only-mobile">' + pag.map(x => C.ticketCard(x)).join('') + '</div>'
          : ui.vacio('inbox', 'No hay tickets en esta vista', nFiltros || st.q ? 'Pruebe quitando filtros o la búsqueda.' : '')) +
        (lista.length > st.porPagina || st.pagina > 1 ? '<div class="pager"><span class="muted small">Mostrando ' + ((st.pagina - 1) * st.porPagina + 1) + '–' + Math.min(st.pagina * st.porPagina, lista.length) + ' de ' + lista.length + '</span>' +
          '<div><button type="button" class="btn-icon" data-pag="-1"' + (st.pagina <= 1 ? ' disabled' : '') + ' aria-label="Página anterior">' + ico('chevron-left', 18) + '</button>' +
          '<span class="small">Página ' + st.pagina + ' de ' + paginas + '</span>' +
          '<button type="button" class="btn-icon" data-pag="1"' + (st.pagina >= paginas ? ' disabled' : '') + ' aria-label="Página siguiente">' + ico('chevron-right', 18) + '</button></div>' +
          '<label class="small">Por página <select data-x="porpag">' + [20, 50, 100].map(n => '<option' + (n === st.porPagina ? ' selected' : '') + '>' + n + '</option>').join('') + '</select></label></div>' : '') +
        '</div></div>';

      enlazar(cats);
      if (document.activeElement === document.body && st._foco) {
        const q = el.querySelector('[data-x="q"]');
        q.focus(); q.setSelectionRange(q.value.length, q.value.length); st._foco = false;
      }
    }

    function panelFiltros(cats) {
      const sel = (k, label, opts) => '<div class="field"><label for="bf_' + k + '">' + label + '</label><select id="bf_' + k + '" data-f="' + k + '"><option value="">Todos</option>' +
        opts.map(o => '<option value="' + esc(o[0]) + '"' + (st.f[k] === o[0] ? ' selected' : '') + '>' + esc(o[1]) + '</option>').join('') + '</select></div>';
      const catsF = cats.categorias.filter(c => !st.f.departamento || c.departamento === st.f.departamento);
      return '<section class="card filters">' +
        '<div class="filters-grid">' +
        sel('departamento', 'Departamento', [['COM', 'Comercial'], ['ALM', 'Almacén'], ['LIQ', 'Liquidaciones']]) +
        sel('categoria', 'Categoría', catsF.map(c => [c.id, c.nombre + (st.f.departamento ? '' : ' (' + c.departamento + ')')])) +
        sel('prioridad', 'Prioridad', ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'].map(p => [p, ui.PRIORIDADES[p][0]])) +
        sel('responsable', 'Responsable', [['__none', 'Sin asignar']].concat(cats.responsables.map(x => [x.id, x.nombre]))) +
        sel('estado', 'Estado', E.ORDEN.map(e => [e, E.ESTADOS[e].label])) +
        sel('tipo', 'Tipo de gestión', cats.tipos.map(t => [t.id, t.nombre])) +
        sel('ruta', 'Ruta', cats.rutas.map(x => [x.id, x.id + ' · ' + x.nombre])) +
        sel('cliente', 'Cliente', cats.clientes.map(x => [x.id, x.nombre])) +
        '<div class="field"><label for="bf_desde">Creado desde</label><input type="date" id="bf_desde" data-f="desde" value="' + esc(st.f.desde) + '"></div>' +
        '<div class="field"><label for="bf_hasta">Creado hasta</label><input type="date" id="bf_hasta" data-f="hasta" value="' + esc(st.f.hasta) + '"></div>' +
        '</div><div class="filters-foot"><label class="switch"><input type="checkbox" data-f="anulados"' + (st.f.anulados ? ' checked' : '') + '><span>Incluir anulados</span></label>' +
        '<button type="button" class="link" data-x="limpiar">Limpiar filtros</button></div></section>';
    }

    function enlazar() {
      const q = el.querySelector('[data-x="q"]');
      q.addEventListener('input', () => { clearTimeout(q._t); q._t = setTimeout(() => { st.q = q.value; st.pagina = 1; st._foco = true; dibujar(); }, 250); });
      el.querySelector('[data-x="avanzado"]').addEventListener('click', () => { st.avanzado = !st.avanzado; dibujar(); });
      el.querySelectorAll('[data-f]').forEach(i => i.addEventListener('change', () => {
        st.f[i.dataset.f] = i.type === 'checkbox' ? i.checked : i.value;
        if (i.dataset.f === 'departamento') st.f.categoria = '';
        st.pagina = 1; dibujar();
      }));
      const limpiar = el.querySelector('[data-x="limpiar"]');
      if (limpiar) limpiar.addEventListener('click', () => { st.f = Object.assign({}, FILTROS_VACIOS); st.pagina = 1; dibujar(); });
      el.querySelectorAll('[data-sort]').forEach(b => b.addEventListener('click', () => {
        const k = b.dataset.sort;
        st.orden = st.orden.k === k ? { k, dir: -st.orden.dir } : { k, dir: k === 'creado_at' || k === 'transcurrido_min' ? -1 : 1 };
        dibujar();
      }));
      el.querySelectorAll('[data-pag]').forEach(b => b.addEventListener('click', () => { st.pagina += Number(b.dataset.pag); dibujar(); }));
      const pp = el.querySelector('[data-x="porpag"]');
      if (pp) pp.addEventListener('change', () => { st.porPagina = Number(pp.value); st.pagina = 1; dibujar(); });
      const tb = el.querySelector('tbody');
      if (tb) tb.addEventListener('click', e => {
        const asig = e.target.closest('[data-asignar]');
        if (asig) { APD.pages.ticket.modalAsignar(asig.dataset.asignar, 'asignar', () => APD.app.refresh()); return; }
        if (e.target.closest('a,button')) return;
        const tr = e.target.closest('tr[data-id]');
        if (tr) APD.app.go('#/ticket/' + tr.dataset.id);
      });
      const colsBtn = el.querySelector('[data-x="columnas"]');
      if (colsBtn) colsBtn.addEventListener('click', () => {
        const vis = columnasVisibles().map(c => c.k);
        ui.modal({
          titulo: 'Columnas de la bandeja', subtitulo: 'Se guarda como preferencia en este navegador.', ancho: 'sm',
          cuerpo: '<div class="check-list">' + COLS.map(c => '<label class="check"><input type="checkbox" value="' + c.k + '"' + (vis.includes(c.k) ? ' checked' : '') + (c.fijo ? ' disabled' : '') + '><span>' + esc(c.label) + '</span></label>').join('') + '</div>',
          acciones: [{ label: 'Restablecer', accion: () => { try { localStorage.removeItem('apd.bandeja.columnas'); } catch (e) { /* */ } dibujar(); } },
            { label: 'Aplicar', clase: 'btn-primary', accion: m => { guardarColumnas(Array.from(m.querySelectorAll('input:checked')).map(i => i.value)); dibujar(); } }]
        });
      });
    }

    dibujar();
  }

  APD.pages.bandeja = { render };
})();
