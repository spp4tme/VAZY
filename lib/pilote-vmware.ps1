# ============================================================================
#  vazy - couche 3 : pilote VMware Workstation
# ============================================================================
#  Seule couche de l'outil qui connaît vmrun.exe et le format des fichiers
#  .vmx. Aucune ligne spécifique à VMware ne doit exister ailleurs.
#
#  CONTRAT DU PILOTE
#  -----------------
#  Un futur pilote (pilote-virtualbox.ps1, pilote-hyperv.ps1...) doit définir
#  exactement ces fonctions, avec les mêmes paramètres et les mêmes retours.
#  Une "machine" est désignée par le chemin de son fichier descripteur (ici
#  le .vmx) ; les autres couches le manipulent comme une chaîne opaque.
#
#  Les six opérations :
#    New-MachineDepuisModele  -Modele -Instantane -Dossier -Nom
#                              -> chemin de la machine créée
#    Set-MachineParametres    -Machine [-RamMo] [-Cpu] [-Brut]
#                              (Brut = paires Cle/Valeur écrites telles quelles)
#    Set-MachineReseau        -Machine -Modes
#                              (un mode par carte : nat | bridged | hostonly)
#    Start-Machine            -Machine [-SansInterface]
#    Stop-Machine             -Machine [-Brutal]
#    Remove-Machine           -Machine
#                              -> $null, ou @{ Type = 'info'|'attention'; Message }
#                                 si des restes ont été nettoyés ou subsistent
#
#  Trois fonctions de lecture seule dont la logique a besoin :
#    Initialize-Pilote        [-CheminForce]
#                              -> description : Nom, Executable, ExtensionMachine,
#                                 SensibleHyperV (dégradé si Hyper-V est actif ?),
#                                 ConseilInstantane ({0} = exécutable, {1} = machine)
#    Get-MachineEnCours        -> chemins des machines en cours d'exécution
#    Get-MachineInstantanes   -Machine
#                              -> noms des instantanés de la machine
#
#  Instantanés (phase 1, remise à zéro) :
#    New-MachineInstantane     -Machine -Nom     prendre un instantané
#    Restore-MachineInstantane -Machine -Nom     revenir à un instantané (machine arrêtée)
#    Remove-MachineInstantane  -Machine -Nom     supprimer un instantané
#    (lister : Get-MachineInstantanes ci-dessus)
#
#  Marque « modèle » : posée par la logique sur chaque modèle enregistré, elle
#  fait refuser au pilote lui-même tout démarrage, suppression ou opération
#  d'instantané sur cette machine, quoi que dise le catalogue :
#    Protect-MachineModele     -Machine          poser la marque
#    Unprotect-MachineModele   -Machine          retirer la marque
#    Test-MachineModele        -Machine          -> $true si marquée
#
#  Invité (personnalisation) :
#    Set-MachineVariableInvite -Machine -Nom [-Valeur]
#                                                dépose une variable guestinfo lisible dans
#                                                l'invité (machine éteinte ; valeur vide = retire)
#    Get-MachineSystemeInvite  -Machine          -> 'windows' | 'linux' | 'inconnu'
#    Wait-MachineOutils        -Machine [-DelaiMaxSec]
#                                                -> $true dès que les outils invité répondent,
#                                                   $false passé le délai
#    Invoke-MachineScript      -Machine -Identifiants -Systeme -Script
#                                                exécute un script dans l'invité (repli par
#                                                identifiants) ; renvoie son code de sortie ;
#                                                le mot de passe n'apparaît dans aucun message
#
#  Affichage distant (écran de la VM vu depuis un autre appareil) :
#    Set-MachineAffichageDistant -Machine -Actif [-Port] [-MotDePasse]
#                                                active ou retire le serveur d'affichage
#                                                distant (machine éteinte : relu au démarrage)
#
#  Protection du modèle et autonomie :
#    Get-MachineEmpreinte      -Machine          -> disques de base (nom -> taille, date)
#    Test-MachineEmpreinte     -Machine -Empreinte
#                                                -> @{ Erreurs ; Attentions } (le modèle est-il intact ?)
#    Convert-MachineEnComplete -Machine -Nom     clone lié -> machine complète, même chemin
#    Get-MachineDisqueGo       -Machine          -> capacité déclarée des disques, en Go
#
#  Observation (journal et --dry-run) :
#    Set-PiloteObservateur     -Observateur -Simulation
#       L'observateur (scriptblock Type, Message) reçoit 'journal' pour chaque
#       commande exécutée et 'simulation' pour chaque commande NON exécutée en
#       mode simulation. Toute commande vmrun est construite en un seul point
#       (Invoke-Vmrun), toute écriture de .vmx passe par Write-FichierVmx.
#
#  Toute erreur est levée sous forme d'exception dont Data['Conseil'] indique
#  quoi faire pour corriger (voir New-ErreurPilote).
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VmrunExe    = $null                          # chemin de vmrun.exe, renseigné par Initialize-Pilote
$script:Simulation  = $false                         # --dry-run : rien n'est modifié, les commandes sont affichées
$script:Observateur = { param($Type, $Message) }     # journal et simulations, fourni par la logique

function Set-PiloteObservateur {
    param([scriptblock]$Observateur, [bool]$Simulation = $false)
    if ($Observateur) { $script:Observateur = $Observateur }
    $script:Simulation = $Simulation
}

# ----------------------------------------------------------------------------
#  Outils internes : erreurs, localisation et exécution de vmrun
# ----------------------------------------------------------------------------

# Construit une exception "propre" : un message qui dit ce qui a raté, et un
# conseil qui dit quoi faire.
function New-ErreurPilote {
    param([string]$Message, [string]$Conseil)
    $e = New-Object System.Exception($Message)
    $e.Data['Conseil'] = $Conseil
    return $e
}

# Cherche vmrun.exe dans l'ordre : chemin forcé par la configuration, dossiers
# d'installation habituels, registre Windows, puis PATH.
function Find-Vmrun {
    param([string]$CheminForce)
    $candidats = New-Object System.Collections.Generic.List[string]
    if ($CheminForce) {
        $candidats.Add([Environment]::ExpandEnvironmentVariables($CheminForce))
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { $candidats.Add((Join-Path $base 'VMware\VMware Workstation\vmrun.exe')) }
    }
    foreach ($cle in @('HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation',
                       'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation')) {
        try {
            $installation = (Get-ItemProperty -Path $cle -ErrorAction Stop).InstallPath
            if ($installation) { $candidats.Add((Join-Path $installation 'vmrun.exe')) }
        } catch { }
    }
    $dansPath = Get-Command 'vmrun.exe' -ErrorAction SilentlyContinue
    if ($dansPath) { $candidats.Add($dansPath.Source) }

    foreach ($c in $candidats) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

# Transforme une liste d'arguments en ligne de commande Windows correctement
# protégée (espaces et guillemets), selon les règles de CommandLineToArgv.
function ConvertTo-LigneCommande {
    param([string[]]$Elements)
    $morceaux = foreach ($e in $Elements) {
        if ($e -eq '' -or $e -match '[\s"]') {
            $t = $e -replace '(\\*)"', '$1$1\"'   # antislashs devant un guillemet : doublés, guillemet échappé
            $t = $t -replace '(\\+)$', '$1$1'     # antislashs finaux : doublés
            '"' + $t + '"'
        } else {
            $e
        }
    }
    return ($morceaux -join ' ')
}

# Exécute vmrun (toujours avec -T ws) et renvoie Code, Lignes et Texte.
# Ne lève pas d'exception sur un code retour non nul : chaque opération
# interprète le résultat pour produire un message utile.
# -Identifiants (PSCredential) : identifiants de l'invité pour les commandes
# qui agissent dans la VM. vmrun ne les accepte que sur sa ligne de commande
# (-gu / -gp) : le mot de passe y est donc visible, pour les processus de ce
# compte Windows, pendant les quelques secondes de l'appel. C'est une limite
# de vmrun. vazy ne l'écrit jamais et le masque dans toute sortie.
function Invoke-Vmrun {
    param([string[]]$Arguments, [System.Management.Automation.PSCredential]$Identifiants = $null)
    $prefixe = @('-T', 'ws')
    $prefixeAffichable = @('-T', 'ws')
    $secret = $null
    if ($null -ne $Identifiants) {
        $secret = $Identifiants.GetNetworkCredential().Password
        $prefixe += @('-gu', $Identifiants.UserName, '-gp', $secret)
        $prefixeAffichable += @('-gu', $Identifiants.UserName, '-gp', '***')
    }
    # Ligne exacte, mot de passe masqué : c'est elle qui va au journal et à l'écran.
    $affichable = 'vmrun ' + (ConvertTo-LigneCommande ($prefixeAffichable + $Arguments))
    # En simulation (--dry-run), les commandes qui modifient quelque chose sont
    # affichées au lieu d'être exécutées ; les lectures s'exécutent toujours.
    $modifie = $Arguments[0] -in @('clone', 'start', 'stop', 'deleteVM', 'snapshot', 'revertToSnapshot', 'deleteSnapshot',
                                    'runProgramInGuest', 'runScriptInGuest', 'writeVariable', 'suspend', 'reset', 'pause', 'unpause')
    if ($script:Simulation -and $modifie) {
        & $script:Observateur 'simulation' $affichable
        return [pscustomobject]@{ Code = 0; Lignes = @(); Texte = ''; Simule = $true }
    }
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $infos = New-Object System.Diagnostics.ProcessStartInfo
    $infos.FileName = $script:VmrunExe
    $infos.Arguments = ConvertTo-LigneCommande ($prefixe + $Arguments)
    $infos.UseShellExecute = $false
    $infos.RedirectStandardOutput = $true
    $infos.RedirectStandardError = $true
    $infos.CreateNoWindow = $true
    try {
        $processus = [System.Diagnostics.Process]::Start($infos)
    } catch {
        throw (New-ErreurPilote "Impossible de lancer vmrun ($($script:VmrunExe)) : $($_.Exception.Message)" `
            "Vérifiez que ce fichier existe et que VMware Workstation est correctement installé.")
    }
    # Lecture asynchrone de stderr pour éviter tout blocage si les deux flux sont remplis.
    $lectureErreurs = $processus.StandardError.ReadToEndAsync()
    $sortie = $processus.StandardOutput.ReadToEnd()
    $processus.WaitForExit()
    $texte = (($sortie + "`n" + $lectureErreurs.Result) -replace "`r", '').Trim()
    if ($secret) { $texte = $texte.Replace($secret, '***') }   # jamais de mot de passe dans un message
    $lignes = @($texte -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    & $script:Observateur 'journal' ('{0}  -> code {1} en {2:0.0} s' -f $affichable, $processus.ExitCode, $chrono.Elapsed.TotalSeconds)
    return [pscustomobject]@{ Code = $processus.ExitCode; Lignes = $lignes; Texte = $texte; Simule = $false }
}

# Extrait le message d'erreur de vmrun ("Error: ...") d'un résultat.
function Get-MessageVmrun {
    param($Resultat)
    foreach ($l in $Resultat.Lignes) {
        if ($l -match '^Error:\s*(.+)$') { return $Matches[1] }
    }
    if ($Resultat.Texte) { return $Resultat.Texte }
    return "vmrun a renvoyé le code $($Resultat.Code) sans message"
}

# ----------------------------------------------------------------------------
#  Outils internes : lecture et écriture des fichiers .vmx
#  Un .vmx est un fichier texte de lignes  cle = "valeur"  ; on le réécrit en
#  conservant son encodage (ligne .encoding), ses fins de ligne et l'ordre
#  des lignes que l'on ne touche pas.
# ----------------------------------------------------------------------------

function Read-FichierVmx {
    param([string]$Chemin)
    if (-not (Test-Path -LiteralPath $Chemin -PathType Leaf)) {
        if ($script:Simulation) {
            # Machine « créée » par une commande simulée : configuration vide, jamais écrite.
            return [pscustomobject]@{ Chemin = $Chemin; Encodage = (New-Object System.Text.UTF8Encoding($false)); FinDeLigne = "`r`n"
                                      Lignes = (New-Object 'System.Collections.Generic.List[string]'); Changements = (New-Object 'System.Collections.Generic.List[string]'); Simule = $true }
        }
        throw (New-ErreurPilote "Fichier de configuration introuvable : $Chemin" `
            "La VM a peut-être été supprimée ou déplacée en dehors de vazy. Retirez-la du catalogue avec : vazy rm <nom>")
    }
    $octets = [System.IO.File]::ReadAllBytes($Chemin)
    $brut = [System.Text.Encoding]::ASCII.GetString($octets)
    $encodage = New-Object System.Text.UTF8Encoding($false)
    if ($brut -match '(?m)^\s*\.encoding\s*=\s*"([^"]+)"') {
        $nom = $Matches[1]
        if ($nom -notmatch '^utf-?8$') {
            try { $encodage = [System.Text.Encoding]::GetEncoding($nom) } catch { }
        }
    }
    $texte = $encodage.GetString($octets).TrimStart([char]0xFEFF)
    $finDeLigne = if ($texte.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lignes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in ($texte -split '\r?\n')) { $lignes.Add($l) }
    while ($lignes.Count -gt 0 -and $lignes[$lignes.Count - 1] -eq '') { $lignes.RemoveAt($lignes.Count - 1) }
    return [pscustomobject]@{ Chemin = $Chemin; Encodage = $encodage; FinDeLigne = $finDeLigne; Lignes = $lignes
                              Changements = (New-Object 'System.Collections.Generic.List[string]'); Simule = $false }
}

# Seul point d'écriture d'un .vmx : journalisé, et simplement affiché en simulation.
function Write-FichierVmx {
    param($Vmx)
    $detail = if ($Vmx.Changements.Count -gt 0) { $Vmx.Changements -join ' ; ' } else { 'aucun changement' }
    if ($script:Simulation) {
        & $script:Observateur 'simulation' ('écriture de {0} : {1}' -f $Vmx.Chemin, $detail)
        $Vmx.Changements.Clear()
        return
    }
    $texte = ($Vmx.Lignes -join $Vmx.FinDeLigne) + $Vmx.FinDeLigne
    try {
        [System.IO.File]::WriteAllText($Vmx.Chemin, $texte, $Vmx.Encodage)
    } catch {
        throw (New-ErreurPilote "Impossible d'écrire $($Vmx.Chemin) : $($_.Exception.Message)" `
            "Vérifiez que la VM est éteinte et que le fichier n'est pas en lecture seule.")
    }
    & $script:Observateur 'journal' ('écriture de {0} : {1}' -f $Vmx.Chemin, $detail)
    $Vmx.Changements.Clear()
}

# Indice de la ligne qui définit une clé (insensible à la casse), ou -1.
function Get-IndexCleVmx {
    param($Vmx, [string]$Cle)
    $motif = '^\s*' + [regex]::Escape($Cle) + '\s*='
    for ($i = 0; $i -lt $Vmx.Lignes.Count; $i++) {
        if ($Vmx.Lignes[$i] -match $motif) { return $i }
    }
    return -1
}

function Get-ValeurVmx {
    param($Vmx, [string]$Cle)
    $i = Get-IndexCleVmx -Vmx $Vmx -Cle $Cle
    if ($i -lt 0) { return $null }
    if ($Vmx.Lignes[$i] -match '=\s*"(.*)"\s*$') { return $Matches[1] }
    if ($Vmx.Lignes[$i] -match '=\s*(.*?)\s*$') { return $Matches[1] }
    return $null
}

# Remplace la ligne de la clé si elle existe, sinon l'ajoute en fin de fichier.
function Set-ValeurVmx {
    param($Vmx, [string]$Cle, [string]$Valeur)
    $v = $Valeur -replace '\|', '|7C' -replace '"', '|22'   # échappement VMware des caractères spéciaux
    $ligne = $Cle + ' = "' + $v + '"'
    $i = Get-IndexCleVmx -Vmx $Vmx -Cle $Cle
    if ($i -ge 0) { if ($Vmx.Lignes[$i] -ceq $ligne) { return }; $Vmx.Lignes[$i] = $ligne } else { $Vmx.Lignes.Add($ligne) }
    # Un secret ne va jamais au journal ni à l'écran : seule la clé est tracée.
    if ($Cle -match '(?i)password|passwd|\.key$|secret') { $Vmx.Changements.Add($Cle + ' = "***"') }
    else { $Vmx.Changements.Add($ligne) }
}

# Supprime toutes les lignes dont la clé correspond à l'expression régulière.
function Remove-ClesVmx {
    param($Vmx, [string]$MotifCle)
    $motif = '^\s*(' + $MotifCle + ')\s*='
    for ($i = $Vmx.Lignes.Count - 1; $i -ge 0; $i--) {
        if ($Vmx.Lignes[$i] -match $motif) {
            $Vmx.Changements.Add('retrait de ' + ($Vmx.Lignes[$i] -replace '\s*=.*$', ''))
            $Vmx.Lignes.RemoveAt($i)
        }
    }
}

# ----------------------------------------------------------------------------
#  Marque « modèle » : fichier témoin posé à côté du descripteur de la machine
#  (<machine>.vazy-modele). vmrun clone ne le copie pas, les clones ne
#  l'héritent donc jamais. Toute opération dangereuse pour les clones liés
#  (démarrer, supprimer, instantanés) est refusée par le pilote lui-même sur
#  une machine marquée, indépendamment du catalogue.
# ----------------------------------------------------------------------------

function Get-CheminMarqueModele {
    param([string]$Machine)
    return ($Machine + '.vazy-modele')
}

function Test-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    return (Test-Path -LiteralPath (Get-CheminMarqueModele $Machine) -PathType Leaf)
}

function Protect-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $marque = Get-CheminMarqueModele $Machine
    if (Test-Path -LiteralPath $marque -PathType Leaf) { return }
    if ($script:Simulation) { & $script:Observateur 'simulation' "création de la marque de modèle $marque"; return }
    $texte = @(
        "Machine marquée comme MODÈLE par vazy le $((Get-Date).ToString('yyyy-MM-dd HH:mm')).",
        "Ne jamais la démarrer, ne jamais supprimer son instantané : des clones liés en dépendent.",
        "vazy refuse toute opération dessus tant que ce fichier existe (vazy template rm <alias> le retire)."
    ) -join "`r`n"
    try {
        [System.IO.File]::WriteAllText($marque, $texte + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        throw (New-ErreurPilote "Impossible de poser la marque de modèle $marque : $($_.Exception.Message)" "Vérifiez vos droits d'écriture dans le dossier du modèle.")
    }
}

function Unprotect-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $marque = Get-CheminMarqueModele $Machine
    if (-not (Test-Path -LiteralPath $marque -PathType Leaf)) { return }
    if ($script:Simulation) { & $script:Observateur 'simulation' "suppression de la marque de modèle $marque"; return }
    Remove-Item -LiteralPath $marque -Force
    & $script:Observateur 'journal' "suppression de la marque de modèle $marque"
}

# Garde-fou appelé par chaque opération dangereuse pour les clones liés.
function Assert-MachinePasModele {
    param([string]$Machine, [string]$Operation)
    if (Test-MachineModele -Machine $Machine) {
        throw (New-ErreurPilote "Refus de $Operation : $Machine est marquée comme modèle." `
            "Un modèle sert uniquement de base aux clones liés ; le démarrer ou toucher à ses instantanés casserait tous ses clones. Si c'est vraiment voulu, retirez-le d'abord du catalogue : vazy template rm <alias> (la marque $(Get-CheminMarqueModele $Machine) disparaît avec lui).")
    }
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : lecture seule
# ----------------------------------------------------------------------------

# Localise vmrun et décrit le pilote. Échoue avec un message clair sinon.
function Initialize-Pilote {
    param([string]$CheminForce)
    $script:VmrunExe = Find-Vmrun -CheminForce $CheminForce
    if (-not $script:VmrunExe) {
        throw (New-ErreurPilote "vmrun.exe est introuvable : VMware Workstation ne semble pas installé (cherché dans Program Files, le registre et le PATH)." `
            "Installez VMware Workstation Pro, ou indiquez où se trouve vmrun.exe : vazy config outilHyperviseur ""C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe""")
    }
    return [ordered]@{
        Nom               = 'VMware Workstation'
        Executable        = $script:VmrunExe
        ExtensionMachine  = '.vmx'
        SensibleHyperV    = $true    # VMware passe en mode dégradé (WHP) quand Hyper-V possède le processeur
        # {0} = exécutable de l'hyperviseur, {1} = chemin de la machine
        ConseilInstantane = 'VM éteinte, dans VMware Workstation : menu VM > Snapshot > Take Snapshot, nommez-le « base ». Ou en ligne de commande : "{0}" -T ws snapshot "{1}" base'
        # Protocole de l'écran distant, dont la logique tire le lien affiché.
        # VMware Workstation Pro embarque un serveur VNC : rien à installer.
        SchemaAffichageDistant = 'vnc'
    }
}

# Chemins des machines actuellement en cours d'exécution.
function Get-MachineEnCours {
    $r = Invoke-Vmrun @('list')
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de lister les machines en cours : $(Get-MessageVmrun $r)" `
            "Ouvrez VMware Workstation une fois pour vérifier qu'il fonctionne, puis réessayez.")
    }
    # Première ligne : "Total running VMs: N", puis un chemin par ligne.
    return @($r.Lignes | Where-Object { $_ -notmatch '^Total running VMs' -and $_ -match '[\\/]' })
}

# Noms des instantanés d'une machine (dans l'ordre renvoyé par VMware).
function Get-MachineInstantanes {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $r = Invoke-Vmrun @('listSnapshots', $Machine)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de lire les instantanés de $Machine : $(Get-MessageVmrun $r)" `
            "Vérifiez que ce fichier est bien une VM VMware valide : elle doit s'ouvrir dans VMware Workstation.")
    }
    # Première ligne : "Total snapshots: N", puis un nom par ligne.
    return @($r.Lignes | Where-Object { $_ -notmatch '^Total snapshots' })
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : les six opérations
# ----------------------------------------------------------------------------

# 1. Créer depuis un modèle : clone lié rattaché à l'instantané du modèle.
#    La machine est créée dans $Dossier\$Nom.vmx et son nom affiché est $Nom.
function New-MachineDepuisModele {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][string]$Instantane,
        [Parameter(Mandatory = $true)][string]$Dossier,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    $destination = Join-Path $Dossier ($Nom + '.vmx')
    if (Test-Path -LiteralPath $destination) {
        throw (New-ErreurPilote "Le fichier $destination existe déjà." "Choisissez un autre nom avec --name, ou supprimez ce dossier s'il s'agit d'un reste d'une VM effacée.")
    }
    if (-not $script:Simulation) {
        try {
            if (-not (Test-Path -LiteralPath $Dossier)) { New-Item -ItemType Directory -Path $Dossier -Force | Out-Null }
        } catch {
            throw (New-ErreurPilote "Impossible de créer le dossier $Dossier : $($_.Exception.Message)" "Vérifiez le chemin et vos droits d'écriture, ou changez le dossier des VM : vazy config dossierVms <chemin>")
        }
    }

    $r = Invoke-Vmrun @('clone', $Modele, $destination, 'linked', "-snapshot=$Instantane", "-cloneName=$Nom")
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le clonage a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez que le modèle est éteint et que son instantané « $Instantane » existe toujours (vazy template list). Le dossier $Dossier peut contenir des restes à supprimer.")
    }
    if (-not $script:Simulation -and -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw (New-ErreurPilote "vmrun n'a signalé aucune erreur mais $destination n'existe pas." "Regardez le dossier $Dossier et le journal de VMware Workstation.")
    }

    # Le clone doit démarrer sans poser de question (ex : « cette VM a été déplacée ou copiée ? »).
    $vmx = Read-FichierVmx -Chemin $destination
    Set-ValeurVmx -Vmx $vmx -Cle 'msg.autoAnswer' -Valeur 'TRUE'
    Write-FichierVmx -Vmx $vmx
    return $destination
}

# 2. Régler les paramètres : RAM (Mo), CPU, puis réglages bruts dans l'ordre.
#    Les réglages bruts ($Brut : objets avec Cle et Valeur) sont écrits tels
#    quels dans le .vmx et peuvent donc écraser RAM et CPU.
function Set-MachineParametres {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [int]$RamMo = 0,
        [int]$Cpu = 0,
        [object[]]$Brut = @()
    )
    $vmx = Read-FichierVmx -Chemin $Machine
    if ($RamMo -gt 0) {
        $RamMo = [int]([math]::Ceiling($RamMo / 4.0) * 4)   # VMware exige un multiple de 4 Mo
        Set-ValeurVmx -Vmx $vmx -Cle 'memsize' -Valeur ([string]$RamMo)
    }
    if ($Cpu -gt 0) {
        # Un seul socket avec N cœurs : accepté par toutes les éditions de Windows
        # invité, et évite l'erreur « numvcpus doit être un multiple de coresPerSocket ».
        Set-ValeurVmx -Vmx $vmx -Cle 'numvcpus' -Valeur ([string]$Cpu)
        Set-ValeurVmx -Vmx $vmx -Cle 'cpuid.coresPerSocket' -Valeur ([string]$Cpu)
    }
    foreach ($p in $Brut) {
        Set-ValeurVmx -Vmx $vmx -Cle $p.Cle -Valeur $p.Valeur
    }
    Write-FichierVmx -Vmx $vmx
}

# 3. Brancher le réseau : remplace toutes les cartes héritées du modèle par
#    une carte par mode demandé. Liste vide = aucune carte.
function Set-MachineReseau {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [string[]]$Modes = @()
    )
    $correspondance = @{ nat = 'nat'; bridged = 'bridged'; hostonly = 'hostonly' }
    $vmx = Read-FichierVmx -Chemin $Machine
    # On conserve le type de carte virtuelle du modèle (e1000, vmxnet3...) : c'est
    # celui pour lequel l'OS invité a déjà un pilote.
    $typeCarte = Get-ValeurVmx -Vmx $vmx -Cle 'ethernet0.virtualDev'
    Remove-ClesVmx -Vmx $vmx -MotifCle 'ethernet\d+\..*'
    for ($i = 0; $i -lt $Modes.Count; $i++) {
        # « nomme:<identifiant> » désigne un segment personnalisé. L'identifiant
        # est celui que ce pilote a lui-même renvoyé (New-ReseauNomme) : la
        # logique le transporte sans jamais l'interpréter.
        $demande = [string]$Modes[$i]
        $segment = $null
        if ($demande -match '^(?i)nomme:(.+)$') { $segment = $Matches[1] }
        $mode = if ($segment) { 'custom' } else { $correspondance[$demande.ToLower()] }
        if (-not $mode) {
            throw (New-ErreurPilote "Mode réseau inconnu pour le pilote VMware : $demande" "Modes acceptés : nat, bridged, hostonly, ou un segment personnalisé (vazy net list).")
        }
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).present" -Valeur 'TRUE'
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).connectionType" -Valeur $mode
        if ($segment) { Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).vnet" -Valeur $segment }
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).addressType" -Valeur 'generated'   # adresse MAC régénérée au premier démarrage
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).startConnected" -Valeur 'TRUE'
        if ($typeCarte) { Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).virtualDev" -Valeur $typeCarte }
    }
    Write-FichierVmx -Vmx $vmx
}

# 4. Démarrer, avec ou sans fenêtre VMware Workstation.
function Start-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$SansInterface
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'démarrer'
    $mode = if ($SansInterface) { 'nogui' } else { 'gui' }
    $r = Invoke-Vmrun @('start', $Machine, $mode)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le démarrage a échoué : $(Get-MessageVmrun $r)" `
            "Ouvrez la VM dans VMware Workstation pour voir le message complet ; les réglages sont dans $Machine (modifiables avec un éditeur de texte).")
    }
}

# 5. Arrêter : proprement via les VMware Tools (soft), ou en coupant le courant (hard).
function Stop-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$Brutal
    )
    $mode = if ($Brutal) { 'hard' } else { 'soft' }
    $r = Invoke-Vmrun @('stop', $Machine, $mode)
    if ($r.Code -ne 0) {
        $message = Get-MessageVmrun $r
        if (-not $Brutal -and $message -match 'Tools') {
            throw (New-ErreurPilote "Arrêt propre impossible : les VMware Tools ne répondent pas dans la VM ($message)" `
                "Éteignez depuis l'intérieur de la VM, ou forcez l'arrêt (équivaut à débrancher la prise) : vazy stop <nom> --hard")
        }
        throw (New-ErreurPilote "L'arrêt a échoué : $message" "Si la VM est bloquée, forcez l'arrêt : vazy stop <nom> --hard")
    }
}

# 6. Supprimer la machine et ses fichiers. Renvoie $null, ou un message
#    @{ Type = 'info'|'attention'; Message } : « info » si vmrun a laissé des
#    restes (journaux, verrous, fichiers d'instantanés) que le pilote a
#    nettoyés, « attention » si des fichiers inconnus subsistent.
function Remove-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Assert-MachinePasModele -Machine $Machine -Operation 'supprimer'
    $dossier = Split-Path -Parent $Machine
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Machine)
    $r = Invoke-Vmrun @('deleteVM', $Machine)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suppression a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez que la VM est éteinte et fermée dans VMware Workstation, puis réessayez. En dernier recours, supprimez le dossier $dossier à la main.")
    }
    if ($script:Simulation) { & $script:Observateur 'simulation' "nettoyage du dossier $dossier"; return $null }
    if (-not (Test-Path -LiteralPath $dossier)) { return $null }

    # deleteVM laisse parfois des résidus : journaux, dossiers de verrou, et
    # selon les versions les fichiers d'instantanés du clone (<nom>-000001.vmdk,
    # <nom>.vmsd, <nom>-Snapshot1.vmsn). Tout ce qui porte le nom de la machine
    # ou est un fichier de service VMware lui appartient : on le retire. Le
    # disque du modèle n'est jamais ici (il est dans le dossier du modèle).
    $motifs = @(($base + '.*'), ($base + '-*'), 'vmware*.log', '*.lck', '*.vmxf', '*.scoreboard', 'nvram', 'caches')
    $nettoyes = @()
    foreach ($e in @(Get-ChildItem -LiteralPath $dossier -Force -ErrorAction SilentlyContinue)) {
        foreach ($m in $motifs) {
            if ($e.Name -like $m) {
                Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $nettoyes += $e.Name
                break
            }
        }
    }
    $restants = @(Get-ChildItem -LiteralPath $dossier -Force -ErrorAction SilentlyContinue)
    if ($restants.Count -gt 0) {
        return @{ Type = 'attention'; Message = ("Fichiers inconnus conservés dans $dossier : " + (($restants | ForEach-Object { $_.Name }) -join ', ') + ". Vérifiez-les puis supprimez le dossier à la main.") }
    }
    Remove-Item -LiteralPath $dossier -Force -ErrorAction SilentlyContinue
    if ($nettoyes.Count -gt 0) {
        return @{ Type = 'info'; Message = ('Restes laissés par deleteVM, nettoyés par vazy : ' + ($nettoyes -join ', ')) }
    }
    return $null
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : instantanés (phase 1)
#  Refusés sur une machine marquée modèle : l'instantané d'ancrage d'un modèle
#  (celui sur lequel reposent les clones liés) ne doit jamais être touché.
# ----------------------------------------------------------------------------

# Prendre un instantané. Machine éteinte : instantané propre et rapide.
# Machine en marche : VMware y inclut la mémoire (plus long, plus gros).
function New-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'prendre un instantané de'
    $r = Invoke-Vmrun @('snapshot', $Machine, $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La prise de l'instantané « $Nom » a échoué : $(Get-MessageVmrun $r)" `
            "Ouvrez VMware Workstation (VM > Snapshot > Snapshot Manager) pour vérifier qu'aucune opération n'est en cours sur cette VM, puis réessayez.")
    }
}

# Revenir à un instantané. vmrun exige une machine arrêtée : l'appelant
# l'arrête avant. Après le retour, la machine est dans l'état enregistré
# (éteinte si l'instantané a été pris machine éteinte).
function Restore-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'revenir à un instantané de'
    $r = Invoke-Vmrun @('revertToSnapshot', $Machine, $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le retour à l'instantané « $Nom » a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez que la VM est bien éteinte (VMware met parfois quelques secondes à la libérer après un arrêt : réessayez) et que l'instantané existe : vazy snaps <nom>")
    }
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : invité
# ----------------------------------------------------------------------------

# Dépose une variable guestinfo dans la configuration de la machine : l'invité
# la lit avec « vmtoolsd --cmd "info-get guestinfo.<nom>" ». Écrite dans le
# .vmx, elle est persistante et se pose machine éteinte, avant le démarrage.
# « vmrun writeVariable ... guestVar » ne convient pas ici : cette variante
# n'existe qu'à l'exécution (perdue à l'extinction) et suppose la machine
# allumée. Valeur vide : la variable est retirée.
function Set-MachineVariableInvite {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom,
        [string]$Valeur = ''
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'modifier la configuration invité de'
    $vmx = Read-FichierVmx -Chemin $Machine
    if ($Valeur) { Set-ValeurVmx -Vmx $vmx -Cle ('guestinfo.' + $Nom) -Valeur $Valeur }
    else { Remove-ClesVmx -Vmx $vmx -MotifCle ('guestinfo\.' + [regex]::Escape($Nom)) }
    Write-FichierVmx -Vmx $vmx
}

# Famille du système invité, d'après la clé guestOS du .vmx.
function Get-MachineSystemeInvite {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $vmx = Read-FichierVmx -Chemin $Machine
    $guestOs = [string](Get-ValeurVmx -Vmx $vmx -Cle 'guestOS')
    if ($guestOs -match '^win') { return 'windows' }
    if ($guestOs -match 'linux|ubuntu|debian|centos|rhel|redhat|fedora|suse|sles|oracle|arch|photon|alma|rocky') { return 'linux' }
    return 'inconnu'
}

# Attend que les outils invité (VMware Tools / open-vm-tools) répondent :
# vmrun checkToolsState renvoie « running » quand l'invité est prêt à
# recevoir des commandes. Interroge toutes les 3 s jusqu'au délai maximal.
function Wait-MachineOutils {
    param([Parameter(Mandatory = $true)][string]$Machine, [int]$DelaiMaxSec = 120)
    if ($script:Simulation) { & $script:Observateur 'simulation' "attente des outils invité de $Machine (au plus $DelaiMaxSec s)"; return $true }
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $dernierSignal = 0
    while ($true) {
        $r = Invoke-Vmrun @('checkToolsState', $Machine)
        if ($r.Code -eq 0 -and (($r.Lignes -join ' ') -match '\brunning\b')) { return $true }
        $ecoule = [int]$chrono.Elapsed.TotalSeconds
        if ($ecoule -ge $DelaiMaxSec) { return $false }
        # Un signe de vie toutes les 15 s : cette attente dure parfois deux
        # minutes, et sans rien à l'écran l'utilisateur croit l'outil bloqué.
        if ($ecoule - $dernierSignal -ge 15) {
            $dernierSignal = $ecoule
            & $script:Observateur 'progression' ("outils invité pas encore prêts ({0} s sur {1})..." -f $ecoule, $DelaiMaxSec)
        }
        Start-Sleep -Seconds 3
    }
}

# Exécute un script dans l'invité, avec les identifiants d'un compte de
# l'invité (chemin de repli : un modèle guestinfo n'en a pas besoin). Le
# script vient de la logique (il dépend du système invité, pas de
# l'hyperviseur) ; ici on ne sait que le faire exécuter :
#   linux   : runScriptInGuest avec /bin/sh (VMware copie le texte dans un
#             fichier temporaire de l'invité et l'exécute)
#   windows : runProgramInGuest powershell.exe -EncodedCommand (le script est
#             transmis en base64 : aucun problème de guillemets)
# Renvoie le code de sortie du script dans l'invité (0 = succès ; la logique
# donne un sens aux autres). Lève une exception si l'invité n'a pas pu
# exécuter le script du tout. checkToolsState répond « running » un peu avant
# que l'invité n'accepte réellement des commandes : ces échecs-là sont
# retentés, pas les refus d'identifiants.
# Le programme tourne avec les droits du compte fourni : sous Windows, un
# compte administrateur soumis à l'UAC n'est PAS élevé.
function Invoke-MachineScript {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Identifiants,
        [Parameter(Mandatory = $true)][string]$Systeme,
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$Tentatives = 4
    )
    Assert-MachinePasModele -Machine $Machine -Operation "exécuter un script dans"
    switch ($Systeme) {
        'linux' {
            $commande = @('runScriptInGuest', $Machine, '/bin/sh', $Script)
        }
        'windows' {
            $encode = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
            $commande = @('runProgramInGuest', $Machine, 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
                          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encode)
        }
        default {
            throw (New-ErreurPilote "Système invité inconnu : « $Systeme »." "Indiquez-le au modèle : vazy template creds <modele> --os linux|windows")
        }
    }
    $message = ''
    for ($essai = 1; $essai -le $Tentatives; $essai++) {
        $r = Invoke-Vmrun -Arguments $commande -Identifiants $Identifiants
        if ($r.Code -eq 0) { return 0 }
        $message = Get-MessageVmrun $r
        if ($message -match 'exit code:?\s*(\d+)') { return [int]$Matches[1] }   # le script a tourné : son code de sortie
        if ($message -match 'user name or password|Invalid user|authentication') {
            throw (New-ErreurPilote "Exécution dans l'invité impossible : $message" `
                "L'invité a refusé le compte « $($Identifiants.UserName) » : vérifiez l'utilisateur et le mot de passe (vazy template creds <modele>), et que ce compte peut ouvrir une session dans la VM.")
        }
        if ($essai -lt $Tentatives) { Start-Sleep -Seconds 5 }   # invité pas encore prêt : on réessaie
    }
    $conseil = if ($message -match 'Tools') {
        "Les outils VMware ne répondent pas dans l'invité : installez open-vm-tools (Linux) ou VMware Tools (Windows) dans le modèle, ou augmentez l'attente : vazy config delaiOutilsSec 300"
    } else {
        "Ouvrez la VM dans VMware Workstation pour voir ce qui se passe dans l'invité."
    }
    throw (New-ErreurPilote "Exécution dans l'invité impossible après $Tentatives tentatives : $message" $conseil)
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : affichage distant
# ----------------------------------------------------------------------------

# Active ou retire le serveur d'affichage distant intégré à l'hyperviseur.
# VMware Workstation Pro embarque un serveur VNC, piloté par trois lignes du
# .vmx : il n'y a donc rien à installer. Les lignes sont lues au démarrage de
# la machine : poser cela sur une machine en marche n'a d'effet qu'au
# démarrage suivant (l'appelant en avertit l'utilisateur).
# Le mot de passe est écrit en clair dans le .vmx, comme VMware l'attend ; il
# n'apparaît ni au journal ni dans les messages (voir Set-ValeurVmx).
function Set-MachineAffichageDistant {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][bool]$Actif,
        [int]$Port = 0,
        [string]$MotDePasse = ''
    )
    Assert-MachinePasModele -Machine $Machine -Operation "activer l'affichage distant de"
    $vmx = Read-FichierVmx -Chemin $Machine
    if ($Actif) {
        if ($Port -le 0) { throw (New-ErreurPilote "Port d'affichage distant invalide : $Port" 'Indiquez un port TCP entre 1 et 65535.') }
        Set-ValeurVmx -Vmx $vmx -Cle 'RemoteDisplay.vnc.enabled'  -Valeur 'TRUE'
        Set-ValeurVmx -Vmx $vmx -Cle 'RemoteDisplay.vnc.port'     -Valeur ([string]$Port)
        if ($MotDePasse) { Set-ValeurVmx -Vmx $vmx -Cle 'RemoteDisplay.vnc.password' -Valeur $MotDePasse }
    } else {
        Remove-ClesVmx -Vmx $vmx -MotifCle 'RemoteDisplay\.vnc\..*'
    }
    Write-FichierVmx -Vmx $vmx
}

# ----------------------------------------------------------------------------
#  Contrat du pilote : protection du modèle et autonomie
# ----------------------------------------------------------------------------

# Disques de base d'une machine : les .vmdk de son dossier qui ne sont pas des
# disques de différences (-000001.vmdk et leurs morceaux). Une fois
# l'instantané d'un modèle pris, ils ne doivent plus jamais changer : les
# clones liés y lisent. Renvoie, par nom de fichier, taille et date.
function Get-MachineEmpreinte {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $dossier = Split-Path -Parent $Machine
    $disques = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath $dossier -Filter '*.vmdk' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($f.Name -match '-\d{6}(-s\d{3}|-f\d{3})?\.vmdk$') { continue }
        $disques[$f.Name] = [ordered]@{ taille = [long]$f.Length; modifie = $f.LastWriteTimeUtc.ToString('o') }
    }
    return $disques
}

# Compare l'état actuel des disques de base d'un modèle à l'empreinte prise à
# la création d'un clone. Fichier manquant ou taille changée : erreur (le
# clone lié est cassé, un instantané du modèle a probablement été supprimé
# ou consolidé). Date seule changée : attention.
function Test-MachineEmpreinte {
    param([Parameter(Mandatory = $true)][string]$Machine, [Parameter(Mandatory = $true)]$Empreinte)
    $erreurs = @(); $attentions = @()
    $dossier = Split-Path -Parent $Machine
    foreach ($nom in @($Empreinte.Keys)) {
        $attendu = $Empreinte[$nom]
        $chemin = Join-Path $dossier $nom
        if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { $erreurs += "disque de base manquant : $chemin"; continue }
        $f = Get-Item -LiteralPath $chemin
        if ([long]$f.Length -ne [long]$attendu['taille']) {
            $erreurs += ("disque de base modifié : {0} ({1} octets à la création du clone, {2} maintenant)" -f $nom, $attendu['taille'], $f.Length)
        } elseif ($f.LastWriteTimeUtc.ToString('o') -ne [string]$attendu['modifie']) {
            $attentions += "disque de base retouché sans changement de taille : $nom"
        }
    }
    return @{ Erreurs = $erreurs; Attentions = $attentions }
}

# Convertit un clone lié en machine complète : clone complet dans un dossier
# voisin (<nom>.freeze), suppression de l'ancienne machine, puis le nouveau
# dossier prend la place de l'ancien, le chemin de la machine ne change pas.
# Machine éteinte obligatoire. Les instantanés ne survivent pas à un clone
# complet : l'appelant reprend son point de retour.
function Convert-MachineEnComplete {
    param([Parameter(Mandatory = $true)][string]$Machine, [Parameter(Mandatory = $true)][string]$Nom)
    Assert-MachinePasModele -Machine $Machine -Operation 'convertir'
    $dossier = Split-Path -Parent $Machine
    $temporaire = Join-Path (Split-Path -Parent $dossier) ($Nom + '.freeze')
    $destination = Join-Path $temporaire ($Nom + '.vmx')
    if (Test-Path -LiteralPath $temporaire) {
        throw (New-ErreurPilote "Le dossier $temporaire existe déjà (reste d'une conversion interrompue)." "Vérifiez son contenu, supprimez-le à la main, puis réessayez.")
    }
    $r = Invoke-Vmrun @('clone', $Machine, $destination, 'full', "-cloneName=$Nom")
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le clone complet a échoué : $(Get-MessageVmrun $r)" "Vérifiez la place disponible et que la VM est éteinte ; le dossier $temporaire peut contenir des restes à supprimer.")
    }
    if ($script:Simulation) { & $script:Observateur 'simulation' "suppression de $dossier puis renommage de $temporaire en $dossier"; return $Machine }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw (New-ErreurPilote "vmrun n'a signalé aucune erreur mais $destination n'existe pas." "Regardez le dossier $temporaire et le journal de VMware Workstation ; l'ancienne VM est intacte.")
    }
    Remove-Machine -Machine $Machine | Out-Null
    if (Test-Path -LiteralPath $dossier) {
        throw (New-ErreurPilote "L'ancien dossier $dossier n'a pas pu être vidé ; la machine complète est prête dans $temporaire." "Supprimez $dossier à la main, puis renommez $temporaire en $dossier.")
    }
    Rename-Item -LiteralPath $temporaire -NewName (Split-Path -Leaf $dossier)
    & $script:Observateur 'journal' "renommage de $temporaire en $dossier"
    $vmx = Read-FichierVmx -Chemin $Machine
    Set-ValeurVmx -Vmx $vmx -Cle 'msg.autoAnswer' -Valeur 'TRUE'
    Write-FichierVmx -Vmx $vmx
    return $Machine
}

# Capacité totale déclarée des disques d'une machine, en Go (0 si illisible),
# lue dans le descripteur des .vmdk référencés par sa configuration.
function Get-MachineDisqueGo {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $vmx = Read-FichierVmx -Chemin $Machine
    $dossier = Split-Path -Parent $Machine
    $total = [long]0
    foreach ($ligne in $vmx.Lignes) {
        if ($ligne -match '^\s*(scsi|sata|ide|nvme)\d+:\d+\.fileName\s*=\s*"([^"]+\.vmdk)"') {
            $chemin = $Matches[2]
            if (-not [System.IO.Path]::IsPathRooted($chemin)) { $chemin = Join-Path $dossier $chemin }
            $total += Get-CapaciteVmdk -Chemin $chemin
        }
    }
    return [math]::Round($total / 1GB, 1)
}

# Le descripteur d'un .vmdk (en tête du fichier, ou fichier séparé pour un
# disque découpé) contient des lignes « RW <secteurs> SPARSE ... ».
function Get-CapaciteVmdk {
    param([string]$Chemin)
    if (-not (Test-Path -LiteralPath $Chemin -PathType Leaf)) { return [long]0 }
    try {
        $flux = [System.IO.File]::OpenRead($Chemin)
        $tampon = New-Object byte[] 65536
        $lu = $flux.Read($tampon, 0, $tampon.Length)
        $flux.Close()
        $texte = [System.Text.Encoding]::ASCII.GetString($tampon, 0, $lu)
        $secteurs = [long]0
        foreach ($m in [regex]::Matches($texte, '(?m)^\s*RW\s+(\d+)\s+(SPARSE|FLAT|VMFS|VMFSSPARSE|ZERO)')) { $secteurs += [long]$m.Groups[1].Value }
        return $secteurs * 512
    } catch { return [long]0 }
}

# Supprimer un instantané. VMware fusionne ses disques avec la suite de la
# chaîne : l'opération peut prendre du temps sur une VM très modifiée.
function Remove-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'supprimer un instantané de'
    $r = Invoke-Vmrun @('deleteSnapshot', $Machine, $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suppression de l'instantané « $Nom » a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez qu'il existe (vazy snaps <nom>) et qu'aucune opération n'est en cours dans VMware Workstation.")
    }
}

# ============================================================================
#  Segments réseau personnalisés
# ============================================================================
#  Un segment est un réseau isolé auquel on rattache plusieurs VM : c'est ce
#  qu'il faut pour un TP de routage ou de segmentation, où « hostonly » ne
#  suffit pas (toutes les machines en hostonly partagent le même segment).
#
#  Chez VMware ce sont les VMnet. VMnet0 (bridged), VMnet1 (host-only) et
#  VMnet8 (NAT) sont réservés ; les autres sont libres.
#
#  Les LECTURES passent par le registre : fiables, et sans droits
#  d'administrateur. Les ÉCRITURES passent par vnetlib, qui exige ces droits.
# ============================================================================

$script:CleVmnet = 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig'
$script:VmnetReserves = @('vmnet0', 'vmnet1', 'vmnet8')

function Find-Vnetlib {
    $dossier = if ($script:VmrunExe) { Split-Path -Parent $script:VmrunExe } else { $null }
    foreach ($nom in @('vnetlib64.exe', 'vnetlib.exe')) {
        if ($dossier) {
            $c = Join-Path $dossier $nom
            if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
        }
    }
    return $null
}

function Test-DroitsAdministrateur {
    try {
        $identite = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identite).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Toute commande vnetlib passe ici : même rôle qu'Invoke-Vmrun.
function Invoke-Vnetlib {
    param([string[]]$Arguments)
    $exe = Find-Vnetlib
    if (-not $exe) {
        throw (New-ErreurPilote "vnetlib est introuvable à côté de vmrun.exe." `
            "Les segments réseau personnalisés demandent l'outil réseau de VMware Workstation. Vérifiez votre installation, ou créez le segment à la main dans Edit > Virtual Network Editor.")
    }
    if (-not (Test-DroitsAdministrateur)) {
        throw (New-ErreurPilote "La modification des réseaux virtuels demande les droits d'administrateur." `
            "Ouvrez une invite de commandes en tant qu'administrateur et relancez la commande. Seule la création et la suppression de segments l'exigent : le reste de vazy fonctionne sans.")
    }
    $affichable = ConvertTo-LigneCommande (@($exe) + $Arguments)
    if ($script:Simulation) {
        & $script:Observateur 'simulation' $affichable
        return @{ Code = 0; Lignes = @(); Sortie = '' }
    }
    & $script:Observateur 'journal' $affichable
    $lignes = & $exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return @{ Code = $LASTEXITCODE; Lignes = @($lignes); Sortie = ($lignes -join "`n") }
}

# Segments existants, lus dans le registre. Les réservés sont exclus : ce sont
# les modes nat/bridged/hostonly, pas des segments à gérer.
function Get-ReseauxNommes {
    $reseaux = @()
    if (-not (Test-Path -LiteralPath $script:CleVmnet)) { return $reseaux }
    foreach ($cle in @(Get-ChildItem -LiteralPath $script:CleVmnet -ErrorAction SilentlyContinue)) {
        $nom = $cle.PSChildName.ToLower()
        if ($nom -notmatch '^vmnet\d+$') { continue }
        if ($script:VmnetReserves -contains $nom) { continue }
        $valeurs = Get-ItemProperty -LiteralPath $cle.PSPath -ErrorAction SilentlyContinue
        $adresse = ''
        $masque  = ''
        $dhcp    = $false
        if ($valeurs) {
            if ($valeurs.PSObject.Properties['IPSubnetAddr']) { $adresse = [string]$valeurs.IPSubnetAddr }
            if ($valeurs.PSObject.Properties['IPSubnetMask']) { $masque  = [string]$valeurs.IPSubnetMask }
            if ($valeurs.PSObject.Properties['UseDHCP'])      { $dhcp    = ([int]$valeurs.UseDHCP -ne 0) }
        }
        $reseaux += @{ Identifiant = $nom; Adresse = $adresse; Masque = $masque; Dhcp = $dhcp }
    }
    return $reseaux
}

# Premier VMnet libre, hors réservés.
function Get-VmnetLibre {
    $pris = @(Get-ReseauxNommes | ForEach-Object { $_.Identifiant })
    for ($i = 2; $i -le 19; $i++) {
        $candidat = 'vmnet' + $i
        if ($script:VmnetReserves -contains $candidat) { continue }
        if ($pris -notcontains $candidat) { return $candidat }
    }
    return $null
}

function New-ReseauNomme {
    param(
        [string]$Identifiant = '',
        [string]$Adresse = '',
        [string]$Masque = '255.255.255.0',
        [bool]$Dhcp = $false
    )
    if (-not $Identifiant) {
        $Identifiant = Get-VmnetLibre
        if (-not $Identifiant) {
            throw (New-ErreurPilote "Plus aucun segment réseau disponible : VMnet2 à VMnet19 sont tous pris." `
                "Libérez-en un (vazy net rm <nom>), ou supprimez un réseau inutilisé dans Edit > Virtual Network Editor.")
        }
    }
    if ($script:VmnetReserves -contains $Identifiant.ToLower()) {
        throw (New-ErreurPilote "« $Identifiant » est un réseau réservé de VMware (bridged, host-only ou NAT)." `
            "Ces trois-là s'utilisent par --mode bridged, hostonly ou nat, pas comme segment personnalisé.")
    }

    $r = Invoke-Vnetlib @('--', 'add', 'vnet', $Identifiant)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La création du segment $Identifiant a échoué : $($r.Sortie)" `
            "Vérifiez dans Edit > Virtual Network Editor qu'il n'existe pas déjà, et que VMware Workstation n'est pas en train de démarrer une VM.")
    }
    if ($Adresse) {
        Invoke-Vnetlib @('--', 'set', 'vnet', $Identifiant, 'addr', $Adresse) | Out-Null
        Invoke-Vnetlib @('--', 'set', 'vnet', $Identifiant, 'mask', $Masque)  | Out-Null
    }
    Invoke-Vnetlib @('--', 'add', 'adapter', $Identifiant) | Out-Null
    if ($Dhcp) {
        Invoke-Vnetlib @('--', 'add', 'dhcp', $Identifiant)    | Out-Null
        Invoke-Vnetlib @('--', 'update', 'dhcp', $Identifiant) | Out-Null
    }
    Invoke-Vnetlib @('--', 'update', 'adapter', $Identifiant) | Out-Null
    return $Identifiant
}

function Remove-ReseauNomme {
    param([Parameter(Mandatory = $true)][string]$Identifiant)
    if ($script:VmnetReserves -contains $Identifiant.ToLower()) {
        throw (New-ErreurPilote "« $Identifiant » est un réseau réservé de VMware : le supprimer casserait les modes nat, bridged ou hostonly." `
            "vazy ne supprime que les segments qu'il a créés.")
    }
    # Le DHCP et la carte hôte d'abord : le segment ne peut pas partir tant
    # qu'ils s'y rattachent. Leur absence n'est pas une erreur.
    Invoke-Vnetlib @('--', 'remove', 'dhcp', $Identifiant)    | Out-Null
    Invoke-Vnetlib @('--', 'remove', 'adapter', $Identifiant) | Out-Null
    $r = Invoke-Vnetlib @('--', 'remove', 'vnet', $Identifiant)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suppression du segment $Identifiant a échoué : $($r.Sortie)" `
            "Vérifiez qu'aucune VM ne l'utilise encore, y compris hors de vazy, puis réessayez.")
    }
}
