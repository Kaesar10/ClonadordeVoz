<#
    Crea (o quita) los accesos directos de la aplicacion:
      - Escritorio:            "Clonador de voz"
      - Menu Inicio:           carpeta "Clonador de voz" con Abrir, Detener y Ver registro

    Uso:   powershell -ExecutionPolicy Bypass -File instalar.ps1
           powershell -ExecutionPolicy Bypass -File instalar.ps1 -Quitar
#>
param(
    [switch]$Quitar
)

$ErrorActionPreference = 'Stop'

$Script     = $PSScriptRoot
$Icono      = Join-Path $Script 'icono.ico'
$Exe        = Join-Path $Script 'Clonador de voz.exe'
$VbsLanzar  = Join-Path $Script 'Lanzar clonador de voz.vbs'
$VbsDetener = Join-Path $Script 'Detener clonador de voz.vbs'
$VbsLog     = Join-Path $Script 'Ver registro.vbs'
$WScriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'

$Escritorio = [Environment]::GetFolderPath('Desktop')
$Programas  = [Environment]::GetFolderPath('Programs')
$Grupo      = Join-Path $Programas 'Clonador de voz'
$AccesoEscritorio = Join-Path $Escritorio 'Clonador de voz.lnk'
$InicioWindows = Join-Path ([Environment]::GetFolderPath('Startup')) 'Clonador de voz.lnk'

function Nuevo-Acceso([string]$ruta, [string]$destino, [string]$argumentos, [string]$icono, [string]$descripcion, [int]$estiloVentana) {
    $shell = New-Object -ComObject WScript.Shell
    $acceso = $shell.CreateShortcut($ruta)
    $acceso.TargetPath = $destino
    # Se asigna siempre: si el .lnk ya existia hay que borrar los argumentos viejos.
    $acceso.Arguments = $argumentos
    $acceso.WorkingDirectory = $Script
    if ($icono) { $acceso.IconLocation = $icono + ',0' } else { $acceso.IconLocation = ',0' }
    $acceso.Description = $descripcion
    $acceso.WindowStyle = $estiloVentana
    $acceso.Save()
    Write-Host ('  [OK] ' + $ruta)
}

# Con la app nativa el acceso apunta directamente al .exe (icono e identidad
# propios, y el anclaje a la barra de tareas conserva el icono). Si no existe
# el .exe, se usa el respaldo que abre Edge en modo aplicacion.
$destinoAbrir = $Exe
$argsAbrir = ''
$estiloAbrir = 1
$iconoAbrir = $Exe
if (-not (Test-Path -LiteralPath $Exe)) {
    $destinoAbrir = $WScriptExe
    $argsAbrir = '"' + $VbsLanzar + '"'
    $estiloAbrir = 7
    $iconoAbrir = $Icono
}

# ---------------------------------------------------------------------------
if ($Quitar) {
    Write-Host ''
    Write-Host ' Quitando accesos directos del Clonador de voz...'
    foreach ($ruta in @($AccesoEscritorio, $InicioWindows)) {
        if (Test-Path -LiteralPath $ruta) {
            Remove-Item -LiteralPath $ruta -Force
            Write-Host ('  [OK] eliminado: ' + $ruta)
        }
    }
    if (Test-Path -LiteralPath $Grupo) {
        Remove-Item -LiteralPath $Grupo -Recurse -Force
        Write-Host ('  [OK] eliminado: ' + $Grupo)
    }
    Write-Host ''
    Write-Host ' Listo. La aplicacion sigue en su carpeta y se puede volver a instalar.'
    Write-Host ''
    exit 0
}

foreach ($necesario in @($VbsDetener, $VbsLog)) {
    if (-not (Test-Path -LiteralPath $necesario)) {
        throw ('Falta el archivo: ' + $necesario)
    }
}

Write-Host ''
Write-Host ' Instalando accesos directos del Clonador de voz...'

Nuevo-Acceso $AccesoEscritorio $destinoAbrir $argsAbrir $iconoAbrir 'Clonador de voz local (Qwen3-TTS)' $estiloAbrir

if (-not (Test-Path -LiteralPath $Grupo)) {
    New-Item -ItemType Directory -Path $Grupo -Force | Out-Null
}
Nuevo-Acceso (Join-Path $Grupo 'Clonador de voz.lnk') $destinoAbrir $argsAbrir $iconoAbrir 'Abrir el Clonador de voz' $estiloAbrir
Nuevo-Acceso (Join-Path $Grupo 'Detener clonador de voz.lnk') $WScriptExe ('"' + $VbsDetener + '"') $Icono 'Detener el Clonador de voz' 7
Nuevo-Acceso (Join-Path $Grupo 'Ver registro.lnk') 'notepad.exe' ('"' + (Join-Path $env:LOCALAPPDATA 'ClonadorVoz\logs\lanzador.log') + '"') $null 'Ver el registro de la aplicacion' 1

Write-Host ''
Write-Host ' Listo. Ya puedes abrir el clonador con el icono "Clonador de voz".'
Write-Host ''
