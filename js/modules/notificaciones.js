/* Notificaciones en la aplicación y preferencias por evento (para evitar saturación). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon;
  const ICONO = { nuevo: 'inbox', asignado: 'user-check', reasignado: 'users', comentario: 'message', info_requerida: 'help', respuesta_info: 'message', sla_proximo: 'clock', sla_vencido: 'alert', resuelto: 'check-circle', cerrado: 'lock', reabierto: 'rotate', rechazado: 'x-circle', sin_responsable: 'user-plus' };

  async function render(el) {
    APD.app.titulo('Notificaciones');
    const [lista, pref] = await Promise.all([APD.api.notificaciones.listar(), APD.api.notificaciones.preferencias()]);
    const noLeidas = lista.filter(n => !n.leida).length;
    el.innerHTML = '<div class="page narrow">' +
      '<div class="page-head"><div><h2>Notificaciones</h2><p class="muted">' + noLeidas + ' sin leer · ' + lista.length + ' en total</p></div>' +
      (noLeidas ? '<div class="page-actions"><button type="button" class="btn btn-secondary" data-x="todas">' + ico('check', 16) + '<span>Marcar todas como leídas</span></button></div>' : '') + '</div>' +
      '<section class="card">' + (lista.length ? '<ul class="notif-list">' + lista.slice(0, 100).map(n =>
        '<li class="' + (n.leida ? '' : 'unread') + ' ev-' + esc(n.evento) + '"><a href="' + (n.ticket_id ? '#/ticket/' + esc(n.ticket_id) : '#/notificaciones') + '" data-n="' + esc(n.id) + '">' +
        '<span class="notif-ico">' + ico(ICONO[n.evento] || 'bell', 18) + '</span><span class="notif-body"><b>' + esc(n.evento_label) + (n.numero ? ' · ' + esc(n.numero) : '') + '</b><span>' + esc(n.texto) + '</span><small class="muted">' + esc(F.relativo(n.ts)) + ' · ' + esc(F.fecha(n.ts)) + '</small></span>' +
        (n.leida ? '' : '<span class="unread-dot" aria-label="Sin leer"></span>') + '</a></li>').join('') + '</ul>' : ui.vacio('bell', 'No tiene notificaciones')) + '</section>' +
      '<form class="card" data-x="pref"><h3>' + ico('settings', 18) + ' Preferencias</h3><p class="muted small">Elija qué eventos desea recibir. Las notificaciones se muestran en la aplicación; el envío por correo para eventos clave se habilita en la Fase 4 (D-14).</p>' +
      '<div class="check-grid">' + Object.keys(pref.eventos).map(k => '<label class="check"><input type="checkbox" name="' + k + '"' + (pref.pref[k] === false ? '' : ' checked') + '><span>' + esc(pref.eventos[k]) + '</span></label>').join('') + '</div>' +
      '<div class="form-actions"><button type="submit" class="btn btn-primary">' + ico('check', 16) + '<span>Guardar preferencias</span></button></div></form></div>';

    el.querySelectorAll('[data-n]').forEach(a => a.addEventListener('click', () => { APD.api.notificaciones.marcarLeidas([a.dataset.n]).then(APD.app.actualizarBadge); }));
    const todas = el.querySelector('[data-x="todas"]');
    if (todas) todas.addEventListener('click', async () => { await APD.api.notificaciones.marcarLeidas(null); render(el); APD.app.actualizarBadge(); });
    el.querySelector('[data-x="pref"]').addEventListener('submit', async e => {
      e.preventDefault();
      const f = ui.leerForm(e.target);
      await APD.api.notificaciones.guardarPreferencias(f);
      ui.toast('Preferencias guardadas');
    });
  }

  APD.pages.notificaciones = { render };
})();
