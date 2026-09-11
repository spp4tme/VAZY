# ============================================================================
#  vazy - généralisation d'un modèle Windows par sysprep (FACULTATIF)
# ============================================================================
#  Pourquoi : deux clones d'un même modèle Windows ont le même SID de machine.
#  Hors domaine, sans importance. Dans un domaine Active Directory, Microsoft
#  ne prend pas en charge des machines de même SID. sysprep donne à chaque
#  clone son propre SID au premier démarrage.
#
#  Quand : UNE fois, DANS le modèle, en administrateur, tout à la fin de sa
#  préparation — juste avant la prise de l'instantané d'ancrage.
#
#      powershell -ExecutionPolicy Bypass -File sysprep.ps1
#
#  Ce que fait ce script :
#    1. vérifie les conditions classiques d'échec de sysprep (droits, domaine,
#       BitLocker) et l'installation du script guestinfo ;
#    2. écrit un fichier de réponses : nom d'ordinateur aléatoire (le script
#       guestinfo le remplacera par le nom demandé à vazy), écrans d'accueil
#       sautés, compteur de réarmement de l'activation préservé ;
#    3. lance sysprep /generalize /oobe /shutdown : la machine s'éteint.
#
#  Ensuite : NE PAS redémarrer le modèle. Prendre l'instantané tout de suite,
#  VM éteinte, puis dans vazy : vazy template mark <alias> --sysprep
#
#  Écrit d'après la documentation de Microsoft, jamais exécuté sur la machine
#  de développement de vazy. Voir README, section 4.8, pour les limites.
# ============================================================================

param([switch]$Oui)

$ErrorActionPreference = 'Stop'

# Fichier de réponses. Isolé dans une fonction pour être vérifiable à part :
# les tests de vazy chargent ce script par point-source et contrôlent le XML
# produit, sans jamais lancer sysprep.
function New-UnattendVazy {
    param(
        [string]$Langue = 'fr-FR',
        [string]$Clavier = '040c:0000040c',
        [string]$Architecture = 'amd64'
    )
    $composant = 'processorArchitecture="' + $Architecture + '" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="generalize">
    <!-- Ne consomme pas le compteur de réarmement de l'activation : sans cela,
         un modèle ne se généralise qu'un nombre limité de fois. -->
    <component name="Microsoft-Windows-Security-SPP" $composant>
      <SkipRearm>1</SkipRearm>
    </component>
  </settings>
  <settings pass="specialize">
    <!-- « * » : nom aléatoire au premier démarrage. Le script vazy-guestinfo
         le remplace ensuite par le nom demandé à vazy. -->
    <component name="Microsoft-Windows-Shell-Setup" $composant>
      <ComputerName>*</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $composant>
      <InputLocale>$Clavier</InputLocale>
      <SystemLocale>$Langue</SystemLocale>
      <UILanguage>$Langue</UILanguage>
      <UserLocale>$Langue</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $composant>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
}

function Test-Administrateur {
    $identite = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identite).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Refus {
    param([string]$Message, [string]$Conseil)
    Write-Host ''
    Write-Host ('Refus : ' + $Message) -ForegroundColor Red
    if ($Conseil) { Write-Host ('  -> ' + $Conseil) -ForegroundColor Yellow }
}

function Invoke-PreparationSysprep {
    param([switch]$Oui)

    Write-Host 'vazy : généralisation de ce modèle Windows par sysprep' -ForegroundColor White
    Write-Host ''

    if (-not (Test-Administrateur)) {
        Write-Refus 'ce script doit être lancé en administrateur.' 'Ouvrez PowerShell avec « Exécuter en tant qu''administrateur », puis relancez-le.'
        return 1
    }

    # Une machine membre d'un domaine ne se généralise pas proprement.
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        Write-Refus "cette machine est membre du domaine « $($cs.Domain) »." 'Un modèle ne doit pas être joint à un domaine : retirez-la du domaine, redémarrez, puis relancez ce script. Ce sont les CLONES qu''on joint au domaine.'
        return 1
    }

    # sysprep refuse un volume système chiffré par BitLocker.
    try {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($volume.ProtectionStatus -eq 'On') {
            Write-Refus "BitLocker protège $env:SystemDrive." "Désactivez-le d'abord (manage-bde -off $env:SystemDrive), attendez la fin du déchiffrement, puis relancez."
            return 1
        }
    } catch { }   # module BitLocker absent : rien à vérifier

    $avertissements = 0
    if (-not (Get-ScheduledTask -TaskName 'vazy-guestinfo' -ErrorAction SilentlyContinue)) {
        Write-Host 'Attention : le script vazy-guestinfo n''est pas installé.' -ForegroundColor Yellow
        Write-Host '  Les clones garderont le nom aléatoire donné par sysprep. Installez-le d''abord : installer.ps1, dans ce même dossier.' -ForegroundColor Yellow
        $avertissements++
    }

    Write-Host 'Ce qui va se passer :'
    Write-Host '  1. un fichier de réponses est écrit (nom aléatoire, écrans d''accueil sautés, activation préservée) ;'
    Write-Host '  2. sysprep généralise la machine : identifiants propres à CETTE installation retirés ;'
    Write-Host '  3. la machine s''éteint.'
    Write-Host ''
    Write-Host 'Ensuite, NE REDÉMARREZ PAS ce modèle : prenez son instantané tout de suite, VM éteinte,' -ForegroundColor Yellow
    Write-Host 'puis dans vazy : vazy template mark <alias> --sysprep' -ForegroundColor Yellow
    Write-Host ''

    if (-not $Oui) {
        $reponse = Read-Host 'Continuer ? (oui/non)'
        if (([string]$reponse).Trim().ToLower() -notin 'o', 'oui', 'y', 'yes') {
            Write-Host 'Abandon : rien n''a été modifié.' -ForegroundColor Gray
            return 0
        }
    }

    # Langue et clavier de l'installation actuelle, pour ne pas changer de
    # langue au premier démarrage des clones.
    $langue = 'fr-FR'
    try { $langue = (Get-Culture).Name } catch { }
    $clavier = '040c:0000040c'
    try {
        $liste = Get-WinUserLanguageList -ErrorAction Stop
        if ($liste.Count -gt 0 -and $liste[0].InputMethodTips.Count -gt 0) { $clavier = [string]$liste[0].InputMethodTips[0] }
    } catch { }
    $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

    $dossierSysprep = Join-Path $env:SystemRoot 'System32\Sysprep'
    $fichier = Join-Path $dossierSysprep 'vazy-unattend.xml'
    [System.IO.File]::WriteAllText($fichier, (New-UnattendVazy -Langue $langue -Clavier $clavier -Architecture $architecture), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Fichier de réponses : $fichier") -ForegroundColor Gray

    Write-Host 'Lancement de sysprep...' -ForegroundColor Cyan
    & (Join-Path $dossierSysprep 'sysprep.exe') /generalize /oobe /shutdown /quiet "/unattend:$fichier"

    Write-Host ''
    Write-Host 'Si la machine ne s''éteint pas d''ici une à deux minutes, sysprep a échoué.' -ForegroundColor Yellow
    Write-Host ('  Le détail est dans ' + (Join-Path $dossierSysprep 'Panther\setuperr.log') + '.') -ForegroundColor Yellow
    Write-Host '  Cause la plus fréquente : une application du Microsoft Store installée pour un seul utilisateur.' -ForegroundColor Yellow
    Write-Host '  Le journal la nomme ; la retirer : Get-AppxPackage <nom> | Remove-AppxPackage' -ForegroundColor Yellow
    return 0
}

# Lancé directement : on prépare. Chargé par point-source (tests) : on ne
# fait que définir les fonctions.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-PreparationSysprep -Oui:$Oui)
}
