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
#                              -> message d'information éventuel (ou $null)
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
function Invoke-Vmrun {
    param([string[]]$Arguments)
    $infos = New-Object System.Diagnostics.ProcessStartInfo
    $infos.FileName = $script:VmrunExe
    $infos.Arguments = ConvertTo-LigneCommande (@('-T', 'ws') + $Arguments)
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

# 6. Supprimer la machine et ses fichiers. Renvoie un message d'information
#    si des fichiers subsistent, $null sinon.
function Remove-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $dossier = Split-Path -Parent $Machine
    $r = Invoke-Vmrun @('deleteVM', $Machine)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suppression a échoué : $(Get-MessageVmrun $r)" `
            "Vérifiez que la VM est éteinte et fermée dans VMware Workstation, puis réessayez. En dernier recours, supprimez le dossier $dossier à la main.")
    }
    # vmrun laisse parfois des résidus (journaux, dossier de verrou) : on nettoie
    # le dossier s'il ne contient plus aucun disque ni descripteur.
    if (Test-Path -LiteralPath $dossier) {
        $restes = @(Get-ChildItem -LiteralPath $dossier -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.vmdk', '.vmx', '.vmsn', '.vmem' })
        if ($restes.Count -eq 0) {
            Remove-Item -LiteralPath $dossier -Recurse -Force -ErrorAction SilentlyContinue
            return $null
        }
        return "Des fichiers subsistent dans $dossier ; vérifiez-les et supprimez-les à la main si besoin."
    }
    return $null
}
