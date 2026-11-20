/* Motor SLA en horas hábiles (Costa Rica, UTC-6).
 * Replica la lógica que en producción vivirá en PostgreSQL (función de horas hábiles + pg_cron).
 * - Calendario: minutos desde medianoche por día de semana (0 = domingo).
 * - Feriados: fechas 'YYYY-MM-DD' sin atención.
 * - Pausas: intervalos en EN ESPERA con motivo que pausa el SLA.
 * - Cada ticket guarda un snapshot de los objetivos vigentes al crearse.
 */
(function () {
  'use strict';
  const OFF = -6 * 3600e3, DAY = 86400e3;

  const METRICAS = { primera_respuesta: 'Primera respuesta', asignacion: 'Asignación', resolucion: 'Resolución' };
  const SEMAFORO = {
    verde: 'Dentro del tiempo', amarillo: 'Próximo a vencer', rojo: 'Vencido',
    cumplido: 'Cumplido', incumplido: 'Incumplido', na: 'No aplica', sin: 'Sin SLA', exceptuado: 'Exceptuado'
  };

  const diaLocal = ms => Math.floor((ms + OFF) / DAY) * DAY;
  function horario(dLocal, ctx) {
    const h = ctx.cal[new Date(dLocal).getUTCDay()];
    if (!h) return null;
    if (ctx.feriados.has(new Date(dLocal).toISOString().slice(0, 10))) return null;
    return h;
  }

  /** Minutos hábiles entre dos instantes */
  function minutosHabiles(desde, hasta, ctx) {
    if (!(hasta > desde)) return 0;
    const ini = desde + OFF, fin = hasta + OFF;
    let total = 0;
    for (let d = diaLocal(desde); d < fin; d += DAY) {
      const h = horario(d, ctx);
      if (!h) continue;
      const a = Math.max(d + h[0] * 60000, ini), b = Math.min(d + h[1] * 60000, fin);
      if (b > a) total += (b - a) / 60000;
    }
    return total;
  }

  /** Días hábiles completos transcurridos después del día de 'desde' hasta el día de 'hasta' */
  function diasHabiles(desde, hasta, ctx) {
    let n = 0;
    for (let d = diaLocal(desde) + DAY; d <= diaLocal(hasta); d += DAY) if (horario(d, ctx)) n++;
    return n;
  }

  /** Mueve un instante al siguiente momento hábil (si ya es hábil, lo devuelve igual) */
  function siguienteHabil(ms, ctx) {
    for (let i = 0; i < 40; i++) {
      const d = diaLocal(ms), h = horario(d, ctx), loc = ms + OFF;
      if (h) {
        const a = d + h[0] * 60000, b = d + h[1] * 60000;
        if (loc < a) return a - OFF;
        if (loc < b) return ms;
      }
      ms = d + DAY - OFF;
    }
    return ms;
  }

  /** Evalúa las tres métricas del ticket contra su snapshot de SLA */
  function evaluar(t, ctx, ahora) {
    const pol = t.sla;
    if (!pol) return { global: 'sin', foco: null, metricas: {}, pausado: false };
    const pausas = t.pausas || [];
    const pausado = pausas.some(p => p.fin == null);
    const minPausa = fin => pausas.reduce((s, p) => {
      const a = Math.max(p.inicio, t.creado_at), b = Math.min(p.fin == null ? ahora : p.fin, fin);
      return s + (b > a ? minutosHabiles(a, b, ctx) : 0);
    }, 0);
    const finalizado = t.anulado || t.estado === 'RECHAZADO' || t.estado === 'CERRADO' || t.cierre_excepcional;

    function medir(clave, finAt) {
      const objetivo = pol[clave];
      if (finAt == null && finalizado) return { clave, estado: 'na', objetivo };
      const fin = finAt == null ? ahora : finAt;
      const transcurrido = Math.max(0, minutosHabiles(t.creado_at, fin, ctx) - minPausa(fin));
      const pct = objetivo ? transcurrido / objetivo : 0;
      if (finAt != null) return { clave, estado: transcurrido <= objetivo ? 'cumplido' : 'incumplido', transcurrido, objetivo, pct };
      const estado = pct >= 1 ? 'rojo' : pct >= pol.umbral ? 'amarillo' : 'verde';
      return { clave, estado, transcurrido, objetivo, pct, restante: objetivo - transcurrido, pausado };
    }

    const metricas = {
      primera_respuesta: medir('primera_respuesta', t.primera_respuesta_at),
      asignacion: medir('asignacion', t.asignado_at),
      resolucion: medir('resolucion', t.resuelto_at)
    };
    if (t.cierre_excepcional && !t.resuelto_at) metricas.resolucion = { clave: 'resolucion', estado: 'na', objetivo: pol.resolucion, excluido: true };

    const rank = { rojo: 3, amarillo: 2, verde: 1 };
    const lista = Object.values(metricas);
    const activas = lista.filter(m => rank[m.estado]).sort((a, b) => rank[b.estado] - rank[a.estado] || a.restante - b.restante);
    let global = 'na', foco = null;
    if (activas.length) { foco = activas[0]; global = foco.estado; }
    else if (lista.some(m => m.estado === 'incumplido')) { global = 'incumplido'; foco = lista.find(m => m.estado === 'incumplido'); }
    else if (lista.some(m => m.estado === 'cumplido')) global = 'cumplido';
    return { global, foco, metricas, pausado };
  }

  function textoFoco(sla) {
    const D = APD.fmt.duracion;
    if (!sla || !sla.foco) return sla ? SEMAFORO[sla.global] : '';
    const f = sla.foco, nombre = METRICAS[f.clave];
    if (f.estado === 'incumplido') return 'Incumplido · ' + nombre;
    const base = f.restante >= 0 ? 'Restan ' + D(f.restante) : 'Vencido hace ' + D(-f.restante);
    return base + ' · ' + nombre + (sla.pausado ? ' (pausado)' : '');
  }

  APD.sla = { METRICAS, SEMAFORO, minutosHabiles, diasHabiles, siguienteHabil, evaluar, textoFoco };
})();
