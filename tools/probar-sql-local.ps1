# Prueba los scripts SQL en un PostgreSQL local (sin Supabase).
# Crea de cero la base "apd_pruebas", aplica la simulacion de Supabase, sql/01..10 y 90,
# y ejecuta sql/98_pruebas_funcionales.sql y sql/99_pruebas_seguridad.sql. Se detiene en el primer error.
# (11_cron.sql se omite: pg_cron no viene en PostgreSQL para Windows.)
# Uso: powershell -ExecutionPolicy Bypass -File tools\probar-sql-local.ps1 -Psql "C:\ruta\psql.exe" -Puerto 55432
param([string]$Psql = 'psql', [int]$Puerto = 55432, [switch]$SinDemo)

$raiz = Split-Path -Parent $PSScriptRoot
$env:PGCLIENTENCODING = 'UTF8'
& $Psql -h localhost -p $Puerto -U postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists apd_pruebas;" -c "create database apd_pruebas;"
if ($LASTEXITCODE -ne 0) { exit 1 }

$scripts = @('sql\local\00_simulacion_supabase.sql', 'sql\01_base.sql', 'sql\02_tablas.sql', 'sql\03_catalogos.sql',
             'sql\04_funciones_seguridad.sql', 'sql\05_motor.sql', 'sql\06_rpc.sql', 'sql\07_triggers.sql',
             'sql\08_rls.sql', 'sql\09_storage.sql', 'sql\10_vistas.sql')
if (-not $SinDemo) { $scripts += 'sql\90_datos_demo.sql'; $scripts += 'sql\98_pruebas_funcionales.sql' }
$scripts += 'sql\99_pruebas_seguridad.sql'

foreach ($s in $scripts) {
  Write-Host "== $s"
  & $Psql -h localhost -p $Puerto -U postgres -d apd_pruebas -v ON_ERROR_STOP=1 -q -X -f (Join-Path $raiz $s)
  if ($LASTEXITCODE -ne 0) { Write-Host "ERROR en $s" -ForegroundColor Red; exit 1 }
}
Write-Host 'Todos los scripts se ejecutaron sin errores.' -ForegroundColor Green
