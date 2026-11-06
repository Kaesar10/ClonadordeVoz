<#
    Lanzador del Clonador de voz local (Qwen3-TTS)

    Hace todo esto, sin mostrar ninguna ventana de consola:
      1. Comprueba si el servidor ya esta en marcha.
      2. Si no lo esta, lo arranca en segundo plano con pythonw.exe.
      3. Espera a que responda.
      4. Abre la interfaz en su propia ventana, como una aplicacion.

    Uso normal: doble clic en el acceso directo (lanza Lanzar clonador de voz.vbs).
    Para probar otro puerto:  powershell -File lanzador.ps1 -Puerto 8095
#>
param(
    [int]$Puerto = 0,
    [switch]$SoloServidor
)

$ErrorActionPreference = 'Stop'

$Raiz           = Split-Path -Parent $PSScriptRoot
$AppPy          = Join-Path $Raiz 'app.py'
$Datos          = Join-Path $env:LOCALAPPDATA 'ClonadorVoz'
$Logs           = Join-Path $Datos 'logs'
$Perfil         = Join-Path $Datos 'navegador'
$Estado         = Join-Path $Datos 'estado.json'
$Log            = Join-Path $Logs 'lanzador.log'
$PuertoPreferido = 8080

foreach ($d in @($Datos, $Logs, $Perfil)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
function Escribir-Log([string]$texto) {
    $linea = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $texto
    try { Add-Content -LiteralPath $Log -Value $linea -Encoding UTF8 } catch { }
}

function Mostrar-Aviso([string]$texto) {
    Escribir-Log ('AVISO: ' + $texto)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show(
            $texto,
            'Clonador de voz local',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    } catch { }
}

# El servidor busca ffmpeg con shutil.which(), es decir, en el PATH. Al abrir la
# app desde el escritorio, el PATH heredado puede ser antiguo y no incluir las
# carpetas donde Winget deja ffmpeg (por eso salia el aviso "Sin ffmpeg").
# Aqui se reconstruye el PATH con el del registro de Windows + rutas habituales.
function Path-Para-El-Servidor {
    $partes = @()
    if ($env:PATH) { $partes += $env:PATH.Split(';') }

    foreach ($clave in @(
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
            'HKCU:\Environment')) {
        try {
            $valor = (Get-ItemProperty -Path $clave -Name 'Path' -ErrorAction Stop).Path
            if ($valor) {
                $valor = [Environment]::ExpandEnvironmentVariables($valor)
                $partes += $valor.Split(';')
            }
        } catch { }
    }

    $extra = @()
    if ($env:LOCALAPPDATA) {
        $extra += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
        $extra += (Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin')
    }
    $extra += 'C:\ffmpeg\bin'
    $extra += 'C:\ProgramData\chocolatey\bin'

    # Paquetes de ffmpeg instalados con winget: <paquete>\bin
    if ($env:LOCALAPPDATA) {
        $paquetes = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $paquetes) {
            try {
                foreach ($d in (Get-ChildItem -LiteralPath $paquetes -Directory -ErrorAction SilentlyContinue)) {
                    if ($d.Name -match 'ffmpeg') {
                        $bin = Join-Path $d.FullName 'bin'
                        if (Test-Path -LiteralPath $bin) { $extra += $bin }
                    }
                }
            } catch { }
        }
    }
    $partes += $extra

    $vistos = @{}
    $limpias = @()
    foreach ($p in $partes) {
        if (-not $p) { continue }
        $p = $p.Trim().Trim('"')
        if (-not $p) { continue }
        if (-not $vistos.ContainsKey($p)) {
            $vistos[$p] = $true
            $limpias += $p
        }
    }
    return ($limpias -join ';')
}

# Llamadas a la API de Windows para traer al frente una ventana ya abierta.
$codigoWin32 = @'
using System;
using System.Runtime.InteropServices;
public class VentanaWin32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
try { Add-Type -TypeDefinition $codigoWin32 -ErrorAction Stop } catch { }

# ---------------------------------------------------------------------------
# Deteccion del servidor
# ---------------------------------------------------------------------------
# En algunos equipos (por ejemplo despues de las actualizaciones de Windows de
# octubre de 2026) los sockets a la escucha llegan con State vacio en lugar de
# 'Listen'. Si solo se filtra por -State Listen, el puerto del clonador no se ve
# nunca y el lanzador cree que el servidor no ha arrancado. Hay que aceptar
# tambien los sockets sin estado y con direccion remota 0.0.0.0:0.
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
        # Respaldo: netstat. Las filas a la escucha pueden venir sin la palabra
        # LISTENING, pero siempre tienen 0.0.0.0:0 como destino.
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

function Buscar-Servidor([int[]]$puertos) {
    $escuchando = @(Puertos-Escuchando $puertos)
    foreach ($p in $escuchando) {
        if (Es-Nuestro $p) { return $p }
    }

    # Si la tabla TCP no devolvio nada, se prueban directamente los primeros
    # puertos del rango (por si el sistema no informa de los sockets).
    if ($escuchando.Count -eq 0) {
        $candidatos = @($puertos | Select-Object -First 3)
        foreach ($p in $candidatos) {
            if (Es-Nuestro $p) { return $p }
        }
    }
    return 0
}

# Lee el puerto del registro del servidor: app.py imprime
# "Clonador de voz local -> http://127.0.0.1:PORT". Con PYTHONUNBUFFERED=1
# la linea aparece en cuanto uvicorn arranca, sin esperar a que termine.
function Puerto-Desde-Log([string]$ruta) {
    try {
        if (-not (Test-Path -LiteralPath $ruta)) { return 0 }
        $texto = ''
        $fs = [System.IO.File]::Open($ruta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $lector = New-Object System.IO.StreamReader($fs)
            $texto = $lector.ReadToEnd()
            $lector.Dispose()
        } finally {
            $fs.Dispose()
        }
        $m = [regex]::Match($texto, '127\.0\.0\.1:(\d+)')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch { }
    return 0
}

# ---------------------------------------------------------------------------
# Deteccion de Python y del navegador
# ---------------------------------------------------------------------------
function Buscar-Pythonw {
    $candidatos = @()

    $py = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($py -and $py.Source) {
        $candidatos += (Join-Path (Split-Path -Parent $py.Source) 'pythonw.exe')
    }
    $candidatos += 'C:\Python314\pythonw.exe'

    try {
        $listado = & py -0p 2>$null
        foreach ($linea in @($listado)) {
            if ($linea -match '([A-Za-z]:\\.*?python\.exe)\s*$') {
                $candidatos += ($Matches[1] -replace 'python\.exe$', 'pythonw.exe')
            }
        }
    } catch { }

    foreach ($c in $candidatos) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    # Ultimo recurso: python.exe normal (mostraria consola, pero mejor eso que nada)
    if ($py -and $py.Source) { return $py.Source }
    return $null
}

function Buscar-Navegador {
    $candidatos = @()
    if (${env:ProgramFiles(x86)}) {
        $candidatos += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        $candidatos += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    }
    if ($env:ProgramFiles) {
        $candidatos += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        $candidatos += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    }
    if ($env:LOCALAPPDATA) {
        $candidatos += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    }
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Ventana de la aplicacion
# ---------------------------------------------------------------------------
function Traer-Ventana-Al-Frente {
    $objetivos = @()

    foreach ($p in @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -like '*Clonador*') {
                $objetivos += $p
            }
        } catch { }
    }

    if ($objetivos.Count -eq 0) {
        try {
            $procesos = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue
            foreach ($c in @($procesos)) {
                if ($c.CommandLine -and $c.CommandLine.Contains($Perfil)) {
                    $p = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
                    if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $objetivos += $p }
                }
            }
        } catch { }
    }

    foreach ($p in $objetivos) {
        try {
            [void][VentanaWin32]::ShowWindow($p.MainWindowHandle, 9)   # SW_RESTORE
            [void][VentanaWin32]::SetForegroundWindow($p.MainWindowHandle)
            return [int]$p.Id
        } catch { }
    }
    return 0
}

function Abrir-Ventana([string]$url, [int]$puerto) {
    # Solo reutilizamos una ventana abierta si apunta a este mismo puerto.
    $mismoPuerto = $false
    if (Test-Path -LiteralPath $Estado) {
        try {
            $anterior = Get-Content -LiteralPath $Estado -Raw | ConvertFrom-Json
            if ($anterior -and ([int]$anterior.puerto -eq $puerto)) { $mismoPuerto = $true }
        } catch { }
    }

    if ($mismoPuerto) {
        $pidExistente = Traer-Ventana-Al-Frente
        if ($pidExistente -gt 0) {
            Escribir-Log 'La ventana ya estaba abierta: se ha traido al frente.'
            return $pidExistente
        }
    }

    $navegador = Buscar-Navegador
    if (-not $navegador) {
        Escribir-Log 'No se encontro Edge ni Chrome: se abre en el navegador por defecto.'
        Start-Process $url | Out-Null
        return 0
    }

    $ancho = 1400
    $alto = 940
    $x = 80
    $y = 40
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $ancho = [int][Math]::Min(1400, [Math]::Round($area.Width * 0.92))
        $alto = [int][Math]::Min(940, [Math]::Round($area.Height * 0.92))
        $x = $area.X + [int](($area.Width - $ancho) / 2)
        $y = $area.Y + [int](($area.Height - $alto) / 2)
        if ($y -lt $area.Y) { $y = $area.Y }
    } catch { }

    $argumentos = @(
        ('--app=' + $url),
        ('--user-data-dir="' + $Perfil + '"'),
        ('--window-size=' + $ancho + ',' + $alto),
        ('--window-position=' + $x + ',' + $y),
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--disable-background-mode',
        '--disable-features=msEdgeSidebarV2,msEdgeWorkspaces,msImplicitSignin,msEdgeSplitScreen'
    )

    Escribir-Log ('Abriendo ventana con ' + $navegador + ' (' + $ancho + 'x' + $alto + ')')
    $proceso = Start-Process -FilePath $navegador -ArgumentList $argumentos -WorkingDirectory $PSScriptRoot -PassThru

    # Edge puede lanzar la ventana en otro proceso: esperamos a que aparezca
    # para guardar el PID correcto (lo usa el boton Detener).
    $limite = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Milliseconds 400
        foreach ($p in @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue)) {
            try {
                if ($p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -like '*Clonador*') {
                    Escribir-Log ('Ventana abierta en el proceso ' + $p.Id + '.')
                    return [int]$p.Id
                }
            } catch { }
        }
    }

    if ($proceso) { return [int]$proceso.Id }
    return 0
}

# ---------------------------------------------------------------------------
# Flujo principal
# ---------------------------------------------------------------------------
try {
    Escribir-Log '=== Lanzador iniciado ==='

    if ($Puerto -gt 0) {
        $rango = @($Puerto)
        $rangoEspera = @()
        for ($i = $Puerto; $i -lt ($Puerto + 20); $i++) { $rangoEspera += $i }
    } else {
        $rango = @()
        $rangoEspera = @()
        for ($i = $PuertoPreferido; $i -lt ($PuertoPreferido + 20); $i++) {
            $rango += $i
            $rangoEspera += $i
        }
    }

    $activo = Buscar-Servidor $rango
    $procesoServidor = $null

    if ($activo -gt 0) {
        Escribir-Log ('El servidor ya estaba en marcha en el puerto ' + $activo + '.')
        try {
            $estadoServidor = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $activo + '/api/estado') -TimeoutSec 5
            if (-not $estadoServidor.ffmpeg) {
                Escribir-Log 'AVISO: el servidor en marcha no encuentra ffmpeg (la interfaz mostrara el aviso).'
            }
        } catch { }
    } else {
        if (-not (Test-Path -LiteralPath $AppPy)) {
            throw ('No se encuentra app.py en ' + $Raiz)
        }

        $pythonw = Buscar-Pythonw
        if (-not $pythonw) {
            throw 'No se encuentra Python en este equipo.'
        }

        $preferido = $Puerto
        if ($preferido -le 0) { $preferido = $PuertoPreferido }

        $env:PUERTO = [string]$preferido
        $env:PATH = Path-Para-El-Servidor
        # Sin buffer: la linea "-> http://127.0.0.1:PUERTO" aparece en el log en
        # cuanto el servidor esta listo (sirve para detectarlo sin sondear).
        $env:PYTHONUNBUFFERED = '1'
        $salida = Join-Path $Logs 'servidor.out.log'
        $errores = Join-Path $Logs 'servidor.err.log'
        # Se vacian para no leer puertos de un arranque anterior.
        try { Remove-Item -LiteralPath $salida, $errores -Force -ErrorAction SilentlyContinue } catch { }

        $hayFfmpeg = $false
        try { $hayFfmpeg = [bool](Get-Command 'ffmpeg' -ErrorAction SilentlyContinue) } catch { }
        Escribir-Log ('ffmpeg visible para el servidor: ' + $hayFfmpeg)

        Escribir-Log ('Arrancando el servidor con ' + $pythonw + ' en el puerto ' + $preferido + '...')
        $procesoServidor = Start-Process -FilePath $pythonw `
            -ArgumentList @('"' + $AppPy + '"') `
            -WorkingDirectory $Raiz `
            -WindowStyle Hidden `
            -RedirectStandardOutput $salida `
            -RedirectStandardError $errores `
            -PassThru

        if ($procesoServidor) {
            Escribir-Log ('Servidor arrancado con PID ' + $procesoServidor.Id + '.')
        }

        # Se espera hasta 3 minutos: en arranques en frio (antivirus, disco
        # ocupado...) el servidor puede tardar bastante mas que unos segundos.
        $inicioEspera = Get-Date
        $limite = (Get-Date).AddSeconds(180)
        $ultimoAviso = Get-Date
        while ((Get-Date) -lt $limite) {
            if ($procesoServidor -and $procesoServidor.HasExited) {
                throw ('El servidor se cerro al arrancar. Revisa el registro: ' + $errores)
            }

            # 1) Por el puerto que el propio servidor escribe en su log.
            $desdeLog = Puerto-Desde-Log $salida
            if ($desdeLog -gt 0 -and (Es-Nuestro $desdeLog)) {
                $activo = $desdeLog
                break
            }

            # 2) Por la tabla de puertos / prueba directa.
            $activo = Buscar-Servidor $rangoEspera
            if ($activo -gt 0) { break }

            if (((Get-Date) - $ultimoAviso).TotalSeconds -ge 15) {
                Escribir-Log ('Sigo esperando al servidor (llevo ' + [int]((Get-Date) - $inicioEspera).TotalSeconds + ' s)...')
                $ultimoAviso = Get-Date
            }
            Start-Sleep -Milliseconds 300
        }

        if ($activo -le 0) {
            throw ('El servidor no respondio en 3 minutos. Revisa el registro: ' + $errores)
        }
        $segundosArranque = [int]((Get-Date) - $inicioEspera).TotalSeconds
        Escribir-Log ('El servidor responde en el puerto ' + $activo + ' (arranque en ' + $segundosArranque + ' s).')
        try {
            $estadoServidor = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $activo + '/api/estado') -TimeoutSec 5
            if (-not $estadoServidor.ffmpeg) {
                Escribir-Log 'AVISO: el servidor arrancado no encuentra ffmpeg (la interfaz mostrara el aviso).'
            }
        } catch { }
    }

    # Modo que usa la ventana nativa (Clonador de voz.exe): solo deja el
    # servidor listo y publica el puerto (en archivo y en la salida estandar).
    if ($SoloServidor) {
        Escribir-Log ('Modo servidor: puerto ' + $activo + '.')
        try {
            Set-Content -LiteralPath (Join-Path $Datos 'puerto.txt') -Value ([string]$activo) -Encoding ASCII
        } catch { }
        Write-Output ('PUERTO=' + $activo)
        exit 0
    }

    $url = 'http://127.0.0.1:' + $activo
    $pidVentana = Abrir-Ventana $url $activo

    $pidServidor = 0
    try {
        # Puede haber varios procesos escuchando en el puerto: nos quedamos con
        # el de Python, que es el servidor del clonador (no Tailscale, etc.).
        # Sin -State Listen: en este equipo los sockets a la escucha llegan con
        # el estado vacio.
        foreach ($conexion in @(Get-NetTCPConnection -LocalPort $activo -ErrorAction Stop)) {
            if (-not (Es-Escucha $conexion)) { continue }
            $candidato = Get-Process -Id $conexion.OwningProcess -ErrorAction SilentlyContinue
            if ($candidato -and $candidato.ProcessName -match '^python') {
                $pidServidor = [int]$candidato.Id
                break
            }
        }
    } catch { }

    $info = [ordered]@{
        puerto       = $activo
        url          = $url
        pid_servidor = $pidServidor
        pid_ventana  = $pidVentana
        perfil       = $Perfil
        actualizado  = (Get-Date).ToString('s')
    }
    try {
        $info | ConvertTo-Json | Set-Content -LiteralPath $Estado -Encoding UTF8
    } catch { }

    Escribir-Log ('Listo. ' + $url)
    exit 0
} catch {
    $mensaje = $_.Exception.Message
    if (-not $mensaje) { $mensaje = 'Error desconocido.' }
    if ($SoloServidor) {
        Write-Output ('ERROR=' + $mensaje)
        exit 1
    }
    Mostrar-Aviso ("No se pudo abrir el Clonador de voz." + [Environment]::NewLine + [Environment]::NewLine + $mensaje + [Environment]::NewLine + [Environment]::NewLine + "Detalles en:" + [Environment]::NewLine + $Log)
    exit 1
}
