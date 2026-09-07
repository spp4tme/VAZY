@echo off
rem vazy - point d'entree unique, pour cmd.exe comme pour PowerShell.
rem Execute lib\interface.ps1 avec Windows PowerShell sans dependre de la
rem politique d'execution des scripts (ExecutionPolicy).
rem Les arguments sont transmis tels quels.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\interface.ps1" %*
exit /b %errorlevel%
