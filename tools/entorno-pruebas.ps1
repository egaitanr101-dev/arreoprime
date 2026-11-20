# Entorno local de pruebas: PostgreSQL + PostgREST + servidor web, con las reglas de seguridad reales.
# Recrea la base "apd_local", aplica sql/local/00, sql/01..10, sql/90 y sql/local/10 (usuarios y tickets de prueba),
# inicia PostgREST y deja el servidor web en primer plano (Ctrl+C para detenerlo).
# Abrir: http://localhost:5510/?entorno=local
#
# Requisitos: binarios de PostgreSQL (carpeta bin) y postgrest.exe. Ejemplo:
#   powershell -ExecutionPolicy Bypass -File tools\entorno-pruebas.ps1 -PgBin C:\pg17\pgsql\bin -PgData C:\pg17\datos -PostgRest C:\postgrest\postgrest.exe
# Si -PgData no existe se inicializa un cluster nuevo (solo escucha en localhost).
# (Archivo en ASCII a proposito.)
param(
  [Parameter(Mandatory = $true)][string]$PgBin,
  [Parameter(Mandatory = $true)][string]$PgData,
  [Parameter(Mandatory = $true)][string]$PostgRest,
  [int]$PuertoPg = 55432,
  [int]$PuertoApi = 3010,
  [int]$PuertoWeb = 5510
)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$trabajo = Join-Path $env:TEMP 'apd-entorno-pruebas'
New-Item -ItemType Directory -Force $trabajo | Out-Null
$env:PATH = "$PgBin;$env:PATH"          # PostgREST necesita libpq de PostgreSQL
$env:PGCLIENTENCODING = 'UTF8'
$psql = Join-Path $PgBin 'psql.exe'

# 1. PostgreSQL
if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
  Write-Host '== Inicializando cluster de PostgreSQL'
  & (Join-Path $PgBin 'initdb.exe') -D $PgData -U postgres -A trust -E UTF8 --locale=C | Out-Null
}
& (Join-Path $PgBin 'pg_isready.exe') -h localhost -p $PuertoPg | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host '== Iniciando PostgreSQL'
  Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') -WindowStyle Hidden -ArgumentList @('-D', "`"$PgData`"", '-o', "`"-p $PuertoPg -c listen_addresses=localhost`"", '-l', "`"$trabajo\postgres.log`"", 'start')
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep 1; & (Join-Path $PgBin 'pg_isready.exe') -h localhost -p $PuertoPg | Out-Null; if ($LASTEXITCODE -eq 0) { break } }
}

# 2. Base de datos
Write-Host '== Recreando la base apd_local'
Get-Process postgrest -ErrorAction SilentlyContinue | Stop-Process -Force
& $psql -h localhost -p $PuertoPg -U postgres -q -v ON_ERROR_STOP=1 -c "drop database if exists apd_local with (force);" -c "create database apd_local;"
$scripts = 'sql\local\00_simulacion_supabase.sql', 'sql\01_base.sql', 'sql\02_tablas.sql', 'sql\03_catalogos.sql', 'sql\04_funciones_seguridad.sql',
           'sql\05_motor.sql', 'sql\06_rpc.sql', 'sql\07_triggers.sql', 'sql\08_rls.sql', 'sql\09_storage.sql', 'sql\10_vistas.sql',
           'sql\90_datos_demo.sql', 'sql\local\10_usuarios_prueba.sql'
foreach ($s in $scripts) {
  & $psql -h localhost -p $PuertoPg -U postgres -d apd_local -q -X -v ON_ERROR_STOP=1 -f (Join-Path $raiz $s) | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Error ejecutando $s" }
}

# 3. PostgREST (secreto aleatorio por ejecucion; nunca se guarda en el proyecto)
$secreto = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
@"
db-uri = "postgres://authenticator:local-solo-pruebas@localhost:$PuertoPg/apd_local"
db-schemas = "public,reporting"
db-anon-role = "anon"
db-max-rows = 1000
jwt-secret = "$secreto"
server-host = "127.0.0.1"
server-port = $PuertoApi
"@ | Set-Content -Encoding ascii (Join-Path $trabajo 'postgrest.conf')
Write-Host '== Iniciando PostgREST'
Start-Process -FilePath $PostgRest -NoNewWindow -ArgumentList "`"$trabajo\postgrest.conf`"" -RedirectStandardOutput "$trabajo\postgrest.log" -RedirectStandardError "$trabajo\postgrest.err"
Start-Sleep 2

# 4. Servidor web con proxy /rest/v1 y usuarios de prueba
[ordered]@{ postgrest = "http://127.0.0.1:$PuertoApi"; secreto = $secreto; usuarios = (Join-Path $raiz 'sql\local\usuarios-prueba.json') } | ConvertTo-Json |
  Set-Content -Encoding UTF8 (Join-Path $trabajo 'pruebas.json')
& (Join-Path $PSScriptRoot 'servidor-local.ps1') -Puerto $PuertoWeb -Pruebas (Join-Path $trabajo 'pruebas.json')
