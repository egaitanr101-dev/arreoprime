/* Selecciona la implementación de APD.api según APD.config.modo.
 *   DEMO     → js/api/mock (datos ficticios en memoria)
 *   SUPABASE → js/api/supabase (proyecto Supabase)
 *   LOCAL    → js/api/supabase contra PostgreSQL + PostgREST local (tools/entorno-pruebas.ps1)
 * Las pantallas solo usan APD.api, por eso no cambian entre modos. */
(function () {
  'use strict';
  const cfg = APD.config;
  const conBase = cfg.modo === 'SUPABASE' || cfg.modo === 'LOCAL';
  if (conBase && window.supabase && cfg.supabase && cfg.supabase.url && cfg.supabase.anonKey) {
    APD.api = APD.apiSupabase.crear();
    return;
  }
  if (conBase) console.error('[ArreoPrime] Falta la configuración de Supabase (js/config.js) o la librería supabase-js. Se usa el modo DEMO.');
  cfg.modo = 'DEMO';
  APD.apiMock.iniciar();
  APD.api = APD.apiMock;
})();
