' Abre el registro de la aplicacion con el Bloc de notas.
Option Explicit

Dim sh, fso, registro, cuaderno

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

registro = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ClonadorVoz\logs\lanzador.log"

If Not fso.FileExists(registro) Then
    Dim ts
    Set ts = fso.CreateTextFile(registro, True)
    ts.WriteLine "Todavia no hay ningun registro: la aplicacion no se ha abierto aun."
    ts.Close
End If

cuaderno = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\notepad.exe"
sh.Run """" & cuaderno & """ """ & registro & """", 1, False
