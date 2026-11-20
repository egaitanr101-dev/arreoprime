/* ============================================================================
 * DATOS DE DEMOSTRACIÓN — TODO EN ESTE ARCHIVO ES FICTICIO.
 * Personas, clientes, rutas, placas, montos, tiempos SLA y feriados son inventados
 * para recorrer el prototipo. No representan información real ni compromisos.
 * ========================================================================== */
(function () {
  'use strict';
  const DAY = 86400e3;

  function mulberry32(a) {
    return function () {
      a |= 0; a = a + 0x6D2B79F5 | 0;
      let t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  /* ---------------- Definición de campos dinámicos ---------------- */
  const CAMPOS = {
    cliente: { etiqueta: 'Cliente', tipo: 'catalogo', catalogo: 'clientes' },
    pedido: { etiqueta: 'Número de pedido', tipo: 'texto', placeholder: 'PED-00000' },
    factura: { etiqueta: 'Número de factura', tipo: 'texto', placeholder: 'FE-000000' },
    ruta: { etiqueta: 'Ruta', tipo: 'catalogo', catalogo: 'rutas' },
    fecha_entrega: { etiqueta: 'Fecha de entrega', tipo: 'fecha' },
    fecha_solicitada: { etiqueta: 'Fecha solicitada', tipo: 'fecha' },
    horario: { etiqueta: 'Horario requerido', tipo: 'texto', placeholder: 'Ej.: 8:00 – 10:00' },
    direccion: { etiqueta: 'Dirección o ubicación', tipo: 'textarea' },
    chofer: { etiqueta: 'Chofer', tipo: 'catalogo', catalogo: 'choferes' },
    bodega_origen: { etiqueta: 'Bodega de origen', tipo: 'catalogo', catalogo: 'bodegas' },
    bodega_destino: { etiqueta: 'Bodega de destino', tipo: 'catalogo', catalogo: 'bodegas' },
    codigo_producto: { etiqueta: 'Código de producto', tipo: 'texto', placeholder: 'P-0000' },
    producto: { etiqueta: 'Descripción del producto', tipo: 'texto' },
    cantidad: { etiqueta: 'Cantidad', tipo: 'numero' },
    unidad: { etiqueta: 'Unidad de medida', tipo: 'catalogo', catalogo: 'unidades' },
    fecha_requerida: { etiqueta: 'Fecha requerida', tipo: 'fecha' },
    vehiculo: { etiqueta: 'Vehículo requerido', tipo: 'catalogo', catalogo: 'vehiculos' },
    ubicacion: { etiqueta: 'Ubicación', tipo: 'texto' },
    responsable_mov: { etiqueta: 'Responsable en sitio', tipo: 'texto' },
    fecha_operacion: { etiqueta: 'Fecha de operación', tipo: 'fecha' },
    ayudante: { etiqueta: 'Ayudante', tipo: 'catalogo', catalogo: 'ayudantes' },
    num_liquidacion: { etiqueta: 'Número de liquidación', tipo: 'texto', placeholder: 'LQ-00000' },
    tipo_diferencia: { etiqueta: 'Tipo de diferencia', tipo: 'opciones', opciones: ['Faltante', 'Sobrante', 'Documental'] },
    medio_pago: { etiqueta: 'Medio de pago', tipo: 'opciones', opciones: ['Efectivo', 'Datáfono', 'Transferencia', 'Depósito', 'Cheque', 'No aplica'] },
    monto_esperado: { etiqueta: 'Monto esperado', tipo: 'crc', financiero: true },
    monto_reportado: { etiqueta: 'Monto reportado (diferencia)', tipo: 'crc', financiero: true, ayuda: 'Monto que Liquidaciones reporta como diferencia; se concilia contra el cálculo.' },
    monto_recibido: { etiqueta: 'Monto recibido', tipo: 'crc', financiero: true }
  };

  /* ---------------- Categorías ---------------- */
  function C(id, dep, nombre, tipo, prio, campos, extra) {
    return Object.assign({
      id, departamento: dep, nombre, tipo_default: tipo,
      tipos_validos: tipo === 'URG' ? ['URG'] : [tipo, 'URG'],
      prioridad_sugerida: prio, activo: true, requiere_aprobacion: false,
      genera_investigacion: false, financiero: false, responsable_sugerido_id: null,
      campos: campos.map(c => ({ clave: c.replace('*', ''), obligatorio: c.endsWith('*') }))
    }, extra || {});
  }
  const MONTOS = ['monto_esperado*', 'monto_reportado*', 'monto_recibido*'];
  const MONTOS_OPC = ['monto_esperado', 'monto_reportado', 'monto_recibido'];
  const FIN = { financiero: true, genera_investigacion: true };

  const CATEGORIAS = [
    C('COM-01', 'COM', 'Entrega extraordinaria', 'SOL', 'ALTA', ['cliente*', 'pedido', 'factura', 'fecha_solicitada*', 'horario', 'direccion*']),
    C('COM-02', 'COM', 'Segunda visita', 'SOL', 'MEDIA', ['cliente*', 'factura*', 'ruta', 'fecha_solicitada*', 'horario']),
    C('COM-03', 'COM', 'Reprogramación de entrega', 'SOL', 'MEDIA', ['cliente*', 'pedido', 'factura', 'fecha_entrega*', 'fecha_solicitada*', 'horario']),
    C('COM-04', 'COM', 'Cambio de horario', 'SOL', 'MEDIA', ['cliente*', 'ruta', 'fecha_entrega*', 'horario*']),
    C('COM-05', 'COM', 'Retiro de producto', 'REQ', 'MEDIA', ['cliente*', 'factura*', 'fecha_solicitada*', 'direccion']),
    C('COM-06', 'COM', 'Atención especial a cliente', 'REQ', 'MEDIA', ['cliente*', 'fecha_solicitada', 'horario', 'direccion']),
    C('COM-07', 'COM', 'Problemas durante la entrega', 'INC', 'ALTA', ['cliente*', 'factura', 'ruta*', 'fecha_entrega*', 'chofer']),
    C('COM-08', 'COM', 'Incidencia con chofer', 'INC', 'ALTA', ['ruta*', 'chofer*', 'fecha_entrega*', 'cliente']),
    C('COM-09', 'COM', 'Reclamo de cliente', 'REC', 'ALTA', ['cliente*', 'factura', 'ruta', 'fecha_entrega']),
    C('COM-10', 'COM', 'Transporte adicional', 'REQ', 'MEDIA', ['cliente', 'fecha_solicitada*', 'horario', 'direccion*']),
    C('COM-11', 'COM', 'Consulta sobre entrega', 'CON', 'BAJA', ['cliente*', 'pedido', 'factura', 'ruta']),
    C('COM-12', 'COM', 'Otros', 'SOL', 'MEDIA', ['cliente', 'ruta']),

    C('ALM-01', 'ALM', 'Movimiento entre bodegas', 'COO', 'MEDIA', ['bodega_origen*', 'bodega_destino*', 'codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'fecha_requerida*']),
    C('ALM-02', 'ALM', 'Traslado de producto', 'REQ', 'MEDIA', ['bodega_origen*', 'ubicacion*', 'producto*', 'cantidad*', 'unidad*', 'fecha_requerida*', 'vehiculo']),
    C('ALM-03', 'ALM', 'Recolección de mercancía', 'REQ', 'MEDIA', ['ubicacion*', 'producto*', 'cantidad', 'unidad', 'fecha_requerida*', 'responsable_mov']),
    C('ALM-04', 'ALM', 'Devolución', 'SOL', 'MEDIA', ['bodega_destino*', 'codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'ubicacion']),
    C('ALM-05', 'ALM', 'Solicitud de vehículo', 'REQ', 'ALTA', ['vehiculo', 'fecha_requerida*', 'ubicacion*', 'responsable_mov']),
    C('ALM-06', 'ALM', 'Apoyo de transporte', 'SOL', 'MEDIA', ['fecha_requerida*', 'ubicacion*', 'responsable_mov']),
    C('ALM-07', 'ALM', 'Coordinación de carga', 'COO', 'MEDIA', ['bodega_origen*', 'vehiculo', 'fecha_requerida*', 'responsable_mov']),
    C('ALM-08', 'ALM', 'Coordinación de descarga', 'COO', 'MEDIA', ['bodega_destino*', 'vehiculo', 'fecha_requerida*', 'responsable_mov']),
    C('ALM-09', 'ALM', 'Diferencias relacionadas con transporte', 'INC', 'ALTA', ['codigo_producto', 'producto*', 'cantidad*', 'unidad*', 'vehiculo', 'fecha_requerida']),
    C('ALM-10', 'ALM', 'Movimientos internos', 'COO', 'BAJA', ['bodega_origen*', 'bodega_destino*', 'producto*', 'cantidad', 'unidad']),
    C('ALM-11', 'ALM', 'Otros', 'SOL', 'MEDIA', ['ubicacion']),

    C('LIQ-01', 'LIQ', 'Diferencias de liquidación de rutas', 'INC', 'ALTA', ['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion*', 'tipo_diferencia*', 'medio_pago'].concat(MONTOS), FIN),
    C('LIQ-02', 'LIQ', 'Faltantes o sobrantes de dinero', 'INC', 'ALTA', ['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion', 'tipo_diferencia*', 'medio_pago*'].concat(MONTOS), FIN),
    C('LIQ-03', 'LIQ', 'Diferencias entre facturas y hoja de ruta', 'INC', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer', 'num_liquidacion', 'factura*', 'tipo_diferencia'].concat(MONTOS), FIN),
    C('LIQ-04', 'LIQ', 'Diferencias en cobros en efectivo', 'INC', 'ALTA', ['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion', 'factura', 'tipo_diferencia*'].concat(MONTOS), FIN),
    C('LIQ-05', 'LIQ', 'Diferencias de datáfono', 'INC', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer*', 'num_liquidacion', 'factura', 'tipo_diferencia*'].concat(MONTOS), FIN),
    C('LIQ-06', 'LIQ', 'Comprobantes de depósitos pendientes', 'REQ', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer*', 'num_liquidacion*', 'medio_pago']),
    C('LIQ-07', 'LIQ', 'Documentación faltante', 'REQ', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer', 'num_liquidacion', 'factura']),
    C('LIQ-08', 'LIQ', 'Rendición de cuentas', 'REQ', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion*']),
    C('LIQ-09', 'LIQ', 'Diferencias de combustible', 'INC', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer*', 'tipo_diferencia*'].concat(MONTOS), FIN),
    C('LIQ-10', 'LIQ', 'Viáticos', 'SOL', 'BAJA', ['ruta', 'fecha_operacion*', 'chofer*', 'ayudante'].concat(MONTOS_OPC), { financiero: true }),
    C('LIQ-11', 'LIQ', 'Incumplimiento en entrega de documentación', 'INC', 'MEDIA', ['ruta*', 'fecha_operacion*', 'chofer*', 'ayudante', 'num_liquidacion']),
    C('LIQ-12', 'LIQ', 'Investigación de movimientos de choferes y ayudantes', 'INC', 'ALTA', ['ruta', 'fecha_operacion*', 'chofer', 'ayudante', 'tipo_diferencia'].concat(MONTOS_OPC), FIN),
    C('LIQ-13', 'LIQ', 'Otros', 'SOL', 'MEDIA', ['ruta', 'fecha_operacion'])
  ];
  // Responsable sugerido por categoría (DEMO)
  CATEGORIAS.forEach(c => {
    c.responsable_sugerido_id = c.departamento === 'COM' ? 'u5' : c.departamento === 'LIQ' ? 'u6' : 'u10';
  });

  function catalogos(ahora) {
    return {
      config: { asignacion_automatica: false, auto_cierre_dias: 3 },
      departamentos: [
        { id: 'COM', nombre: 'Comercial', tipo: 'SOLICITANTE' },
        { id: 'ALM', nombre: 'Almacén', tipo: 'SOLICITANTE' },
        { id: 'LIQ', nombre: 'Liquidaciones', tipo: 'SOLICITANTE' },
        { id: 'TRA', nombre: 'Distrib. y Transp. Cárnico', tipo: 'RECEPTOR' },
        { id: 'GER', nombre: 'Gerencia', tipo: 'CONSULTA' },
        { id: 'SIS', nombre: 'Sistemas', tipo: 'ADMINISTRACION' }
      ],
      tipos: [
        { id: 'SOL', nombre: 'Solicitud' }, { id: 'REQ', nombre: 'Requerimiento' }, { id: 'INC', nombre: 'Incidencia' },
        { id: 'REC', nombre: 'Reclamo' }, { id: 'COO', nombre: 'Coordinación' }, { id: 'CON', nombre: 'Consulta' },
        { id: 'URG', nombre: 'Urgencia operativa' }
      ],
      prioridades: [
        { id: 'CRITICA', nombre: 'Crítica', orden: 1 }, { id: 'ALTA', nombre: 'Alta', orden: 2 },
        { id: 'MEDIA', nombre: 'Media', orden: 3 }, { id: 'BAJA', nombre: 'Baja', orden: 4 }
      ],
      campos: CAMPOS,
      categorias: CATEGORIAS,
      motivos: [
        { id: 'INFO_SOLICITANTE', tipo: 'ESPERA', nombre: 'Información del solicitante', pausa_sla: true },
        { id: 'TERCERO', tipo: 'ESPERA', nombre: 'Depende de un tercero (cliente o proveedor)', pausa_sla: true },
        { id: 'PROGRAMADO', tipo: 'ESPERA', nombre: 'Programado para una fecha posterior', pausa_sla: true },
        { id: 'VEHICULO', tipo: 'ESPERA', nombre: 'Disponibilidad de vehículo', pausa_sla: false },
        { id: 'INTERNO', tipo: 'ESPERA', nombre: 'Coordinación interna de Transportes', pausa_sla: false },
        { id: 'FUERA_ALCANCE', tipo: 'RECHAZO', nombre: 'Fuera del alcance de Transportes' },
        { id: 'DUPLICADO', tipo: 'RECHAZO', nombre: 'Ticket duplicado' },
        { id: 'INFO_INSUF', tipo: 'RECHAZO', nombre: 'Información insuficiente' },
        { id: 'NO_PROCEDE', tipo: 'RECHAZO', nombre: 'No procede según política' }
      ],
      respuestas: [
        { id: 'R1', nombre: 'Solicitud recibida', texto: 'Solicitud recibida. La estamos revisando y le informaremos el avance.' },
        { id: 'R2', nombre: 'En revisión', texto: 'Su solicitud está en revisión por el equipo de Transportes.' },
        { id: 'R3', nombre: 'Información adicional requerida', texto: 'Para continuar necesitamos información adicional. Por favor indíquenos: ' },
        { id: 'R4', nombre: 'Asignado para atención', texto: 'Su solicitud fue asignada a un responsable de Transportes para su atención.' },
        { id: 'R5', nombre: 'En proceso', texto: 'Estamos trabajando en su solicitud. Le avisaremos al completarla.' },
        { id: 'R6', nombre: 'Solucionado', texto: 'La solicitud fue atendida. Por favor confirme la resolución.' },
        { id: 'R7', nombre: 'Cerrado', texto: 'El ticket se cierra. Gracias por utilizar la mesa de servicio de Transportes.' }
      ],
      resultados: ['Diferencia justificada', 'Pendiente de aclaración', 'Error documental', 'Error operativo', 'Atribuible a otro proceso', 'No determinada', 'Escalado'],
      clientes: [
        { id: 'C-1001', nombre: 'Súper El Ahorro' }, { id: 'C-1002', nombre: 'Pulpería Don Chepe' },
        { id: 'C-1003', nombre: 'Restaurante La Fogata' }, { id: 'C-1004', nombre: 'Hotel Vista Volcán' },
        { id: 'C-1005', nombre: 'Carnicería La Central' }, { id: 'C-1006', nombre: 'Minisúper Los Ángeles' },
        { id: 'C-1007', nombre: 'Soda Mi Tierra' }, { id: 'C-1008', nombre: 'Supermercado Las Palmas' },
        { id: 'C-1009', nombre: 'Asados El Corral' }, { id: 'C-1010', nombre: 'Mercado Familiar San Pedro' }
      ],
      rutas: [
        { id: 'R-101', nombre: 'San José Centro' }, { id: 'R-102', nombre: 'Escazú – Santa Ana' },
        { id: 'R-103', nombre: 'Heredia' }, { id: 'R-104', nombre: 'Alajuela' }, { id: 'R-105', nombre: 'Cartago' },
        { id: 'R-106', nombre: 'Desamparados' }, { id: 'R-107', nombre: 'Tibás – Moravia' },
        { id: 'R-108', nombre: 'Puntarenas' }, { id: 'R-109', nombre: 'Limón' }, { id: 'R-110', nombre: 'Guanacaste' }
      ],
      choferes: [
        { id: 'CH-01', nombre: 'Luis Gómez' }, { id: 'CH-02', nombre: 'Mauricio Salas' }, { id: 'CH-03', nombre: 'Rándall Fallas' },
        { id: 'CH-04', nombre: 'Esteban Chinchilla' }, { id: 'CH-05', nombre: 'Johnny Céspedes' }, { id: 'CH-06', nombre: 'Allan Picado' },
        { id: 'CH-07', nombre: 'Greivin Montero' }, { id: 'CH-08', nombre: 'Óscar Zúñiga' }
      ],
      ayudantes: [
        { id: 'AY-01', nombre: 'Daniel Corrales' }, { id: 'AY-02', nombre: 'Kendall Arias' }, { id: 'AY-03', nombre: 'Jason Madrigal' },
        { id: 'AY-04', nombre: 'Bryan Calderón' }, { id: 'AY-05', nombre: 'Andrés Porras' }, { id: 'AY-06', nombre: 'Josué Elizondo' }
      ],
      vehiculos: [
        { id: 'CL-101234', nombre: 'Camión refrigerado 5 t' }, { id: 'CL-102877', nombre: 'Camión refrigerado 3,5 t' },
        { id: 'CL-099451', nombre: 'Camión refrigerado 8 t' }, { id: 'CL-110902', nombre: 'Furgón refrigerado 1,5 t' },
        { id: 'CL-087316', nombre: 'Camión seco 3 t' }, { id: 'CL-115540', nombre: 'Pick-up de apoyo' }
      ],
      bodegas: [
        { id: 'B-01', nombre: 'Bodega Central' }, { id: 'B-02', nombre: 'Cámara fría 1' }, { id: 'B-03', nombre: 'Cámara fría 2' },
        { id: 'B-04', nombre: 'Bodega de Despacho' }, { id: 'B-05', nombre: 'Bodega de Devoluciones' }
      ],
      unidades: [
        { id: 'KG', nombre: 'Kilogramo' }, { id: 'CJ', nombre: 'Caja' }, { id: 'UN', nombre: 'Unidad' },
        { id: 'TA', nombre: 'Tarima' }, { id: 'BU', nombre: 'Bulto' }
      ],
      usuarios: [
        U('u1', 'Ana Solís Méndez', 'SOLICITANTE', 'COM'),
        U('u2', 'Carlos Mora Vega', 'SOLICITANTE', 'COM'),
        U('u3', 'Laura Jiménez Rojas', 'SOLICITANTE', 'ALM'),
        U('u11', 'Gabriela Núñez Soto', 'SOLICITANTE', 'ALM'),
        U('u4', 'Diego Vargas Alpízar', 'SOLICITANTE', 'LIQ'),
        U('u12', 'Fernando Solano Ruiz', 'SOLICITANTE', 'LIQ'),
        U('u13', 'Marta Quesada Arias', 'SUPERVISOR_LIQUIDACIONES', 'LIQ', { nota_demo: 'Dashboard y reportes de Liquidaciones' }),
        U('u5', 'María Rojas Chaves', 'OPERADOR_TRANSPORTES', 'TRA', { alcance: ['COM', 'ALM'] }),
        U('u6', 'José Araya Brenes', 'OPERADOR_TRANSPORTES', 'TRA', {
          alcance: ['LIQ', 'COM'], permisos_extra: ['financiero.ver', 'financiero.registrar', 'investigacion.ver', 'investigacion.gestionar'],
          nota_demo: 'Coordinador con permiso financiero e investigaciones'
        }),
        U('u10', 'Pablo Méndez Castro', 'OPERADOR_TRANSPORTES', 'TRA', { alcance: ['ALM', 'COM'], nota_demo: 'No disponible (vacaciones): no recibe asignaciones' }),
        U('u13', 'Kevin Brenes Lobo', 'OPERADOR_TRANSPORTES', 'TRA', { alcance: ['COM'], activo: false, nota_demo: 'Usuario inactivo: no puede ingresar' }),
        U('u7', 'Sofía Castro Umaña', 'SUPERVISOR_TRANSPORTES', 'TRA'),
        U('u14', 'Andrés Rojas Mena', 'SUPERUSUARIO', 'TRA', { nota_demo: 'Acceso total: operación, finanzas y administración' }),
        U('u8', 'Ricardo Pérez Quirós', 'GERENCIA', 'GER', { nota_demo: 'Solo lectura' }),
        U('u9', 'Andrea Quesada Mora', 'ADMINISTRADOR', 'SIS', { nota_demo: 'Sin acceso a contenido operativo por defecto' })
      ],
      calendario: { 0: null, 1: [420, 1020], 2: [420, 1020], 3: [420, 1020], 4: [420, 1020], 5: [420, 1020], 6: [420, 720] },
      feriados: [
        ['2026-01-01', 'Año Nuevo'], ['2026-04-02', 'Jueves Santo'], ['2026-04-03', 'Viernes Santo'],
        ['2026-04-11', 'Día de Juan Santamaría'], ['2026-05-01', 'Día del Trabajador'], ['2026-07-25', 'Anexión del Partido de Nicoya'],
        ['2026-08-02', 'Virgen de los Ángeles'], ['2026-08-15', 'Día de la Madre'], ['2026-08-31', 'Día de la Persona Negra'],
        ['2026-09-15', 'Día de la Independencia'], ['2026-12-01', 'Abolición del Ejército'], ['2026-12-25', 'Navidad']
      ].map(f => ({ fecha: f[0], nombre: f[1] })),
      sla_versiones: [{
        version: 1, vigente_desde: ahora - 400 * DAY, vigente_hasta: null, creado_por: 'u9', umbral: 0.75,
        nota: 'Valores DEMO para el prototipo. Pendientes de definición (decisión D-15).',
        valores: {
          CRITICA: { primera_respuesta: 30, asignacion: 60, resolucion: 240, maximo_horas: 24 },
          ALTA: { primera_respuesta: 60, asignacion: 120, resolucion: 480, maximo_horas: 48 },
          MEDIA: { primera_respuesta: 120, asignacion: 240, resolucion: 960, maximo_horas: 96 },
          BAJA: { primera_respuesta: 240, asignacion: 480, resolucion: 2400, maximo_horas: 168 }
        }
      }]
    };
  }
  function U(id, nombre, rol, dep, extra) {
    const correo = nombre.split(' ').slice(0, 2).join('.').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '') + '@demo.invalid';
    return Object.assign({ id, nombre, correo, rol, departamento: dep, activo: true, disponible: true, alcance: [], permisos_extra: [], pref_notif: {}, nota_demo: '' }, extra || {});
  }

  /* ---------------- Generador de escenario ----------------
   * Usa el MISMO motor de reglas que la API simulada (M), de modo que cada
   * transición del escenario pasa por las validaciones de permisos y estados. */
  function poblar(M, ahora) {
    const rnd = mulberry32(20261116);
    const pick = a => a[Math.floor(rnd() * a.length)];
    const rint = (a, b) => a + Math.floor(rnd() * (b - a + 1));
    const db = M.db;
    const U_ = id => db.usuarios.find(u => u.id === id);
    const SUP = U_('u7');

    const productos = ['Lomo de res empacado al vacío', 'Pechuga de pollo deshuesada', 'Costilla de cerdo', 'Carne molida especial', 'Chuleta ahumada', 'Embutidos surtidos', 'Posta de cerdo', 'Bistec de res'];
    const direcciones = ['San Pedro de Montes de Oca, 200 m norte de la iglesia', 'Escazú centro, frente al parque', 'Heredia, Barrio Fátima, local esquinero', 'Alajuela, 100 m sur del hospital', 'Cartago, contiguo al mercado municipal', 'Santa Ana, centro comercial Río Oro, local 4'];
    const horarios = ['7:00 – 9:00', '9:00 – 11:00', '13:00 – 15:00', 'Antes de las 10:00', 'Después de las 14:00'];
    const responsablesSitio = ['Encargado de recibo', 'Jefe de bodega de turno', 'Administrador del local', 'Coordinador de despacho'];
    const ubicaciones = ['Andén 3 — Bodega Central', 'Cliente Súper El Ahorro, Curridabat', 'Zona franca, bodega del proveedor', 'Sucursal Heredia', 'Patio de carga'];
    const fechaISO = ms => APD.fmt.fechaISO(ms);
    const redondear = (n, m) => Math.round(n / m) * m;

    function datosPara(c, ts) {
      const d = {};
      const cat = n => pick(db[n]).id;
      c.campos.forEach(({ clave, obligatorio }) => {
        if (!obligatorio && rnd() < 0.35) return;
        switch (clave) {
          case 'cliente': d[clave] = cat('clientes'); break;
          case 'ruta': d[clave] = cat('rutas'); break;
          case 'chofer': d[clave] = cat('choferes'); break;
          case 'ayudante': d[clave] = cat('ayudantes'); break;
          case 'vehiculo': d[clave] = cat('vehiculos'); break;
          case 'unidad': d[clave] = cat('unidades'); break;
          case 'bodega_origen': d[clave] = cat('bodegas'); break;
          case 'bodega_destino': { let b; do { b = cat('bodegas'); } while (b === d.bodega_origen); d[clave] = b; break; }
          case 'pedido': d[clave] = 'PED-' + rint(10000, 99999); break;
          case 'factura': d[clave] = 'FE-' + rint(100000, 999999); break;
          case 'num_liquidacion': d[clave] = 'LQ-' + rint(20000, 29999); break;
          case 'codigo_producto': d[clave] = 'P-' + rint(1000, 9999); break;
          case 'producto': d[clave] = pick(productos); break;
          case 'cantidad': d[clave] = String(rint(5, 300)); break;
          case 'horario': d[clave] = pick(horarios); break;
          case 'direccion': d[clave] = pick(direcciones); break;
          case 'ubicacion': d[clave] = pick(ubicaciones); break;
          case 'responsable_mov': d[clave] = pick(responsablesSitio); break;
          case 'fecha_operacion': d[clave] = fechaISO(ts - rint(1, 4) * DAY); break;
          case 'fecha_entrega': d[clave] = fechaISO(ts - rint(0, 2) * DAY); break;
          case 'fecha_solicitada': case 'fecha_requerida': d[clave] = fechaISO(ts + rint(0, 4) * DAY); break;
          case 'tipo_diferencia': d[clave] = rnd() < 0.88 ? 'Faltante' : 'Sobrante'; break;
          case 'medio_pago': d[clave] = pick(['Efectivo', 'Efectivo', 'Datáfono', 'Transferencia', 'Depósito']); break;
          default: break;
        }
      });
      const tieneMontos = c.campos.some(x => x.clave === 'monto_esperado');
      if (tieneMontos && (c.campos.find(x => x.clave === 'monto_esperado').obligatorio || rnd() < 0.6)) {
        const comb = c.id === 'LIQ-09' || c.id === 'LIQ-10';
        const esperado = redondear(comb ? rint(40000, 180000) : rint(300000, 2600000), 50);
        const dif = redondear(comb ? rint(3000, 25000) : rint(5000, 185000), 50);
        const sobrante = d.tipo_diferencia === 'Sobrante';
        const recibido = sobrante ? esperado + dif : esperado - dif;
        d.monto_esperado = String(esperado);
        d.monto_recibido = String(recibido);
        d.monto_reportado = String(rnd() < 0.85 ? dif : redondear(dif * 1.1, 50));
      }
      return d;
    }
    function textos(c, d) {
      const nom = (col, id) => { const x = db[col].find(v => v.id === id); return x ? x.nombre : ''; };
      let asunto = c.nombre, desc;
      if (c.departamento === 'COM') {
        const cli = nom('clientes', d.cliente);
        if (cli) asunto += ' — ' + cli; else if (d.ruta) asunto += ' — Ruta ' + d.ruta;
        desc = 'Se requiere gestionar "' + c.nombre.toLowerCase() + '"' + (cli ? ' para el cliente ' + cli : '') + '. ' +
          pick(['El cliente indica que no recibió el producto completo.', 'Favor coordinar con el chofer de la ruta.', 'El cliente solicita confirmar la hora de llegada.', 'Pedido prioritario por un evento del cliente.', 'Se adjunta el detalle de la factura.']);
      } else if (c.departamento === 'ALM') {
        if (d.producto) asunto += ' — ' + d.producto;
        desc = c.nombre + (d.cantidad ? ': ' + d.cantidad + ' ' + (nom('unidades', d.unidad) || 'unidades').toLowerCase() + (d.producto ? ' de ' + d.producto.toLowerCase() : '') : '') + '. ' +
          pick(['Se requiere coordinar el vehículo con anticipación.', 'El producto debe mantener la cadena de frío.', 'Favor confirmar la hora estimada.', 'Coordinar con el encargado en sitio.']);
      } else {
        asunto += d.ruta ? ' — Ruta ' + d.ruta : '';
        desc = d.monto_esperado
          ? 'Se detecta una diferencia (' + (d.tipo_diferencia || 'por confirmar').toLowerCase() + ') en la liquidación ' + (d.num_liquidacion || 'sin número') + ' de la ruta ' + (d.ruta || '—') + '. ' + pick(['Se solicita revisar comprobantes y hoja de ruta.', 'Los montos no coinciden con el cierre de caja.', 'Se adjunta el reporte de cierre del día.'])
          : c.nombre + ' correspondiente a la ruta ' + (d.ruta || '—') + '. ' + pick(['Se requiere la documentación para cerrar la liquidación.', 'Favor gestionar con el chofer responsable de la entrega de documentos.']);
      }
      return { asunto, descripcion: desc };
    }
    function elegirResponsable(t, ts) {
      if (t.departamento === 'LIQ') return U_('u6');
      const ops = ['u5', 'u6', 'u10'].map(U_).filter(u => u.alcance.includes(t.departamento) && !(u.id === 'u10' && ts > ahora - 14 * DAY));
      return pick(ops);
    }

    const NOTAS_INTERNAS = ['Coordinado con el chofer por radio; confirma disponibilidad.', 'Revisar carga del camión antes de confirmar.', 'Se consultó con bodega; producto disponible.', 'Cliente con historial de cambios de horario; confirmar por teléfono.', 'Pendiente confirmar espacio en la ruta de mañana.'];
    const PEDIDOS_INFO = ['Por favor confirmar el contacto en sitio y un teléfono.', 'Necesitamos el número de factura asociado para continuar.', 'Favor indicar el horario exacto de recibo del cliente.', 'Adjunte el comprobante o fotografía de respaldo.'];
    const RESPUESTAS_INFO = ['Adjunto la información solicitada. Contacto: encargado de recibo.', 'La factura es la indicada en el ticket; adjunto copia.', 'El cliente recibe de 8:00 a 11:00.', 'Adjunto el comprobante solicitado.'];
    const DETALLES_ESPERA = ['Esperando confirmación del cliente.', 'Vehículo refrigerado en mantenimiento hasta mañana.', 'Programado para la próxima salida de la ruta.'];
    const HALLAZGOS = ['Se revisó la hoja de ruta: dos facturas sin sello de recibido.', 'El cierre de datáfono muestra una transacción duplicada.', 'El depósito del día aparece registrado con fecha posterior.', 'El chofer indica pago parcial de un cliente; se solicita comprobante.', 'Se verificó el conteo de efectivo con el ayudante.'];
    const CONCLUSIONES = {
      'Diferencia justificada': 'Con los comprobantes aportados la diferencia queda justificada en su totalidad.',
      'Error documental': 'La diferencia corresponde a un error en la documentación de la liquidación; se corrigió el registro.',
      'Error operativo': 'Se determinó un error operativo en el proceso de cobro. Se documenta para seguimiento según el proceso autorizado.',
      'Atribuible a otro proceso': 'La diferencia se originó en el proceso de facturación, no en la ruta.',
      'No determinada': 'Con la información disponible no fue posible determinar el origen de la diferencia.',
      'Pendiente de aclaración': 'Se concluye la revisión de Transportes; queda pendiente aclaración de un tercero.',
      'Escalado': 'Se escala a la jefatura correspondiente por el monto involucrado.'
    };
    const RESOLUCIONES = {
      COM: ['Se coordinó la entrega con la ruta y el cliente confirmó recibido.', 'Se reprogramó la visita y se completó la entrega.', 'Se atendió la solicitud y se informó al cliente.'],
      ALM: ['Movimiento realizado y confirmado por bodega.', 'Se asignó vehículo y se completó el traslado.', 'Carga/descarga coordinada y ejecutada.'],
      LIQ: ['Investigación concluida y documentada; se informa el resultado a Liquidaciones.', 'Se entregó la documentación solicitada.', 'Se completó la rendición de cuentas.']
    };

    /* ---- Simulación de un ticket a lo largo del tiempo ---- */
    function simular(ts, forzado) {
      const f = forzado || {};
      const dep = f.dep || (rnd() < 0.45 ? 'COM' : rnd() < 0.55 ? 'ALM' : 'LIQ');
      const sol = f.sol ? U_(f.sol) : pick(db.usuarios.filter(u => u.rol === 'SOLICITANTE' && u.departamento === dep));
      const cats = db.categorias.filter(c => c.departamento === dep);
      const c = f.cat ? db.categorias.find(x => x.id === f.cat) : (rnd() < 0.05 ? cats.find(x => x.nombre === 'Otros') : pick(cats.filter(x => x.nombre !== 'Otros')));
      const datos = Object.assign(datosPara(c, ts), f.datos || {});
      const tx = textos(c, datos);
      const evid = rnd() < 0.4 ? [{ nombre: pick(['foto_entrega.jpg', 'factura_escaneada.pdf', 'hoja_de_ruta.pdf', 'comprobante.jpg', 'foto_producto.jpg']), tamano: rint(80, 2400) * 1024, tipo: 'image/jpeg' }] : [];
      const t = M.crear(sol, { categoria_id: c.id, tipo_id: rnd() < 0.07 ? 'URG' : c.tipo_default, asunto: tx.asunto, descripcion: tx.descripcion, datos, evidencias: evid }, ts);

      const vel = f.vel || (0.35 + rnd() * 2.4);
      let cur = ts;
      const limite = typeof f.hasta === 'number' ? f.hasta : 99;
      // Casos guiados avanzan en tiempo calendario para no depender de la hora en que se abre la demo
      const avanzar = base => {
        const sig = cur + base * vel * (0.5 + rnd()) * 60000;
        cur = forzado ? sig : M.siguienteHabil(sig);
        return cur < ahora - 10 * 60000;
      };
      let paso = 0;
      const sigue = () => ++paso <= limite;

      // 1. Revisión
      const directo = f.directo != null ? f.directo : rnd() < 0.2;
      if (!directo) {
        if (!sigue() || !avanzar(25)) return t;
        M.accion(SUP, t.id, 'tomar_revision', {}, cur);
        if (rnd() < 0.8 && avanzar(3)) M.comentar(SUP, t.id, { texto: 'Solicitud recibida. Estamos revisando la información.', visibilidad: 'PUBLICO' }, cur);
      }
      if (!forzado && rnd() < 0.07) {
        if (!avanzar(30)) return t;
        M.accion(SUP, t.id, 'rechazar', { motivo_id: pick(['DUPLICADO', 'FUERA_ALCANCE', 'INFO_INSUF']), justificacion: 'Revisado por Transportes: la solicitud no procede en los términos planteados. Puede registrar una nueva con la información completa.' }, cur);
        return t;
      }
      // 2. Asignación
      const resp = f.resp ? U_(f.resp) : elegirResponsable(t, ts);
      if (!sigue() || !avanzar(directo ? 35 : 40)) return t;
      if (rnd() < 0.3 && !f.resp) M.accion(resp, t.id, 'autoasignar', {}, cur);
      else M.accion(SUP, t.id, 'asignar', { responsable_id: resp.id }, cur);
      if (rnd() < 0.45 && avanzar(2)) M.comentar(SUP, t.id, { texto: pick(NOTAS_INTERNAS), visibilidad: 'INTERNO' }, cur);
      const inv = db.investigaciones.find(i => i.ticket_id === t.id);
      if (inv) { if (!avanzar(15)) return t; M.invAsignar(SUP, inv.id, resp.id, cur); }
      // 3. Atención
      if (!sigue() || !avanzar(50)) return t;
      M.accion(resp, t.id, 'iniciar', {}, cur);
      if (inv) { if (!avanzar(60)) return t; M.invHallazgo(resp, inv.id, pick(HALLAZGOS), cur); }
      // 4. Espera (opcional)
      if (f.espera || (!f.sinEspera && rnd() < 0.27)) {
        if (!sigue() || !avanzar(90)) return t;
        const info = f.espera === 'INFO' || (!f.espera && rnd() < 0.6);
        M.accion(resp, t.id, 'espera', { motivo_id: info ? 'INFO_SOLICITANTE' : pick(['TERCERO', 'VEHICULO', 'PROGRAMADO']), detalle: f.detalleEspera || (info ? pick(PEDIDOS_INFO) : pick(DETALLES_ESPERA)) }, cur);
        if (!sigue() || !avanzar(info ? 500 : 700)) return t;
        if (info) M.responderInfo(sol, t.id, pick(RESPUESTAS_INFO), cur);
        else M.accion(resp, t.id, 'reanudar', {}, cur);
      }
      if (rnd() < 0.4 && avanzar(60)) M.comentar(resp, t.id, { texto: pick(NOTAS_INTERNAS), visibilidad: 'INTERNO' }, cur);
      if (rnd() < 0.22) {
        if (!avanzar(40)) return t;
        M.comentar(sol, t.id, { texto: '¿Hay alguna actualización sobre esta solicitud?', visibilidad: 'PUBLICO' }, cur);
        if (!avanzar(30)) return t;
        M.comentar(resp, t.id, { texto: 'Sí, ya está en atención. Le informamos apenas quede listo.', visibilidad: 'PUBLICO' }, cur);
      }
      // 5. Resolución (y conclusión de investigación en Liquidaciones)
      const factor = { CRITICA: 0.4, ALTA: 0.8, MEDIA: 1.6, BAJA: 3 }[t.prioridad];
      if (inv) {
        const dif = db.diferencias.find(d => d.ticket_id === t.id);
        if (!sigue() || !avanzar(300 * factor)) return t;
        if (dif && dif.monto_diferencia > 0 && (f.aclaracion || rnd() < 0.55)) {
          M.movimiento(resp, dif.id, { tipo: 'ACLARACION', monto: f.aclaracion || redondear(dif.monto_diferencia * pick([0.25, 0.5, 1]), 50), nota: 'Monto respaldado con comprobantes aportados por el chofer.' }, cur);
        }
        if (f.hasta === 'inv') return t;
        if (!avanzar(120)) return t;
        const resultado = pick(['Diferencia justificada', 'Error documental', 'Error operativo', 'Error operativo', 'Atribuible a otro proceso', 'No determinada']);
        M.invConcluir(resp, inv.id, { resultado, conclusion: CONCLUSIONES[resultado] }, cur);
        if (dif && dif.monto_diferencia > 0 && resultado === 'Error operativo' && rnd() < 0.7) {
          const pend = M.pendiente(dif.id);
          if (pend > 0 && avanzar(200)) M.movimiento(SUP, dif.id, { tipo: 'RECUPERACION', monto: redondear(pend * pick([0.5, 1]), 50), nota: 'Recuperación registrada según proceso autorizado fuera del sistema (DEMO).' }, cur);
        }
      }
      if (!sigue() || !avanzar(240 * factor)) return t;
      // Al resolver, el faltante pendiente se cierra: recuperado si fue error operativo; si no, aclarado
      const difR = db.diferencias.find(d => d.ticket_id === t.id && d.monto_diferencia > 0);
      const invR = db.investigaciones.find(i => i.ticket_id === t.id);
      const cierre_dif = difR && M.pendiente(difR.id) > 0
        ? (invR && invR.resultado === 'Error operativo' ? { tipo: 'RECUPERADO', forma: 'Boleta de rebajo' } : { tipo: 'ACLARADO' }) : undefined;
      M.accion(resp, t.id, 'resolver', { resolucion: pick(RESOLUCIONES[dep]), cierre_dif }, cur);
      // 6. Cierre
      if (f.sinCierre) return t;
      if (rnd() < 0.72) {
        if (!sigue() || !avanzar(300)) return t;
        M.accion(sol, t.id, 'confirmar', {}, cur);
      } else {
        const cierre = M.siguienteHabil(cur + 4 * DAY);
        if (cierre < ahora) M.autoCerrar(t.id, cierre);
      }
      return t;
    }

    /* ---- Escenario aleatorio reproducible (≈ 80 días) ---- */
    const N = 58, creados = [];
    for (let i = 0; i < N; i++) {
      let ts = M.siguienteHabil(ahora - (Math.pow(rnd(), 1.7) * 80 * DAY + 3 * 3600e3));
      if (ts > ahora - 3 * 3600e3) ts = ahora - rint(3, 30) * 3600e3;
      creados.push(ts);
    }
    creados.sort((a, b) => a - b).forEach(ts => {
      try { simular(ts); } catch (e) { console.warn('[DEMO] Escenario omitido:', e.message); }
    });

    /* ---- Casos guiados para recorrer los flujos ---- */
    const guiados = [
      // A. Comercial: Transportes pide información → Ana/Carlos deben responder
      () => simular(ahora - 5 * 3600e3, { dep: 'COM', sol: 'u1', cat: 'COM-02', resp: 'u5', directo: false, espera: 'INFO', detalleEspera: 'Por favor confirmar si el cliente puede recibir después de las 14:00 y un teléfono de contacto en sitio.', vel: 0.15, hasta: 4 }),
      // B. Liquidaciones: investigación en curso con aclaración parcial
      () => simular(ahora - 2 * DAY, { dep: 'LIQ', sol: 'u4', cat: 'LIQ-02', resp: 'u6', directo: false, sinEspera: true, vel: 0.5, hasta: 'inv', aclaracion: 48500, datos: { tipo_diferencia: 'Faltante', medio_pago: 'Efectivo', monto_esperado: '1485000', monto_recibido: '1336500', monto_reportado: '148500', chofer: 'CH-03', ayudante: 'AY-02', ruta: 'R-105' } }),
      // C. Almacén: nuevo, sin asignar, prioridad alta
      () => simular(ahora - 150 * 60000, { dep: 'ALM', sol: 'u3', cat: 'ALM-05', hasta: 0 }),
      // D. Comercial: resuelto, pendiente de confirmación del solicitante
      () => simular(ahora - 26 * 3600e3, { dep: 'COM', sol: 'u2', cat: 'COM-03', resp: 'u5', directo: true, sinEspera: true, vel: 0.3, sinCierre: true }),
      // E. Almacén: en proceso con un operador que hoy no está disponible
      () => simular(ahora - 3 * DAY, { dep: 'ALM', sol: 'u11', cat: 'ALM-08', resp: 'u10', directo: true, sinEspera: true, vel: 0.4, hasta: 2 })
    ];
    guiados.forEach(g => { try { g(); } catch (e) { console.warn('[DEMO] Caso guiado omitido:', e.message); } });

    // Estado final de los usuarios DEMO
    U_('u10').disponible = false;
    M.renumerar();
    M.procesosProgramados(ahora);
    // Notificaciones antiguas se dan por leídas
    db.notificaciones.forEach(n => { if (n.ts < ahora - 2 * DAY) n.leida = true; });
  }

  APD.mockData = { catalogos, poblar };
})();
