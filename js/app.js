/* Arranque, enrutador por hash y estructura (sidebar + topbar) según el rol. */
(function () {
  'use strict';
  const F = APD.fmt, P = APD.permisos, ui = APD.ui, ico = APD.icon, esc = F.esc;
  APD.pages = APD.pages || {};
  const state = APD.state = { usuario: null };
  let shellDe = null;
  let renderId = 0;

  /* ---------- Tema (preferencia de interfaz: único uso de localStorage) ---------- */
  function leerTema() { try { return localStorage.getItem('apd.tema'); } catch (e) { return null; } }
  function aplicarTema(t) {
    if (t) document.documentElement.setAttribute('data-theme', t); else document.documentElement.removeAttribute('data-theme');
  }
  function temaActual() {
    const t = document.documentElement.getAttribute('data-theme');
    if (t) return t;
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  aplicarTema(leerTema());

  /* ---------- Navegación por rol ---------- */
  const it = (href, label, icon, extra) => Object.assign({ href, label, icon }, extra || {});
  function menu(u) {
    const g = [];
    const notif = it('#/notificaciones', 'Notificaciones', 'bell', { badge: true });
    switch (u.rol) {
      case 'SOLICITANTE':
        g.push({ items: [it('#/inicio', 'Inicio', 'home'), it('#/crear', 'Crear solicitud', 'plus'), it('#/solicitudes', 'Solicitudes del departamento', 'list'), it('#/consultar', 'Consultar estado', 'search')] });
        if (P.puede(u, 'financiero.ver')) g.push({ titulo: 'Liquidaciones', items: [it('#/liquidaciones', 'Diferencias e investigaciones', 'coins')] });
        g.push({ items: [notif] });
        break;
      case 'SUPERVISOR_LIQUIDACIONES':
        g.push({ items: [it('#/tablero-liquidaciones', 'Dashboard de Liquidaciones', 'grid')] });
        g.push({ titulo: 'Solicitudes', items: [it('#/crear', 'Crear solicitud', 'plus'), it('#/solicitudes', 'Solicitudes del departamento', 'list'), it('#/consultar', 'Consultar estado', 'search')] });
        g.push({ titulo: 'Control', items: [it('#/liquidaciones', 'Diferencias e investigaciones', 'coins'), it('#/reportes', 'Reportes', 'file'), notif] });
        break;
      case 'OPERADOR_TRANSPORTES':
        g.push({ items: [it('#/dashboard', 'Dashboard operativo', 'grid')] });
        g.push({ titulo: 'Tickets', items: [it('#/bandeja?vista=todos', 'Bandeja central', 'inbox'), it('#/bandeja?vista=mios', 'Mis asignados', 'user-check'), it('#/bandeja?vista=sin_asignar', 'Sin asignar', 'user-plus'), it('#/bandeja?vista=proceso', 'En proceso', 'play'), it('#/bandeja?vista=espera', 'En espera', 'pause'), it('#/bandeja?vista=resueltos', 'Resueltos', 'check-circle')] });
        g.push({ titulo: 'Más', items: (P.puede(u, 'investigacion.ver') ? [it('#/liquidaciones', 'Investigaciones', 'coins')] : []).concat([it('#/crear', 'Registro asistido', 'plus'), it('#/reportes', 'Reportes', 'file'), it('#/sla', 'Control SLA', 'clock'), notif]) });
        break;
      case 'SUPERVISOR_TRANSPORTES':
        g.push({ items: [it('#/dashboard', 'Dashboard', 'grid')] });
        g.push({ titulo: 'Tickets', items: [it('#/bandeja?vista=todos', 'Todos los tickets', 'inbox'), it('#/bandeja?vista=sin_asignar', 'Asignaciones', 'users'), it('#/bandeja?vista=vencidos', 'Vencidos', 'alert'), it('#/crear', 'Registro asistido', 'plus')] });
        g.push({ titulo: 'Control', items: [it('#/sla', 'SLA', 'clock'), it('#/liquidaciones', 'Investigaciones', 'coins'), it('#/tablero-liquidaciones', 'Dashboard de Liquidaciones', 'grid'), it('#/reportes', 'Reportes', 'file'), it('#/auditoria', 'Auditoría', 'shield'), notif] });
        break;
      case 'GERENCIA':
        g.push({ items: [it('#/dashboard', 'Dashboard gerencial', 'grid'), it('#/bandeja?vista=todos', 'Consulta de tickets', 'inbox'), it('#/liquidaciones', 'Liquidaciones', 'coins'), it('#/tablero-liquidaciones', 'Dashboard de Liquidaciones', 'grid'), it('#/reportes', 'Reportes', 'file'), it('#/sla', 'Cumplimiento SLA', 'clock'), notif] });
        break;
      case 'SUPERUSUARIO':
        g.push({ items: [it('#/dashboard', 'Dashboard', 'grid'), it('#/tablero-liquidaciones', 'Dashboard de Liquidaciones', 'coins')] });
        g.push({ titulo: 'Tickets', items: [it('#/bandeja?vista=todos', 'Todos los tickets', 'inbox'), it('#/bandeja?vista=sin_asignar', 'Asignaciones', 'users'), it('#/bandeja?vista=vencidos', 'Vencidos', 'alert'), it('#/crear', 'Registro asistido', 'plus')] });
        g.push({ titulo: 'Control', items: [it('#/liquidaciones', 'Investigaciones', 'search2'), it('#/sla', 'SLA y calendario', 'clock'), it('#/reportes', 'Reportes', 'file'), it('#/auditoria', 'Auditoría', 'shield'), notif] });
        g.push({ titulo: 'Administración', items: [it('#/admin/usuarios', 'Usuarios', 'users'), it('#/admin/permisos', 'Roles y permisos', 'shield'), it('#/admin/departamentos', 'Departamentos', 'building'), it('#/admin/categorias', 'Categorías', 'layers'), it('#/admin/configuracion', 'Configuración', 'settings')] });
        break;
      case 'ADMINISTRADOR':
        g.push({ titulo: 'Administración', items: [it('#/admin/usuarios', 'Usuarios', 'users'), it('#/admin/permisos', 'Roles y permisos', 'shield'), it('#/admin/departamentos', 'Departamentos', 'building'), it('#/admin/categorias', 'Categorías', 'layers'), it('#/admin/configuracion', 'Configuración', 'settings'), it('#/sla', 'SLA y calendario', 'clock'), it('#/auditoria', 'Auditoría', 'history')] });
        break;
      default: break;
    }
    // Respaldo: si el rol no tiene menú propio, se arma con sus permisos (nunca queda vacío)
    if (!g.length) {
      const items = [];
      if (P.puede(u, 'dashboard.gerencial') || P.puede(u, 'dashboard.operativo')) items.push(it('#/dashboard', 'Dashboard', 'grid'));
      if (P.puede(u, 'dashboard.liquidaciones')) items.push(it('#/tablero-liquidaciones', 'Dashboard de Liquidaciones', 'coins'));
      if (P.puede(u, 'ticket.ver_todos')) items.push(it('#/bandeja?vista=todos', 'Todos los tickets', 'inbox'));
      else if (P.puede(u, 'ticket.ver_departamento')) items.push(it('#/solicitudes', 'Solicitudes del departamento', 'list'));
      if (P.puede(u, 'ticket.crear') || P.puede(u, 'ticket.registro_asistido')) items.push(it('#/crear', 'Crear solicitud', 'plus'));
      if (P.puede(u, 'financiero.ver')) items.push(it('#/liquidaciones', 'Diferencias e investigaciones', 'coins'));
      if (P.puede(u, 'reporte.operativo') || P.puede(u, 'reporte.completo')) items.push(it('#/reportes', 'Reportes', 'file'));
      if (P.puede(u, 'sla.ver')) items.push(it('#/sla', 'SLA', 'clock'));
      if (P.puede(u, 'auditoria.operativa') || P.puede(u, 'auditoria.administrativa')) items.push(it('#/auditoria', 'Auditoría', 'shield'));
      if (P.puede(u, 'admin.usuarios')) items.push(it('#/admin/usuarios', 'Usuarios', 'users'));
      items.push(notif);
      g.push({ items });
    }
    // Misión, visión y valores: visible para todos
    g.push({ titulo: "Grupo CIISA", items: [it("#/empresa", "Nuestra empresa", "flag")] });
    return g;
  }

  function parse() {
    const h = location.hash.slice(1) || '/inicio';
    const [path, qs] = h.split('?');
    return { parts: path.split('/').filter(Boolean), query: Object.fromEntries(new URLSearchParams(qs || '')), path };
  }
  function claveRuta(href) {
    const [path, qs] = href.replace(/^#/, '').split('?');
    const q = new URLSearchParams(qs || '');
    return path + (path === '/bandeja' ? '?vista=' + (q.get('vista') || 'todos') : '');
  }

  /* ---------- Estructura ---------- */
  function asegurarShell() {
    const u = state.usuario;
    if (shellDe === u.id && document.getElementById('main')) return;
    shellDe = u.id;
    const app = document.getElementById('app');
    const buscador = u.rol !== 'ADMINISTRADOR';
    const modo = APD.api.modo;
    const banner = modo === 'DEMO'
      ? '<div class="demo-banner" role="note">' + ico('info', 16) +
        '<span><b>MODO DEMOSTRACIÓN</b> · Datos ficticios en memoria: se pierden al recargar la página.</span>' +
        '<span class="demo-actions"><button type="button" class="link" data-act="reset">Reiniciar datos</button>' +
        '<button type="button" class="link" data-act="switch">Cambiar de usuario</button></span></div>'
      : modo === 'LOCAL'
        ? '<div class="demo-banner local-banner" role="note">' + ico('info', 16) +
          '<span><b>ENTORNO LOCAL DE PRUEBAS</b> · PostgreSQL en este equipo con las reglas de seguridad reales. Datos de prueba.</span>' +
          '<span class="demo-actions"><button type="button" class="link" data-act="switch">Cambiar de usuario</button></span></div>'
        : '';
    app.innerHTML =
      '<div class="shell">' +
      '<aside class="sidebar" id="sidebar" aria-label="Navegación principal">' +
      '<div class="brand"><img class="brand-logo" src="assets/logo-el-arreo.png" alt="El Arreo"><span class="brand-text"><b>ArreoPrime</b><small>TRANSPORTES · SERVICIO · LOGÍSTICA</small></span></div>' +
      '<nav class="nav">' + menu(u).map(g => (g.titulo ? '<div class="nav-group">' + esc(g.titulo) + '</div>' : '') +
        g.items.map(i => '<a class="nav-item" href="' + i.href + '" data-clave="' + esc(claveRuta(i.href)) + '">' + ico(i.icon, 18) + '<span>' + esc(i.label) + '</span>' + (i.badge ? '<span class="nav-badge" data-badge hidden></span>' : '') + '</a>').join('')).join('') + '</nav>' +
      '<div class="sidebar-user">' + ui.avatar(u.nombre) + '<div><b>' + esc(u.nombre) + '</b><small>' + esc(P.etiquetaRol(u.rol, u.departamento)) + ' · ' + esc(u.depto_nombre) + '</small></div>' +
      '<button type="button" class="btn-icon" data-act="switch" aria-label="Cerrar sesión" title="Cerrar sesión">' + ico('log-out', 18) + '</button></div>' +
      '</aside><div class="scrim" data-act="close-nav"></div>' +
      '<div class="main-col">' + banner + '<header class="topbar">' +
      '<button type="button" class="btn-icon only-mobile" data-act="open-nav" aria-label="Abrir menú">' + ico('menu', 20) + '</button>' +
      '<img class="topbar-logo" src="assets/logo-el-arreo.png" alt="El Arreo">' +
      '<h1 class="topbar-title" id="page-title"></h1>' +
      (buscador ? '<form class="topbar-search" role="search" data-act="buscar">' + ico('search', 16) + '<input type="search" name="q" placeholder="' + (P.esSolicitante(u) ? 'Número de ticket, factura o ruta' : 'Buscar ticket, cliente, ruta, factura…') + '" aria-label="Buscar"></form>' : '<span class="spacer"></span>') +
      '<button type="button" class="btn-icon" data-act="tema" aria-label="Cambiar tema" title="Cambiar tema claro/oscuro">' + ico(temaActual() === 'dark' ? 'sun' : 'moon', 18) + '</button>' +
      (u.rol !== 'ADMINISTRADOR' ? '<a class="btn-icon bell" href="#/notificaciones" aria-label="Notificaciones">' + ico('bell', 18) + '<span class="bell-dot" data-badge hidden></span></a>' : '') +
      '</header><main id="main" class="main" tabindex="-1"></main></div></div>' +
      (P.esSolicitante(u) ? '<a class="fab only-mobile" href="#/crear" aria-label="Crear solicitud">' + ico('plus', 24) + '</a>' : '');
  }

  function marcarActivo(r) {
    const clave = claveRuta('#' + r.path + (r.query.vista ? '?vista=' + r.query.vista : ''));
    document.querySelectorAll('.nav-item').forEach(a => a.classList.toggle('active', a.dataset.clave === clave));
  }
  async function actualizarBadge() {
    if (!state.usuario || state.usuario.rol === 'ADMINISTRADOR') return;
    try {
      const n = await APD.api.notificaciones.noLeidas();
      document.querySelectorAll('[data-badge]').forEach(b => { b.hidden = !n; b.textContent = n > 99 ? '99+' : String(n); });
    } catch (e) { /* sin sesión */ }
  }

  /* ---------- Rutas ---------- */
  const RUTAS = {
    inicio: (el, r) => APD.pages.portal.render(el, r),
    crear: (el, r) => APD.pages.crear.render(el, r),
    solicitudes: (el, r) => APD.pages.solicitudes.render(el, r),
    consultar: (el, r) => APD.pages.consultar.render(el, r),
    bandeja: (el, r) => APD.pages.bandeja.render(el, r),
    ticket: (el, r) => APD.pages.ticket.render(el, r),
    dashboard: (el, r) => APD.pages.dashboard.render(el, r),
    liquidaciones: (el, r) => APD.pages.liquidaciones.render(el, r),
    'tablero-liquidaciones': (el, r) => APD.pages.tableroLiq.render(el, r),
    reportes: (el, r) => APD.pages.reportes.render(el, r),
    sla: (el, r) => APD.pages.sla.render(el, r),
    admin: (el, r) => APD.pages.admin.render(el, r),
    auditoria: (el, r) => APD.pages.admin.render(el, { parts: ['admin', 'auditoria'], query: r.query }),
    notificaciones: (el, r) => APD.pages.notificaciones.render(el, r),
    empresa: el => APD.pages.empresa.render(el),
    'definir-clave': el => APD.pages.login.definirClave(el)
  };

  let retornoProcesado = false;
  async function render(opc) {
    const id = ++renderId;
    const app = document.getElementById('app');
    // Retorno desde un enlace de invitación o de recuperación de contraseña (Supabase Auth)
    if (!retornoProcesado) {
      retornoProcesado = true;
      try {
        const tipo = APD.api.sesion.procesarRetorno ? await APD.api.sesion.procesarRetorno() : null;
        if (tipo) { history.replaceState(null, '', location.pathname + location.search + (tipo === 'login' ? '#/inicio' : '#/definir-clave')); }
      } catch (e) {
        history.replaceState(null, '', location.pathname + location.search + '#/login');
        state.aviso = e.message;
      }
    }
    const r = parse();
    if (!state.usuario) {
      try { state.usuario = await APD.api.sesion.actual(); } catch (e) { state.usuario = null; if (e && e.message) state.aviso = e.message; }
    }
    if (!state.usuario || r.parts[0] === 'login') {
      if (r.parts[0] !== 'login') { location.replace('#/login'); return; }
      shellDe = null;
      document.title = 'Ingreso · ArreoPrime';
      await APD.pages.login.render(app);
      if (state.aviso) { ui.toast(state.aviso, 'error'); state.aviso = null; }
      return;
    }
    if (r.parts[0] === 'inicio' && state.usuario.rol !== 'SOLICITANTE') {
      location.replace(state.usuario.rol === 'ADMINISTRADOR' ? '#/admin/usuarios' : state.usuario.rol === 'SUPERVISOR_LIQUIDACIONES' ? '#/tablero-liquidaciones' : '#/dashboard');
      return;
    }
    asegurarShell();
    marcarActivo(r);
    const main = document.getElementById('main');
    const ruta = RUTAS[r.parts[0]];
    const scroll = window.scrollY;
    if (!(opc && opc.mantener)) main.innerHTML = '<div class="page"><div class="loading" aria-busy="true">Cargando…</div></div>';
    try {
      if (!ruta) throw Object.assign(new Error('La página solicitada no existe.'), { code: 'NO_ENCONTRADO' });
      await ruta(main, r);
    } catch (e) {
      if (id !== renderId) return;
      console.error(e);
      if (e && e.code === 'NO_AUTENTICADO') { state.usuario = null; location.replace('#/login'); return; }
      main.innerHTML = ui.errorPagina(e);
    }
    if (id !== renderId) return;
    document.body.classList.remove('nav-open');
    if (opc && opc.mantener) window.scrollTo(0, scroll); else { window.scrollTo(0, 0); }
    actualizarBadge();
  }

  function titulo(t) {
    const el = document.getElementById('page-title');
    if (el) el.textContent = t;
    document.title = t + ' · ArreoPrime';
  }
  function go(hash) { if (location.hash === hash) render(); else location.hash = hash; }

  /* ---------- Eventos globales ---------- */
  document.addEventListener('click', async e => {
    const b = e.target.closest('[data-act]');
    if (!b || b.tagName === 'FORM') return;
    const act = b.dataset.act;
    if (act === 'open-nav') document.body.classList.add('nav-open');
    else if (act === 'close-nav') document.body.classList.remove('nav-open');
    else if (act === 'switch') { await APD.api.sesion.cerrar(); state.usuario = null; shellDe = null; go('#/login'); }
    else if (act === 'reset') {
      ui.modal({
        titulo: 'Reiniciar datos de demostración', cuerpo: '<p>Se regenerarán los tickets ficticios y se perderán los cambios hechos en esta sesión.</p>',
        acciones: [{ label: 'Cancelar' }, { label: 'Reiniciar', clase: 'btn-primary', icono: 'rotate', accion: async () => { await APD.api.demo.reiniciar(); ui.toast('Datos de demostración reiniciados'); if (!(await APD.api.sesion.actual())) { state.usuario = null; go('#/login'); } else render(); } }]
      });
    } else if (act === 'tema') {
      const nuevo = temaActual() === 'dark' ? 'light' : 'dark';
      aplicarTema(nuevo);
      try { localStorage.setItem('apd.tema', nuevo); } catch (err) { /* modo privado */ }
      b.innerHTML = ico(nuevo === 'dark' ? 'sun' : 'moon', 18);
    }
  });
  document.addEventListener('submit', e => {
    const f = e.target.closest('form[data-act="buscar"]');
    if (!f) return;
    e.preventDefault();
    const q = f.q.value.trim();
    if (!q) return;
    f.q.value = '';
    if (P.esSolicitante(state.usuario)) go('#/consultar?q=' + encodeURIComponent(q));
    else go('#/bandeja?vista=todos&q=' + encodeURIComponent(q));
  });
  window.addEventListener('hashchange', () => render());

  APD.app = {
    titulo, go, actualizarBadge,
    refresh: () => render({ mantener: true }),
    iniciarSesion: u => { state.usuario = u; shellDe = null; go('#/inicio'); }
  };

  document.addEventListener('DOMContentLoaded', () => {
    render();
    // Contador de notificaciones: se refresca cada minuto mientras haya sesión
    setInterval(() => { if (state.usuario && !document.hidden) actualizarBadge(); }, 60000);
  });
})();
