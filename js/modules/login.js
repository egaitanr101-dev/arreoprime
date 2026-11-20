/* Ingreso.
 *   DEMO     → elegir un usuario ficticio.
 *   LOCAL    → elegir un usuario de prueba del entorno local (base de datos real).
 *   SUPABASE → correo y contraseña (alta por invitación) y, si está activo, Microsoft 365 (D-02). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos;

  /* Portada de ingreso: fondo con la flota, marca, mensaje, atributos y tarjeta de acceso */
  function marca() {
    const rasgo = (icono, t) => '<li>' + ico(icono, 30) + '<span>' + t + '</span></li>';
    return '<section class="login-hero">' +
      '<div class="login-brand-row"><img class="login-logo" src="assets/logo-el-arreo.png" alt="El Arreo"><span class="login-divider" aria-hidden="true"></span>' +
      '<div class="login-title"><b>ArreoPrime</b><small>TRANSPORTES · SERVICIO · LOGÍSTICA</small></div></div>' +
      '<div class="login-message"><h1>Todas las solicitudes a Transportes, <em>en un solo lugar.</em></h1>' +
      '<div class="login-mision"><span>Misión · Distribución y Transportes</span>' +
      '<p>Entregar productos con calidad, frescura y servicio, asegurando la cantidad y calidad requeridas, al menor costo posible, mediante una operación eficiente y responsable que cumpla estrictamente con los estándares de inocuidad.</p></div></div>' +
      '<ul class="login-features">' + rasgo('stopwatch', 'Eficiencia') + rasgo('package', 'Entrega') + rasgo('handshake', 'Servicio') + '</ul></section>';
  }
  function pantalla(tarjeta) {
    return '<div class="login"><div class="login-bg" aria-hidden="true"></div>' +
      '<svg class="login-swoosh" viewBox="0 0 1440 900" preserveAspectRatio="none" aria-hidden="true"><defs><linearGradient id="lg-oro" x1="0" x2="1"><stop offset="0" stop-color="#f0b020" stop-opacity="0"/><stop offset=".55" stop-color="#f0b020"/><stop offset="1" stop-color="#f7cf6b" stop-opacity=".2"/></linearGradient></defs>' +
      '<path d="M690 0 C760 120 800 260 820 420" stroke="url(#lg-oro)" stroke-width="10" fill="none" opacity=".9"/>' +
      '<path d="M720 0 C800 140 846 280 868 430" stroke="url(#lg-oro)" stroke-width="3" fill="none" opacity=".55"/>' +
      '<path d="M0 842 C420 820 900 790 1440 760" stroke="url(#lg-oro)" stroke-width="4" fill="none"/></svg>' +
      '<div class="login-wrap">' + marca() + '<section class="login-panel"><div class="login-card">' + tarjeta + '</div></section></div>' +
      '<footer class="login-footer"><b>El Arreo · Grupo CIISA</b><span class="login-footer-sep" aria-hidden="true"></span><em>Alimentamos el crecimiento para una vida mejor</em>' +
      '<small class="login-version">' + esc(APD.config.version) + '</small></footer></div>';
  }
  const cabecera = (titulo, sub) => '<div class="login-card-head"><span class="login-badge" aria-hidden="true">' + ico('truck', 46) + '</span><h2>' + titulo + '</h2>' + (sub ? '<p>' + sub + '</p>' : '') + '</div>';
  const protegido = '<p class="login-secure">' + ico('shield-check', 16) + '<span>Su información está protegida</span></p>';

  async function render(app) {
    const modo = APD.api.modo;
    if (modo === 'SUPABASE') return formulario(app, 'ingreso');
    const usuarios = await APD.api.sesion.usuariosDemo();
    const grupos = [
      { t: 'Solicitantes', d: 'Comercial, Almacén y Liquidaciones', f: u => u.rol === 'SOLICITANTE' || u.rol === 'SUPERVISOR_LIQUIDACIONES' },
      { t: 'Transportes', d: 'Coordinadores de rutas y supervisión', f: u => u.rol === 'OPERADOR_TRANSPORTES' || u.rol === 'SUPERVISOR_TRANSPORTES' },
      { t: 'Gerencia y administración', d: 'Consulta y configuración', f: u => u.rol === 'GERENCIA' || u.rol === 'ADMINISTRADOR' || u.rol === 'SUPERUSUARIO' }
    ];
    const nota = modo === 'LOCAL'
      ? '<div class="alert alert-info">' + ico('info', 16) + '<span><b>Entorno local de pruebas.</b> Base de datos PostgreSQL en este equipo con las reglas de seguridad reales (RLS y funciones del servidor). Usuarios de prueba.</span></div>'
      : ui.demoNota('Prototipo con datos ficticios. Elija un usuario para recorrer la aplicación con su rol y sus permisos.');
    app.innerHTML = pantalla(cabecera('Ingresar como…', 'Elija un usuario para recorrer la aplicación') + nota + '<div class="login-list">' +
      grupos.map(g => {
        const lista = usuarios.filter(g.f);
        if (!lista.length) return '';
        return '<div class="login-group"><h3>' + esc(g.t) + ' <small>' + esc(g.d) + '</small></h3><div class="login-users">' +
          lista.map(u => '<button type="button" class="login-user" data-id="' + esc(u.id) + '"' + (u.activo ? '' : ' disabled') + '>' +
            ui.avatar(u.nombre) + '<span><b>' + esc(u.nombre) + '</b><small>' + esc(P.etiquetaRol(u.rol, u.departamento)) + ' · ' + esc(u.depto_nombre || u.departamento) + '</small>' +
            (u.nota_demo ? '<em>' + esc(u.nota_demo) + '</em>' : '') + '</span>' + ico('arrow-right', 16) + '</button>').join('') + '</div></div>';
      }).join('') + '</div>' +
      (modo === 'DEMO' ? '<p class="muted small login-foot">' + ico('lock', 14) + ' En producción el ingreso es con cuenta corporativa (Microsoft 365) o correo y contraseña por invitación, sin autorregistro.</p>' : '') +
      protegido);
    app.querySelectorAll('.login-user').forEach(b => b.addEventListener('click', async () => {
      try { APD.app.iniciarSesion(await APD.api.sesion.iniciar(b.dataset.id)); }
      catch (e) { ui.toast(e.message, 'error'); }
    }));
  }

  /* ---------- Supabase: correo y contraseña / Microsoft / recuperación ---------- */
  function formulario(app, vista) {
    const ms = APD.config.microsoft;
    const cuerpo = vista === 'recuperar'
      ? cabecera('Recuperar contraseña', 'Le enviaremos un enlace a su correo para definir una contraseña nueva.') +
        '<form data-x="f" novalidate><div class="field"><label for="lg_c">' + ico('user', 16) + 'Correo</label><input id="lg_c" type="email" name="correo" autocomplete="username" placeholder="usuario@grupociisa.com" required></div>' +
        '<div class="form-actions"><button type="button" class="btn btn-secondary" data-x="volver">' + ico('arrow-left', 16) + '<span>Volver</span></button>' +
        '<button type="submit" class="btn btn-primary">' + ico('send', 16) + '<span>Enviar enlace</span></button></div></form>'
      : cabecera('Ingresar', 'Acceda a su cuenta para gestionar sus solicitudes') +
        (ms ? '<button type="button" class="btn btn-secondary login-ms" data-x="ms">' + ico('building', 18) + '<span>Ingresar con Microsoft 365</span></button><div class="login-sep"><span>o con correo y contraseña</span></div>' : '') +
        '<form data-x="f" novalidate><div class="field"><label for="lg_c">' + ico('user', 16) + 'Correo</label><input id="lg_c" type="email" name="correo" autocomplete="username" placeholder="usuario@grupociisa.com" required></div>' +
        '<div class="field"><label for="lg_p">' + ico('lock', 16) + 'Contraseña</label><input id="lg_p" type="password" name="clave" autocomplete="current-password" required></div>' +
        '<div class="form-actions"><button type="button" class="link" data-x="olvido">¿Olvidó su contraseña?</button>' +
        '<button type="submit" class="btn btn-primary">' + ico('log-in', 18) + '<span>Ingresar</span></button></div></form>' +
        '<p class="muted small login-foot">' + ico('lock', 14) + ' Las cuentas las crea el Administrador por invitación. Si no tiene acceso, solicítelo a su jefatura.</p>';
    app.innerHTML = pantalla(cuerpo + protegido);
    const f = app.querySelector('[data-x="f"]');
    f.querySelector('input').focus();
    const volver = app.querySelector('[data-x="volver"]');
    if (volver) volver.addEventListener('click', () => formulario(app, 'ingreso'));
    const olvido = app.querySelector('[data-x="olvido"]');
    if (olvido) olvido.addEventListener('click', () => formulario(app, 'recuperar'));
    const bms = app.querySelector('[data-x="ms"]');
    if (bms) bms.addEventListener('click', async () => { try { await APD.api.sesion.iniciarMicrosoft(); } catch (e) { ui.toast(e.message, 'error'); } });
    f.addEventListener('submit', async e => {
      e.preventDefault();
      const btn = f.querySelector('[type="submit"]');
      try {
        ui.validarRequeridos(f);
        btn.disabled = true;
        if (vista === 'recuperar') {
          await APD.api.sesion.recuperar(f.correo.value);
          ui.toast('Si el correo está registrado, recibirá un enlace en unos minutos.', 'info');
          formulario(app, 'ingreso');
        } else {
          APD.app.iniciarSesion(await APD.api.sesion.iniciarConCorreo(f.correo.value, f.clave.value));
        }
      } catch (err) {
        ui.toast(err.message, 'error');
        btn.disabled = false;
      }
    });
  }

  /* ---------- Definir contraseña (tras una invitación o recuperación) ---------- */
  async function definirClave(el) {
    APD.app.titulo('Definir contraseña');
    el.innerHTML = '<div class="page narrow"><section class="card"><h2>Defina su contraseña</h2>' +
      '<p class="muted">Use al menos 10 caracteres. La contraseña es personal: no la comparta.</p>' +
      '<form data-x="f" novalidate><div class="form-grid">' +
      '<div class="field"><label for="dc_1">Contraseña nueva</label><input id="dc_1" type="password" name="clave" autocomplete="new-password" minlength="10" required></div>' +
      '<div class="field"><label for="dc_2">Repetir contraseña</label><input id="dc_2" type="password" name="clave2" autocomplete="new-password" required></div></div>' +
      '<div class="form-actions"><button type="submit" class="btn btn-primary">' + ico('check', 16) + '<span>Guardar contraseña</span></button></div></form></section></div>';
    const f = el.querySelector('[data-x="f"]');
    f.addEventListener('submit', async e => {
      e.preventDefault();
      try {
        ui.validarRequeridos(f);
        if (f.clave.value.length < 10) throw new Error('La contraseña debe tener al menos 10 caracteres.');
        if (f.clave.value !== f.clave2.value) throw new Error('Las contraseñas no coinciden.');
        await APD.api.sesion.definirClave(f.clave.value);
        ui.toast('Contraseña guardada.');
        APD.app.go('#/inicio');
      } catch (err) { ui.toast(err.message, 'error'); }
    });
  }

  APD.pages.login = { render, definirClave };
})();
