# ArreoPrime | TRANSPORTES · SERVICIO · LOGÍSTICA

Mesa de servicio de Transportes para las solicitudes de Comercial, Almacén y Liquidaciones.

**Estado actual:** Fase 4 entregada: el frontend funciona con datos ficticios (DEMO) o con la base de datos real (Supabase), y se probó de punta a punta contra PostgreSQL local. Falta conectar el proyecto Supabase ([docs/FASE-4-DESARROLLO.md](docs/FASE-4-DESARROLLO.md) §5).

Antes: Fase 3 entregada. Prototipo navegable con **datos ficticios** (Fase 2) y scripts de base de datos y seguridad para Supabase (Fase 3), probados en PostgreSQL 17 local: 21 pruebas funcionales y 19 de seguridad correctas.

- Base de datos: carpeta `sql/` (ejecutar 01 → 11; en desarrollo, luego 90, 98 y 99). Prueba local: `tools\probar-sql-local.ps1`. Detalle en [docs/FASE-3-ARQUITECTURA-BD.md](docs/FASE-3-ARQUITECTURA-BD.md).

- Abrir: doble clic en `index.html`, o `powershell -ExecutionPolicy Bypass -File tools\servidor-local.ps1` y luego `http://localhost:5510/`.
- Análisis y arquitectura: [docs/FASE-1-ANALISIS-FUNCIONAL.md](docs/FASE-1-ANALISIS-FUNCIONAL.md)
- Prototipo, recorridos y pruebas: [docs/FASE-2-PROTOTIPO.md](docs/FASE-2-PROTOTIPO.md)

Stack: HTML5, CSS3 y JavaScript puro, sin npm ni frameworks. Backend previsto: Supabase (PostgreSQL, Auth, RLS, Storage).

## Publicación (Vercel)

- Sitio estático sin compilación: Vercel sirve la raíz del repositorio (`index.html`, `css/`, `js/`, `assets/`).
- `.vercelignore` excluye del sitio `sql/`, `docs/`, `tools/` y `supabase/` (quedan en el repositorio, pero no en el sitio). El repositorio es **público**: las migraciones que nombran a personas reales están en `.gitignore` y quedan solo en el equipo local.
- `vercel.json` agrega cabeceras de seguridad y evita que `index.html` quede en caché. Al cambiar CSS/JS, subir el número `?v=` en `index.html`.
- Configuración en Vercel: *Framework Preset* = **Other**, sin *Build Command* ni *Output Directory*.
- Después de publicar: en Supabase → Authentication → URL Configuration, poner la URL de Vercel como *Site URL* y agregarla en *Redirect URLs* (invitaciones y recuperación de contraseña).
- `js/config.js` solo contiene la URL y la clave **publicable** de Supabase (son públicas por diseño). Nunca subir la `service_role`.
