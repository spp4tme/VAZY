# Installe vazy-guestinfo dans un modèle Windows : copie le script dans
# C:\ProgramData\vazy et crée la tâche planifiée « vazy-guestinfo », lancée au
# démarrage sous le compte SYSTEM. À lancer dans la VM modèle, en
# administrateur, AVANT de l'éteindre et de prendre l'instantané :
#     powershell -ExecutionPolicy Bypass -File installer.ps1
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$dossier = 'C:\ProgramData\vazy'
$script  = Join-Path $dossier 'vazy-guestinfo.ps1'
$source  = Join-Path $PSScriptRoot 'vazy-guestinfo.ps1'
if (-not (Test-Path $source)) { throw "vazy-guestinfo.ps1 doit être à côté de ce script ($PSScriptRoot)." }
if (-not (Test-Path (Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'))) {
    throw "Les VMware Tools manquent : installez-les d'abord (menu VM > Install VMware Tools)."
}
New-Item -ItemType Directory -Path $dossier -Force | Out-Null
Copy-Item -Path $source -Destination $script -Force

$action      = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"')
$declencheur = New-ScheduledTaskTrigger -AtStartup
$principal   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$reglages    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'vazy-guestinfo' -Action $action -Trigger $declencheur -Principal $principal -Settings $reglages -Force | Out-Null

# Première exécution dans le modèle : enregistre l'identité du modèle (ses
# clés SSH éventuelles sont régénérées une fois) ; aucune variable déposée,
# donc pas de renommage ni de redémarrage.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script

Write-Host 'vazy-guestinfo installé : tâche planifiée « vazy-guestinfo » au démarrage (compte SYSTEM).' -ForegroundColor Green
Write-Host 'Suite : éteignez la VM, prenez l''instantané, puis sur l''hôte : vazy template mark <alias> --guestinfo'
