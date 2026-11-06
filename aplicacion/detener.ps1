<#
    Detiene el Clonador de voz local: cierra la ventana de la aplicacion y
    para el servidor que escucha en 127.0.0.1 (puertos 8080-8099).

    Uso normal: doble clic en "Detener clonador de voz.vbs".
#>
param(
    [switch]$Silencioso,
    [int]$Puerto = 0
)

$ErrorActionPreference = 'Continue'

$Datos  = Join-Path $env:LOCALAPPDATA 'ClonadorVoz'
$Logs   = Join-Path $Datos 'logs'
$Perfil = Join-Path $Datos 'navegador'
$Estado = Join-Path $Datos 'estado.json'
$Log    = Join-Path $Logs 'lanzador.log'

if (-not (Test-Path -LiteralPath $Logs)) {
    New-Item -ItemType Directory -Path $Logs -Force | Out-Null
}

function Escribir-Log([string]$texto) {
    $linea = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $texto
    try { Add-Content -LiteralPath $Log -Value $linea -Encoding UTF8 } catch { }
}

function Mostrar-Mensaje([string]$texto, [string]$icono) {
    if ($Silencioso) { Write-Host $texto; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $tipoIcono = [System.Windows.Forms.MessageBoxIcon]::Information
        if ($icono -eq 'Warning') { $tipoIcono = [System.Windows.Forms.MessageBoxIcon]::Warning }
        [void][System.Windows.Forms.MessageBox]::Show($texto, 'Clonador de voz local', [System.Windows.Forms.MessageBoxButtons]::OK, $tipoIcono)
    } catch {
        Write-Host $texto
    }
}

# Igual que en el lanzador: tras algunas actualizaciones de Windows los sockets
# a la escucha llegan con el estado vacio en lugar de 'Listen'.
function Es-Escucha($c) {
    if ($c.State -eq 'Listen') { return $true }
    if ([string]::IsNullOrEmpty([string]$c.State) -and [int]$c.RemotePort -eq 0) { return $true }
    return $false
}

function Puertos-Escuchando([int[]]$rango) {
    $puertos = @()
    try {
        foreach ($c in @(Get-NetTCPConnection -ErrorAction Stop)) {
            $p = [int]$c.LocalPort
            if (($rango -contains $p) -and (Es-Escucha $c)) { $puertos += $p }
        }
    } catch { }

    if (@($puertos).Count -eq 0) {
        try {
            foreach ($linea in @(& netstat -ano -p tcp 2>$null)) {
                if ($linea -match '^\s*TCP\s+127\.0\.0\.1:(\d+)\s+0\.0\.0\.0:0\s*(LISTENING)?\s*$') {
                    $p = [int]$Matches[1]
                    if ($rango -contains $p) { $puertos += $p }
                }
            }
        } catch { }
    }

    return @($puertos | Sort-Object -Unique)
}

function Es-Nuestro([int]$p) {
    try {
        $r = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/api/estado' -f $p) -TimeoutSec 5 -ErrorAction Stop
        $nombres = @($r.PSObject.Properties.Name)
        return (($nombres -contains 'binario_ok') -and ($nombres -contains 'idiomas') -and ($nombres -contains 'dispositivos'))
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# 1. Cerrar la ventana de la aplicacion
# ---------------------------------------------------------------------------
$ventanasCerradas = 0
$pids = @()

try {
    if (Test-Path -LiteralPath $Estado) {
        $info = Get-Content -LiteralPath $Estado -Raw | ConvertFrom-Json
        if ($info -and $info.pid_ventana) { $pids += [int]$info.pid_ventana }
    }
} catch { }

try {
    $procesos = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue
    foreach ($c in @($procesos)) {
        if ($c.CommandLine -and $c.CommandLine.Contains($Perfil)) { $pids += [int]$c.ProcessId }
    }
} catch { }

# Ventana nativa de la app (Clonador de voz.exe)
$pidsApp = @()
try {
    foreach ($p in @(Get-Process -Name 'Clonador de voz' -ErrorAction SilentlyContinue)) {
        $pidsApp += [int]$p.Id
    }
} catch { }

foreach ($id in ($pids | Select-Object -Unique)) {
    try {
        $p = Get-Process -Id $id -ErrorAction Stop
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        $ventanasCerradas++
    } catch { }
}

# Cerrar la ventana nativa de forma ordenada, para que WebView2 se apague bien
# y no deje el perfil bloqueado para la proxima vez.
if ($pidsApp.Count -gt 0) {
    $codigoCerrar = @'
using System;
using System.Runtime.InteropServices;
public class CerrarVentana {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
'@
    try { Add-Type -TypeDefinition $codigoCerrar -ErrorAction Stop } catch { }

    foreach ($id in ($pidsApp | Select-Object -Unique)) {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
            try {
                [void][CerrarVentana]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                $ventanasCerradas++
            } catch { }
        }
    }

    $limiteCierre = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $limiteCierre) {
        $vivos = @($pidsApp | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($vivos.Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }

    foreach ($id in ($pidsApp | Select-Object -Unique)) {
        if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
    }
}

# Procesos de WebView2 que hayan quedado colgados del perfil de la app.
try {
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue)) {
        if ($c.CommandLine -and $c.CommandLine -like '*ClonadorVoz*webview2*') {
            Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
} catch { }

if ($ventanasCerradas -gt 0) {
    Escribir-Log ('Ventana de la aplicacion cerrada (' + $ventanasCerradas + ' proceso(s)).')
    Start-Sleep -Milliseconds 400
}

# ---------------------------------------------------------------------------
# 2. Parar el servidor
# ---------------------------------------------------------------------------
# Ojo: no usar una variable llamada $puerto, porque en PowerShell seria la
# misma que el parametro $Puerto (no distinguen mayusculas) y lo pisaria.
$puertoActivo = 0
if ($Puerto -gt 0) {
    if (Es-Nuestro $Puerto) { $puertoActivo = $Puerto }
} else {
    $candidatos = @()
    for ($p = 8080; $p -lt 8100; $p++) { $candidatos += $p }
    foreach ($p in (Puertos-Escuchando $candidatos)) {
        if (Es-Nuestro $p) { $puertoActivo = $p; break }
    }
}

if ($puertoActivo -eq 0) {
    Escribir-Log 'Detener: el servidor no estaba en marcha.'
    Mostrar-Mensaje "El Clonador de voz no estaba en marcha." 'Information'
    exit 0
}

# Cuidado: puede haber mas de un proceso escuchando en el mismo puerto (por
# ejemplo Tailscale usa el 8080). Nos quedamos solo con el que es Python,
# que es el servidor del clonador.
$pidServidor = 0
$otros = @()
try {
    # Sin -State Listen: en este equipo los sockets a la escucha llegan con el
    # estado vacio desde las actualizaciones de octubre de 2026.
    foreach ($conexion in @(Get-NetTCPConnection -LocalPort $puertoActivo -ErrorAction Stop)) {
        if (-not (Es-Escucha $conexion)) { continue }
        $candidato = Get-Process -Id $conexion.OwningProcess -ErrorAction SilentlyContinue
        if ($candidato -and $candidato.ProcessName -match '^python') {
            $pidServidor = [int]$candidato.Id
            break
        }
        $otros += [int]$conexion.OwningProcess
    }
} catch { }

if ($pidServidor -le 0) {
    Escribir-Log ('Detener: no hay proceso python escuchando en el puerto ' + $puertoActivo + '.')
    Mostrar-Mensaje ("No se pudo identificar el proceso del servidor en el puerto $puertoActivo." + [Environment]::NewLine + [Environment]::NewLine + "El puerto lo esta usando otro programa (por ejemplo Tailscale).") 'Warning'
    exit 1
}

# Procesos hijos (por ejemplo llama-tts a mitad de una sintesis)
try {
    $hijos = Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $pidServidor) -ErrorAction SilentlyContinue
    foreach ($h in @($hijos)) {
        Stop-Process -Id ([int]$h.ProcessId) -Force -ErrorAction SilentlyContinue
    }
} catch { }

try {
    Stop-Process -Id $pidServidor -Force -ErrorAction Stop
    Escribir-Log ('Detener: servidor parado (PID ' + $pidServidor + ', puerto ' + $puertoActivo + ').')
    try { Remove-Item -LiteralPath $Estado -Force -ErrorAction SilentlyContinue } catch { }
    Mostrar-Mensaje "Clonador de voz detenido correctamente." 'Information'
    exit 0
} catch {
    Escribir-Log ('Detener: no se pudo parar el servidor. ' + $_.Exception.Message)
    Mostrar-Mensaje ("No se pudo detener el servidor." + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message) 'Warning'
    exit 1
}
