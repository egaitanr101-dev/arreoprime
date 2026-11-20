/* Cálculos compartidos de indicadores, liquidaciones y reportes.
 * Funciones puras: reciben filas YA filtradas por permisos (RLS en la base de datos o la
 * API simulada) y devuelven la misma estructura en modo DEMO y con base de datos real.
 * Nunca suman montos desde tablas unidas: cada diferencia llega una sola vez con sus saldos. */
(function () {
  'use strict';
  const E = APD.estados, S = APD.sla, F = APD.fmt, P = APD.permisos;
  const DAY = 86400e3;
  const round2 = n => Math.round(n * 100) / 100;
  const lbl = e => E.ESTADOS[e].label;
  const prioLabel = p => APD.ui.PRIORIDADES[p][0];
  const promedio = a => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : null);

  function contar(rows, clave, etiqueta) {
    const m = new Map();
    rows.forEach(r => { const k = r[clave] || '—'; m.set(k, (m.get(k) || 0) + 1); });
    return Array.from(m, ([k, v]) => ({ clave: k, label: etiqueta ? etiqueta(k) : k, valor: v })).sort((a, b) => b.valor - a.valor);
  }
  /** Filtro de período (días hacia atrás) y departamento; excluye anulados */
  function filtrar(rows, f) {
    const desde = f && f.dias ? Date.now() - Number(f.dias) * DAY : 0;
    return rows.filter(r => !r.anulado && r.creado_at >= desde && (!f || !f.departamento || r.departamento === f.departamento));
  }

  /* ---------------- Dashboard ---------------- */
  function dashboard(todas, responsables, u, f, cats) {
    const rows = filtrar(todas, f);
    const conRes = rows.filter(r => r.sla.metricas.resolucion && ['cumplido', 'incumplido'].includes(r.sla.metricas.resolucion.estado));
    const kpis = {
      total: rows.length,
      nuevos: rows.filter(r => r.estado === 'NUEVO').length,
      pendientes: rows.filter(r => E.ABIERTOS.includes(r.estado)).length,
      en_proceso: rows.filter(r => r.estado === 'EN_PROCESO').length,
      en_espera: rows.filter(r => r.estado === 'EN_ESPERA').length,
      resueltos: rows.filter(r => r.estado === 'RESUELTO').length,
      cerrados: rows.filter(r => r.estado === 'CERRADO').length,
      rechazados: rows.filter(r => r.estado === 'RECHAZADO').length,
      vencidos: rows.filter(r => r.sla.global === 'rojo').length,
      proximos: rows.filter(r => r.sla.global === 'amarillo').length,
      sin_asignar: rows.filter(r => !r.responsable_id && E.ABIERTOS.includes(r.estado)).length,
      cumplimiento: conRes.length ? conRes.filter(r => r.sla.metricas.resolucion.estado === 'cumplido').length / conRes.length : null,
      cumplimiento_base: conRes.length,
      prom_respuesta: promedio(rows.filter(r => r.sla.metricas.primera_respuesta && r.sla.metricas.primera_respuesta.estado !== 'na' && r.primera_respuesta_at).map(r => r.sla.metricas.primera_respuesta.transcurrido)),
      prom_asignacion: promedio(rows.filter(r => r.asignado_at && r.sla.metricas.asignacion && r.sla.metricas.asignacion.estado !== 'na').map(r => r.sla.metricas.asignacion.transcurrido)),
      prom_resolucion: promedio(conRes.map(r => r.sla.metricas.resolucion.transcurrido))
    };
    const porResponsable = responsables.map(x => {
      const mios = rows.filter(r => r.responsable_id === x.id);
      const res = mios.filter(r => r.resuelto_at);
      return {
        id: x.id, nombre: x.nombre, activo: x.activo, disponible: x.disponible,
        atendidos: res.length,
        pendientes: mios.filter(r => E.ABIERTOS.includes(r.estado)).length,
        vencidos: mios.filter(r => r.sla.global === 'rojo').length,
        prom_resolucion: promedio(res.filter(r => r.sla.metricas.resolucion && r.sla.metricas.resolucion.transcurrido != null).map(r => r.sla.metricas.resolucion.transcurrido))
      };
    }).filter(x => x.atendidos || x.pendientes);

    // Tendencia semanal (últimas 8 semanas, o el período si es corto)
    const semanas = [];
    const lunes = ms => { const d = new Date(ms + F.OFF); const dow = (d.getUTCDay() + 6) % 7; return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - dow) - F.OFF; };
    const ahora = Date.now();
    const nSem = f && f.dias && Number(f.dias) <= 30 ? Math.max(2, Math.ceil(Number(f.dias) / 7)) : 8;
    for (let i = nSem - 1; i >= 0; i--) {
      const ini = lunes(ahora) - i * 7 * DAY, fin = ini + 7 * DAY;
      semanas.push({ label: F.fechaCorta(ini).replace(/\s\d{4}$/, '').replace('.', ''), ini, fin, creados: 0, resueltos: 0 });
    }
    todas.filter(r => !r.anulado && (!f || !f.departamento || r.departamento === f.departamento)).forEach(r => {
      semanas.forEach(s => {
        if (r.creado_at >= s.ini && r.creado_at < s.fin) s.creados++;
        if (r.resuelto_at && r.resuelto_at >= s.ini && r.resuelto_at < s.fin) s.resueltos++;
      });
    });

    const etiqueta = col => k => { const x = (cats[col] || []).find(i => i.id === k); return x ? x.id + ' · ' + x.nombre : k; };
    const recurrente = (clave, col) => contar(rows.filter(r => r[clave]), clave, etiqueta(col)).filter(x => x.valor >= 2).slice(0, 6);

    const res = {
      kpis,
      por_departamento: contar(rows, 'depto_nombre'),
      por_estado: E.ORDEN.map(e => ({ clave: e, label: lbl(e), valor: rows.filter(r => r.estado === e).length })).filter(x => x.valor),
      por_prioridad: ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'].map(p => ({ clave: p, label: prioLabel(p), valor: rows.filter(r => r.prioridad === p).length })),
      por_categoria: contar(rows, 'categoria_nombre').slice(0, 8),
      por_responsable: porResponsable,
      tendencia: semanas,
      recurrentes: { clientes: recurrente('cliente_id', 'clientes'), rutas: recurrente('ruta_id', 'rutas'), choferes: recurrente('chofer_id', 'choferes') }
    };
    if (P.esTransportes(u)) {
      const mios = rows.filter(r => r.responsable_id === u.id);
      res.mios = {
        abiertos: mios.filter(r => E.ABIERTOS.includes(r.estado)).length,
        vencidos: mios.filter(r => r.sla.global === 'rojo').length,
        proximos: mios.filter(r => r.sla.global === 'amarillo').length,
        resueltos: mios.filter(r => r.resuelto_at).length,
        sin_asignar_alcance: rows.filter(r => !r.responsable_id && E.ABIERTOS.includes(r.estado) && (P.puede(u, 'ticket.asignar') || (u.alcance || []).includes(r.departamento))).length,
        cola: mios.filter(r => E.ABIERTOS.includes(r.estado)).sort((a, b) => a.sla_orden - b.sla_orden).slice(0, 8)
      };
    }
    return res;
  }

  /* ---------------- Liquidaciones ----------------
     filas: una por diferencia, con saldos ya calculados desde el libro.
     invs: investigaciones visibles [{estado, fecha_inicio, fecha_resolucion}] (ms). */
  function liquidaciones(todasFilas, invs, f, verInv) {
    const desde = f && f.dias ? Date.now() - Number(f.dias) * DAY : 0;
    const filas = todasFilas.filter(x => x.creado_at >= desde);
    const falt = filas.filter(x => x.naturaleza === 'FALTANTE');
    const suma = (a, k) => round2(a.reduce((s, x) => s + (Number(x[k]) || 0), 0));
    const agrupar = clave => {
      const m = new Map();
      falt.forEach(x => { const k = x[clave] || 'Sin dato'; const o = m.get(k) || { label: k, valor: 0, casos: 0 }; o.valor += Number(x.monto_diferencia); o.casos++; m.set(k, o); });
      return Array.from(m.values()).map(o => Object.assign(o, { valor: round2(o.valor), extra: o.casos + (o.casos === 1 ? ' caso' : ' casos') })).sort((a, b) => b.valor - a.valor);
    };
    const concl = invs.filter(i => i.estado === 'CONCLUIDA' && i.fecha_resolucion);
    return {
      kpis: {
        faltante_reportado: suma(falt, 'monto_diferencia'),
        sobrante_reportado: round2(filas.filter(x => x.naturaleza === 'SOBRANTE').reduce((s, x) => s + Math.abs(Number(x.monto_diferencia)), 0)),
        bajo_investigacion: suma(falt.filter(x => x.inv_abierta), 'pendiente'),
        aclarado: suma(falt, 'aclarado'), recuperado: suma(falt, 'recuperado'), pendiente: suma(falt, 'pendiente'),
        casos: filas.length,
        inv_abiertas: invs.filter(i => !['CONCLUIDA', 'CANCELADA'].includes(i.estado)).length,
        prom_investigacion_dias: concl.length ? concl.reduce((s, i) => s + (i.fecha_resolucion - i.fecha_inicio), 0) / concl.length / DAY : null
      },
      por_ruta: agrupar('ruta'), por_chofer: agrupar('chofer'), por_ayudante: agrupar('ayudante'), por_tipo: agrupar('categoria'),
      recurrentes: agrupar('chofer').filter(x => x.casos >= 2),
      // Los sobrantes no quedan pendientes de cobro: se ordenan después de los faltantes con saldo
      filas: filas.slice().sort((a, b) => (b.naturaleza === 'FALTANTE' ? b.pendiente : -1) - (a.naturaleza === 'FALTANTE' ? a.pendiente : -1)),
      ver_investigacion: verInv
    };
  }

  /* ---------------- Dashboard de Liquidaciones ----------------
     tickets: tickets visibles de Liquidaciones; difs: filas de diferencias (una por diferencia, con saldos).
     f: { mes: 'AAAA-MM' | '', motivo: nombre de categoría | '' } */
  const mesDe = ms => { const d = new Date(ms + F.OFF); return d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0'); };
  const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const nombreMes = k => { const [y, m] = k.split('-'); return MESES[Number(m) - 1] + ' ' + y; };
  const lunesCR = ms => { const d = new Date(ms + F.OFF); const dow = (d.getUTCDay() + 6) % 7; return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - dow) - F.OFF; };

  function dashboardLiq(todosTickets, todasDifs, f) {
    f = f || {};
    const base = todosTickets.filter(t => !t.anulado);
    const meses = Array.from(new Set(base.map(t => mesDe(t.creado_at)))).sort().reverse().map(k => ({ id: k, label: nombreMes(k) }));
    const motivos = Array.from(new Set(base.map(t => t.categoria_nombre))).sort();
    const enFiltro = (ms, motivo) => (!f.mes || mesDe(ms) === f.mes) && (!f.motivo || motivo === f.motivo);
    const tks = base.filter(t => enFiltro(t.creado_at, t.categoria_nombre));
    const ids = new Set(tks.map(t => t.id));
    const difs = todasDifs.filter(d => ids.has(d.ticket_id));
    const falt = difs.filter(d => d.naturaleza === 'FALTANTE');
    const suma = (a, k) => round2(a.reduce((s, x) => s + (Number(x[k]) || 0), 0));
    const faltante = suma(falt, 'monto_diferencia');
    const cerrados = tks.filter(t => t.resuelto_at);

    // Tendencia semanal: semanas del mes elegido, o las últimas 12 semanas
    let ini, fin;
    if (f.mes) { const [y, m] = f.mes.split('-').map(Number); ini = lunesCR(Date.UTC(y, m - 1, 1) - F.OFF); fin = Date.UTC(y, m, 1) - F.OFF; }
    else { fin = lunesCR(Date.now()) + 7 * DAY; ini = fin - 12 * 7 * DAY; }
    const semanas = [];
    for (let s = ini; s < fin; s += 7 * DAY) semanas.push({ label: F.fechaCorta(s).replace(/\s\d{4}$/, '').replace('.', ''), ini: s, fin: s + 7 * DAY, tickets: 0, resueltos: 0, monto: 0 });
    const semBase = base.filter(t => !f.motivo || t.categoria_nombre === f.motivo);
    const idsSem = new Set(semBase.map(t => t.id));
    semanas.forEach(s => {
      s.tickets = semBase.filter(t => t.creado_at >= s.ini && t.creado_at < s.fin).length;
      s.resueltos = semBase.filter(t => t.resuelto_at && t.resuelto_at >= s.ini && t.resuelto_at < s.fin).length;
      s.monto = round2(todasDifs.filter(d => idsSem.has(d.ticket_id) && d.naturaleza === 'FALTANTE' && d.creado_at >= s.ini && d.creado_at < s.fin)
        .reduce((a, d) => a + Number(d.monto_diferencia), 0));
    });

    // Por motivo (categoría): cantidad de tickets y monto faltante
    const porMotivo = new Map();
    tks.forEach(t => { const o = porMotivo.get(t.categoria_nombre) || { label: t.categoria_nombre, tickets: 0, monto: 0 }; o.tickets++; porMotivo.set(t.categoria_nombre, o); });
    falt.forEach(d => { const t = tks.find(x => x.id === d.ticket_id); const o = t && porMotivo.get(t.categoria_nombre); if (o) o.monto = round2(o.monto + Number(d.monto_diferencia)); });

    // Top de choferes involucrados: incidencias (diferencias) y monto
    const porChofer = new Map();
    difs.filter(d => d.chofer).forEach(d => {
      const o = porChofer.get(d.chofer) || { chofer: d.chofer, incidencias: 0, faltantes: 0, monto: 0, aclarado: 0, recuperado: 0, pendiente: 0, sobrante: 0 };
      o.incidencias++;
      if (d.naturaleza === 'FALTANTE') {
        o.faltantes++; o.monto = round2(o.monto + Number(d.monto_diferencia));
        o.aclarado = round2(o.aclarado + Number(d.aclarado)); o.recuperado = round2(o.recuperado + Number(d.recuperado)); o.pendiente = round2(o.pendiente + Number(d.pendiente));
      } else if (d.naturaleza === 'SOBRANTE') o.sobrante = round2(o.sobrante + Math.abs(Number(d.monto_diferencia)));
      porChofer.set(d.chofer, o);
    });

    return {
      filtros: { meses, motivos },
      kpis: {
        tickets: tks.length,
        abiertos: tks.filter(t => E.ABIERTOS.includes(t.estado)).length,
        resueltos: cerrados.length,
        con_diferencia: difs.length,
        faltante, aclarado: suma(falt, 'aclarado'), recuperado: suma(falt, 'recuperado'), pendiente: suma(falt, 'pendiente'),
        sobrante: round2(difs.filter(d => d.naturaleza === 'SOBRANTE').reduce((s, d) => s + Math.abs(Number(d.monto_diferencia)), 0)),
        pct_cerrado: faltante ? (suma(falt, 'aclarado') + suma(falt, 'recuperado')) / faltante : null,
        prom_resolucion_dias: cerrados.length ? cerrados.reduce((s, t) => s + (t.resuelto_at - t.creado_at), 0) / cerrados.length / DAY : null,
        inv_abiertas: difs.filter(d => d.inv_abierta).length
      },
      tendencia: semanas,
      por_motivo: Array.from(porMotivo.values()).sort((a, b) => b.tickets - a.tickets || b.monto - a.monto),
      por_estado: E.ORDEN.map(e => ({ clave: e, label: lbl(e), valor: tks.filter(t => t.estado === e).length })).filter(x => x.valor),
      top_choferes: Array.from(porChofer.values()).sort((a, b) => b.monto - a.monto || b.incidencias - a.incidencias).slice(0, 10)
    };
  }

  /* ---------------- Reportes ---------------- */
  const REPORTES = {
    tickets_departamento: { titulo: 'Tickets por departamento', permiso: 'reporte.operativo' },
    tickets_categoria: { titulo: 'Tickets por categoría', permiso: 'reporte.operativo' },
    tickets_estado: { titulo: 'Tickets por estado', permiso: 'reporte.operativo' },
    tickets_responsable: { titulo: 'Tickets por responsable', permiso: 'reporte.operativo' },
    cumplimiento_sla: { titulo: 'Cumplimiento SLA por prioridad', permiso: 'reporte.operativo' },
    vencidos: { titulo: 'Tickets vencidos', permiso: 'reporte.operativo' },
    tiempos: { titulo: 'Tiempos de atención (minutos hábiles)', permiso: 'reporte.operativo' },
    investigaciones: { titulo: 'Investigaciones de Liquidaciones', permiso: 'investigacion.ver' },
    diferencias: { titulo: 'Diferencias financieras', permiso: 'financiero.ver' },
    incidencias_chofer: { titulo: 'Incidencias y montos por chofer', permiso: 'financiero.ver' },
    historial: { titulo: 'Historial de solicitudes', permiso: null }
  };
  function puedeReporte(u, k) {
    if (!REPORTES[k]) return false;
    if (k === 'historial') return P.puede(u, 'reporte.operativo') || P.puede(u, 'reporte.departamento');
    if (k === 'diferencias' || k === 'investigaciones' || k === 'incidencias_chofer') return P.puede(u, 'reporte.completo') && P.puede(u, REPORTES[k].permiso);
    return P.puede(u, REPORTES[k].permiso);
  }
  function tiposReporte(u) {
    return Object.keys(REPORTES).filter(k => puedeReporte(u, k)).map(k => ({ id: k, titulo: REPORTES[k].titulo }));
  }

  /** extra.investigaciones(): filas normalizadas; extra.liquidaciones(): resultado de liquidaciones() */
  function reporte(u, tipo, todas, f, extra) {
    const rows = filtrar(todas, f);
    const min = v => (v == null ? null : Math.round(v));
    const col = (clave, label) => ({ clave, label });
    let columnas = [], filas = [];
    const agrupado = (clave, etiqueta) => {
      const m = new Map();
      rows.forEach(r => { const k = r[clave] || '—'; m.set(k, (m.get(k) || []).concat([r])); });
      return Array.from(m, ([k, g]) => ({
        grupo: etiqueta ? etiqueta(k, g) : k, total: g.length,
        abiertos: g.filter(r => E.ABIERTOS.includes(r.estado)).length,
        resueltos: g.filter(r => r.estado === 'RESUELTO').length, cerrados: g.filter(r => r.estado === 'CERRADO').length,
        rechazados: g.filter(r => r.estado === 'RECHAZADO').length, vencidos: g.filter(r => r.sla.global === 'rojo').length,
        prom_resolucion: min(promedio(g.filter(r => r.resuelto_at && r.sla.metricas.resolucion && r.sla.metricas.resolucion.transcurrido != null).map(r => r.sla.metricas.resolucion.transcurrido)))
      })).sort((a, b) => b.total - a.total);
    };
    const colsAgr = l => [col('grupo', l), col('total', 'Total'), col('abiertos', 'Abiertos'), col('resueltos', 'Resueltos'), col('cerrados', 'Cerrados'), col('rechazados', 'Rechazados'), col('vencidos', 'Vencidos'), col('prom_resolucion', 'Prom. resolución (min háb.)')];
    switch (tipo) {
      case 'tickets_departamento': columnas = colsAgr('Departamento'); filas = agrupado('depto_nombre'); break;
      case 'tickets_categoria': columnas = colsAgr('Categoría'); filas = agrupado('categoria_nombre', (k, g) => k + ' (' + g[0].depto_nombre + ')'); break;
      case 'tickets_responsable': columnas = colsAgr('Responsable'); filas = agrupado('responsable_nombre', k => (k === '—' ? 'Sin asignar' : k)); break;
      case 'tickets_estado':
        columnas = [col('estado', 'Estado'), col('total', 'Total'), col('porcentaje', '% del total')];
        filas = E.ORDEN.map(e => { const n = rows.filter(r => r.estado === e).length; return { estado: lbl(e), total: n, porcentaje: rows.length ? Math.round(n / rows.length * 1000) / 10 : 0 }; });
        break;
      case 'cumplimiento_sla':
        columnas = [col('prioridad', 'Prioridad'), col('metrica', 'Métrica'), col('medidos', 'Medidos'), col('cumplidos', 'Cumplidos'), col('incumplidos', 'Incumplidos'), col('porcentaje', '% cumplimiento')];
        ['CRITICA', 'ALTA', 'MEDIA', 'BAJA'].forEach(p => Object.keys(S.METRICAS).forEach(m => {
          const g = rows.filter(r => r.prioridad === p && r.sla.metricas[m] && ['cumplido', 'incumplido'].includes(r.sla.metricas[m].estado));
          const ok = g.filter(r => r.sla.metricas[m].estado === 'cumplido').length;
          filas.push({ prioridad: prioLabel(p), metrica: S.METRICAS[m], medidos: g.length, cumplidos: ok, incumplidos: g.length - ok, porcentaje: g.length ? Math.round(ok / g.length * 1000) / 10 : null });
        }));
        break;
      case 'vencidos':
        columnas = [col('numero', 'Ticket'), col('departamento', 'Departamento'), col('categoria', 'Categoría'), col('prioridad', 'Prioridad'), col('estado', 'Estado'), col('responsable', 'Responsable'), col('metrica', 'Métrica'), col('objetivo', 'Objetivo (min)'), col('transcurrido', 'Transcurrido (min)')];
        rows.forEach(r => Object.values(r.sla.metricas).forEach(m => {
          if (m.estado === 'rojo' || m.estado === 'incumplido') filas.push({ numero: r.numero, departamento: r.depto_nombre, categoria: r.categoria_nombre, prioridad: prioLabel(r.prioridad), estado: lbl(r.estado), responsable: r.responsable_nombre || 'Sin asignar', metrica: S.METRICAS[m.clave] + (m.estado === 'rojo' ? ' (en curso)' : ''), objetivo: m.objetivo, transcurrido: min(m.transcurrido) });
        }));
        break;
      case 'tiempos':
        columnas = [col('numero', 'Ticket'), col('creado', 'Creado'), col('departamento', 'Departamento'), col('prioridad', 'Prioridad'), col('primera_respuesta', '1.ª respuesta'), col('asignacion', 'Asignación'), col('resolucion', 'Resolución'), col('total', 'Tiempo total abierto (min calendario)')];
        filas = rows.map(r => ({
          numero: r.numero, creado: F.fecha(r.creado_at), departamento: r.depto_nombre, prioridad: prioLabel(r.prioridad),
          primera_respuesta: r.primera_respuesta_at && r.sla.metricas.primera_respuesta ? min(r.sla.metricas.primera_respuesta.transcurrido) : null,
          asignacion: r.asignado_at && r.sla.metricas.asignacion ? min(r.sla.metricas.asignacion.transcurrido) : null,
          resolucion: r.resuelto_at && r.sla.metricas.resolucion ? min(r.sla.metricas.resolucion.transcurrido) : null,
          total: r.transcurrido_min
        }));
        break;
      case 'investigaciones': {
        columnas = [col('numero', 'Ticket'), col('categoria', 'Categoría'), col('estado', 'Estado'), col('responsable', 'Responsable'), col('inicio', 'Inicio'), col('resultado', 'Resultado'), col('resolucion', 'Fecha de resolución'), col('dias', 'Días')];
        const ids = new Set(rows.map(r => r.id));
        filas = extra.investigaciones().filter(i => ids.has(i.ticket_id)).map(i => ({
          numero: i.numero, categoria: i.categoria, estado: String(i.estado).replace('_', ' '), responsable: i.responsable || 'Sin asignar',
          inicio: F.fecha(i.fecha_inicio), resultado: i.resultado || '', resolucion: i.fecha_resolucion ? F.fecha(i.fecha_resolucion) : '',
          dias: i.fecha_resolucion ? Math.round((i.fecha_resolucion - i.fecha_inicio) / DAY * 10) / 10 : null
        }));
        break;
      }
      case 'diferencias':
        columnas = [col('numero', 'Ticket'), col('fecha_operacion', 'Fecha operación'), col('ruta', 'Ruta'), col('chofer', 'Chofer'), col('ayudante', 'Ayudante'), col('tipo_diferencia', 'Tipo'), col('monto_esperado', 'Esperado'), col('monto_recibido', 'Recibido'), col('monto_diferencia', 'Diferencia'), col('aclarado', 'Aclarado'), col('recuperado', 'Recuperado'), col('pendiente', 'Pendiente'), col('inv_estado', 'Investigación'), col('inv_resultado', 'Resultado')];
        filas = extra.liquidaciones().filas;
        break;
      case 'incidencias_chofer': {
        columnas = [col('chofer', 'Chofer'), col('incidencias', 'Incidencias'), col('faltantes', 'Faltantes'), col('monto', 'Monto faltante'), col('aclarado', 'Aclarado'), col('recuperado', 'Recuperado'), col('pendiente', 'Pendiente'), col('sobrante', 'Sobrante')];
        const m = new Map();
        extra.liquidaciones().filas.filter(d => d.chofer).forEach(d => {
          const o = m.get(d.chofer) || { chofer: d.chofer, incidencias: 0, faltantes: 0, monto: 0, aclarado: 0, recuperado: 0, pendiente: 0, sobrante: 0 };
          o.incidencias++;
          if (d.naturaleza === 'FALTANTE') { o.faltantes++; o.monto = round2(o.monto + Number(d.monto_diferencia)); o.aclarado = round2(o.aclarado + Number(d.aclarado)); o.recuperado = round2(o.recuperado + Number(d.recuperado)); o.pendiente = round2(o.pendiente + Number(d.pendiente)); }
          else if (d.naturaleza === 'SOBRANTE') o.sobrante = round2(o.sobrante + Math.abs(Number(d.monto_diferencia)));
          m.set(d.chofer, o);
        });
        filas = Array.from(m.values()).sort((a, b) => b.monto - a.monto || b.incidencias - a.incidencias);
        break;
      }
      case 'historial':
        columnas = [col('numero', 'Ticket'), col('creado', 'Creado'), col('departamento', 'Departamento'), col('solicitante', 'Solicitante'), col('tipo', 'Tipo'), col('categoria', 'Categoría'), col('asunto', 'Asunto'), col('prioridad', 'Prioridad'), col('estado', 'Estado'), col('responsable', 'Responsable'), col('resuelto', 'Resuelto'), col('cerrado', 'Cerrado')];
        filas = rows.map(r => ({ numero: r.numero, creado: F.fecha(r.creado_at), departamento: r.depto_nombre, solicitante: r.solicitante_nombre, tipo: r.tipo_nombre, categoria: r.categoria_nombre, asunto: r.asunto, prioridad: prioLabel(r.prioridad), estado: lbl(r.estado), responsable: r.responsable_nombre || '', resuelto: r.resuelto_at ? F.fecha(r.resuelto_at) : '', cerrado: r.cerrado_at ? F.fecha(r.cerrado_at) : '' }));
        break;
      default: break;
    }
    return { tipo, titulo: REPORTES[tipo].titulo, columnas, filas, generado: Date.now(), generado_por: u.nombre };
  }

  APD.calculos = { filtrar, contar, dashboard, dashboardLiq, liquidaciones, REPORTES, puedeReporte, tiposReporte, reporte };
})();
