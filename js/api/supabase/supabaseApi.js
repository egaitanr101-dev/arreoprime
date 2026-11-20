/* ============================================================================
 * API con base de datos real (Supabase / PostgreSQL + PostgREST).
 *
 * Implementa exactamente la misma interfaz pública que la API de demostración
 * (APD.api), de modo que las pantallas no cambian. Toda la seguridad la aplica la
 * base de datos: las lecturas pasan por RLS y las escrituras por funciones RPC.
 * Este archivo solo traduce formatos; no decide permisos.
 *
 * Modos:
 *   SUPABASE → proyecto Supabase (Auth, Storage, Edge Functions).
 *   LOCAL    → PostgreSQL + PostgREST en el propio equipo, con usuarios de prueba
 *              (tools/entorno-pruebas.ps1). Sin Storage ni envío de correos.
 * ========================================================================== */
(function () {
  'use strict';
  const P = APD.permisos, E = APD.estados;
  const ApiError = APD.ApiError || class extends Error { constructor(m, c) { super(m); this.code = c || 'ERROR'; } };
  APD.ApiError = ApiError;
  const CODIGOS = ['NO_AUTENTICADO', 'NO_AUTORIZADO', 'NO_ENCONTRADO', 'VALIDACION', 'TRANSICION_INVALIDA', 'INMUTABLE'];
  // Se captura antes de que el cliente procese y limpie el retorno de invitación o recuperación.
  const HASH_INICIAL = location.hash;

  function crear() {
    const cfg = APD.config;
    const local = cfg.modo === 'LOCAL';
    let tokenPrueba = null;
    const sb = window.supabase.createClient(cfg.supabase.url, cfg.supabase.anonKey, local
      ? { accessToken: async () => tokenPrueba || cfg.supabase.anonKey }
      : { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });

    let perfil = null;
    let cache = null;

    /* ---------------- Utilidades ---------------- */
    function aError(e) {
      if (e instanceof ApiError) return e;
      const hint = e && e.hint;
      let codigo = CODIGOS.includes(hint) ? hint
        : e && e.code === '42501' ? 'NO_AUTORIZADO'
        : e && (e.code === 'PGRST301' || e.code === 'PGRST302' || e.status === 401) ? 'NO_AUTENTICADO' : 'ERROR';
      let msg = (e && e.message) || 'Error de comunicación con el servidor.';
      if (codigo === 'NO_AUTORIZADO' && /permission denied|row-level security/i.test(msg)) msg = 'No autorizado para esta operación.';
      if (/Failed to fetch|NetworkError/i.test(msg)) msg = 'No hay conexión con el servidor. Revise su conexión e intente de nuevo.';
      if (/Invalid login credentials/i.test(msg)) { msg = 'Correo o contraseña incorrectos.'; codigo = 'NO_AUTENTICADO'; }
      if (/Email not confirmed/i.test(msg)) { msg = 'Debe confirmar su correo con el enlace de invitación antes de ingresar.'; codigo = 'NO_AUTENTICADO'; }
      if (/Password should be at least/i.test(msg)) msg = 'La contraseña no cumple la longitud mínima.';
      if (/rate limit/i.test(msg)) msg = 'Demasiados intentos. Espere unos minutos e intente de nuevo.';
      return new ApiError(msg, codigo);
    }
    async function q(consulta) {
      let r;
      try { r = await consulta; } catch (e) { throw aError(e); }
      if (r.error) throw aError(r.error);
      return r.data;
    }
    const rpc = (fn, args) => q(sb.rpc(fn, args || {}));
    /** Lee todas las filas en bloques de 1 000 (límite por solicitud de la API) */
    async function todos(armar) {
      const out = [];
      for (let i = 0; ; i += 1000) {
        const d = await q(armar().range(i, i + 999));
        out.push.apply(out, d);
        if (d.length < 1000) break;
      }
      return out;
    }
    const ms = s => (s ? Date.parse(s) : null);
    const num = v => (v == null ? null : Number(v));
    const exigir = permiso => { if (!P.puede(perfil, permiso)) throw new ApiError('No autorizado para esta operación.', 'NO_AUTORIZADO'); };
    const requiereSesion = () => { if (!perfil) throw new ApiError('Sesión no válida. Inicie sesión nuevamente.', 'NO_AUTENTICADO'); };

    /* ---------------- Sesión ---------------- */
    async function cargarPerfil() {
      const p = await rpc('fn_mi_perfil');
      cache = null;
      perfil = {
        id: p.id, nombre: p.nombre, correo: p.correo, rol: p.rol, departamento: p.departamento, depto_nombre: p.depto_nombre,
        activo: p.activo, disponible: p.disponible, alcance: p.alcance || [], permisos_extra: [], permisos_efectivos: p.permisos || []
      };
      return perfil;
    }

    /* ---------------- Catálogos (caché por sesión) ---------------- */
    async function catalogos() {
      requiereSesion();
      if (cache) return cache;
      const t = n => q(sb.from(n).select('*'));
      const [deps, tipos, prios, campos, cats, catTipos, catCampos, motivos, respuestas, resultados, eventos,
        clientes, rutas, vehiculos, colaboradores, bodegas, unidades, perfiles, alcance] = await Promise.all([
        t('departamentos'), t('tipos_gestion'), t('prioridades'), t('campos_definicion'), t('categorias'), t('categoria_tipos'),
        q(sb.from('categoria_campos').select('*').order('orden')), t('motivos'), q(sb.from('respuestas_rapidas').select('*').eq('activo', true).order('orden')),
        q(sb.from('resultados_investigacion').select('*').order('orden')), t('eventos_notificacion'),
        t('clientes'), t('rutas'), t('vehiculos'), t('colaboradores'), t('bodegas'), t('unidades_medida'),
        todos(() => sb.from('perfiles').select('id,nombre,rol_id,departamento_id,activo,disponible')), t('operador_alcance')]);
      const esT = P.esTransportes(perfil), adm = P.puede(perfil, 'admin.catalogos');
      const camposMap = {};
      campos.forEach(c => { camposMap[c.clave] = { etiqueta: c.etiqueta, tipo: c.tipo, catalogo: c.catalogo, opciones: c.opciones, financiero: c.financiero, placeholder: c.placeholder, ayuda: c.ayuda }; });
      const activos = l => l.filter(x => x.activo !== false);
      const transportes = perfiles.filter(x => x.rol_id === 'OPERADOR_TRANSPORTES' || x.rol_id === 'SUPERVISOR_TRANSPORTES');
      cache = {
        departamentos: deps.map(d => ({ id: d.id, nombre: d.nombre, tipo: d.tipo })),
        tipos: tipos.sort((a, b) => a.orden - b.orden).map(x => ({ id: x.id, nombre: x.nombre })),
        prioridades: prios.sort((a, b) => a.orden - b.orden),
        campos: camposMap,
        categorias: cats.sort((a, b) => a.departamento_id.localeCompare(b.departamento_id) || a.orden - b.orden)
          .filter(c => adm || (c.activo && (esT || perfil.rol === 'GERENCIA' || c.departamento_id === perfil.departamento)))
          .map(c => ({
            id: c.id, departamento: c.departamento_id, nombre: c.nombre, tipo_default: c.tipo_gestion_default,
            tipos_validos: catTipos.filter(x => x.categoria_id === c.id).map(x => x.tipo_id).sort((a, b) => (a === c.tipo_gestion_default ? -1 : b === c.tipo_gestion_default ? 1 : 0)),
            prioridad_sugerida: c.prioridad_sugerida, activo: c.activo, financiero: c.financiero, genera_investigacion: c.genera_investigacion,
            requiere_aprobacion: c.requiere_aprobacion, responsable_sugerido_id: c.responsable_sugerido_id,
            campos: catCampos.filter(x => x.categoria_id === c.id).map(x => ({ clave: x.campo_clave, obligatorio: x.obligatorio }))
          })),
        motivos: motivos.filter(m => m.activo).map(m => ({ id: m.id, tipo: m.tipo, nombre: m.nombre, pausa_sla: m.pausa_sla })),
        respuestas: esT ? respuestas.map(r => ({ id: r.id, nombre: r.nombre, texto: r.texto })) : [],
        resultados: resultados.map(r => r.nombre),
        clientes: activos(clientes), rutas: activos(rutas), bodegas: activos(bodegas), unidades: activos(unidades),
        vehiculos: activos(vehiculos).map(v => ({ id: v.id, nombre: v.descripcion })),
        choferes: activos(colaboradores).filter(c => c.tipo === 'CHOFER'),
        ayudantes: activos(colaboradores).filter(c => c.tipo === 'AYUDANTE'),
        solicitantes: P.puede(perfil, 'ticket.registro_asistido') ? perfiles.filter(x => (x.rol_id === 'SOLICITANTE' || x.rol_id === 'SUPERVISOR_LIQUIDACIONES') && x.activo).map(x => ({ id: x.id, nombre: x.nombre, departamento: x.departamento_id })) : [],
        responsables: (esT || perfil.rol === 'GERENCIA') ? transportes.map(x => ({ id: x.id, nombre: x.nombre, rol: x.rol_id, activo: x.activo, disponible: x.disponible, alcance: alcance.filter(a => a.perfil_id === x.id).map(a => a.departamento_id) })) : [],
        // internos
        _perfiles: new Map(perfiles.map(x => [x.id, x])),
        _resultados: resultados,
        _eventos: eventos,
        _catsTodas: cats
      };
      return cache;
    }
    const nombreDe = (c, id) => (id == null ? 'Sistema (proceso automático)' : (c._perfiles.get(id) || {}).nombre || '—');
    const etiqueta = (c, col, id) => { if (!id) return null; const x = (c[col] || []).find(i => i.id === id); return x ? x.id + ' · ' + x.nombre : id; };
    function mostrarValor(c, clave, v) {
      const def = c.campos[clave];
      if (v == null || v === '') return null;
      if (def.tipo === 'catalogo') return etiqueta(c, def.catalogo, v);
      if (def.tipo === 'fecha') return APD.fmt.fechaDeISO(v);
      if (def.tipo === 'crc') return APD.fmt.crc(v);
      if (def.tipo === 'numero') return APD.fmt.num(Number(v));
      return String(v);
    }

    /* ---------------- Tickets ---------------- */
    function normSla(s) {
      if (!s) return { global: 'sin', foco: null, metricas: {}, pausado: false };
      const m = {};
      Object.keys(s.metricas || {}).forEach(k => { m[k] = Object.assign({ clave: k }, s.metricas[k]); });
      const foco = s.foco ? Object.assign({}, m[s.foco.metrica] || {}, { clave: s.foco.metrica, estado: s.foco.estado, restante: num(s.foco.restante) }) : null;
      return { global: s.global, foco, metricas: m, pausado: !!s.pausado };
    }
    function fila(v) {
      const d = v.datos || {};
      return {
        id: v.id, numero: v.numero, creado_at: ms(v.creado_at), departamento: v.departamento_id, depto_nombre: v.depto_nombre,
        solicitante_id: v.solicitante_id, solicitante_nombre: v.solicitante_nombre || '—', registrado_por_nombre: v.registrado_por_nombre || '—', canal: v.canal,
        tipo_id: v.tipo_gestion_id, tipo_nombre: v.tipo_nombre, categoria_id: v.categoria_id, categoria_nombre: v.categoria_nombre,
        asunto: v.asunto, descripcion: v.descripcion, datos: d,
        prioridad: v.prioridad_id, prioridad_sugerida: v.prioridad_sugerida, prioridad_orden: v.prioridad_orden,
        estado: v.estado_id, estado_orden: v.estado_orden, estado_previo: v.estado_previo, motivo_espera_nombre: v.motivo_espera_nombre,
        responsable_id: v.responsable_id, responsable_nombre: v.responsable_nombre, responsable_alerta: v.responsable_alerta,
        cliente_id: v.cliente_id, cliente_nombre: v.cliente_nombre, ruta_id: v.ruta_id, ruta_nombre: v.ruta_nombre,
        factura: v.factura, pedido: v.pedido, fecha_requerida: v.fecha_requerida, transcurrido_min: v.transcurrido_min,
        sla: normSla(v.sla), sla_orden: v.sla ? num(v.sla.orden) : 9e9, sla_version: v.sla ? v.sla.version : null,
        primera_respuesta_at: ms(v.primera_respuesta_at), asignado_at: ms(v.asignado_at), resuelto_at: ms(v.resuelto_at),
        cerrado_at: ms(v.cerrado_at), rechazado_at: ms(v.rechazado_at), reaperturas: v.reaperturas,
        cierre_excepcional: v.cierre_excepcional, anulado: v.anulado, anulado_motivo: v.anulado_motivo,
        motivo_rechazo_nombre: v.motivo_rechazo_nombre, resolucion: v.resolucion,
        pendiente_info: v.pendiente_info, tiene_investigacion: v.tiene_investigacion,
        chofer_id: d.chofer || null, ayudante_id: d.ayudante || null
      };
    }
    async function listar() {
      requiereSesion();
      const filas = await todos(() => sb.from('v_tickets').select('*').order('creado_at', { ascending: false }).order('id'));
      return filas.map(fila);
    }

    async function subirEvidencias(ticketId, evidencias, visibilidad, comentarioId) {
      const lista = (evidencias || []).filter(e => e && e.archivo);
      if (!lista.length) return null;
      if (local) return 'Archivos no cargados: el entorno local de pruebas no incluye almacenamiento de archivos.';
      for (const e of lista) {
        const prep = await rpc('fn_evidencia_preparar', {
          p_ticket: ticketId, p_nombre: e.nombre, p_tamano: e.tamano, p_mime: e.tipo || e.archivo.type || 'application/octet-stream',
          p_visibilidad: visibilidad || 'PUBLICO', p_comentario: comentarioId || null
        });
        await q(sb.storage.from(prep.bucket).upload(prep.ruta, e.archivo, { contentType: e.tipo || e.archivo.type, upsert: false }));
        await rpc('fn_evidencia_confirmar', { p_evidencia: prep.id });
      }
      return null;
    }

    async function obtener(id) {
      requiereSesion();
      const c = await catalogos();
      const v = (await q(sb.from('v_tickets').select('*').eq('id', id)))[0];
      if (!v) throw new ApiError('Ticket no encontrado o sin acceso.', 'NO_ENCONTRADO');
      const t = fila(v);
      const cat = c._catsTodas.find(x => x.id === t.categoria_id) || {};
      const catDef = c.categorias.find(x => x.id === t.categoria_id);
      const verFin = P.puede(perfil, 'financiero.ver');
      const verInv = P.puede(perfil, 'investigacion.ver');
      const verInvRes = P.puede(perfil, 'investigacion.ver_resumen');
      const vacio = Promise.resolve([]);
      const [coms, evs, hist, asigs, acciones, difs, movs, invs] = await Promise.all([
        q(sb.from('comentarios').select('*').eq('ticket_id', id).order('creado_at').order('id')),
        q(sb.from('evidencias').select('*').eq('ticket_id', id).eq('estado', 'CONFIRMADA').order('creado_at')),
        q(sb.from('historial_tickets').select('*').eq('ticket_id', id).order('ts').order('id')),
        P.puede(perfil, 'ticket.ver_todos') ? q(sb.from('asignaciones').select('*').eq('ticket_id', id).order('desde')) : vacio,
        rpc('fn_ticket_acciones', { p_ticket: id }),
        verFin && cat.financiero ? q(sb.schema('reporting').from('v_diferencias').select('*').eq('ticket_id', id)) : vacio,
        verFin && cat.financiero ? q(sb.from('movimientos_financieros').select('*').eq('ticket_id', id).order('creado_at')) : vacio,
        (verInv || verInvRes) && cat.genera_investigacion ? q(sb.from('investigaciones').select('*').eq('ticket_id', id)) : vacio
      ]);
      const rolLabel = uid => { const p = c._perfiles.get(uid); return p ? P.etiquetaRol(p.rol_id, p.departamento_id) : ''; };
      const evid = evs.map(e => ({ id: e.id, nombre: e.nombre, tamano: e.tamano_bytes, tipo: e.mime, visibilidad: e.visibilidad, ruta: e.ruta, comentario_id: e.comentario_id, ts: ms(e.creado_at), subido_por_nombre: nombreDe(c, e.subido_por) }));
      const comentarios = coms.map(x => {
        const p = c._perfiles.get(x.autor_id);
        return { id: x.id, ticket_id: x.ticket_id, autor_id: x.autor_id, ts: ms(x.creado_at), visibilidad: x.visibilidad, tipo: x.tipo, texto: x.texto,
          autor_nombre: nombreDe(c, x.autor_id), autor_rol: rolLabel(x.autor_id), es_transportes: !!p && P.esTransportes({ rol: p.rol_id }),
          evidencias: evid.filter(e => e.comentario_id === x.id) };
      });
      const info = comentarios.filter(x => x.tipo === 'SOLICITUD_INFO' || x.tipo === 'RESPUESTA_INFO');
      const ult = info[info.length - 1];
      const pendiente = ult && ult.tipo === 'SOLICITUD_INFO' && !t.anulado && !E.TERMINALES.includes(t.estado) ? ult : null;

      const r = {
        ticket: t,
        campos: (catDef ? catDef.campos.map(x => x.clave) : Object.keys(t.datos))
          .filter(k => c.campos[k] && !c.campos[k].financiero && t.datos[k] != null)
          .map(k => ({ clave: k, etiqueta: c.campos[k].etiqueta, valor: mostrarValor(c, k, t.datos[k]) })),
        comentarios, evidencias: evid,
        historial: hist.map(h => ({ id: h.id, ts: ms(h.ts), evento: h.evento, detalle: h.detalle, visibilidad: h.visibilidad, usuario_nombre: nombreDe(c, h.usuario_id) })),
        acciones: (acciones || []).filter(a => E.ACCIONES[a.codigo]).map(a => {
          const m = E.ACCIONES[a.codigo];
          return { codigo: a.codigo, label: m.label, icono: m.icono, primaria: !!m.primaria, peligro: !!m.peligro, requiere: m.requiere || [], bloqueo: a.bloqueo || null };
        }).sort((x, y) => Object.keys(E.ACCIONES).indexOf(x.codigo) - Object.keys(E.ACCIONES).indexOf(y.codigo)),
        asignaciones: P.puede(perfil, 'ticket.ver_todos') ? asigs.map(a => ({ responsable_nombre: nombreDe(c, a.responsable_id), asignado_por_nombre: nombreDe(c, a.asignado_por), tipo: a.tipo, motivo: a.motivo, desde: ms(a.desde), hasta: ms(a.hasta) })) : null,
        financiero: null, investigacion: null, pendiente_info: pendiente,
        puede: {
          comentar_publico: P.puede(perfil, 'ticket.comentar_publico') && !t.anulado && (P.esTransportes(perfil) || !E.TERMINALES.includes(t.estado)),
          nota_interna: P.puede(perfil, 'ticket.nota_interna') && !t.anulado,
          adjuntar: P.puede(perfil, 'evidencia.subir') && !t.anulado && (P.esTransportes(perfil) || !E.TERMINALES.includes(t.estado)),
          responder_info: P.puede(perfil, 'ticket.responder_info') && perfil.departamento === t.departamento && !!pendiente,
          registrar_movimiento: P.puede(perfil, 'financiero.registrar') && !t.anulado
        }
      };
      if (cat.financiero) {
        r.financiero = !verFin ? { restringido: true } : (difs.length ? {
          diferencias: difs.map(d => {
            const mv = movs.filter(m => m.diferencia_id === d.diferencia_id);
            const dif = num(d.monto_diferencia);
            return {
              id: d.diferencia_id, ticket_id: d.ticket_id, num_liquidacion: d.num_liquidacion, ruta_id: d.ruta_id, fecha_operacion: d.fecha_operacion,
              chofer_id: d.chofer_id, ayudante_id: d.ayudante_id, tipo_diferencia: d.tipo_diferencia, medio_pago: d.medio_pago,
              monto_esperado: num(d.monto_esperado), monto_recibido: num(d.monto_recibido), monto_reportado: num(d.monto_reportado), monto_diferencia: dif,
              ruta_nombre: etiqueta(c, 'rutas', d.ruta_id), chofer_nombre: etiqueta(c, 'choferes', d.chofer_id), ayudante_nombre: etiqueta(c, 'ayudantes', d.ayudante_id),
              conciliado: d.monto_reportado == null || Math.abs(Math.abs(dif) - num(d.monto_reportado)) < 0.01,
              resumen: { base: Math.abs(dif), aclarado: num(d.aclarado), recuperado: num(d.recuperado), ajuste: num(d.ajuste), pendiente: num(d.pendiente), naturaleza: d.naturaleza },
              movimientos: mv.map(m => ({ id: m.id, ts: ms(m.creado_at), tipo: m.tipo, monto: num(m.monto), nota: m.nota, revierte_id: m.revierte_id, usuario_nombre: nombreDe(c, m.usuario_id), revertido: mv.some(x => x.revierte_id === m.id) }))
            };
          })
        } : null);
      }
      if (cat.genera_investigacion) {
        const inv = invs[0];
        const resNombre = rid => { const x = c._resultados.find(y => y.id === rid); return x ? x.nombre : rid; };
        if (!inv) r.investigacion = (verInv || verInvRes) ? null : { nivel: 'restringido' };
        else if (verInv) {
          const [hall, invol, concl] = await Promise.all([
            q(sb.from('investigacion_hallazgos').select('*').eq('investigacion_id', inv.id).order('creado_at')),
            q(sb.from('investigacion_involucrados').select('*').eq('investigacion_id', inv.id)),
            q(sb.from('investigacion_conclusiones').select('*').eq('investigacion_id', inv.id).order('concluida_at'))]);
          r.investigacion = {
            id: inv.id, nivel: 'completo', estado: inv.estado, responsable_id: inv.responsable_id, responsable_nombre: inv.responsable_id ? nombreDe(c, inv.responsable_id) : null,
            fecha_inicio: ms(inv.fecha_inicio), resultado: inv.resultado_id ? resNombre(inv.resultado_id) : null, conclusion: inv.conclusion,
            fecha_resolucion: ms(inv.fecha_resolucion), concluida_por_nombre: inv.concluida_por ? nombreDe(c, inv.concluida_por) : null,
            involucrados: invol.map(x => ({ rol: x.rol, nombre: etiqueta(c, x.rol === 'Chofer' ? 'choferes' : 'ayudantes', x.colaborador_id) || x.colaborador_id })),
            hallazgos: hall.map(h => ({ id: h.id, texto: h.texto, autor_nombre: nombreDe(c, h.autor_id), ts: ms(h.creado_at) })),
            conclusiones_previas: concl.map(x => ({ resultado: resNombre(x.resultado_id), conclusion: x.conclusion, fecha: ms(x.concluida_at) })),
            // Igual que app.puede_gestionar_inv: supervisión, el responsable de la investigación o, sin responsable, el del ticket
            puede_gestionar: P.puede(perfil, 'investigacion.gestionar') && (P.puede(perfil, 'ticket.gestionar_todos') || inv.responsable_id === perfil.id ||
              (!inv.responsable_id && t.responsable_id === perfil.id)),
            puede_asignar: P.puede(perfil, 'ticket.asignar') && P.puede(perfil, 'investigacion.gestionar'),
            puede_reabrir: P.puede(perfil, 'ticket.reabrir') && P.puede(perfil, 'investigacion.gestionar'),
            candidatos: c.responsables.filter(x => x.activo).map(x => ({ id: x.id, nombre: x.nombre })),
            resultados: c.resultados
          };
        } else {
          r.investigacion = { nivel: 'resumen', estado: inv.estado, resultado: inv.resultado_id ? resNombre(inv.resultado_id) : null, conclusion: inv.conclusion, fecha_inicio: ms(inv.fecha_inicio), fecha_resolucion: ms(inv.fecha_resolucion) };
        }
      }
      return r;
    }

    /* ---------------- Liquidaciones ---------------- */
    async function filasDiferencias() {
      const c = await catalogos();
      const verInv = P.puede(perfil, 'investigacion.ver') || P.puede(perfil, 'investigacion.ver_resumen');
      const [difs, invs] = await Promise.all([
        todos(() => sb.schema('reporting').from('v_diferencias').select('*').order('creado_at')),
        verInv ? todos(() => sb.schema('reporting').from('v_investigaciones').select('*')) : Promise.resolve([])
      ]);
      const catNombre = id => (c._catsTodas.find(x => x.id === id) || {}).nombre || id;
      const resNombre = rid => { const x = c._resultados.find(y => y.id === rid); return x ? x.nombre : rid; };
      const filas = difs.map(d => ({
        id: d.diferencia_id, ticket_id: d.ticket_id, numero: d.numero, estado_ticket: d.estado_ticket, categoria: catNombre(d.categoria_id), creado_at: ms(d.creado_at),
        fecha_operacion: d.fecha_operacion, ruta: etiqueta(c, 'rutas', d.ruta_id), ruta_id: d.ruta_id, chofer: etiqueta(c, 'choferes', d.chofer_id), ayudante: etiqueta(c, 'ayudantes', d.ayudante_id),
        tipo_diferencia: d.tipo_diferencia, medio_pago: d.medio_pago, monto_esperado: num(d.monto_esperado), monto_recibido: num(d.monto_recibido),
        monto_reportado: num(d.monto_reportado), monto_diferencia: num(d.monto_diferencia), naturaleza: d.naturaleza,
        aclarado: num(d.aclarado), recuperado: num(d.recuperado), ajuste: num(d.ajuste), pendiente: num(d.pendiente),
        inv_estado: verInv ? d.investigacion_estado : null, inv_resultado: verInv && d.investigacion_resultado ? resNombre(d.investigacion_resultado) : null,
        inv_abierta: !!d.investigacion_estado && !['CONCLUIDA', 'CANCELADA'].includes(d.investigacion_estado)
      }));
      const investigaciones = invs.map(i => ({
        ticket_id: i.ticket_id, numero: i.numero, categoria: catNombre(i.categoria_id), estado: i.estado,
        responsable: i.responsable_id ? nombreDe(c, i.responsable_id) : null, fecha_inicio: ms(i.fecha_inicio),
        resultado: i.resultado_id ? resNombre(i.resultado_id) : null, fecha_resolucion: ms(i.fecha_resolucion)
      }));
      return { filas, investigaciones, verInv };
    }
    async function resumenFinanciero(f) {
      requiereSesion();
      exigir('financiero.ver');
      const d = await filasDiferencias();
      return APD.calculos.liquidaciones(d.filas, d.investigaciones, f, d.verInv);
    }

    /* ---------------- SLA ---------------- */
    const hm = s => { const [h, m] = String(s).split(':').map(Number); return h * 60 + m; };
    async function estadoSla() {
      requiereSesion();
      exigir('sla.ver');
      const [vers, vals, cal, fer] = await Promise.all([
        q(sb.from('sla_versiones').select('*').order('version')), q(sb.from('sla_valores').select('*')),
        q(sb.from('calendario_laboral').select('*')), q(sb.from('feriados').select('*').order('fecha'))]);
      const versiones = vers.map(v => {
        const valores = {};
        vals.filter(x => x.version === v.version && !x.categoria_id).forEach(x => {
          valores[x.prioridad_id] = { primera_respuesta: x.minutos_primera_respuesta, asignacion: x.minutos_asignacion, resolucion: x.minutos_resolucion, maximo_horas: x.horas_maximo_atencion };
        });
        return { version: v.version, vigente_desde: ms(v.vigente_desde), vigente_hasta: ms(v.vigente_hasta), umbral: num(v.umbral), nota: v.nota, valores,
                 especificos: vals.filter(x => x.version === v.version && x.categoria_id).length };
      });
      const calendario = { 0: null, 1: null, 2: null, 3: null, 4: null, 5: null, 6: null };
      cal.forEach(x => { calendario[x.dia_semana] = [hm(x.hora_inicio), hm(x.hora_fin)]; });
      const r = { versiones, vigente: versiones.find(v => v.vigente_hasta == null) || null, calendario, feriados: fer, puede_configurar: P.puede(perfil, 'sla.configurar'), riesgo: null };
      if (P.puede(perfil, 'ticket.ver_todos')) {
        const filas = (await listar()).filter(x => !x.anulado && E.ABIERTOS.includes(x.estado));
        r.riesgo = { conteo: { verde: 0, amarillo: 0, rojo: 0, pausado: 0 }, filas: filas.filter(x => x.sla.global === 'rojo' || x.sla.global === 'amarillo').sort((a, b) => a.sla_orden - b.sla_orden) };
        filas.forEach(x => { if (x.sla.pausado) r.riesgo.conteo.pausado++; if (r.riesgo.conteo[x.sla.global] != null) r.riesgo.conteo[x.sla.global]++; });
      }
      return r;
    }

    /* ---------------- API pública (misma interfaz que el modo DEMO) ---------------- */
    const api = {
      modo: cfg.modo,
      sesion: {
        usuariosDemo: async () => (cfg.usuariosPrueba || []).map(x => ({ id: x.id, nombre: x.nombre, rol: x.rol, departamento: x.departamento, depto_nombre: x.depto_nombre, activo: true, nota_demo: x.nota || '' })),
        iniciar: async id => {
          const u = (cfg.usuariosPrueba || []).find(x => x.id === id);
          if (!u) throw new ApiError('Usuario de prueba no encontrado.', 'NO_ENCONTRADO');
          tokenPrueba = u.token;
          try { return await cargarPerfil(); } catch (e) { tokenPrueba = null; perfil = null; throw e; }
        },
        iniciarConCorreo: async (correo, clave) => {
          await q(sb.auth.signInWithPassword({ email: String(correo || '').trim(), password: clave }));
          try { return await cargarPerfil(); } catch (e) { await sb.auth.signOut(); perfil = null; throw e; }
        },
        iniciarMicrosoft: async () => {
          await q(sb.auth.signInWithOAuth({ provider: 'azure', options: { scopes: 'email openid profile', redirectTo: location.origin + location.pathname } }));
        },
        recuperar: async correo => {
          await q(sb.auth.resetPasswordForEmail(String(correo || '').trim(), { redirectTo: location.origin + location.pathname }));
          return true;
        },
        definirClave: async clave => { await q(sb.auth.updateUser({ password: clave })); return true; },
        /** Tras volver de un enlace de invitación o recuperación: 'invite' | 'recovery' | null */
        procesarRetorno: async () => {
          if (local || !/access_token=|error_description=/.test(HASH_INICIAL)) return null;
          const p = new URLSearchParams(HASH_INICIAL.replace(/^#/, ''));
          if (p.get('error_description')) throw new ApiError(p.get('error_description'), 'NO_AUTENTICADO');
          await sb.auth.getSession();
          return p.get('type') === 'invite' || p.get('type') === 'recovery' ? p.get('type') : 'login';
        },
        cerrar: async () => { perfil = null; cache = null; if (local) tokenPrueba = null; else await sb.auth.signOut(); },
        actual: async () => {
          if (perfil) return perfil;
          if (local) return null;
          const s = await q(sb.auth.getSession());
          if (!s || !s.session) return null;
          return cargarPerfil();
        }
      },
      catalogos: async () => catalogos(),
      tickets: {
        listar,
        obtener,
        crear: async p => {
          requiereSesion();
          const r = await rpc('fn_ticket_crear', { p: { asistido: !!p.asistido, solicitante_id: p.solicitante_id || null, categoria_id: p.categoria_id, tipo_id: p.tipo_id, asunto: p.asunto, descripcion: p.descripcion, datos: p.datos || {} } });
          let advertencia = null;
          try { advertencia = await subirEvidencias(r.id, p.evidencias, 'PUBLICO', null); }
          catch (e) { advertencia = 'El ticket se creó, pero no se pudieron cargar los archivos: ' + aError(e).message; }
          const v = (await q(sb.from('v_tickets').select('*').eq('id', r.id)))[0];
          return Object.assign(fila(v), { advertencia });
        },
        accion: async (id, codigo, p) => {
          p = Object.assign({}, p || {});
          if (p.resultado_inv) {  // la interfaz muestra el nombre; el servidor espera el código
            const c = await catalogos();
            const res = c._resultados.find(x => x.nombre === p.resultado_inv || x.id === p.resultado_inv);
            if (res) p.resultado_inv = res.id;
          }
          const evidencias = p.evidencias; delete p.evidencias;
          await rpc('fn_ticket_accion', { p_ticket: id, p_accion: codigo, p });
          // Evidencias de la resolución: se cargan después y se unen al comentario de resolución
          if (codigo === 'resolver' && evidencias && evidencias.length) {
            let adv;
            try {
              const cRes = (await q(sb.from('comentarios').select('id').eq('ticket_id', id).eq('tipo', 'RESOLUCION').eq('autor_id', perfil.id)
                .order('creado_at', { ascending: false }).limit(1)))[0];
              adv = await subirEvidencias(id, evidencias, 'PUBLICO', cRes ? cRes.id : null);
            } catch (e) { adv = 'no se pudieron cargar los archivos: ' + aError(e).message; }
            if (adv) throw new ApiError('El ticket quedó resuelto, pero ' + adv.charAt(0).toLowerCase() + adv.slice(1) + ' Adjúntelos desde la conversación.', 'VALIDACION');
          }
          return true;
        },
        comentar: async (id, p) => {
          const cid = await rpc('fn_ticket_comentar', { p_ticket: id, p_texto: p.texto, p_visibilidad: p.visibilidad || 'PUBLICO' });
          const adv = await subirEvidencias(id, p.evidencias, p.visibilidad, cid);
          if (adv) throw new ApiError('Comentario publicado. ' + adv, 'VALIDACION');
          return true;
        },
        responderInfo: async (id, texto, evidencias) => {
          const cid = await rpc('fn_ticket_responder_info', { p_ticket: id, p_texto: texto });
          const adv = await subirEvidencias(id, evidencias, 'PUBLICO', cid);
          if (adv) throw new ApiError('Respuesta enviada. ' + adv, 'VALIDACION');
          return true;
        },
        adjuntar: async (id, archivos, vis) => subirEvidencias(id, archivos, vis, null),
        responsables: async id => rpc('fn_responsables_para', { p_ticket: id }),
        buscar: async texto => {
          const n = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
          const qq = n(texto).trim();
          if (qq.length < 2) return [];
          return (await listar()).filter(r => [r.numero, r.factura, r.pedido, r.ruta_id, r.ruta_nombre, r.cliente_nombre, r.asunto].some(v => n(v).includes(qq))).slice(0, 20);
        }
      },
      /** URL firmada de 5 minutos (solo si el usuario puede ver la evidencia) */
      urlEvidencia: local ? null : async ruta => (await q(sb.storage.from('evidencias').createSignedUrl(ruta, 300))).signedUrl,
      investigaciones: {
        asignar: async (id, rid) => rpc('fn_inv_asignar', { p_inv: id, p_responsable: rid }),
        hallazgo: async (id, txt) => rpc('fn_inv_hallazgo', { p_inv: id, p_texto: txt }),
        aclaracion: async (id, txt) => rpc('fn_inv_aclaracion', { p_inv: id, p_texto: txt }),
        concluir: async (id, p) => {
          const c = await catalogos();
          const res = c._resultados.find(x => x.nombre === p.resultado || x.id === p.resultado);
          return rpc('fn_inv_concluir', { p_inv: id, p_resultado: res ? res.id : p.resultado, p_conclusion: p.conclusion });
        },
        reabrir: async (id, m) => rpc('fn_inv_reabrir', { p_inv: id, p_motivo: m })
      },
      finanzas: {
        movimiento: async (difId, p) => rpc('fn_movimiento_registrar', {
          p_diferencia: difId, p_tipo: p.tipo, p_monto: p.monto === '' || p.monto == null ? null : Number(p.monto), p_nota: p.nota,
          p_revierte: p.revierte_id || null, p_forma: p.forma || null, p_comprobante: p.comprobante || null, p_fecha: p.fecha || null
        }),
        resumen: resumenFinanciero,
        dashboard: async f => {
          requiereSesion();
          exigir('dashboard.liquidaciones'); exigir('financiero.ver');
          const [tks, d] = await Promise.all([listar(), filasDiferencias()]);
          return APD.calculos.dashboardLiq(tks.filter(t => t.departamento === 'LIQ'), d.filas, f);
        }
      },
      dashboard: async f => {
        requiereSesion();
        if (!P.puede(perfil, 'dashboard.gerencial') && !P.puede(perfil, 'dashboard.operativo')) throw new ApiError('No autorizado para esta operación.', 'NO_AUTORIZADO');
        const [c, rows] = await Promise.all([catalogos(), listar()]);
        return APD.calculos.dashboard(rows, c.responsables, perfil, f, { clientes: c.clientes, rutas: c.rutas, choferes: c.choferes });
      },
      reportes: {
        tipos: async () => { requiereSesion(); return APD.calculos.tiposReporte(perfil); },
        generar: async (tipo, f) => {
          requiereSesion();
          if (!APD.calculos.puedeReporte(perfil, tipo)) throw new ApiError('No autorizado para este reporte.', 'NO_AUTORIZADO');
          const rows = await listar();
          let liq = null, invs = [];
          if (tipo === 'diferencias' || tipo === 'investigaciones' || tipo === 'incidencias_chofer') {
            const d = await filasDiferencias();
            invs = d.investigaciones;
            if (tipo !== 'investigaciones') liq = APD.calculos.liquidaciones(d.filas, d.investigaciones, f, d.verInv);
          }
          return APD.calculos.reporte(perfil, tipo, rows, f, { liquidaciones: () => liq, investigaciones: () => invs });
        },
        registrarExportacion: async (tipo, formato, n) => {
          const r = APD.calculos.REPORTES[tipo];
          await rpc('fn_exportacion_registrar', { p_reporte: r ? r.titulo : tipo, p_formato: formato, p_filas: n });
          return true;
        }
      },
      notificaciones: {
        listar: async () => {
          const c = await catalogos();
          const filas = await q(sb.from('notificaciones').select('*, tickets(numero)').order('creado_at', { ascending: false }).limit(200));
          return filas.map(n => ({ id: n.id, ts: ms(n.creado_at), evento: n.evento, evento_label: (c._eventos.find(e => e.id === n.evento) || {}).nombre || n.evento,
                                   ticket_id: n.ticket_id, numero: n.tickets ? n.tickets.numero : null, texto: n.texto, leida: n.leida }));
        },
        noLeidas: async () => {
          if (!perfil) return 0;
          const r = await sb.from('notificaciones').select('id', { count: 'exact', head: true }).eq('leida', false);
          if (r.error) throw aError(r.error);
          return r.count || 0;
        },
        marcarLeidas: async ids => rpc('fn_notificaciones_marcar_leidas', { p_ids: ids || null }),
        preferencias: async () => {
          const c = await catalogos();
          const pref = await q(sb.from('preferencias_notificacion').select('*'));
          const eventos = {};
          c._eventos.forEach(e => { eventos[e.id] = e.nombre; });
          const p = {};
          pref.forEach(x => { p[x.evento] = x.activo; });
          return { eventos, pref: p };
        },
        guardarPreferencias: async p => rpc('fn_preferencias_guardar', { p })
      },
      sla: {
        estado: estadoSla,
        nuevaVersion: async (valores, umbral, nota) => rpc('fn_sla_nueva_version', {
          p_valores: Object.keys(valores).map(k => ({ prioridad_id: k, minutos_primera_respuesta: valores[k].primera_respuesta, minutos_asignacion: valores[k].asignacion,
                                                      minutos_resolucion: valores[k].resolucion, horas_maximo_atencion: valores[k].maximo_horas })),
          p_umbral: umbral, p_nota: String(nota || '').trim() || 'Sin nota'
        }),
        agregarFeriado: async (fecha, nombre) => rpc('fn_feriado_agregar', { p_fecha: fecha, p_nombre: nombre }),
        quitarFeriado: async fecha => rpc('fn_feriado_quitar', { p_fecha: fecha })
      },
      admin: {
        usuarios: async () => {
          const deps = (await catalogos()).departamentos;
          return (await rpc('fn_admin_usuarios')).map(x => ({
            id: x.id, nombre: x.nombre, correo: x.correo, rol: x.rol, rol_label: x.rol && P.ROLES[x.rol] ? P.etiquetaRol(x.rol, x.departamento) : 'Sin rol (pendiente)',
            departamento: x.departamento, depto_nombre: (deps.find(d => d.id === x.departamento) || {}).nombre || '—',
            activo: x.activo, disponible: x.disponible, alcance: x.alcance || [], permisos_extra: x.permisos_extra || [], carga: x.carga
          }));
        },
        guardarUsuario: async (id, cambios) => { await rpc('fn_admin_usuario_guardar', { p_usuario: id, p: cambios }); cache = null; return true; },
        crearUsuario: async datos => {
          if (local) throw new ApiError('La invitación por correo requiere Supabase (función admin-invitar). En el entorno local use los usuarios de prueba.', 'VALIDACION');
          const r = await sb.functions.invoke('admin-invitar', { body: datos });
          if (r.error || (r.data && r.data.error)) throw new ApiError((r.data && r.data.error) || r.error.message, 'VALIDACION');
          cache = null;
          return r.data;
        },
        departamentos: async () => {
          const [c, us] = await Promise.all([catalogos(), rpc('fn_admin_usuarios')]);
          return c.departamentos.map(d => Object.assign({}, d, { usuarios: us.filter(u => u.departamento === d.id).length }));
        },
        categoriaActiva: async (id, activo) => { await rpc('fn_admin_categoria_guardar', { p_categoria: id, p: { activo: !!activo } }); cache = null; return true; },
        config: async () => {
          const filas = await q(sb.from('configuracion').select('*'));
          const v = k => (filas.find(x => x.clave === k) || {}).valor;
          return { asignacion_automatica: v('asignacion_automatica') === true, auto_cierre_dias: Number(v('auto_cierre_dias')) };
        },
        guardarConfig: async c => { await rpc('fn_admin_config_guardar', { p: c }); return true; },
        auditoria: async () => {
          const c = await catalogos();
          const filas = await q(sb.from('auditoria').select('*').order('ts', { ascending: false }).limit(500));
          const ids = Array.from(new Set(filas.map(a => a.ticket_id).filter(Boolean)));
          const nums = ids.length ? await q(sb.from('tickets').select('id,numero').in('id', ids)) : [];
          return filas.map(a => ({ id: a.id, ts: ms(a.ts), usuario_nombre: nombreDe(c, a.usuario_id), ambito: a.ambito, accion: a.accion, detalle: a.detalle,
                                   ticket_id: a.ticket_id, numero: (nums.find(x => x.id === a.ticket_id) || {}).numero || null }));
        }
      },
      demo: { reiniciar: async () => { throw new ApiError('No disponible con base de datos real.', 'VALIDACION'); } }
    };
    if (!local) {
      sb.auth.onAuthStateChange(evento => {
        if (evento === 'SIGNED_OUT') { perfil = null; cache = null; }
        if (evento === 'PASSWORD_RECOVERY' && APD.app) APD.app.go('#/definir-clave');
      });
    }
    return api;
  }

  APD.apiSupabase = { crear };
})();
