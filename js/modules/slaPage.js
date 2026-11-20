/* Control SLA: semáforo operativo, política versionada, calendario laboral y feriados. */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun, S = APD.sla;
  const DIAS = ['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado'];
  const PRIOS = ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'];
  const hhmm = m => String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');

  async function render(el) {
    const u = APD.state.usuario;
    if (!P.puede(u, 'sla.ver')) throw C.noAutorizado();
    APD.app.titulo(u.rol === 'ADMINISTRADOR' ? 'SLA y calendario' : 'Control SLA');
    const d = await APD.api.sla.estado();
    const v = d.vigente;
    let h = '<div class="page wide"><div class="page-head"><div><h2>' + (d.riesgo ? 'Control de SLA' : 'Configuración de SLA') + '</h2>' +
      '<p class="muted">Tiempos en horas hábiles según el calendario laboral. ' + (v ? 'Versión vigente: <b>v' + v.version + '</b> desde ' + esc(F.fecha(v.vigente_desde)) + '.' : '<b>Sin SLA configurado.</b>') + '</p></div>' +
      (d.puede_configurar ? '<div class="page-actions"><button type="button" class="btn btn-primary" data-x="version">' + ico('plus', 16) + '<span>' + (v ? 'Nueva versión de SLA' : 'Publicar la primera versión') + '</span></button></div>' : '') + '</div>' +
      (APD.api.modo === 'DEMO' || (v && /DEMO/.test(v.nota)) ? ui.demoNota('Los tiempos de compromiso mostrados son ficticios. Los valores reales los define la organización (decisión D-15).') : '') +
      (!v ? '<div class="alert alert-warn">' + ico('alert', 16) + '<span>No hay una política de SLA vigente: los tickets se registran «Sin SLA» y no hay semáforo. La organización debe definir los tiempos (D-15); el Administrador los publica aquí.</span></div>' : '');

    if (d.riesgo) {
      const c = d.riesgo.conteo;
      const kpi = APD.pages.dashboard.kpi;
      h += '<div class="kpi-grid kpi-grid-4">' +
        kpi('Dentro del tiempo', F.num(c.verde), { icono: 'check-circle' }) +
        kpi('Próximos a vencer', F.num(c.amarillo), { cls: c.amarillo ? 'kpi-warning' : '', icono: 'clock', href: '#/bandeja?vista=proximos' }) +
        kpi('Vencidos', F.num(c.rojo), { cls: c.rojo ? 'kpi-critical' : '', icono: 'alert', href: '#/bandeja?vista=vencidos' }) +
        kpi('Con SLA en pausa', F.num(c.pausado), { icono: 'pause', nota: 'en espera justificada' }) + '</div>';
      h += '<section class="card table-card"><div class="card-head"><h3>Tickets en riesgo</h3><span class="muted small">Ordenados por tiempo restante</span></div>' +
        (d.riesgo.filas.length ? '<div class="table-wrap"><table class="table"><thead><tr><th>Ticket</th><th>Departamento</th><th>Prioridad</th><th>Responsable</th><th>Estado</th><th>SLA</th></tr></thead><tbody>' +
          d.riesgo.filas.map(r => '<tr data-id="' + esc(r.id) + '"><td><a class="tnum" href="#/ticket/' + esc(r.id) + '">' + esc(r.numero) + '</a><small class="muted block trunc">' + esc(r.asunto) + '</small></td><td>' + esc(r.depto_nombre) + '</td><td>' + ui.badgePrioridad(r.prioridad) + '</td><td>' + (r.responsable_nombre ? esc(r.responsable_nombre) : '<span class="muted">Sin asignar</span>') + '</td><td>' + ui.badgeEstado(r.estado) + '</td><td>' + ui.semaforo(r.sla) + '</td></tr>').join('') +
          '</tbody></table></div>' : ui.vacio('check-circle', 'No hay tickets en riesgo', 'Todos los tickets abiertos están dentro del tiempo.')) + '</section>';
    }

    h += '<div class="chart-grid">' +
      (v ? '<section class="card span-2"><div class="card-head"><h3>Política vigente (v' + v.version + ')</h3><span class="muted small">Alerta amarilla al ' + Math.round(v.umbral * 100) + ' % del tiempo</span></div>' +
      '<div class="table-wrap"><table class="table"><thead><tr><th>Prioridad</th><th>Primera respuesta</th><th>Asignación</th><th>Resolución</th><th>Máximo de atención</th></tr></thead><tbody>' +
      PRIOS.map(p => { const x = v.valores[p] || {}; return '<tr><td>' + ui.badgePrioridad(p) + '</td><td>' + F.duracion(x.primera_respuesta) + '</td><td>' + F.duracion(x.asignacion) + '</td><td>' + F.duracion(x.resolucion) + '</td><td>' + (x.maximo_horas || '—') + ' h calendario</td></tr>'; }).join('') +
      '</tbody></table></div><p class="help">' + esc(v.nota) + (v.especificos ? ' · ' + v.especificos + ' valor(es) específico(s) por categoría.' : '') + ' Los tickets conservan la versión de SLA con la que se crearon, de modo que cambiar la política no altera tiempos históricos.</p></section>'
        : '<section class="card span-2">' + ui.vacio('clock', 'Sin política de SLA', 'Pendiente de definición (D-15).') + '</section>') +
      '<section class="card"><h3>' + ico('calendar', 18) + ' Calendario laboral</h3><dl class="dl dl-compact">' +
      [1, 2, 3, 4, 5, 6, 0].map(i => '<dt>' + DIAS[i] + '</dt><dd>' + (d.calendario[i] ? hhmm(d.calendario[i][0]) + ' – ' + hhmm(d.calendario[i][1]) : '<span class="muted">Sin atención</span>') + '</dd>').join('') + '</dl></section>' +
      '<section class="card"><div class="card-head"><h3>' + ico('flag', 18) + ' Feriados</h3>' + (d.puede_configurar ? '<button type="button" class="btn btn-secondary sm" data-x="feriado">' + ico('plus', 14) + '<span>Agregar</span></button>' : '') + '</div>' +
      '<ul class="plain-list">' + d.feriados.map(f => '<li><span><b>' + esc(F.fechaDeISO(f.fecha)) + '</b> · ' + esc(f.nombre) + '</span>' + (d.puede_configurar ? '<button type="button" class="btn-icon sm" data-quitar="' + esc(f.fecha) + '" aria-label="Quitar feriado ' + esc(f.nombre) + '">' + ico('x', 14) + '</button>' : '') + '</li>').join('') + '</ul>' +
      (d.feriados.length ? '' : '<p class="muted small">No hay feriados registrados.</p>') +
      '<p class="help">Debe coincidir con el calendario oficial de feriados de Costa Rica.</p></section>' +
      '</div>';
    if (d.versiones.length > 1 || d.puede_configurar) {
      h += '<section class="card"><h3>Historial de versiones</h3><ul class="timeline compact">' + d.versiones.slice().reverse().map(x => '<li>' + ico('history', 14) + '<span><b>Versión ' + x.version + '</b>' + (x.vigente_hasta ? '' : ' ' + ui.chip('Vigente', 'chip-ok')) +
        '<small class="muted block">Desde ' + esc(F.fecha(x.vigente_desde)) + (x.vigente_hasta ? ' hasta ' + esc(F.fecha(x.vigente_hasta)) : '') + ' · ' + esc(x.nota) + '</small></span></li>').join('') + '</ul></section>';
    }
    el.innerHTML = h + '</div>';

    const tb = el.querySelector('tbody tr[data-id]') && el.querySelector('.table-card tbody');
    if (tb) tb.addEventListener('click', e => { if (e.target.closest('a')) return; const tr = e.target.closest('tr[data-id]'); if (tr) APD.app.go('#/ticket/' + tr.dataset.id); });
    const bv = el.querySelector('[data-x="version"]');
    if (bv) bv.addEventListener('click', () => modalVersion(v || { version: 0, umbral: 0.75, valores: { CRITICA: {}, ALTA: {}, MEDIA: {}, BAJA: {} } }, () => render(el)));
    const bf = el.querySelector('[data-x="feriado"]');
    if (bf) bf.addEventListener('click', () => ui.modal({
      titulo: 'Agregar feriado', ancho: 'sm',
      cuerpo: '<div class="field"><label for="fe_f">Fecha <span class="req">*</span></label><input type="date" id="fe_f" name="fecha" required></div><div class="field"><label for="fe_n">Nombre <span class="req">*</span></label><input id="fe_n" name="nombre" required></div>',
      acciones: [{ label: 'Cancelar' }, { label: 'Agregar', clase: 'btn-primary', accion: async m => { ui.validarRequeridos(m); const f = ui.leerForm(m); await APD.api.sla.agregarFeriado(f.fecha, f.nombre); ui.toast('Feriado agregado'); render(el); } }]
    }));
    el.querySelectorAll('[data-quitar]').forEach(b => b.addEventListener('click', async () => {
      try { await APD.api.sla.quitarFeriado(b.dataset.quitar); ui.toast('Feriado eliminado'); render(el); } catch (e) { ui.toast(e.message, 'error'); }
    }));
  }

  function modalVersion(v, alTerminar) {
    const campos = [['primera_respuesta', '1.ª respuesta (min)'], ['asignacion', 'Asignación (min)'], ['resolucion', 'Resolución (min)'], ['maximo_horas', 'Máximo (h cal.)']];
    ui.modal({
      titulo: 'Nueva versión de SLA', subtitulo: 'Aplica a tickets nuevos. Los existentes conservan la versión v' + v.version + '.', ancho: 'lg',
      cuerpo: '<div class="table-wrap"><table class="table table-form"><thead><tr><th>Prioridad</th>' + campos.map(c => '<th>' + c[1] + '</th>').join('') + '</tr></thead><tbody>' +
        PRIOS.map(p => '<tr><td>' + ui.badgePrioridad(p) + '</td>' + campos.map(c => '<td><input type="number" min="1" step="1" required aria-label="' + p + ' ' + c[1] + '" data-p="' + p + '" data-k="' + c[0] + '" value="' + ((v.valores[p] || {})[c[0]] == null ? '' : v.valores[p][c[0]]) + '"></td>').join('') + '</tr>').join('') +
        '</tbody></table></div><div class="form-grid"><div class="field"><label for="sv_u">Alerta amarilla al (%)</label><input id="sv_u" type="number" min="50" max="99" name="umbral" value="' + Math.round(v.umbral * 100) + '" required></div>' +
        '<div class="field"><label for="sv_n">Nota de la versión</label><input id="sv_n" name="nota" placeholder="Ej.: valores aprobados por Gerencia"></div></div>',
      acciones: [{ label: 'Cancelar' }, {
        label: 'Publicar versión', clase: 'btn-primary', accion: async m => {
          ui.validarRequeridos(m);
          const valores = {};
          m.querySelectorAll('[data-p]').forEach(i => { (valores[i.dataset.p] = valores[i.dataset.p] || {})[i.dataset.k] = Number(i.value); });
          await APD.api.sla.nuevaVersion(valores, Number(m.querySelector('[name="umbral"]').value) / 100, m.querySelector('[name="nota"]').value);
          ui.toast('Nueva versión de SLA publicada');
          alTerminar();
        }
      }]
    });
  }

  APD.pages.sla = { render };
})();
