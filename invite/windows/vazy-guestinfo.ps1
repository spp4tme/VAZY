# vazy-guestinfo : applique au démarrage la configuration déposée par vazy dans
# la variable guestinfo.vazy_config (JSON encodé en base64), lue avec les
# VMware Tools. vazy n'entre jamais dans la VM : il dépose de l'extérieur,
# avant le démarrage, et ce script lit.
#
# Lancé par la tâche planifiée « vazy-guestinfo » au démarrage, compte SYSTEM
# (voir installer.ps1). Clé appliquée : hostname. Les clés d'adressage
# statique (ip, masque, passerelle, dns) et cle_ssh sont appliquées par le
# script Linux ; sous Windows elles sont ignorées pour l'instant, sans erreur.
# Idempotent : si le nom est déjà le bon, ne fait rien et ne redémarre pas. Un
# renommage effectif exige un redémarrage : il n'est fait qu'une fois, juste
# après. Après un sysprep (nom aléatoire au premier démarrage), c'est ce
# script qui donne à chaque clone le nom demandé par vazy.
$ErrorActionPreference = 'Stop'
$dossier = 'C:\ProgramData\vazy'
$journal = Join-Path $dossier 'vazy-guestinfo.log'
function Ecrire-Journal([string]$Message) {
    try { Add-Content -Path $journal -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) } catch { }
}
try { New-Item -ItemType Directory -Path $dossier -Force | Out-Null } catch { }

# --- 1. Identité de la machine : clés d'identité du serveur OpenSSH ------------
# L'UUID de la machine change à chaque clone. Si les clés du serveur SSH ont
# été générées sur une autre machine (le modèle), on les supprime : sshd les
# régénère au démarrage suivant du service.
$uuid = ''
try { $uuid = [string](Get-CimInstance Win32_ComputerSystemProduct).UUID } catch { }
$fichierUuid = Join-Path $dossier 'identite.uuid'
if ($uuid) {
    $connu = if (Test-Path $fichierUuid) { (Get-Content $fichierUuid -Raw).Trim() } else { '' }
    if ($connu -ne $uuid) {
        $cles = @(Get-ChildItem 'C:\ProgramData\ssh\ssh_host_*' -ErrorAction SilentlyContinue)
        if ($cles.Count -gt 0) {
            $cles | Remove-Item -Force -ErrorAction SilentlyContinue
            $keygen = 'C:\Windows\System32\OpenSSH\ssh-keygen.exe'
            if (Test-Path $keygen) { try { & $keygen -A 2>$null | Out-Null } catch { } }
            try { Restart-Service sshd -ErrorAction SilentlyContinue } catch { }
            Ecrire-Journal 'clés du serveur SSH régénérées (nouvelle machine)'
        }
        Set-Content -Path $fichierUuid -Value $uuid
    }
}

# --- 2. Configuration déposée par vazy -----------------------------------------
$vmtoolsd = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
if (-not (Test-Path $vmtoolsd)) { Ecrire-Journal 'vmtoolsd.exe introuvable : VMware Tools non installés'; exit 0 }
$brut = ''
try { $brut = ((& $vmtoolsd --cmd 'info-get guestinfo.vazy_config' 2>$null) | Out-String).Trim() } catch { $brut = '' }
if (-not $brut -or $brut -like 'No value found*') { exit 0 }
$config = $null
try {
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($brut))
    $config = ConvertFrom-Json -InputObject $json
} catch { Ecrire-Journal "charge utile illisible : $brut"; exit 0 }

$nom = if ($config.PSObject.Properties['hostname']) { ([string]$config.hostname).Trim() } else { '' }
if ($nom -and $nom -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' -and ($env:COMPUTERNAME -ine $nom)) {
    Rename-Computer -NewName $nom -Force
    Ecrire-Journal "renommée « $env:COMPUTERNAME » -> « $nom », redémarrage"
    Restart-Computer -Force
} elseif ($nom -and $env:COMPUTERNAME -ine $nom) {
    Ecrire-Journal "nom d'hôte refusé : « $nom » (15 caractères max, lettres, chiffres, tirets)"
}
exit 0
