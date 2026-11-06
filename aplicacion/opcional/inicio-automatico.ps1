<#
    Activa o desactiva que el Clonador de voz se abra solo al iniciar Windows.

    Es opcional: por defecto NO se abre solo. Este script alterna el estado
    cada vez que se ejecuta (lo pone o lo quita).
#>
$ErrorActionPreference = 'Stop'

$Script      = Split-Path -Parent $PSScriptRoot
$VbsLanzar   = Join-Path $Script 'Lanzar clonador de voz.vbs'
$WScriptExe  = Join-Path $env:SystemRoot 'System32\wscript.exe'
$Icono       = Join-Path $Script 'icono.ico'
$Inicio      = [Environment]::GetFolderPath('Startup')
$Acceso      = Join-Path $Inicio 'Clonador de voz.lnk'

Write-Host ''
Write-Host ' Inicio automatico del Clonador de voz'
Write-Host ' --------------------------------------'

if (Test-Path -LiteralPath $Acceso) {
    Remove-Item -LiteralPath $Acceso -Force
    Write-Host ''
    Write-Host ' [OK] DESACTIVADO: el clonador ya no se abrira solo al encender el PC.'
    Write-Host '      Seguiras abriendolo con el icono "Clonador de voz".'
} else {
    $shell = New-Object -ComObject WScript.Shell
    $atajo = $shell.CreateShortcut($Acceso)
    $atajo.TargetPath = $WScriptExe
    $atajo.Arguments = '"' + $VbsLanzar + '"'
    $atajo.WorkingDirectory = $Script
    $atajo.IconLocation = $Icono + ',0'
    $atajo.Description = 'Abrir el Clonador de voz al iniciar Windows'
    $atajo.WindowStyle = 7
    $atajo.Save()
    Write-Host ''
    Write-Host ' [OK] ACTIVADO: el clonador se abrira solo al iniciar sesion en Windows.'
    Write-Host '      Para desactivarlo, vuelve a ejecutar este mismo archivo.'
}

Write-Host ''
