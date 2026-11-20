# Servidor estatico minimo para el prototipo en http://localhost:5510/
# No requiere instalar nada (usa .NET incluido en Windows). Solo escucha en localhost.
#
# Uso normal (modo DEMO):
#   powershell -ExecutionPolicy Bypass -File tools\servidor-local.ps1
#
# Entorno local de pruebas con base de datos real (lo arranca tools\entorno-pruebas.ps1):
#   -Pruebas <archivo.json> con { postgrest, secreto, usuarios: ruta a sql\local\usuarios-prueba.json }
#   * /rest/v1/*            -> se reenvia a PostgREST (igual que la API de Supabase)
#   * /__pruebas/config.js  -> configuracion LOCAL con tokens JWT de los usuarios de prueba
#   Abrir: http://localhost:5510/?entorno=local
#
# (Archivo en ASCII a proposito: Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI.)
param([int]$Puerto = 5510, [string]$Pruebas = '')

$raiz = Split-Path -Parent $PSScriptRoot
$tipos = @{
  '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.md' = 'text/plain; charset=utf-8'
}

function B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function NuevoJwt($carga, [string]$secreto) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $h = B64Url $enc.GetBytes('{"alg":"HS256","typ":"JWT"}')
  $p = B64Url $enc.GetBytes(($carga | ConvertTo-Json -Compress))
  $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $enc.GetBytes($secreto))
  $s = B64Url $hmac.ComputeHash($enc.GetBytes("$h.$p"))
  return "$h.$p.$s"
}

$cfg = $null
$configJs = $null
if ($Pruebas) {
  $cfg = Get-Content -Raw -Encoding UTF8 $Pruebas | ConvertFrom-Json
  $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 12 * 3600
  $anon = NuevoJwt ([ordered]@{ role = 'anon'; exp = $exp }) $cfg.secreto
  $lista = @()
  $usuarios = Get-Content -Raw -Encoding UTF8 $cfg.usuarios | ConvertFrom-Json
  foreach ($u in $usuarios) {
    $tok = NuevoJwt ([ordered]@{ sub = $u.id; role = 'authenticated'; aud = 'authenticated'; exp = $exp }) $cfg.secreto
    $lista += [ordered]@{ id = $u.id; nombre = $u.nombre; rol = $u.rol; departamento = $u.departamento; depto_nombre = $u.depto_nombre; nota = $u.nota; token = $tok }
  }
  $configJs = "/* Generado por tools/servidor-local.ps1 - SOLO entorno local de pruebas */`n" +
    "APD.config.modo = 'LOCAL';`n" +
    "APD.config.supabase = { url: location.origin, anonKey: '$anon' };`n" +
    "APD.config.usuariosPrueba = " + (ConvertTo-Json -InputObject $lista -Compress -Depth 4) + ";`n"
}

function Reenviar($ctx, [string]$destino) {
  $req = $ctx.Request; $res = $ctx.Response
  $w = [System.Net.HttpWebRequest]::Create($destino)
  $w.Method = $req.HttpMethod
  $w.AllowAutoRedirect = $false
  foreach ($k in $req.Headers.AllKeys) {
    switch -Regex ($k) {
      '^(Authorization|Prefer|Accept-Profile|Content-Profile|apikey|x-client-info)$' { $w.Headers[$k] = $req.Headers[$k] }
      '^Accept$' { $w.Accept = $req.Headers[$k] }
      '^Content-Type$' { $w.ContentType = $req.Headers[$k] }
    }
  }
  if ($req.HasEntityBody) {
    $ms = New-Object System.IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    $cuerpo = $ms.ToArray()
    $w.ContentLength = $cuerpo.Length
    $s = $w.GetRequestStream(); $s.Write($cuerpo, 0, $cuerpo.Length); $s.Close()
  }
  try { $r = $w.GetResponse() }
  catch [System.Net.WebException] {
    $r = $_.Exception.Response
    if (-not $r) { $res.StatusCode = 502; $res.Close(); return }
  }
  $res.StatusCode = [int]$r.StatusCode
  foreach ($h in 'Content-Range', 'Preference-Applied', 'Location') { if ($r.Headers[$h]) { $res.Headers.Add($h, $r.Headers[$h]) } }
  if ($r.Headers['Content-Type']) { $res.ContentType = $r.Headers['Content-Type'] }
  $rs = $r.GetResponseStream()
  $ms2 = New-Object System.IO.MemoryStream
  if ($rs) { $rs.CopyTo($ms2); $rs.Close() }
  $r.Close()
  $bytes = $ms2.ToArray()
  $res.ContentLength64 = $bytes.Length
  if ($bytes.Length -gt 0 -and $req.HttpMethod -ne 'HEAD') { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
  $res.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Puerto/")
$listener.Start()
if ($cfg) { Write-Host "ArreoPrime (ENTORNO LOCAL DE PRUEBAS) en http://localhost:$Puerto/?entorno=local - Ctrl+C para detener" }
else { Write-Host "ArreoPrime (DEMO) en http://localhost:$Puerto/ - Ctrl+C para detener" }
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $ruta = [System.Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
      $resp = $ctx.Response
      if ($cfg -and $ruta.StartsWith('rest/v1/')) {
        Reenviar $ctx ($cfg.postgrest + '/' + $ctx.Request.Url.AbsolutePath.Substring(9) + $ctx.Request.Url.Query)
        continue
      }
      if ($cfg -and $ruta -eq '__pruebas/config.js') {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($configJs)
        $resp.ContentType = $tipos['.js']
        $resp.Headers.Add('Cache-Control', 'no-store')
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.Close()
        continue
      }
      if ([string]::IsNullOrEmpty($ruta)) { $ruta = 'index.html' }
      $archivo = [System.IO.Path]::GetFullPath((Join-Path $raiz $ruta))
      if ($archivo.StartsWith($raiz) -and (Test-Path -LiteralPath $archivo -PathType Leaf)) {
        $bytes = [System.IO.File]::ReadAllBytes($archivo)
        $ext = [System.IO.Path]::GetExtension($archivo).ToLower()
        if ($tipos.ContainsKey($ext)) { $resp.ContentType = $tipos[$ext] } else { $resp.ContentType = 'application/octet-stream' }
        $resp.Headers.Add('Cache-Control', 'no-store')
        $resp.ContentLength64 = $bytes.Length
        if ($ctx.Request.HttpMethod -ne 'HEAD') { $resp.OutputStream.Write($bytes, 0, $bytes.Length) }
      } else {
        $resp.StatusCode = 404
      }
      $resp.Close()
    } catch {
      Write-Host "Error atendiendo $($ctx.Request.Url): $($_.Exception.Message)"
      try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch { }
    }
  }
} finally {
  $listener.Stop()
}
