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
#  Invité (phase 4, personnalisation) :
#    Get-MachineSystemeInvite  -Machine          -> 'windows' | 'linux' | 'inconnu'
#    Wait-MachineOutils        -Machine [-DelaiMaxSec]
#                                                -> $true dès que les outils invité répondent,
#                                                   $false passé le délai
#    Invoke-MachineScript      -Machine -Identifiants -Systeme -Script
#                                                exécute un script dans l'invité
#                                                (Identifiants = PSCredential ; le mot de
#                                                passe n'apparaît dans aucun message)
#
#  Toute erreur est levée sous forme d'exception dont Data['Conseil'] indique
#  quoi faire pour corriger (voir New-ErreurPilote).
# ============================================================================

$script:VmrunExe = $null   # chemin de vmrun.exe, renseigné par Initialize-Pilote

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
    $secret = $null
    if ($null -ne $Identifiants) {
        $secret = $Identifiants.GetNetworkCredential().Password
        $prefixe += @('-gu', $Identifiants.UserName, '-gp', $secret)
    }
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
    return [pscustomobject]@{ Code = $processus.ExitCode; Lignes = $lignes; Texte = $texte }
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
    return [pscustomobject]@{ Chemin = $Chemin; Encodage = $encodage; FinDeLigne = $finDeLigne; Lignes = $lignes }
}

function Write-FichierVmx {
    param($Vmx)
    $texte = ($Vmx.Lignes -join $Vmx.FinDeLigne) + $Vmx.FinDeLigne
    try {
        [System.IO.File]::WriteAllText($Vmx.Chemin, $texte, $Vmx.Encodage)
    } catch {
        throw (New-ErreurPilote "Impossible d'écrire $($Vmx.Chemin) : $($_.Exception.Message)" `
            "Vérifiez que la VM est éteinte et que le fichier n'est pas en lecture seule.")
    }
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
    if ($i -ge 0) { $Vmx.Lignes[$i] = $ligne } else { $Vmx.Lignes.Add($ligne) }
}

# Supprime toutes les lignes dont la clé correspond à l'expression régulière.
function Remove-ClesVmx {
    param($Vmx, [string]$MotifCle)
    $motif = '^\s*(' + $MotifCle + ')\s*='
    for ($i = $Vmx.Lignes.Count - 1; $i -ge 0; $i--) {
        if ($Vmx.Lignes[$i] -match $motif) { $Vmx.Lignes.RemoveAt($i) }
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
    if (Test-Path -LiteralPath $marque -PathType Leaf) { Remove-Item -LiteralPath $marque -Force }
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
    try {
        if (-not (Test-Path -LiteralPath $Dossier)) { New-Item -ItemType Directory -Path $Dossier -Force | Out-Null }
    } catch {
        throw (New-ErreurPilote "Impossible de créer le dossier $Dossier : $($_.Exception.Message)" "Vérifiez le chemin et vos droits d'écriture, ou changez le dossier des VM : vazy config dossierVms <chemin>")
    }

    $r = Invoke-Vmrun @('clone', $Modele, $destination, 'linked', "-snapshot=$Instantane", "-cloneName=$Nom")
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le clonage a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez que le modèle est éteint et que son instantané « $Instantane » existe toujours (vazy template list). Le dossier $Dossier peut contenir des restes à supprimer.")
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
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
        $mode = $correspondance[$Modes[$i].ToLower()]
        if (-not $mode) {
            throw (New-ErreurPilote "Mode réseau inconnu pour le pilote VMware : $($Modes[$i])" "Modes acceptés : nat, bridged, hostonly.")
        }
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).present" -Valeur 'TRUE'
        Set-ValeurVmx -Vmx $vmx -Cle "ethernet$($i).connectionType" -Valeur $mode
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
#  Contrat du pilote : invité (phase 4)
# ----------------------------------------------------------------------------

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
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $r = Invoke-Vmrun @('checkToolsState', $Machine)
        if ($r.Code -eq 0 -and (($r.Lignes -join ' ') -match '\brunning\b')) { return $true }
        if ($chrono.Elapsed.TotalSeconds -ge $DelaiMaxSec) { return $false }
        Start-Sleep -Seconds 3
    }
}

# Exécute un script dans l'invité, avec les identifiants d'un compte de
# l'invité. Le script vient de la logique (il dépend du système invité, pas
# de l'hyperviseur) ; ici on ne sait que le faire exécuter :
#   linux   : runScriptInGuest avec /bin/sh (VMware copie le texte dans un
#             fichier temporaire de l'invité et l'exécute)
#   windows : runProgramInGuest powershell.exe -EncodedCommand (le script est
#             transmis en base64 : aucun problème de guillemets)
# Le programme tourne avec les droits du compte fourni : sous Windows, un
# compte administrateur soumis à l'UAC n'est PAS élevé.
function Invoke-MachineScript {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Identifiants,
        [Parameter(Mandatory = $true)][string]$Systeme,
        [Parameter(Mandatory = $true)][string]$Script
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
    $r = Invoke-Vmrun -Arguments $commande -Identifiants $Identifiants
    if ($r.Code -ne 0) {
        $message = Get-MessageVmrun $r
        $conseil = if ($message -match 'user name or password|Invalid user|authentication') {
            "L'invité a refusé le compte « $($Identifiants.UserName) » : vérifiez l'utilisateur et le mot de passe (vazy template creds <modele>), et que ce compte peut ouvrir une session dans la VM."
        } elseif ($message -match 'Tools') {
            "Les outils VMware ne répondent pas dans l'invité : installez open-vm-tools (Linux) ou VMware Tools (Windows) dans le modèle."
        } elseif ($message -match 'exit code') {
            "Le script a échoué dans l'invité : droits insuffisants ? Sous Linux, le compte doit pouvoir faire sudo sans mot de passe (ou être root) ; sous Windows, il doit être administrateur sans invite UAC (compte Administrateur intégré)."
        } else {
            "Ouvrez la VM dans VMware Workstation pour voir ce qui se passe dans l'invité."
        }
        throw (New-ErreurPilote "Exécution dans l'invité impossible : $message" $conseil)
    }
    return $r.Texte
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
