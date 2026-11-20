# ArreoPrime Desk | TRANSPORTES SERVICE DESK
## FASE 4 — Desarrollo funcional (frontend conectado a la base de datos)

| Campo | Valor |
|---|---|
| Versión | 0.4.0 |
| Fecha | 2026-11-17 |
| Decisiones aplicadas | D-02: ingreso con Microsoft 365 **y** con correo y contraseña por invitación. D-14: por ahora solo notificaciones en la aplicación; el correo se conecta cuando se elija el proveedor. D-17: Excel con SheetJS. |
| Estado | Probado de punta a punta contra PostgreSQL local con las reglas reales. Falta conectarlo a un proyecto Supabase (§5). |

---

## 1. Qué cambió

| Área | Cambio |
|---|---|
| **Tres modos, una sola interfaz** | `js/api/api.js` elige la implementación de `APD.api` según `js/config.js`: **DEMO** (datos ficticios), **SUPABASE** (proyecto real) o **LOCAL** (PostgreSQL + PostgREST en el equipo, solo pruebas). Las pantallas son las mismas en los tres. |
| **Adaptador de base de datos** | `js/api/supabase/supabaseApi.js`: lecturas por vistas y tablas con RLS; escrituras solo por las funciones RPC de la Fase 3. No decide permisos: los aplica la base de datos. |
| **Cálculos compartidos** | `js/api/calculos.js`: dashboard, liquidaciones y reportes con el mismo código en DEMO y con base real. |
| **Permisos en la interfaz** | Con base real, la lista efectiva de permisos viene del servidor (`fn_mi_perfil`); la interfaz ya no depende de una copia local de la matriz. |
| **Ingreso** | Correo y contraseña, «¿Olvidó su contraseña?», ingreso con Microsoft 365 (se activa con `microsoft: true` en `js/config.js` cuando Azure esté configurado) y pantalla para definir la contraseña al aceptar una invitación. |
| **Evidencias** | Carga real al bucket privado (preparar → subir → confirmar) y descarga con URL firmada de 5 minutos. |
| **Liquidaciones** | Las recuperaciones piden forma, fecha y comprobante (D-19). Los identificadores largos se muestran abreviados. |
| **Excel** | Botón «Excel» en Reportes (`js/vendor/xlsx-0.20.3.full.min.js`). Cada exportación queda en auditoría. |
| **Notificaciones** | El contador se actualiza cada minuto. |
| **SLA** | La pantalla funciona sin política vigente («Sin SLA configurado») y permite publicar la primera versión. |
| **Investigaciones (corrección 19/11)** | El operador asignado al ticket gestiona la investigación sin esperar a Supervisión: al asignar el ticket, la investigación sin responsable pasa a esa persona, y si aún no tiene responsable la puede gestionar el responsable del ticket (requiere `investigacion.gestionar`). El bloqueo de «Marcar resuelto» indica qué hacer. Migración: `sql/migraciones/2026-11-19_01_investigacion_operador.sql`; pruebas F4c y F4d en `98_pruebas_funcionales.sql`. |
| **Resolución en un solo paso (19/11)** | «Marcar resuelto» pide el resultado de la investigación y usa el texto de la resolución como conclusión: concluye la investigación y resuelve el ticket a la vez. Hallazgos y aclaraciones quedan opcionales. El rol `OPERADOR_TRANSPORTES` se muestra como «Coordinador de Rutas» y el departamento `TRA` como «Distrib. y Transp. Cárnico» (los códigos internos no cambian). Migración: `sql/migraciones/2026-11-19_02_resolucion_un_paso.sql` (incluye la 01). |
| **Cierre del faltante, evidencias y sobrantes (19/11)** | Al resolver un ticket con faltante pendiente se elige Aclarado, Recuperado o parte y parte (con forma, fecha y comprobante de la recuperación); los movimientos se registran en el libro y el pendiente queda en ₡0. «Marcar resuelto» y «Confirmar y cerrar» admiten evidencias opcionales (y comentario al confirmar). El monto reportado se calcula solo. Los sobrantes se muestran como «Sobrante», sin saldo pendiente. Migración: `sql/migraciones/2026-11-19_03_cierre_faltante.sql`; prueba F4c ampliada. |
| **Supervisor de Liquidaciones y Dashboard de Liquidaciones (19/11)** | Rol `SUPERVISOR_LIQUIDACIONES` («Supervisor de Liquidaciones Crédito y Cobro»): permisos del solicitante de Liquidaciones + `dashboard.liquidaciones`, `reporte.operativo` y `reporte.completo`, todos limitados a LIQ. Pantalla `#/tablero-liquidaciones` (`js/modules/tableroLiq.js`): filtros por mes y motivo, KPIs, tendencia semanal de tickets y de monto, tickets y monto por motivo, top de choferes con incidencias y monto, exportación a Excel (4 hojas) y PDF. Reporte nuevo «Incidencias y montos por chofer». El solicitante de Liquidaciones se muestra como «Liquidador de Rutas Crédito y Cobro» (`P.etiquetaRol`). Migración: `sql/migraciones/2026-11-19_04_supervisor_liquidaciones.sql`; prueba F8. |
| **Librerías** | `js/vendor/supabase-js-2.45.4.js` y `js/vendor/xlsx-0.20.3.full.min.js`, con versión fija y servidas desde la propia aplicación (sin CDN). |

## 2. Verificación realizada

Entorno: PostgreSQL 17.6 y PostgREST 12.2.3 en este equipo, con la simulación de Supabase. El frontend real habla con PostgREST por `/rest/v1`, igual que con Supabase, usando tokens JWT de usuarios de prueba.

| Prueba | Resultado |
|---|---|
| Flujo completo desde la aplicación: crear → revisión → asignar (sugerido) → en espera → respuesta del solicitante (reanuda sola) → resolver → confirmar | Correcto |
| Restricciones con la base real: solicitante no asigna ni ve finanzas; operadora sin permiso ve el ticket de Liquidaciones pero no montos ni investigación; Gerencia no comenta; Administrador no ve tickets ni cambia su rol; no se asigna a usuarios no disponibles | Correctas (mensajes del servidor) |
| Liquidaciones: faltante ₡148 500, aclarado ₡48 500, pendiente ₡100 000; aclaración mayor al pendiente rechazada; resolución bloqueada hasta concluir la investigación; Liquidaciones ve el resultado pero no los hallazgos | Correcto |
| Dashboard, 10 reportes, SLA, notificaciones y auditoría con datos reales | Correcto |
| Recorrido automático de 79 pantallas con 8 roles, incluidas las 4 pestañas del ticket | Sin errores |
| Regresión del modo DEMO (dashboard, liquidaciones, 10 reportes, 7 roles) | Sin errores |

**No probado todavía** (requiere el proyecto Supabase): inicio de sesión real con correo y contraseña, invitaciones, Microsoft 365, carga y descarga de archivos en Storage, la Edge Function `admin-invitar` y el proceso programado con pg_cron.

## 3. Entorno local de pruebas

```
powershell -ExecutionPolicy Bypass -File tools\entorno-pruebas.ps1 -PgBin <carpeta bin de PostgreSQL> -PgData <carpeta de datos> -PostgRest <ruta a postgrest.exe> -PuertoWeb 5520
```

Luego abra `http://localhost:5520/?entorno=local`. El script recrea la base `apd_local`, carga usuarios y tickets de prueba (`sql/local/10_usuarios_prueba.sql`), genera un secreto JWT aleatorio por ejecución (nunca se guarda en el proyecto) y deja el servidor en primer plano. El modo LOCAL solo se activa en `localhost` con `?entorno=local`; en un hosting real ese archivo no existe.

## 4. Pendientes de esta fase

| Pendiente | Motivo |
|---|---|
| Correo para eventos clave (D-14) | Falta elegir el proveedor (Microsoft 365 / Graph u otro). Punto de conexión previsto: webhook de base de datos sobre `notificaciones` → Edge Function de envío. |
| Paginación en el servidor de la bandeja | Con el volumen esperado no es necesaria. Si crece, pedir la columna `sla` solo para la página visible (Fase 3 §12). |
| Pruebas con usuarios reales de cada departamento | Fase 5. |

## 5. Conectar el proyecto Supabase (pasos)

1. **Crear el proyecto** de desarrollo en supabase.com (región más cercana a Costa Rica, por ejemplo `us-east-1`).
2. **Base de datos:** en Database → Extensions, habilitar `pg_cron`. En el SQL Editor, ejecutar `sql/instalar_supabase.sql` (es `sql/01` a `sql/11` en un solo archivo). En desarrollo, ejecutar después `sql/90`, `sql/98` y `sql/99`, **cada uno en un envío separado**: el Editor SQL ejecuta cada envío como una sola transacción, y las pruebas terminan con `ROLLBACK`. Desactive la traducción automática del navegador en supabase.com, porque rompe el panel.
3. **API:** en Project Settings → API → *Exposed schemas*, agregar `reporting` (además de `public`).
4. **Autenticación:** en Authentication → Providers → Email, desactivar «Allow new users to sign up». En URL Configuration, poner la URL del sitio. Traducir las plantillas de invitación y recuperación. Opcional: proveedor Azure (Microsoft 365).
5. **Storage:** confirmar que el bucket `evidencias` es privado y que sus dos políticas existen. Si `09_storage.sql` no pudo crearlas, se crean desde Storage → Policies con el mismo texto.
6. **Edge Function:** `supabase functions deploy admin-invitar`, con las variables `APP_URL` y `APP_ORIGIN`.
7. **Frontend:** en `js/config.js`, completar `supabase.url` y `supabase.anonKey` (Project Settings → API; ambos son públicos). Poner `microsoft: true` solo si se configuró Azure.
8. **Primer administrador:** crearlo en Authentication → Users → *Add user* → *Create new user* (correo, contraseña y *Auto Confirm User*), o con *Invite* cuando la URL del sitio ya esté configurada. Luego activarlo una sola vez en el SQL Editor:
   `update public.perfiles set rol_id = 'ADMINISTRADOR', departamento_id = 'SIS', activo = true where correo = '<correo>';`
   Desde ahí, el resto de usuarios se invita desde la aplicación (Administración → Usuarios), lo que requiere la Edge Function. Mientras no esté desplegada, se crean en Authentication → Users y el Administrador les asigna rol, departamento y estado desde Administración → Usuarios.

**Estado del proyecto de desarrollo (2026-11-17):** instalado y verificado en Supabase (`arreoprime-desk-dev`): 49 tablas, 27 funciones RPC, 68 políticas RLS, 2 políticas de Storage, 7 vistas de reportes y la tarea programada. Las suites 98 y 99 pasan. La API expone solo `public` y `reporting`, el autorregistro está cerrado y, sin sesión, toda lectura o llamada se rechaza. `js/config.js` apunta a este proyecto; agregar `?demo=1` a la dirección abre el modo demostración.
