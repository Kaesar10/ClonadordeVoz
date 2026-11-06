' Abre el Clonador de voz local sin mostrar ninguna ventana de consola.
Option Explicit

Dim sh, fso, carpeta, ps1, comando

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(carpeta, "lanzador.ps1")

comando = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run comando, 0, False
