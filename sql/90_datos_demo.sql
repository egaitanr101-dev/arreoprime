-- =============================================================================
-- 90_datos_demo.sql — SOLO PARA PROYECTOS DE DESARROLLO O PRUEBAS
--
-- Todo lo que inserta este script es FICTICIO: clientes, rutas, colaboradores,
-- vehículos, bodegas, tiempos SLA y calendario. NO ejecutar en producción.
-- En producción estos valores los define la organización (D-15, D-18).
-- La lista de feriados es orientativa y debe validarse contra el calendario oficial.
-- =============================================================================
begin;

insert into public.clientes (id, nombre) values
  ('C-1001', 'Súper El Ahorro (DEMO)'), ('C-1002', 'Pulpería Don Chepe (DEMO)'), ('C-1003', 'Restaurante La Fogata (DEMO)'),
  ('C-1004', 'Hotel Vista Volcán (DEMO)'), ('C-1005', 'Carnicería La Central (DEMO)');
insert into public.rutas (id, nombre) values
  ('R-101', 'San José Centro (DEMO)'), ('R-102', 'Escazú – Santa Ana (DEMO)'), ('R-103', 'Heredia (DEMO)'),
  ('R-104', 'Alajuela (DEMO)'), ('R-105', 'Cartago (DEMO)');
insert into public.colaboradores (id, nombre, tipo) values
  ('CH-01', 'Chofer Demo Uno', 'CHOFER'), ('CH-02', 'Chofer Demo Dos', 'CHOFER'), ('CH-03', 'Chofer Demo Tres', 'CHOFER'),
  ('AY-01', 'Ayudante Demo Uno', 'AYUDANTE'), ('AY-02', 'Ayudante Demo Dos', 'AYUDANTE');
insert into public.vehiculos (id, descripcion) values
  ('DEMO-001', 'Camión refrigerado 5 t (DEMO)'), ('DEMO-002', 'Furgón refrigerado 1,5 t (DEMO)');
insert into public.bodegas (id, nombre) values
  ('B-01', 'Bodega Central (DEMO)'), ('B-02', 'Cámara fría 1 (DEMO)'), ('B-03', 'Bodega de Devoluciones (DEMO)');
insert into public.unidades_medida (id, nombre) values
  ('KG', 'Kilogramo'), ('CJ', 'Caja'), ('UN', 'Unidad'), ('TA', 'Tarima');

-- Calendario y SLA de demostración (los mismos valores ficticios del prototipo)
insert into public.calendario_laboral (dia_semana, hora_inicio, hora_fin) values
  (1, '07:00', '17:00'), (2, '07:00', '17:00'), (3, '07:00', '17:00'), (4, '07:00', '17:00'), (5, '07:00', '17:00'), (6, '07:00', '12:00');
insert into public.feriados (fecha, nombre) values
  ('2026-12-01', 'Abolición del Ejército (validar)'), ('2026-12-25', 'Navidad (validar)'), ('2027-01-01', 'Año Nuevo (validar)');

insert into public.sla_versiones (version, umbral, nota) values (1, 0.75, 'DEMO — valores ficticios, no son compromisos (D-15)');
insert into public.sla_valores (version, categoria_id, prioridad_id, minutos_primera_respuesta, minutos_asignacion, minutos_resolucion, horas_maximo_atencion) values
  (1, null, 'CRITICA', 30, 60, 240, 24),
  (1, null, 'ALTA', 60, 120, 480, 48),
  (1, null, 'MEDIA', 120, 240, 960, 96),
  (1, null, 'BAJA', 240, 480, 2400, 168);

commit;
