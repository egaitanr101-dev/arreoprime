/* Crear solicitud en tres pasos: 1) categoría, 2) datos específicos, 3) revisar y enviar.
 * También sirve para el "registro asistido" de Transportes (D-03). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ui = APD.ui, ico = APD.icon, P = APD.permisos, C = APD.comun;
  const DEPTOS = { COM: 'Comercial', ALM: 'Almacén', LIQ: 'Liquidaciones' };
  let st, cats, el;

  async function render(contenedor) {
    el = contenedor;
    const u = APD.state.usuario;
    const asistido = !P.puede(u, 'ticket.crear') && P.puede(u, 'ticket.registro_asistido');
    if (!P.puede(u, 'ticket.crear') && !asistido) throw C.noAutorizado('Su rol no permite registrar solicitudes.');
    APD.app.titulo(asistido ? 'Registro asistido' : 'Crear solicitud');
    cats = await APD.api.catalogos();
    st = { paso: 1, asistido, depto: asistido ? '' : u.departamento, solicitante_id: '', cat: null, tipo: null, datos: {}, asunto: '', asuntoEditado: false, descripcion: '', archivos: [], creado: null };
    dibujar();
  }

  const categoria = () => cats.categorias.find(c => c.id === st.cat);
  const nombreTipo = id => (cats.tipos.find(t => t.id === id) || {}).nombre || id;
  const prioridadLabel = p => ui.PRIORIDADES[p][0];

  function cabecera() {
    const pasos = ['Categoría', 'Detalles', 'Revisar y enviar'];
    const actual = st.paso === 'ok' ? 3 : st.paso - 1;
    return '<ol class="wizard" aria-label="Pasos">' + pasos.map((p, i) =>
      '<li class="' + (i < actual ? 'done' : i === actual ? 'current' : '') + '"' + (i === actual ? ' aria-current="step"' : '') + '><span>' + (i < actual ? ico('check', 14) : i + 1) + '</span>' + p + '</li>').join('') + '</ol>';
  }

  function dibujar() {
    let html = '<div class="page narrow">';
    if (st.paso !== 'ok') html += '<div class="page-head"><div><h2>' + (st.asistido ? 'Registro asistido' : 'Nueva solicitud a Transportes') + '</h2>' +
      '<p class="muted">' + (st.asistido ? 'Registre una solicitud recibida por llamada o mensaje, a nombre del solicitante real.' : 'Departamento: <b>' + esc(DEPTOS[st.depto]) + '</b>') + '</p></div></div>' + cabecera();
    if (st.paso === 1) html += paso1();
    else if (st.paso === 2) html += paso2();
    else if (st.paso === 3) html += paso3();
    else html += confirmacion();
    el.innerHTML = html + '</div>';
    enlazar();
  }

  /* ---------- Paso 1 ---------- */
  function paso1() {
    let h = '';
    if (st.asistido) {
      const sols = cats.solicitantes.filter(s => s.departamento === st.depto);
      h += '<section class="card"><h3>Solicitante</h3><p class="muted small">El ticket queda registrado a nombre del solicitante y de su departamento; usted figura como quien lo registró.</p><div class="form-grid">' +
        '<div class="field"><label for="a_depto">Departamento <span class="req">*</span></label><select id="a_depto" data-x="depto"><option value="">Seleccione…</option>' +
        Object.keys(DEPTOS).map(k => '<option value="' + k + '"' + (k === st.depto ? ' selected' : '') + '>' + DEPTOS[k] + '</option>').join('') + '</select></div>' +
        '<div class="field"><label for="a_sol">Solicitante <span class="req">*</span></label><select id="a_sol" data-x="sol"' + (st.depto ? '' : ' disabled') + '><option value="">Seleccione…</option>' +
        sols.map(s => '<option value="' + s.id + '"' + (s.id === st.solicitante_id ? ' selected' : '') + '>' + esc(s.nombre) + '</option>').join('') + '</select></div></div></section>';
    }
    const lista = cats.categorias.filter(c => c.departamento === st.depto && c.activo);
    h += '<section class="card"><h3>¿Qué necesita?</h3><p class="muted small">Seleccione la categoría. El tipo de gestión se propone automáticamente y puede ajustarlo en el siguiente paso.</p>';
    if (!st.depto) h += '<p class="muted">Seleccione primero el departamento del solicitante.</p>';
    else h += '<div class="cat-grid">' + lista.map(c =>
      '<button type="button" class="cat-card' + (c.id === st.cat ? ' on' : '') + '" data-cat="' + c.id + '"' + (st.asistido && !st.solicitante_id ? ' disabled' : '') + '>' +
      '<span class="cat-tipo">' + esc(nombreTipo(c.tipo_default)) + '</span><b>' + esc(c.nombre) + '</b>' +
      '<small>' + c.campos.filter(x => x.obligatorio).length + ' datos obligatorios' + (c.financiero ? ' · incluye montos' : '') + '</small></button>').join('') + '</div>';
    return h + '</section>';
  }

  /* ---------- Paso 2 ---------- */
  function paso2() {
    const c = categoria();
    const tipos = c.tipos_validos;
    return '<form class="card" data-x="form" novalidate>' +
      '<div class="card-head"><div><p class="eyebrow">' + esc(DEPTOS[st.depto]) + '</p><h3>' + esc(c.nombre) + '</h3></div><button type="button" class="link" data-x="cambiar">Cambiar categoría</button></div>' +
      '<fieldset class="field"><legend>Tipo de gestión</legend><div class="seg">' + tipos.map(t =>
        '<label><input type="radio" name="__tipo" value="' + t + '"' + (t === st.tipo ? ' checked' : '') + '><span>' + esc(nombreTipo(t)) + '</span></label>').join('') + '</div></fieldset>' +
      '<div class="form-grid">' + ordenCampos(c.campos).map(x => C.campoHTML(cats, x.clave, x.obligatorio, st.datos[x.clave])).join('') + '</div>' +
      (c.financiero ? '<div class="calc" data-x="calc" aria-live="polite"></div>' : '') +
      '<div class="form-grid">' +
      '<div class="field full"><label for="f_asunto">Asunto <span class="req">*</span></label><input id="f_asunto" name="__asunto" maxlength="140" required value="' + esc(st.asunto) + '"></div>' +
      '<div class="field full"><label for="f_desc">Descripción de la solicitud <span class="req">*</span></label><textarea id="f_desc" name="__descripcion" rows="4" required placeholder="Explique qué necesita, cuándo y cualquier detalle útil para Transportes.">' + esc(st.descripcion) + '</textarea></div>' +
      '<div class="field full"><label for="f_files">Evidencias o fotografías</label><input id="f_files" type="file" multiple accept="image/*,application/pdf,.doc,.docx,.xls,.xlsx" data-x="files">' +
      '<ul class="file-list" data-x="filelist">' + listaArchivos() + '</ul><p class="help">' + (APD.api.modo === 'SUPABASE' ? 'Máximo 10 MB por archivo: imágenes, PDF u Office. Se guardan en almacenamiento privado con acceso por permisos.' : APD.api.modo === 'LOCAL' ? 'Entorno local: los archivos no se cargan (no hay almacenamiento).' : 'DEMO: se registran el nombre y el tamaño; el archivo no se almacena.') + '</p></div>' +
      '</div>' +
      '<div class="form-actions"><button type="button" class="btn btn-secondary" data-x="atras">' + ico('arrow-left', 16) + '<span>Atrás</span></button>' +
      '<button type="submit" class="btn btn-primary"><span>Revisar</span>' + ico('arrow-right', 16) + '</button></div></form>';
  }
  function listaArchivos() {
    return st.archivos.map((a, i) => '<li>' + ico('paperclip', 14) + '<span>' + esc(a.nombre) + ' <small class="muted">' + F.tamano(a.tamano) + '</small></span><button type="button" class="btn-icon sm" data-quitar="' + i + '" aria-label="Quitar ' + esc(a.nombre) + '">' + ico('x', 14) + '</button></li>').join('');
  }
  function asuntoSugerido() {
    const c = categoria(), d = st.datos;
    const cli = d.cliente && cats.clientes.find(x => x.id === d.cliente);
    const sufijo = cli ? cli.nombre : d.ruta ? 'Ruta ' + d.ruta : d.producto ? d.producto : '';
    return c.nombre + (sufijo ? ' — ' + sufijo : '');
  }
  /* El monto calculado (diferencia) va después del monto recibido */
  function ordenCampos(campos) {
    const rep = campos.find(x => x.clave === 'monto_reportado'), iRec = campos.findIndex(x => x.clave === 'monto_recibido');
    if (!rep || iRec < 0) return campos;
    const resto = campos.filter(x => x !== rep);
    resto.splice(resto.findIndex(x => x.clave === 'monto_recibido') + 1, 0, rep);
    return resto;
  }
  /* El monto reportado (diferencia) se calcula solo: |monto esperado − monto recibido| */
  function autoReportado(f) {
    const i = f && f.elements.monto_reportado;
    if (!i) return;
    if (!i.readOnly) {
      i.readOnly = true; i.tabIndex = -1; i.classList.add('auto');
      const ayuda = i.closest('.field').querySelector('.help');
      const txt = 'Se calcula automáticamente: monto esperado − monto recibido.';
      if (ayuda) ayuda.textContent = txt; else i.closest('.field').insertAdjacentHTML('beforeend', '<p class="help">' + txt + '</p>');
    }
    const e = st.datos.monto_esperado, r = st.datos.monto_recibido;
    const v = (e === undefined || e === '' || r === undefined || r === '') ? '' : String(Math.round(Math.abs(Number(e) - Number(r)) * 100) / 100);
    i.value = v; st.datos.monto_reportado = v;
  }
  function calcularDiferencia() {
    const box = el.querySelector('[data-x="calc"]');
    if (!box) return;
    const e = Number(st.datos.monto_esperado), r = Number(st.datos.monto_recibido), rep = st.datos.monto_reportado;
    if (st.datos.monto_esperado === undefined || st.datos.monto_esperado === '' || st.datos.monto_recibido === undefined || st.datos.monto_recibido === '') {
      box.innerHTML = ico('coins', 18) + '<span>La diferencia se calcula automáticamente: <b>monto esperado − monto recibido</b>.</span>';
      box.className = 'calc';
      return;
    }
    const dif = Math.round((e - r) * 100) / 100;
    const nat = dif > 0 ? 'Faltante' : dif < 0 ? 'Sobrante' : 'Sin diferencia';
    const noConcilia = rep !== undefined && rep !== '' && Math.abs(Math.abs(dif) - Number(rep)) >= 0.01;
    box.className = 'calc' + (noConcilia ? ' calc-warn' : '');
    box.innerHTML = ico('coins', 18) + '<span>Diferencia calculada: <b>' + F.crc(Math.abs(dif)) + '</b> (' + nat + ')' +
      (noConcilia ? '<br><small>El monto reportado (' + F.crc(rep) + ') no coincide con el cálculo; se registrará para conciliación.</small>' : '') + '</span>';
  }

  /* ---------- Paso 3 ---------- */
  function paso3() {
    const c = categoria();
    const filas = [
      ['Departamento', esc(DEPTOS[st.depto])],
      st.asistido ? ['Solicitante', esc((cats.solicitantes.find(s => s.id === st.solicitante_id) || {}).nombre || '')] : null,
      ['Tipo de gestión', esc(nombreTipo(st.tipo))], ['Categoría', esc(c.nombre)],
      ['Prioridad sugerida', ui.badgePrioridad(c.prioridad_sugerida) + ' <small class="muted">Transportes la confirma o ajusta.</small>'],
      ['Asunto', esc(st.asunto)]
    ].filter(Boolean);
    c.campos.forEach(x => { if (st.datos[x.clave] !== undefined && st.datos[x.clave] !== '') filas.push([esc(cats.campos[x.clave].etiqueta), esc(C.mostrarValor(cats, cats.campos[x.clave], st.datos[x.clave]))]); });
    filas.push(['Descripción', '<span class="pre">' + esc(st.descripcion) + '</span>']);
    filas.push(['Evidencias', st.archivos.length ? st.archivos.map(a => esc(a.nombre)).join(', ') : '<span class="muted">Ninguna</span>']);
    return '<section class="card"><h3>Revise su solicitud</h3><dl class="dl">' + filas.map(f => '<dt>' + f[0] + '</dt><dd>' + f[1] + '</dd>').join('') + '</dl>' +
      (c.financiero ? '<div class="calc" data-x="calc"></div>' : '') +
      '<div class="form-actions"><button type="button" class="btn btn-secondary" data-x="editar">' + ico('arrow-left', 16) + '<span>Editar</span></button>' +
      '<button type="button" class="btn btn-primary" data-x="enviar">' + ico('send', 16) + '<span>Enviar solicitud</span></button></div></section>';
  }

  function confirmacion() {
    const t = st.creado;
    return '<section class="card success-card"><div class="success-icon">' + ico('check-circle', 40) + '</div>' +
      '<h2>Solicitud registrada</h2><p class="muted">Transportes recibió la solicitud y fue notificado.</p>' +
      '<p class="ticket-number">' + esc(t.numero) + '</p>' +
      '<dl class="dl dl-compact">' +
      '<dt>Fecha de creación</dt><dd>' + esc(F.fecha(t.creado_at)) + '</dd>' +
      '<dt>Departamento</dt><dd>' + esc(t.depto_nombre) + '</dd>' +
      (t.canal === 'ASISTIDO' ? '<dt>Solicitante</dt><dd>' + esc(t.solicitante_nombre) + ' <small class="muted">(registro asistido)</small></dd>' : '') +
      '<dt>Categoría</dt><dd>' + esc(t.categoria_nombre) + '</dd>' +
      '<dt>Prioridad</dt><dd>' + ui.badgePrioridad(t.prioridad) + '</dd>' +
      '<dt>Estado</dt><dd>' + ui.badgeEstado(t.estado) + (t.responsable_nombre ? ' <small class="muted">Asignado a ' + esc(t.responsable_nombre) + '</small>' : '') + '</dd></dl>' +
      '<div class="form-actions center"><a class="btn btn-primary" href="#/ticket/' + esc(t.id) + '">' + ico('eye', 16) + '<span>Ver ticket</span></a>' +
      '<button type="button" class="btn btn-secondary" data-x="otra">' + ico('plus', 16) + '<span>Crear otra</span></button></div></section>';
  }

  /* ---------- Eventos ---------- */
  function leerPaso2() {
    const f = el.querySelector('[data-x="form"]');
    if (!f) return;
    const c = categoria();
    c.campos.forEach(x => { const i = f.elements[x.clave]; if (i) st.datos[x.clave] = i.value.trim(); });
    const t = f.querySelector('[name="__tipo"]:checked');
    if (t) st.tipo = t.value;
    st.asunto = f.elements.__asunto.value.trim();
    st.descripcion = f.elements.__descripcion.value.trim();
  }
  function enlazar() {
    const q = s => el.querySelector('[data-x="' + s + '"]');
    if (st.paso === 1) {
      if (q('depto')) q('depto').addEventListener('change', e => { st.depto = e.target.value; st.solicitante_id = ''; st.cat = null; dibujar(); });
      if (q('sol')) q('sol').addEventListener('change', e => { st.solicitante_id = e.target.value; dibujar(); });
      el.querySelectorAll('[data-cat]').forEach(b => b.addEventListener('click', () => {
        if (st.cat !== b.dataset.cat) { st.cat = b.dataset.cat; st.datos = {}; st.asuntoEditado = false; st.tipo = categoria().tipo_default; st.asunto = categoria().nombre; }
        st.paso = 2; dibujar();
        const first = el.querySelector('.form-grid input, .form-grid select');
        if (first) first.focus();
      }));
    }
    if (st.paso === 2) {
      const f = q('form');
      autoReportado(f);
      calcularDiferencia();
      f.addEventListener('input', e => {
        leerPaso2();
        autoReportado(f);
        if (e.target.name === '__asunto') st.asuntoEditado = true;
        else if (!st.asuntoEditado) { st.asunto = asuntoSugerido(); f.elements.__asunto.value = st.asunto; }
        calcularDiferencia();
        const campo = e.target.closest('.field');
        if (campo) campo.classList.remove('invalid');
      });
      f.addEventListener('change', () => { leerPaso2(); autoReportado(f); if (!st.asuntoEditado) { st.asunto = asuntoSugerido(); f.elements.__asunto.value = st.asunto; } calcularDiferencia(); });
      q('files').addEventListener('change', e => {
        Array.from(e.target.files).forEach(fl => st.archivos.push({ nombre: fl.name, tamano: fl.size, tipo: fl.type, archivo: fl }));
        e.target.value = '';
        q('filelist').innerHTML = listaArchivos();
      });
      q('filelist').addEventListener('click', e => {
        const b = e.target.closest('[data-quitar]');
        if (!b) return;
        st.archivos.splice(Number(b.dataset.quitar), 1);
        q('filelist').innerHTML = listaArchivos();
      });
      q('cambiar').addEventListener('click', () => { leerPaso2(); st.paso = 1; dibujar(); });
      q('atras').addEventListener('click', () => { leerPaso2(); st.paso = 1; dibujar(); });
      f.addEventListener('submit', e => {
        e.preventDefault();
        leerPaso2();
        try {
          ui.validarRequeridos(f);
          if (st.asunto.length < 5) throw new Error('El asunto debe tener al menos 5 caracteres.');
          if (st.descripcion.length < 10) throw new Error('Describa la solicitud (mínimo 10 caracteres).');
          const big = st.archivos.find(a => a.tamano > 10 * 1048576);
          if (big) throw new Error('"' + big.nombre + '" supera el máximo de 10 MB.');
          st.paso = 3; dibujar();
        } catch (err) {
          ui.toast(err.message, 'error');
          const inv = f.querySelector('.invalid input, .invalid select, .invalid textarea');
          if (inv) inv.focus();
        }
      });
    }
    if (st.paso === 3) {
      calcularDiferencia();
      q('editar').addEventListener('click', () => { st.paso = 2; dibujar(); });
      q('enviar').addEventListener('click', async e => {
        const btn = e.currentTarget;
        btn.disabled = true;
        try {
          st.creado = await APD.api.tickets.crear({
            asistido: st.asistido, solicitante_id: st.solicitante_id || undefined,
            categoria_id: st.cat, tipo_id: st.tipo, asunto: st.asunto, descripcion: st.descripcion,
            datos: st.datos, evidencias: st.archivos
          });
          st.paso = 'ok'; dibujar();
          if (st.creado.advertencia) ui.toast(st.creado.advertencia, 'info');
          APD.app.actualizarBadge();
        } catch (err) {
          ui.toast(err.message, 'error');
          btn.disabled = false;
        }
      });
    }
    if (st.paso === 'ok') {
      q('otra').addEventListener('click', () => render(el));
    }
  }

  APD.pages.crear = { render };
})();
