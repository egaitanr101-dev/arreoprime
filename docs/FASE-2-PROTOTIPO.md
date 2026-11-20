# ArreoPrime Desk | TRANSPORTES SERVICE DESK
## FASE 2 — Prototipo UX/UI navegable

| Campo | Valor |
|---|---|
| Versión | 0.2.0 (prototipo) |
| Fecha | 2026-11-16 |
| Base | Análisis de la Fase 1 con las 21 decisiones aprobadas según la recomendación |
| Estado | Listo para revisión |

> **Todos los datos del prototipo son ficticios** (personas, clientes, rutas, placas, montos, tiempos SLA y feriados). El prototipo **no se conecta a ninguna base de datos**: funciona con una API simulada en memoria y los cambios se pierden al recargar la página. Esto se indica en una franja amarilla en todas las pantallas.

---

## 1. Cómo abrirlo

**Opción A — doble clic (sin instalar nada):** abra `index.html` con Edge o Chrome.

**Opción B — servidor local** (recomendado para probar en otro equipo de la red o si el navegador bloquea archivos locales):

```
powershell -ExecutionPolicy Bypass -File tools\servidor-local.ps1
```

Luego abra `http://localhost:5510/`. El servidor solo escucha en el propio equipo y se detiene con Ctrl+C.

En la pantalla de ingreso elija un **usuario de demostración**. Use «Cambiar de usuario» (franja amarilla o icono de salida) para probar otro rol **sin perder** los cambios; «Reiniciar datos» regenera el escenario.

## 2. Usuarios de demostración

| Usuario | Rol | Departamento | Para probar |
|---|---|---|---|
| Ana Solís | Solicitante | Comercial | Portal, crear solicitud, responder información, confirmar/reabrir |
| Carlos Mora | Solicitante | Comercial | Visibilidad por departamento (ve lo de Ana y viceversa) |
| Laura Jiménez / Gabriela Núñez | Solicitante | Almacén | Formularios de bodegas y movimientos |
| Diego Vargas / Fernando Solano | Solicitante | Liquidaciones | Montos CRC, cálculo de diferencia, resumen de investigación |
| María Rojas | Operador | Transportes (alcance COM, ALM) | Tickets asignados; **no** ve montos de Liquidaciones |
| José Araya | Operador | Transportes (alcance LIQ, COM) | Permiso financiero e investigaciones otorgado individualmente |
| Pablo Méndez | Operador | Transportes | «No disponible»: el sistema impide asignarle tickets |
| Kevin Brenes | Operador | Transportes | Inactivo: no puede ingresar |
| Sofía Castro | Supervisora | Transportes | Asignaciones, cierres, reaperturas, SLA, auditoría |
| Ricardo Pérez | Gerencia | Gerencia | Solo lectura: dashboards, reportes, consulta |
| Andrea Quesada | Administradora | Sistemas | Usuarios, permisos, categorías, SLA; sin acceso a tickets |

## 3. Recorridos sugeridos

1. **Respuesta a solicitud de información:** ingrese como Ana → Inicio → «Requieren atención» → ticket «Segunda visita» en espera → responda. El ticket se reanuda solo (D-07) y el SLA deja de estar pausado.
2. **Crear una solicitud en 3 pasos:** Ana → Crear solicitud → categoría → datos → revisar → enviar. Observe el número `TS-2026-NNNNNN` y la confirmación.
3. **Asignación con carga de trabajo:** Sofía → Asignaciones → «Asignar» en el ticket de Almacén sin asignar. Vea el responsable sugerido, la carga de cada uno y por qué Pablo y Kevin no son elegibles.
4. **Notas internas:** Sofía o María → un ticket → Conversación → «Nota interna» (fondo ámbar). Luego ingrese como Ana: la nota no aparece ni en la conversación ni en el historial.
5. **Investigación de Liquidaciones:** José → Investigaciones → ticket «Faltantes o sobrantes de dinero — Ruta R-105» → Información (libro de movimientos) y Gestión (hallazgos, concluir). «Marcar resuelto» está bloqueado hasta concluir la investigación.
6. **Integridad financiera:** José → registrar una aclaración mayor al pendiente (lo rechaza), luego una válida y su reversión. Los totales del módulo Liquidaciones no cambian por comentarios ni por reversiones.
7. **Restricción financiera:** María → abra el mismo ticket de Liquidaciones: ve el ticket, pero los montos y la investigación aparecen como restringidos.
8. **SLA versionado:** Andrea → SLA y calendario → «Nueva versión». Los tickets existentes conservan la versión con la que se crearon.
9. **Reportes con permisos:** Ricardo o Sofía → Reportes → exportar CSV o PDF. Ana puede exportar solo las solicitudes de Comercial desde «Solicitudes del departamento».
10. **Móvil:** en el teléfono o con el navegador estrecho, las tablas se convierten en tarjetas, el menú se oculta y hay un botón flotante para crear solicitudes.

## 4. Qué cubre el prototipo

| Pantalla | Contenido |
|---|---|
| Ingreso | Selección de usuario ficticio por rol (en producción: Supabase Auth, D-02) |
| Portal solicitante | Inicio con 3 accesos, solicitudes del departamento (filtro «Solo creadas por mí»), consultar estado con avance paso a paso |
| Formulario de tickets | 3 pasos, campos dinámicos por categoría (36 categorías), cálculo de diferencia CRC, adjuntos, registro asistido para Transportes (D-03) |
| Bandeja de Transportes | Filtros rápidos con conteos, filtros avanzados, búsqueda, orden, paginación, columnas personalizables, panel de carga de trabajo |
| Detalle del ticket | Información · Gestión · Conversación · Historial; acciones según rol y estado; SLA por métrica; avance |
| Dashboard | KPI, distribución por departamento/estado/prioridad/categoría, tendencia semanal, productividad, casos recurrentes; vista «Mi trabajo» para operadores |
| Liquidaciones | KPI financieros desde el libro de movimientos, faltantes por ruta/chofer/ayudante/tipo, detalle de diferencias e investigaciones |
| Reportes | 10 reportes, filtros por período y departamento, CSV (UTF-8, separador «;») y PDF por impresión; cada exportación queda en auditoría |
| SLA | Semáforo, tickets en riesgo, política vigente versionada, calendario laboral, feriados |
| Administración | Usuarios (invitar, editar, alcance, permisos otorgables), matriz de permisos, departamentos, categorías, configuración, auditoría |
| Notificaciones | Bandeja in-app con contador y preferencias por evento |

## 5. Reglas que el prototipo ya hace cumplir

La API simulada (`js/api/mock/mockApi.js`) vuelve a validar cada operación, igual que lo harán las funciones RPC y las políticas RLS de la Fase 3. Ocultar un botón nunca es la única barrera.

- El departamento del ticket lo fija el servidor desde el perfil; se ignora el valor enviado por el navegador.
- Un solicitante no abre tickets de otro departamento: recibe «no encontrado» (no se revela que existe).
- Notas internas, evidencias internas y eventos internos del historial nunca llegan a los solicitantes.
- Los montos de Liquidaciones están en registros separados con su propio permiso.
- Transiciones de estado validadas contra la tabla única de `js/core/estados.js`; justificaciones y motivos obligatorios.
- No se asigna a usuarios inactivos, no disponibles o fuera de alcance; la asignación automática (desactivada por defecto) sigue la misma regla.
- No se puede resolver un ticket con investigación abierta. Las investigaciones concluidas no se editan; al reabrirlas se conserva la conclusión anterior.
- El libro financiero no admite ediciones ni saldos negativos; las correcciones son reversiones y no se puede revertir dos veces.
- Nadie modifica su propio rol; rol y departamento deben ser coherentes.
- El Administrador no ve tickets; Gerencia no modifica nada.

## 6. Verificación realizada

| Prueba | Resultado |
|---|---|
| 26 pruebas negativas de permisos (acceso entre departamentos, notas internas, rol propio, Gerencia, Administrador, usuario inactivo) | 26/26 correctas |
| Flujo completo creación → asignación → espera → respuesta → resolución → reapertura → confirmación | Correcto (15 eventos de historial) |
| Integridad financiera (pendiente negativo, reversión doble, totales tras comentarios y reversiones) | Correcto |
| SLA versionado (ticket previo conserva v1, nuevo usa v2) | Correcto |
| Recorrido automático de todas las pantallas de 7 roles, incluidas las 4 pestañas del ticket | Sin errores |
| Desbordamiento horizontal en móvil (375 px) | Ninguno tras corregir la sub-navegación de Administración |

**No verificado aún:** pruebas con usuarios reales de cada departamento, Safari en iOS, lectores de pantalla.

## 7. Lo que es simulado (y se reemplaza en la Fase 4)

| Elemento | Prototipo | Producción |
|---|---|---|
| Datos | Memoria del navegador, escenario generado | PostgreSQL (Supabase) |
| Ingreso | Selección de usuario | Supabase Auth (D-02) |
| Archivos | Solo nombre y tamaño | Bucket privado + URL firmada |
| Notificaciones | In-app | In-app + correo para eventos clave (D-14) |
| Procesos programados (auto-cierre, alertas SLA) | Al consultar, cada 30 s | pg_cron |
| Excel (.xlsx) | No incluido; CSV abre en Excel | SheetJS con versión fija (D-17) |
| Edición de catálogos y motivos | Solo lectura (salvo activar/desactivar categorías) | Pantallas de edición |

## 8. Estructura

```
index.html                 punto de entrada
css/                       tokens (tema claro/oscuro), layout, componentes
js/config.js               configuración pública (modo DEMO)
js/core/                   formatos, matriz de permisos, máquina de estados, motor SLA
js/ui/                     iconos y componentes
js/api/mock/               DATOS FICTICIOS + API simulada (único acceso a datos)
js/modules/                pantallas: login, portal, crear, bandeja, ticket, dashboard, liquidaciones, reportes, SLA, admin, notificaciones
js/app.js                  enrutador y estructura por rol
tools/servidor-local.ps1   servidor estático local opcional
```

**Decisión técnica documentada:** se usan scripts clásicos en lugar de módulos ES para que el prototipo abra con doble clic sin servidor. Las pantallas solo hablan con `APD.api`; en la Fase 4 se agrega `js/api/supabase/` con la misma interfaz y se retira `js/api/mock/`.

## 9. Observaciones para su revisión

1. **Prioridades sugeridas por categoría:** son valores DEMO. Confirme o ajuste la prioridad sugerida de cada una de las 36 categorías (Administración → Categorías).
2. **Campos por categoría:** revise que los campos obligatorios sean los correctos para su operación; están definidos en `js/api/mock/data.js` y se trasladarán a la tabla `categoria_campos`.
3. **Pendientes que bloquean producción:** D-02 (autenticación), D-09 (fórmula de diferencia confirmada con Liquidaciones), D-14 (correo), D-15 (tiempos SLA, horario y feriados).
4. **Siguiente fase:** con su aprobación del prototipo, la Fase 3 entrega los scripts SQL completos (esquema, funciones RPC, RLS, Storage, vistas `reporting`) y la suite de pruebas negativas por rol en SQL.
