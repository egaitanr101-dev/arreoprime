// =============================================================================
// Edge Function "admin-invitar" — Alta de usuarios por invitación (sin autorregistro)
//
// Por qué existe: invitar un usuario requiere la service_role, que NUNCA puede estar
// en el navegador. Esta función corre en el servidor de Supabase (Deno):
//   1. Verifica en la base de datos que quien llama tiene el permiso admin.usuarios.
//   2. Envía la invitación con la service_role (variable de entorno del servidor).
//   3. Activa el perfil con rol y departamento mediante fn_admin_usuario_guardar,
//      con la identidad del administrador, para que quede en auditoría y pase por
//      las mismas validaciones (coherencia rol ↔ departamento, permisos otorgables).
//
// Variables (Supabase las define automáticamente salvo APP_URL y APP_ORIGIN):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, APP_URL, APP_ORIGIN
// Despliegue: supabase functions deploy admin-invitar
// =============================================================================
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const ORIGEN = Deno.env.get('APP_ORIGIN') ?? '';
const CORS = {
  'Access-Control-Allow-Origin': ORIGEN,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};
const ROLES = ['SOLICITANTE', 'SUPERVISOR_LIQUIDACIONES', 'OPERADOR_TRANSPORTES', 'SUPERVISOR_TRANSPORTES', 'GERENCIA', 'ADMINISTRADOR', 'SUPERUSUARIO'];

function respuesta(cuerpo: unknown, estado = 200): Response {
  return new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return respuesta({ error: 'Método no permitido' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const autorizacion = req.headers.get('Authorization') ?? '';
  if (!autorizacion.startsWith('Bearer ')) return respuesta({ error: 'No autenticado' }, 401);

  // Cliente con la identidad de quien llama: la base de datos decide si es administrador.
  const llamante = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: autorizacion } },
    auth: { persistSession: false },
  });
  const { data: perfil, error: errPerfil } = await llamante.rpc('fn_mi_perfil');
  if (errPerfil || !Array.isArray(perfil?.permisos) || !perfil.permisos.includes('admin.usuarios')) {
    return respuesta({ error: 'No autorizado' }, 403);
  }

  const cuerpo = await req.json().catch(() => null);
  const correo = String(cuerpo?.correo ?? '').trim().toLowerCase();
  const nombre = String(cuerpo?.nombre ?? '').trim();
  const rol = String(cuerpo?.rol ?? '');
  const departamento = String(cuerpo?.departamento ?? '');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)) return respuesta({ error: 'Correo no válido' }, 400);
  if (nombre.length < 3) return respuesta({ error: 'Nombre no válido' }, 400);
  if (!ROLES.includes(rol)) return respuesta({ error: 'Rol no válido' }, 400);

  // Invitación con service_role (solo en el servidor).
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: invitacion, error: errInv } = await admin.auth.admin.inviteUserByEmail(correo, {
    data: { nombre },
    redirectTo: Deno.env.get('APP_URL') ?? undefined,
  });
  if (errInv || !invitacion?.user) return respuesta({ error: errInv?.message ?? 'No se pudo invitar' }, 400);

  // El trigger crea el perfil INACTIVO; se activa con la RPC auditada (identidad del administrador).
  const { error: errPerfilNuevo } = await llamante.rpc('fn_admin_usuario_guardar', {
    p_usuario: invitacion.user.id,
    p: {
      rol, departamento, activo: true,
      alcance: Array.isArray(cuerpo?.alcance) ? cuerpo.alcance : [],
      permisos_extra: Array.isArray(cuerpo?.permisos_extra) ? cuerpo.permisos_extra : [],
    },
  });
  if (errPerfilNuevo) {
    return respuesta({ error: errPerfilNuevo.message, usuario_id: invitacion.user.id, nota: 'Invitación enviada; perfil pendiente de activación' }, 400);
  }
  return respuesta({ id: invitacion.user.id, correo });
});
