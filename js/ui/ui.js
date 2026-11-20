/* Componentes de interfaz reutilizables: toasts, modales, insignias, gráficos simples,
 * estados vacíos, descargas y tooltips. Todo texto dinámico pasa por fmt.esc(). */
(function () {
  'use strict';
  const F = APD.fmt, esc = F.esc, ico = (n, s) => APD.icon(n, s);

  /* ---------- Toasts ---------- */
  function toast(msg, tipo) {
    tipo = tipo || 'ok';
    const root = document.getElementById('toasts');
    const el = document.createElement('div');
    el.className = 'toast toast-' + tipo;
    el.innerHTML = ico(tipo === 'error' ? 'alert' : tipo === 'info' ? 'info' : 'check-circle', 18) + '<span>' + esc(msg) + '</span>';
    root.appendChild(el);
    setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 300); }, tipo === 'error' ? 6000 : 3500);
  }

  /* ---------- Modal ---------- */
  function modal(opc) {
    const root = document.getElementById('modal-root');
    const wrap = document.createElement('div');
    wrap.className = 'modal-backdrop';
    wrap.innerHTML =
      '<div class="modal modal-' + (opc.ancho || 'md') + '" role="dialog" aria-modal="true" aria-labelledby="modal-titulo">' +
      '<header class="modal-head"><div><h2 id="modal-titulo">' + esc(opc.titulo) + '</h2>' +
      (opc.subtitulo ? '<p class="muted small">' + esc(opc.subtitulo) + '</p>' : '') + '</div>' +
      '<button type="button" class="btn-icon" data-close aria-label="Cerrar">' + ico('x') + '</button></header>' +
      '<div class="modal-body">' + (opc.cuerpo || '') + '</div><footer class="modal-foot"></footer></div>';
    const foot = wrap.querySelector('.modal-foot');
    const modalEl = wrap.querySelector('.modal');
    const previo = document.activeElement;
    const cerrar = () => { wrap.remove(); document.removeEventListener('keydown', onKey); if (previo && previo.focus) previo.focus(); };
    const onKey = e => { if (e.key === 'Escape') cerrar(); };
    (opc.acciones || []).forEach(a => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn ' + (a.clase || 'btn-secondary');
      b.innerHTML = (a.icono ? ico(a.icono, 16) : '') + '<span>' + esc(a.label) + '</span>';
      b.addEventListener('click', async () => {
        if (!a.accion) { cerrar(); return; }
        b.disabled = true;
        try {
          const r = await a.accion(modalEl, cerrar);
          if (r !== false) cerrar();
        } catch (e) {
          errorEnModal(modalEl, e);
        } finally { b.disabled = false; }
      });
      foot.appendChild(b);
    });
    if (!(opc.acciones || []).length) foot.remove();
    wrap.addEventListener('click', e => { if (e.target.closest('[data-close]')) cerrar(); });
    document.addEventListener('keydown', onKey);
    root.appendChild(wrap);
    const f = modalEl.querySelector('.modal-body input:not([type=hidden]), .modal-body select, .modal-body textarea');
    (f || modalEl.querySelector('[data-close]')).focus();
    if (opc.alAbrir) opc.alAbrir(modalEl);
    return { el: modalEl, cerrar };
  }
  function errorEnModal(modalEl, e) {
    let box = modalEl.querySelector('.modal-error');
    if (!box) {
      box = document.createElement('div');
      box.className = 'alert alert-error modal-error';
      modalEl.querySelector('.modal-body').prepend(box);
    }
    box.innerHTML = ico('alert', 18) + '<span>' + esc(e && e.message ? e.message : String(e)) + '</span>';
  }

  /** Lee los campos con name dentro de un contenedor */
  function leerForm(el) {
    const o = {};
    el.querySelectorAll('[name]').forEach(i => {
      if (i.type === 'checkbox') {
        if (i.dataset.multi) { (o[i.name] = o[i.name] || []); if (i.checked) o[i.name].push(i.value); }
        else o[i.name] = i.checked;
      } else if (i.type === 'radio') { if (i.checked) o[i.name] = i.value; }
      else o[i.name] = typeof i.value === 'string' ? i.value.trim() : i.value;
    });
    return o;
  }
  /** Marca campos requeridos vacíos y lanza error legible */
  function validarRequeridos(el) {
    let falta = 0;
    el.querySelectorAll('[required]').forEach(i => {
      const vacio = i.type === 'radio' ? !el.querySelector('[name="' + i.name + '"]:checked') : !String(i.value || '').trim();
      const campo = i.closest('.field') || i;
      campo.classList.toggle('invalid', vacio);
      if (vacio) falta++;
    });
    if (falta) throw new Error('Complete los campos obligatorios marcados.');
  }

  /* ---------- Insignias ---------- */
  function badgeEstado(e) {
    const m = APD.estados.ESTADOS[e];
    return m ? '<span class="badge ' + m.cls + '"><i class="dot"></i>' + m.label + '</span>' : '';
  }
  const PRIORIDADES = { CRITICA: ['Crítica', 'pr-critica'], ALTA: ['Alta', 'pr-alta'], MEDIA: ['Media', 'pr-media'], BAJA: ['Baja', 'pr-baja'] };
  function badgePrioridad(p) {
    const m = PRIORIDADES[p];
    return m ? '<span class="prio ' + m[1] + '"><i class="bars" aria-hidden="true"><b></b><b></b><b></b></i>' + m[0] + '</span>' : '';
  }
  function semaforo(sla, compacto) {
    if (!sla) return '';
    const g = sla.global;
    const texto = APD.sla.textoFoco(sla);
    const icono = { verde: 'clock', amarillo: 'alert', rojo: 'alert', cumplido: 'check', incumplido: 'x', na: 'clock', sin: 'clock' }[g];
    return '<span class="sla sla-' + g + '" title="' + esc(APD.sla.SEMAFORO[g] + ' — ' + texto) + '">' + ico(icono, 14) +
      '<span>' + esc(compacto ? APD.sla.SEMAFORO[g] : texto) + '</span></span>';
  }
  function avatar(nombre, tam) {
    return '<span class="avatar' + (tam ? ' avatar-' + tam : '') + '" aria-hidden="true">' + esc(F.iniciales(nombre)) + '</span>';
  }
  function chip(texto, cls) { return '<span class="chip ' + (cls || '') + '">' + esc(texto) + '</span>'; }

  /* ---------- Bloques ---------- */
  function vacio(icono, titulo, texto) {
    return '<div class="empty">' + ico(icono || 'inbox', 32) + '<h3>' + esc(titulo) + '</h3>' + (texto ? '<p>' + esc(texto) + '</p>' : '') + '</div>';
  }
  function errorPagina(e) {
    const noAut = e && (e.code === 'NO_AUTORIZADO' || e.code === 'NO_ENCONTRADO');
    return '<div class="page"><div class="card">' + vacio(noAut ? 'lock' : 'alert', noAut ? 'Sin acceso' : 'Ocurrió un error', e && e.message ? e.message : String(e)) +
      '<p class="center"><a class="btn btn-secondary" href="#/inicio">' + ico('home', 16) + '<span>Ir al inicio</span></a></p></div></div>';
  }
  function demoNota(texto) {
    // Solo en modo demostración: con datos reales el aviso sería falso
    if (!APD.api || APD.api.modo !== 'DEMO') return '';
    return '<div class="demo-note">' + ico('info', 16) + '<span><b>DEMO</b> · ' + esc(texto) + '</span></div>';
  }

  /** Paso a paso CREACIÓN → CIERRE */
  function stepper(t) {
    const E = APD.estados;
    const actual = E.pasoActual(t);
    const rechazado = t.estado === 'RECHAZADO';
    return '<ol class="stepper' + (rechazado ? ' rechazado' : '') + '">' + E.PASOS.map((p, i) => {
      const cls = i < actual ? 'done' : i === actual ? (rechazado ? 'fail' : 'current') : '';
      const etiqueta = rechazado && i === actual ? 'Rechazado' : (t.estado === 'EN_ESPERA' && i === actual ? p + ' (en espera)' : p);
      return '<li class="' + cls + '"><span class="step-dot">' + (i < actual ? ico('check', 12) : '') + '</span><span class="step-label">' + esc(etiqueta) + '</span></li>';
    }).join('') + '</ol>';
  }

  /* ---------- Gráficos (CSS, sin dependencias) ----------
   * Una serie → un solo tono (series-1), sin leyenda. Valores rotulados al final de la barra.
   * Tooltip por marca mediante data-tip. */
  function barras(datos, opc) {
    opc = opc || {};
    if (!datos.length) return '<p class="muted small">Sin datos para el período.</p>';
    const max = Math.max.apply(null, datos.map(d => d.valor)) || 1;
    const fmtV = opc.formato || (v => F.num(v));
    return '<div class="hbars" role="list">' + datos.map(d => {
      const w = Math.max(d.valor > 0 ? 2 : 0, (d.valor / max) * 100);
      const tip = d.label + ': ' + fmtV(d.valor) + (d.extra ? ' · ' + d.extra : '');
      return '<div class="hbar" role="listitem" data-tip="' + esc(tip) + '"><span class="hbar-label" title="' + esc(d.label) + '">' + esc(d.label) + '</span>' +
        '<span class="hbar-track"><span class="hbar-fill" style="width:' + w.toFixed(1) + '%"></span></span>' +
        '<span class="hbar-val">' + esc(fmtV(d.valor)) + '</span></div>';
    }).join('') + '</div>';
  }
  /** Columnas agrupadas para tendencia (máximo 2 series, con leyenda) */
  function columnas(grupos, series) {
    if (!grupos.length) return '<p class="muted small">Sin datos para el período.</p>';
    const max = Math.max(1, ...grupos.flatMap(g => series.map(s => g[s.clave] || 0)));
    const leyenda = '<div class="legend">' + series.map((s, i) => '<span><i class="sw sw-' + (i + 1) + '"></i>' + esc(s.label) + '</span>').join('') + '</div>';
    const cols = grupos.map(g => '<div class="vcol-group">' +
      '<div class="vcol-bars">' + series.map((s, i) => {
        const v = g[s.clave] || 0;
        return '<span class="vcol sw-' + (i + 1) + '" style="height:' + ((v / max) * 100).toFixed(1) + '%" data-tip="' + esc(g.label + ' · ' + s.label + ': ' + F.num(v)) + '"></span>';
      }).join('') + '</div><span class="vcol-label">' + esc(g.label) + '</span></div>').join('');
    return leyenda + '<div class="vcols" role="img" aria-label="Tendencia semanal">' + cols + '</div>';
  }

  /** Líneas para tendencias (máximo 2 series de la paleta categórica, mismo eje).
   * Trazos de 2 px, marcadores de 8 px con anillo de superficie, cuadrícula tenue y una guía con
   * tooltip por punto (todas las series de esa semana). Etiquetas en HTML para que no se deformen. */
  function lineas(grupos, series, opc) {
    opc = opc || {};
    if (!grupos.length) return '<p class="muted small">Sin datos para el período.</p>';
    const fmtV = opc.formato || (v => F.num(v));
    const bruto = Math.max(0, ...grupos.flatMap(g => series.map(s => Number(g[s.clave]) || 0)));
    const paso = (() => { if (!bruto) return 1; const e = Math.pow(10, Math.floor(Math.log10(bruto / 4))); const r = bruto / 4 / e; return (r <= 1 ? 1 : r <= 2 ? 2 : r <= 2.5 ? 2.5 : r <= 5 ? 5 : 10) * e; })();
    const max = paso * 4;
    const n = grupos.length;
    const X = i => (n === 1 ? 50 : (i / (n - 1)) * 100), Y = v => 100 - ((Number(v) || 0) / max) * 100;
    const leyenda = series.length > 1 ? '<div class="legend">' + series.map((s, i) => '<span><i class="sw sw-' + (i + 1) + '"></i>' + esc(s.label) + '</span>').join('') + '</div>' : '';
    const ticks = [0, 1, 2, 3, 4].map(k => k * paso);
    const area = series.length === 1 && opc.area !== false
      ? '<path class="lc-area" d="M0 100 ' + grupos.map((g, i) => 'L' + X(i).toFixed(2) + ' ' + Y(g[series[0].clave]).toFixed(2)).join(' ') + ' L100 100 Z"/>' : '';
    const trazos = series.map((s, si) => '<polyline class="lc-line lc-s' + (si + 1) + '" points="' + grupos.map((g, i) => X(i).toFixed(2) + ',' + Y(g[s.clave]).toFixed(2)).join(' ') + '"/>').join('');
    const puntos = series.map((s, si) => grupos.map((g, i) => '<span class="lc-dot lc-s' + (si + 1) + '" style="left:' + X(i).toFixed(2) + '%;top:' + Y(g[s.clave]).toFixed(2) + '%"></span>').join('')).join('');
    const ancho = n === 1 ? 100 : 100 / (n - 1);
    const bandas = grupos.map((g, i) => '<span class="lc-band" style="left:' + (X(i) - ancho / 2).toFixed(2) + '%;width:' + ancho.toFixed(2) + '%" data-tip="' +
      esc(g.label + ' · ' + series.map(s => s.label + ': ' + fmtV(Number(g[s.clave]) || 0)).join(' · ')) + '"></span>').join('');
    const cada = n > 14 ? 3 : n > 8 ? 2 : 1;
    const tabla = '<table class="sr-only"><caption>' + esc(opc.titulo || 'Tendencia') + '</caption><tr><th>Semana</th>' + series.map(s => '<th>' + esc(s.label) + '</th>').join('') + '</tr>' +
      grupos.map(g => '<tr><td>' + esc(g.label) + '</td>' + series.map(s => '<td>' + esc(fmtV(Number(g[s.clave]) || 0)) + '</td>').join('') + '</tr>').join('') + '</table>';
    return leyenda + '<div class="lchart" style="--lc-h:' + (opc.alto || 220) + 'px">' +
      '<div class="lc-y" aria-hidden="true">' + ticks.map(t => '<span style="bottom:' + (t / max * 100) + '%">' + esc(fmtV(t)) + '</span>').join('') + '</div>' +
      '<div class="lc-plot" aria-hidden="true">' + ticks.map(t => '<i class="lc-grid" style="bottom:' + (t / max * 100) + '%"></i>').join('') +
      '<svg viewBox="0 0 100 100" preserveAspectRatio="none">' + area + trazos + '</svg>' + puntos + bandas + '</div>' +
      '<div class="lc-x" aria-hidden="true">' + grupos.map((g, i) => '<span style="left:' + X(i).toFixed(2) + '%">' + (i % cada === 0 || i === n - 1 ? esc(g.label) : '') + '</span>').join('') + '</div>' +
      tabla + '</div>';
  }

  /* ---------- Utilidades ---------- */
  function descargar(nombre, contenido, mime) {
    const blob = new Blob([contenido], { type: mime || 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = nombre;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }
  /** CSV con BOM UTF-8 y separador ';' (Excel en configuración regional de Costa Rica) */
  function aCSV(columnas, filas) {
    const celda = v => {
      if (v == null) return '';
      if (typeof v === 'number') return String(v).replace('.', ',');
      const s = String(v);
      return /[;"\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    return '﻿' + [columnas.map(c => celda(c.label)).join(';')]
      .concat(filas.map(f => columnas.map(c => celda(f[c.clave])).join(';'))).join('\r\n');
  }

  /** Excel nativo (.xlsx) con SheetJS; los números quedan como números */
  function descargarExcel(nombre, titulo, columnas, filas) {
    if (!window.XLSX) throw new Error('La exportación a Excel no está disponible.');
    const datos = [columnas.map(c => c.label)].concat(filas.map(f => columnas.map(c => (f[c.clave] == null ? '' : f[c.clave]))));
    const hoja = window.XLSX.utils.aoa_to_sheet(datos);
    hoja['!cols'] = columnas.map(c => ({ wch: Math.min(40, Math.max(10, c.label.length + 2)) }));
    const libro = window.XLSX.utils.book_new();
    window.XLSX.utils.book_append_sheet(libro, hoja, String(titulo || 'Reporte').replace(/[\\/?*[\]:]/g, ' ').slice(0, 31));
    window.XLSX.writeFile(libro, nombre);
  }

  /* ---------- Tooltip global ---------- */
  let tipEl = null;
  document.addEventListener('mouseover', e => {
    const t = e.target.closest && e.target.closest('[data-tip]');
    if (!t) { if (tipEl) tipEl.hidden = true; return; }
    if (!tipEl) { tipEl = document.createElement('div'); tipEl.className = 'tooltip'; tipEl.setAttribute('role', 'tooltip'); document.body.appendChild(tipEl); }
    tipEl.textContent = t.getAttribute('data-tip');
    tipEl.hidden = false;
    const r = t.getBoundingClientRect();
    const w = tipEl.offsetWidth, h = tipEl.offsetHeight;
    let x = r.left + r.width / 2 - w / 2;
    x = Math.max(8, Math.min(x, window.innerWidth - w - 8));
    let y = r.top - h - 8;
    if (y < 8) y = r.bottom + 8;
    tipEl.style.left = x + 'px';
    tipEl.style.top = y + 'px';
  });
  document.addEventListener('scroll', () => { if (tipEl) tipEl.hidden = true; }, true);

  APD.ui = {
    toast, modal, errorEnModal, leerForm, validarRequeridos, badgeEstado, badgePrioridad, semaforo, avatar, chip,
    vacio, errorPagina, demoNota, stepper, barras, columnas, lineas, descargar, descargarExcel, aCSV, PRIORIDADES
  };
})();
