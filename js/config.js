/* ArreoPrime | TRANSPORTES · SERVICIO · LOGÍSTICA
 * Configuración pública del frontend.
 *
 * Para conectar a Supabase complete "url" y "anonKey" (Project Settings → API).
 * Ambos valores son públicos por diseño: la seguridad la aplican RLS y las funciones
 * del servidor. NUNCA colocar aquí la service_role, contraseñas ni otros secretos.
 * Con url vacía la aplicación funciona en modo DEMO (datos ficticios en memoria).
 */
window.APD = window.APD || {};
APD.pages = APD.pages || {};

APD.config = {
  nombreApp: 'ArreoPrime',
  subtitulo: 'TRANSPORTES · SERVICIO · LOGÍSTICA',
  version: '0.4.0 · Fase 4',
  zonaHoraria: 'America/Costa_Rica',
  offsetHoras: -6,
  supabase: {
    // Proyecto de DESARROLLO "arreoprime-desk-dev". Clave publicable: segura en el navegador con RLS activo.
    url: 'https://wkbiasltcdrjhrccfinb.supabase.co',
    anonKey: 'sb_publishable_DgQ0Yyy64u05o1Gfzoc6wQ_6qPPU1kG'
  },
  // Ingreso con Microsoft 365 (D-02). Activar cuando el proveedor Azure esté configurado en Supabase.
  microsoft: false
};
APD.config.modo = APD.config.supabase.url ? 'SUPABASE' : 'DEMO';
// Agregar ?demo=1 a la dirección abre el prototipo con datos ficticios, sin tocar la base de datos.
if (/[?&]demo=1\b/.test(location.search)) APD.config.modo = 'DEMO';
