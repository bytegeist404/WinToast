' Launches toast.ps1 with no visible window.
'
' powershell.exe's own -WindowStyle Hidden flag is unreliable on Windows 11 when
' Windows Terminal is set as the default terminal app -- it overrides the flag and
' shows the console window anyway. WScript.Shell.Run's window-style argument hides
' the window at process creation instead, which works regardless of that setting.

Dim shell, fso, scriptDir, scriptPath, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\toast.ps1"

cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.Run cmd, 0, False
