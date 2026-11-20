/* Formatos: fechas en hora de Costa Rica, colones (CRC), duraciones y escape HTML. */
(function () {
  'use strict';
  const TZ = 'America/Costa_Rica';
  const OFF = -6 * 3600e3; // Costa Rica: UTC-6 sin horario de verano

  const dtf = new Intl.DateTimeFormat('es-CR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  const df = new Intl.DateTimeFormat('es-CR', { timeZone: TZ, day: '2-digit', month: 'short', year: 'numeric' });
  const hf = new Intl.DateTimeFormat('es-CR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
  const crcF = new Intl.NumberFormat('es-CR', { style: 'currency', currency: 'CRC', minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const crcCorto = new Intl.NumberFormat('es-CR', { style: 'currency', currency: 'CRC', maximumFractionDigits: 0 });
  const numF = new Intl.NumberFormat('es-CR');

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function fecha(ms) { return ms == null ? '—' : dtf.format(new Date(ms)); }
  function fechaCorta(ms) { return ms == null ? '—' : df.format(new Date(ms)); }
  function hora(ms) { return ms == null ? '—' : hf.format(new Date(ms)); }
  /** 'YYYY-MM-DD' del día en Costa Rica */
  function fechaISO(ms) { return new Date(ms + OFF).toISOString().slice(0, 10); }
  /** ms de la medianoche de Costa Rica para 'YYYY-MM-DD' */
  function desdeFechaCR(str) {
    if (!str) return null;
    const [y, m, d] = str.split('-').map(Number);
    return Date.UTC(y, m - 1, d) - OFF;
  }
  /** Muestra una fecha 'YYYY-MM-DD' (campo de formulario) como fecha corta */
  function fechaDeISO(str) { return str ? fechaCorta(desdeFechaCR(str) + 12 * 3600e3) : '—'; }
  function crc(n) { return n == null || n === '' || isNaN(n) ? '—' : crcF.format(Number(n)); }
  function crcK(n) { return n == null || isNaN(n) ? '—' : crcCorto.format(Number(n)); }
  function num(n) { return n == null ? '—' : numF.format(n); }
  function pct(x, dec) { return x == null || isNaN(x) ? '—' : (x * 100).toFixed(dec == null ? 0 : dec).replace('.', ',') + ' %'; }
  function duracion(min) {
    if (min == null || isNaN(min)) return '—';
    min = Math.round(Math.abs(min));
    if (min < 60) return min + ' min';
    const h = Math.floor(min / 60), m = min % 60;
    if (h < 24) return h + ' h' + (m ? ' ' + m + ' min' : '');
    const d = Math.floor(h / 24), hh = h % 24;
    return d + ' d' + (hh ? ' ' + hh + ' h' : '');
  }
  function relativo(ms, ahora) {
    const diff = Math.round(((ahora || Date.now()) - ms) / 60000);
    if (diff < 1) return 'hace un momento';
    return 'hace ' + duracion(diff);
  }
  function iniciales(nombre) {
    return String(nombre || '?').split(/\s+/).filter(Boolean).slice(0, 2).map(p => p[0]).join('').toUpperCase();
  }
  function tamano(bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(0) + ' KB';
    return (bytes / 1048576).toFixed(1).replace('.', ',') + ' MB';
  }

  APD.fmt = { esc, fecha, fechaCorta, hora, fechaISO, desdeFechaCR, fechaDeISO, crc, crcK, num, pct, duracion, relativo, iniciales, tamano, OFF };
})();
