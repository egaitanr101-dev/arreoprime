/* Administración: usuarios, roles y permisos, departamentos, categorías, configuración y auditoría.
 * El Administrador no tiene acceso al contenido operativo (tickets, comentarios, montos) por defecto. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const TABS = [['usuarios', 'Usuarios', 'users', 'admin.usuarios'], ['permisos', 'Roles y permisos', 'shield', 'admin.usuarios'], ['departamentos', 'Departamentos', 'building', 'admin.catalogos'], ['categorias', 'Categorías', 'layers', 'admin.catalogos'], ['configuracion', 'Configuración', 'settings', 'admin.catalogos'], ['auditoria', 'Auditoría', 'history', null]];
  const DEPTOS = { COM: 'Comercial', ALM: 'Almacén', LIQ: 'Liquidaciones', TRA: 'Distrib. y Transp. Cárnico', GER: 'Gerencia', SIS: 'Sistemas' };
  const DEPTO_POR_ROL = { SOLICITANTE: ['COM', 'ALM', 'LIQ'], SUPERVISOR_LIQUIDACIONES: ['LIQ'], OPERADOR_TRANSPORTES: ['TRA'], SUPERVISOR_TRANSPORTES: ['TRA'], GERENCIA: ['GER'], ADMINISTRADOR: ['SIS'], SUPERUSUARIO: ['TRA'] };
  let filtroAud = '';

  async function render(el, r) {
    const u = APD.state.usuario;
    const tab = r.parts[1] || 'usuarios';
    const def = TABS.find(t => t[0] === tab);
    if (!def) throw Object.assign(new Error('Sección no encontrada.'), { code: 'NO_ENCONTRADO' });
    const permitido = tab === 'auditoria' ? (P.puede(u, 'auditoria.administrativa') || P.puede(u, 'auditoria.operativa')) : P.puede(u, def[3]);
    if (!permitido) throw C.noAutorizado();
    APD.app.titulo(def[1]);
    const esAdmin = P.puede(u, 'admin.usuarios');
    let cuerpo = '';
    switch (tab) {
      case 'usuarios': cuerpo = await usuarios(u); break;
      case 'permisos': cuerpo = permisos(); break;
      case 'departamentos': cuerpo = await departamentos(); break;
      case 'categorias': cuerpo = await categorias(); break;
      case 'configuracion': cuerpo = await configuracion(); break;
      case 'auditoria': cuerpo = await auditoria(u); break;
      default: break;
    }
    el.innerHTML = '<div class="page wide">' +
      (esAdmin ? '<nav class="subnav scroll-x" aria-label="Secciones de administración">' + TABS.map(t => '<a class="fchip' + (t[0] === tab ? ' on' : '') + '" href="#/' + (t[0] === 'auditoria' ? 'auditoria' : 'admin/' + t[0]) + '">' + ico(t[2], 14) + t[1] + '</a>').join('') + '</nav>' : '') +
      cuerpo + '</div>';
    enlazar(el, tab, u);
  }

  /* ---------- Usuarios ---------- */
  let cacheUsuarios = [];
  async function usuarios(u) {
    cacheUsuarios = await APD.api.admin.usuarios();
    return '<div class="page-head"><div><h2>Usuarios</h2><p class="muted">Rol y departamento se asignan solo desde aquí y se validan en el servidor; nadie puede modificar su propio perfil.</p></div>' +
      '<div class="page-actions"><button type="button" class="btn btn-primary" data-x="nuevo">' + ico('user-plus', 16) + '<span>Invitar usuario</span></button></div></div>' +
      '<section class="card table-card"><div class="table-wrap"><table class="table"><thead><tr><th>Usuario</th><th>Rol</th><th>Departamento</th><th>Estado</th><th>Alcance / permisos adicionales</th><th></th></tr></thead><tbody>' +
      cacheUsuarios.map(x => '<tr><td>' + ui.avatar(x.nombre, 'xs') + ' <b>' + esc(x.nombre) + '</b><small class="muted block">' + esc(x.correo) + '</small></td>' +
        '<td>' + esc(x.rol_label) + '</td><td>' + esc(x.depto_nombre) + '</td>' +
        '<td>' + (x.activo ? ui.chip('Activo', 'chip-ok') : ui.chip('Inactivo', 'chip-muted')) + (x.activo && !x.disponible ? ' ' + ui.chip('No disponible', 'chip-warn') : '') + '</td>' +
        '<td class="small">' + (x.alcance.length ? 'Alcance: ' + x.alcance.map(a => DEPTOS[a]).join(', ') : '') + (x.permisos_extra.length ? '<span class="block">' + x.permisos_extra.map(p => esc(P.PERMISOS[p])).join(' · ') + '</span>' : '') + (!x.alcance.length && !x.permisos_extra.length ? '<span class="muted">—</span>' : '') + '</td>' +
        '<td class="right">' + (x.id === u.id ? '<span class="muted small">Su perfil</span>' : '<button type="button" class="btn btn-ghost sm" data-editar="' + esc(x.id) + '">' + ico('settings', 14) + '<span>Editar</span></button>') + '</td></tr>').join('') +
      '</tbody></table></div></section>';
  }
  function formUsuario(x) {
    const rol = x ? x.rol : 'SOLICITANTE';
    return (x ? '' : '<div class="form-grid"><div class="field"><label for="us_n">Nombre completo <span class="req">*</span></label><input id="us_n" name="nombre" required></div><div class="field"><label for="us_c">Correo <span class="req">*</span></label><input id="us_c" type="email" name="correo" required></div></div>') +
      '<div class="form-grid"><div class="field"><label for="us_r">Rol <span class="req">*</span></label><select id="us_r" name="rol" required>' + Object.keys(P.ROLES).map(k => '<option value="' + k + '"' + (k === rol ? ' selected' : '') + '>' + P.ROLES[k].label + '</option>').join('') + '</select></div>' +
      '<div class="field"><label for="us_d">Departamento <span class="req">*</span></label><select id="us_d" name="departamento" required data-depto-actual="' + (x ? x.departamento : '') + '"></select></div></div>' +
      (x ? '<div class="form-grid"><label class="switch"><input type="checkbox" name="activo"' + (x.activo ? ' checked' : '') + '><span>Usuario activo</span></label><label class="switch"><input type="checkbox" name="disponible"' + (x.disponible ? ' checked' : '') + '><span>Disponible para asignaciones</span></label></div>' : '') +
      '<fieldset class="field" data-x="alcance"><legend>Alcance del coordinador (departamentos que puede gestionar)</legend><div class="check-row">' + ['COM', 'ALM', 'LIQ'].map(a => '<label class="check"><input type="checkbox" name="alcance" data-multi="1" value="' + a + '"' + (x && x.alcance.includes(a) ? ' checked' : '') + '><span>' + DEPTOS[a] + '</span></label>').join('') + '</div></fieldset>' +
      '<fieldset class="field"><legend>Permisos adicionales (auditados)</legend><div class="check-list">' + P.OTORGABLES.map(p => '<label class="check"><input type="checkbox" name="permisos_extra" data-multi="1" value="' + p + '"' + (x && x.permisos_extra.includes(p) ? ' checked' : '') + '><span>' + esc(P.PERMISOS[p]) + '</span></label>').join('') + '</div></fieldset>';
  }
  function sincronizarForm(m) {
    const rol = m.querySelector('[name="rol"]').value;
    const sel = m.querySelector('[name="departamento"]');
    const actual = sel.value || sel.dataset.deptoActual;
    sel.innerHTML = DEPTO_POR_ROL[rol].map(d => '<option value="' + d + '"' + (d === actual ? ' selected' : '') + '>' + DEPTOS[d] + '</option>').join('');
    m.querySelector('[data-x="alcance"]').hidden = rol !== 'OPERADOR_TRANSPORTES';
  }

  /* ---------- Roles y permisos ---------- */
  function permisos() {
    const roles = Object.keys(P.ROLES);
    return '<div class="page-head"><div><h2>Matriz de roles y permisos</h2><p class="muted">Fuente única de autorización. En producción vive en las tablas roles / permisos / rol_permisos y la usan las políticas RLS y las funciones del servidor.</p></div></div>' +
      '<section class="card table-card"><div class="table-wrap"><table class="table matrix"><thead><tr><th>Permiso</th>' + roles.map(r => '<th class="center">' + esc(P.ROLES[r].label) + '</th>').join('') + '</tr></thead><tbody>' +
      Object.keys(P.PERMISOS).map(p => '<tr><td><b class="mono small">' + esc(p) + '</b><small class="muted block">' + esc(P.PERMISOS[p]) + '</small></td>' +
        roles.map(r => '<td class="center">' + (P.MATRIZ[r].includes(p) ? '<span class="ok-mark" title="Permitido">' + ico('check', 16) + '</span>' + (r === 'SOLICITANTE' && (p === 'financiero.ver' || p === 'investigacion.ver_resumen') ? '<small class="muted block">solo LIQ</small>' : '') : (P.OTORGABLES.includes(p) && r === 'OPERADOR_TRANSPORTES' ? '<small class="muted">otorgable</small>' : '<span class="muted">—</span>')) + '</td>').join('') + '</tr>').join('') +
      '</tbody></table></div><p class="help">Solo lectura en el prototipo. «Otorgable» = el Administrador puede concederlo a un usuario específico desde Usuarios; queda en auditoría.</p></section>';
  }

  /* ---------- Departamentos ---------- */
  async function departamentos() {
    const d = await APD.api.admin.departamentos();
    const tipo = { SOLICITANTE: 'Solicitante', RECEPTOR: 'Receptor único', CONSULTA: 'Consulta', ADMINISTRACION: 'Administración' };
    return '<div class="page-head"><div><h2>Departamentos</h2><p class="muted">Tres departamentos solicitantes y un único receptor: Transportes.</p></div></div>' +
      '<section class="card table-card"><div class="table-wrap"><table class="table"><thead><tr><th>Código</th><th>Nombre</th><th>Función</th><th class="num">Usuarios</th></tr></thead><tbody>' +
      d.map(x => '<tr><td class="mono">' + esc(x.id) + '</td><td><b>' + esc(x.nombre) + '</b></td><td>' + esc(tipo[x.tipo]) + '</td><td class="num">' + x.usuarios + '</td></tr>').join('') + '</tbody></table></div></section>';
  }

  /* ---------- Categorías ---------- */
  async function categorias() {
    const cats = await APD.api.catalogos();
    const tipo = id => (cats.tipos.find(t => t.id === id) || {}).nombre;
    return '<div class="page-head"><div><h2>Categorías y formularios</h2><p class="muted">Cada categoría define los campos del formulario dinámico, el tipo de gestión propuesto y la prioridad sugerida.</p></div></div>' +
      ['COM', 'ALM', 'LIQ'].map(dep => '<section class="card table-card"><div class="card-head"><h3>' + DEPTOS[dep] + '</h3></div><div class="table-wrap"><table class="table"><thead><tr><th>Categoría</th><th>Tipo propuesto</th><th>Prioridad sugerida</th><th>Campos</th><th>Características</th><th>Activa</th></tr></thead><tbody>' +
        cats.categorias.filter(c => c.departamento === dep).map(c => '<tr' + (c.activo ? '' : ' class="row-muted"') + '><td><b>' + esc(c.nombre) + '</b><small class="muted block mono">' + esc(c.id) + '</small></td><td>' + esc(tipo(c.tipo_default)) + '</td><td>' + ui.badgePrioridad(c.prioridad_sugerida) + '</td>' +
          '<td class="small">' + c.campos.map(x => esc(cats.campos[x.clave].etiqueta) + (x.obligatorio ? '*' : '')).join(', ') + '</td>' +
          '<td>' + (c.financiero ? ui.chip('Montos CRC', 'chip-info') : '') + (c.genera_investigacion ? ' ' + ui.chip('Investigación', 'chip-info') : '') + (c.requiere_aprobacion ? ' ' + ui.chip('Aprobación') : '') + '</td>' +
          '<td><label class="switch"><input type="checkbox" data-cat="' + esc(c.id) + '"' + (c.activo ? ' checked' : '') + '><span class="sr-only">Activa</span></label></td></tr>').join('') +
        '</tbody></table></div></section>').join('') +
      '<p class="help">* obligatorio. Prioridades sugeridas DEMO (decisión C-10). Ninguna categoría requiere aprobación hasta que se defina (C-09). Desactivar una categoría la oculta del formulario sin afectar los tickets existentes.</p>';
  }

  /* ---------- Configuración ---------- */
  async function configuracion() {
    const [cfg, cats] = await Promise.all([APD.api.admin.config(), APD.api.catalogos()]);
    return '<div class="page-head"><div><h2>Configuración</h2><p class="muted">Parámetros generales de la mesa de servicio.</p></div></div>' +
      '<form class="card" data-x="cfg"><h3>Parámetros</h3>' +
      '<label class="switch"><input type="checkbox" name="asignacion_automatica"' + (cfg.asignacion_automatica ? ' checked' : '') + '><span><b>Asignación automática</b><small class="block muted">Asigna al coordinador activo, disponible, con alcance y menor carga. Si nadie califica, el ticket queda sin asignar y se alerta a supervisión (D-21).</small></span></label>' +
      '<div class="field narrow-field"><label for="cf_d">Auto-cierre de tickets resueltos (días hábiles)</label><input id="cf_d" type="number" min="1" max="15" name="auto_cierre_dias" value="' + cfg.auto_cierre_dias + '" required></div>' +
      '<div class="form-actions"><button type="submit" class="btn btn-primary">' + ico('check', 16) + '<span>Guardar</span></button></div></form>' +
      '<div class="chart-grid">' +
      '<section class="card"><h3>Tipos de gestión</h3><ul class="plain-list">' + cats.tipos.map(t => '<li>' + esc(t.nombre) + '</li>').join('') + '</ul></section>' +
      '<section class="card"><h3>Motivos de espera</h3><ul class="plain-list">' + cats.motivos.filter(m => m.tipo === 'ESPERA').map(m => '<li><span>' + esc(m.nombre) + '</span>' + (m.pausa_sla ? ui.chip('Pausa SLA', 'chip-info') : ui.chip('No pausa')) + '</li>').join('') + '</ul></section>' +
      '<section class="card"><h3>Motivos de rechazo</h3><ul class="plain-list">' + cats.motivos.filter(m => m.tipo === 'RECHAZO').map(m => '<li>' + esc(m.nombre) + '</li>').join('') + '</ul></section>' +
      '<section class="card"><h3>Resultados de investigación</h3><ul class="plain-list">' + cats.resultados.map(x => '<li>' + esc(x) + '</li>').join('') + '</ul></section>' +
      '</div><p class="help">Los catálogos se muestran en solo lectura en el prototipo; su edición se habilita en la Fase 4.</p>';
  }

  /* ---------- Auditoría ---------- */
  async function auditoria(u) {
    const filas = await APD.api.admin.auditoria();
    const acciones = Array.from(new Set(filas.map(a => a.accion))).sort();
    const vis = filas.filter(a => !filtroAud || a.accion === filtroAud);
    return '<div class="page-head"><div><h2>Auditoría</h2><p class="muted">' + (P.puede(u, 'auditoria.administrativa') ? 'Operaciones administrativas y operativas sensibles.' : 'Operaciones operativas sensibles (cierres excepcionales, anulaciones, movimientos financieros, investigaciones).') + ' Registro de solo inserción.</p></div>' +
      '<div class="page-actions"><select data-x="aud" aria-label="Filtrar por acción"><option value="">Todas las acciones</option>' + acciones.map(a => '<option' + (a === filtroAud ? ' selected' : '') + '>' + esc(a) + '</option>').join('') + '</select></div></div>' +
      '<section class="card table-card">' + (vis.length ? '<div class="table-wrap"><table class="table"><thead><tr><th>Fecha</th><th>Usuario</th><th>Ámbito</th><th>Acción</th><th>Detalle</th></tr></thead><tbody>' +
        vis.slice(0, 300).map(a => '<tr><td class="nowrap">' + esc(F.fecha(a.ts)) + '</td><td>' + esc(a.usuario_nombre) + '</td><td>' + ui.chip(a.ambito === 'OPERATIVA' ? 'Operativa' : 'Administrativa') + '</td><td class="mono small">' + esc(a.accion) + '</td><td>' + (a.numero ? (P.puede(u, 'ticket.ver_todos') ? '<a class="tnum" href="#/ticket/' + esc(a.ticket_id) + '">' + esc(a.numero) + '</a> · ' : '<span class="mono">' + esc(a.numero) + '</span> · ') : '') + esc(a.detalle) + '</td></tr>').join('') +
        '</tbody></table></div>' : ui.vacio('history', 'Sin registros')) + '</section>';
  }

  /* ---------- Eventos ---------- */
  function enlazar(el, tab, u) {
    if (tab === 'usuarios') {
      const abrir = x => ui.modal({
        titulo: x ? 'Editar usuario' : 'Invitar usuario', subtitulo: x ? x.nombre + ' · ' + x.correo : 'DEMO: no se envía correo; en producción se envía una invitación de Supabase Auth.', ancho: 'md',
        cuerpo: formUsuario(x),
        alAbrir: m => { sincronizarForm(m); m.querySelector('[name="rol"]').addEventListener('change', () => sincronizarForm(m)); },
        acciones: [{ label: 'Cancelar' }, {
          label: x ? 'Guardar cambios' : 'Invitar', clase: 'btn-primary', accion: async m => {
            ui.validarRequeridos(m);
            const f = ui.leerForm(m);
            if (x) await APD.api.admin.guardarUsuario(x.id, f); else await APD.api.admin.crearUsuario(f);
            ui.toast(x ? 'Usuario actualizado (registrado en auditoría)' : 'Usuario creado');
            render(el, { parts: ['admin', 'usuarios'] });
          }
        }]
      });
      el.querySelector('[data-x="nuevo"]').addEventListener('click', () => abrir(null));
      el.querySelectorAll('[data-editar]').forEach(b => b.addEventListener('click', () => abrir(cacheUsuarios.find(x => x.id === b.dataset.editar))));
    }
    if (tab === 'categorias') {
      el.querySelectorAll('[data-cat]').forEach(i => i.addEventListener('change', async () => {
        try { await APD.api.admin.categoriaActiva(i.dataset.cat, i.checked); ui.toast('Categoría ' + (i.checked ? 'activada' : 'desactivada')); i.closest('tr').classList.toggle('row-muted', !i.checked); }
        catch (e) { ui.toast(e.message, 'error'); i.checked = !i.checked; }
      }));
    }
    if (tab === 'configuracion') {
      el.querySelector('[data-x="cfg"]').addEventListener('submit', async e => {
        e.preventDefault();
        try { const f = ui.leerForm(e.target); await APD.api.admin.guardarConfig({ asignacion_automatica: f.asignacion_automatica, auto_cierre_dias: Number(f.auto_cierre_dias) }); ui.toast('Configuración guardada'); }
        catch (err) { ui.toast(err.message, 'error'); }
      });
    }
    if (tab === 'auditoria') {
      el.querySelector('[data-x="aud"]').addEventListener('change', e => { filtroAud = e.target.value; render(el, { parts: ['admin', 'auditoria'] }); });
    }
    void u;
  }

  APD.pages.admin = { render };
})();
