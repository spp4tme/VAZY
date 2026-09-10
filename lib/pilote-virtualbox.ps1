# ============================================================================
#  vazy - couche 3 : pilote Oracle VirtualBox
# ============================================================================
#  Implémente le contrat décrit en tête de lib\pilote-vmware.ps1, via
#  VBoxManage. Seule couche à connaître VirtualBox : aucune ligne propre à cet
#  hyperviseur ne doit exister ailleurs.
#
#  Activation :  vazy config hyperviseur virtualbox
#
#  Les écarts réels avec VMware (identité des machines, réglages bruts,
#  affichage distant, personnalisation de l'invité) sont expliqués dans
#  docs\PILOTE-VIRTUALBOX.md. Les principaux :
#
#  - Une machine est ici désignée, comme dans le contrat, par le chemin de son
#    descripteur (.vbox). Mais VBoxManage, lui, ne connaît que des noms et des
#    UUID : ce pilote fait la traduction (Get-NomMachine) et la met en cache.
#  - « --set » n'a pas d'équivalent exact : VirtualBox n'a pas de fichier de
#    configuration en texte libre. Les réglages bruts partent dans
#    « setextradata », ce qui n'est PAS la même chose qu'une clé .vmx.
#  - L'affichage distant passe par VRDE, qui parle RDP par défaut et VNC
#    seulement si l'extension VNC est installée. Le pilote annonce le
#    protocole obtenu (SchemaAffichageDistant), et la logique construit le
#    lien en conséquence.
#
#  Toute commande VBoxManage est construite en un seul point
#  (Invoke-VBoxManage), comme Invoke-Vmrun côté VMware : c'est ce qui garantit
#  le journal, --dry-run et le masquage des mots de passe.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Délai maximal d'une commande, voir la note équivalente du pilote VMware.
$script:DelaiCommandeSec = 1800

$script:VBoxExe      = $null                          # chemin de VBoxManage.exe
$script:Simulation   = $false                         # --dry-run
$script:Observateur  = { param($Type, $Message) }     # journal et simulations
$script:NomsMachines = @{}                            # chemin .vbox -> nom VirtualBox (cache du processus)
$script:ExtensionVnc = $null                          # l'extension VNC est-elle installée ? (calculé une fois)

function Set-PiloteObservateur {
    param([scriptblock]$Observateur, [bool]$Simulation = $false)
    if ($Observateur) { $script:Observateur = $Observateur }
    $script:Simulation = $Simulation
}

function New-ErreurPilote {
    param([string]$Message, [string]$Conseil)
    $e = New-Object System.Exception($Message)
    $e.Data['Conseil'] = $Conseil
    return $e
}

# ----------------------------------------------------------------------------
#  Localisation de VBoxManage et exécution des commandes
# ----------------------------------------------------------------------------

function Find-VBoxManage {
    param([string]$CheminForce)
    $candidats = New-Object System.Collections.Generic.List[string]
    if ($CheminForce) { $candidats.Add([Environment]::ExpandEnvironmentVariables($CheminForce)) }
    # VirtualBox pose son dossier d'installation dans cette variable.
    if ($env:VBOX_MSI_INSTALL_PATH) { $candidats.Add((Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe')) }
    if ($env:VBOX_INSTALL_PATH)     { $candidats.Add((Join-Path $env:VBOX_INSTALL_PATH 'VBoxManage.exe')) }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidats.Add((Join-Path $base 'Oracle\VirtualBox\VBoxManage.exe')) }
    }
    try {
        $cle = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction Stop
        if ($cle.InstallDir) { $candidats.Add((Join-Path $cle.InstallDir 'VBoxManage.exe')) }
    } catch { }
    foreach ($c in $candidats) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    $viaPath = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($viaPath) { return $viaPath.Source }
    return $null
}

# Rend une ligne de commande affichable, avec les guillemets qu'il faut.
function ConvertTo-LigneCommande {
    param([string[]]$Elements)
    $morceaux = foreach ($e in $Elements) {
        if ($e -eq '' -or $e -match '[\s"]') {
            $t = $e -replace '(\\*)"', '$1$1\"'
            '"' + $t + '"'
        } else { $e }
    }
    return ($morceaux -join ' ')
}

# Point de passage unique de toute commande VirtualBox.
# -Secrets : valeurs à masquer dans le journal (mots de passe).
# -Lecture : commande sans effet de bord, exécutée même en simulation.
function Invoke-VBoxManage {
    param(
        [string[]]$Arguments,
        [string[]]$Secrets = @(),
        [switch]$Lecture
    )
    if (-not $script:VBoxExe) {
        throw (New-ErreurPilote 'Le pilote VirtualBox n''a pas été initialisé.' 'Erreur interne : Initialize-Pilote doit être appelé avant toute opération.')
    }
    $affichable = ConvertTo-LigneCommande (@($script:VBoxExe) + $Arguments)
    foreach ($s in $Secrets) {
        if ($s) { $affichable = $affichable.Replace($s, '***') }
    }

    if ($script:Simulation -and -not $Lecture) {
        & $script:Observateur 'simulation' $affichable
        return @{ Code = 0; Lignes = @(); Sortie = '' }
    }

    & $script:Observateur 'journal' $affichable
    # Même précaution que côté VMware : « startvm » lance VirtualBoxVM.exe, qui
    # hérite des tuyaux de sortie et les garde ouverts tant que la VM tourne.
    # On attend la fin du processus, pas celle des flux.
    $infos = New-Object System.Diagnostics.ProcessStartInfo
    $infos.FileName = $script:VBoxExe
    $infos.Arguments = ConvertTo-LigneCommande $Arguments
    $infos.UseShellExecute = $false
    $infos.RedirectStandardOutput = $true
    $infos.RedirectStandardError = $true
    $infos.CreateNoWindow = $true
    try {
        $processus = [System.Diagnostics.Process]::Start($infos)
    } catch {
        throw (New-ErreurPilote "Impossible de lancer VBoxManage ($($script:VBoxExe)) : $($_.Exception.Message)" `
            "Vérifiez que ce fichier existe et que VirtualBox est correctement installé.")
    }
    $lectureSortie  = $processus.StandardOutput.ReadToEndAsync()
    $lectureErreurs = $processus.StandardError.ReadToEndAsync()
    if (-not $processus.WaitForExit($script:DelaiCommandeSec * 1000)) {
        try { $processus.Kill() } catch { }
        throw (New-ErreurPilote "VBoxManage n'a pas répondu au bout de $($script:DelaiCommandeSec) s : $affichable" `
            ("Regardez VirtualBox : une fenêtre attend peut-être une réponse.`n" +
             "L'opération a peut-être abouti malgré tout : vérifiez avec vazy list avant de recommencer."))
    }
    $sortie  = if ($lectureSortie.Wait(2000))  { $lectureSortie.Result }  else { '' }
    $erreurs = if ($lectureErreurs.Wait(1000)) { $lectureErreurs.Result } else { '' }
    $texte = (($sortie + "`n" + $erreurs) -replace "`r", '').Trim()
    $lignes = @($texte -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return @{ Code = $processus.ExitCode; Lignes = $lignes; Sortie = $texte }
}

# Message d'erreur lisible extrait de la sortie de VBoxManage.
function Get-MessageVBox {
    param($Resultat)
    foreach ($l in $Resultat.Lignes) {
        if ($l -match 'VBoxManage.exe:\s*error:\s*(.+)$') { return $Matches[1].Trim() }
    }
    foreach ($l in $Resultat.Lignes) {
        if ($l -match '\S') { return $l.Trim() }
    }
    return 'aucun détail fourni par VBoxManage'
}

# ----------------------------------------------------------------------------
#  Identité des machines
#  Le contrat désigne une machine par le chemin de son descripteur ; VBoxManage
#  ne connaît que des noms et des UUID. Toute la traduction est ici.
# ----------------------------------------------------------------------------

# Valeur d'une clé dans une sortie « --machinereadable » (clé="valeur").
function Get-ValeurMachineReadable {
    param($Resultat, [string]$Cle)
    $motif = '^"?' + [regex]::Escape($Cle) + '"?="?(.*?)"?$'
    foreach ($l in $Resultat.Lignes) {
        if ($l -match $motif) { return $Matches[1] }
    }
    return $null
}

# Le fichier de configuration déclaré par VirtualBox pour cette machine.
function Get-CheminConfigMachine {
    param([string]$NomOuUuid)
    $r = Invoke-VBoxManage @('showvminfo', $NomOuUuid, '--machinereadable') -Lecture
    if ($r.Code -ne 0) { return $null }
    return (Get-ValeurMachineReadable -Resultat $r -Cle 'CfgFile')
}

function Test-MemeChemin {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        $a = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
        $b = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
        return ($a -ieq $b)
    } catch { return ($A -ieq $B) }
}

# Nom VirtualBox de la machine dont le descripteur est à ce chemin.
# Essaie d'abord le nom du fichier (cas courant), puis balaie le registre.
function Get-NomMachine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $cle = $Machine.ToLower()
    if ($script:NomsMachines.ContainsKey($cle)) { return $script:NomsMachines[$cle] }

    $candidat = [System.IO.Path]::GetFileNameWithoutExtension($Machine)
    if ($candidat) {
        $config = Get-CheminConfigMachine -NomOuUuid $candidat
        if (Test-MemeChemin $config $Machine) {
            $script:NomsMachines[$cle] = $candidat
            return $candidat
        }
    }

    # Le nom du fichier ne correspond pas (machine renommée) : on balaie.
    $r = Invoke-VBoxManage @('list', 'vms') -Lecture
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de lister les machines VirtualBox : $(Get-MessageVBox $r)" `
            'Ouvrez VirtualBox une fois pour vérifier qu''il fonctionne, puis réessayez.')
    }
    foreach ($l in $r.Lignes) {
        if ($l -match '^"(.+)"\s+\{([0-9a-fA-F-]+)\}\s*$') {
            $nom = $Matches[1]
            $config = Get-CheminConfigMachine -NomOuUuid $Matches[2]
            if (Test-MemeChemin $config $Machine) {
                $script:NomsMachines[$cle] = $nom
                return $nom
            }
        }
    }
    throw (New-ErreurPilote "Aucune machine VirtualBox n'est enregistrée pour $Machine." `
        ("VirtualBox ne gère que les machines inscrites à son registre, contrairement à VMware qui ouvre un fichier au vol.`n" +
         "Inscrivez-la : `"$($script:VBoxExe)`" registervm `"$Machine`""))
}

# ----------------------------------------------------------------------------
#  Marque « modèle »
#  Fichier témoin posé à côté du descripteur, exactement comme côté VMware :
#  le mécanisme ne dépend pas de l'hyperviseur.
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
    New-Item -ItemType File -Path $marque -Force | Out-Null
    & $script:Observateur 'journal' "marque de modèle posée : $marque"
}

function Unprotect-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $marque = Get-CheminMarqueModele $Machine
    if (-not (Test-Path -LiteralPath $marque -PathType Leaf)) { return }
    if ($script:Simulation) { & $script:Observateur 'simulation' "suppression de la marque de modèle $marque"; return }
    Remove-Item -LiteralPath $marque -Force
    & $script:Observateur 'journal' "marque de modèle retirée : $marque"
}

function Assert-MachinePasModele {
    param([string]$Machine, [string]$Operation)
    if (Test-MachineModele -Machine $Machine) {
        throw (New-ErreurPilote "Refus de $Operation : $Machine est marquée comme modèle." `
            ("Un modèle sert uniquement de base aux clones liés ; le démarrer ou toucher à ses instantanés casserait tous ses clones. " +
             "Si c'est vraiment voulu, retirez-le d'abord du catalogue : vazy template rm <alias> (la marque $(Get-CheminMarqueModele $Machine) disparaît avec lui)."))
    }
}

# ----------------------------------------------------------------------------
#  Description du pilote et lectures
# ----------------------------------------------------------------------------

# L'extension VNC est-elle installée ? Sans elle, VRDE parle RDP.
function Test-ExtensionVnc {
    if ($null -ne $script:ExtensionVnc) { return $script:ExtensionVnc }
    $script:ExtensionVnc = $false
    try {
        $r = Invoke-VBoxManage @('list', 'extpacks') -Lecture
        if ($r.Code -eq 0 -and $r.Sortie -match '(?im)^\s*Pack no\.\d+:\s*.*VNC') { $script:ExtensionVnc = $true }
    } catch { }
    return $script:ExtensionVnc
}

function Initialize-Pilote {
    param([string]$CheminForce)
    $script:VBoxExe = Find-VBoxManage -CheminForce $CheminForce
    if (-not $script:VBoxExe) {
        throw (New-ErreurPilote 'VBoxManage.exe est introuvable : VirtualBox ne semble pas installé (cherché dans Program Files, le registre, les variables VBOX_* et le PATH).' `
            "Installez Oracle VirtualBox, ou indiquez où se trouve VBoxManage.exe : vazy config outilHyperviseur ""C:\Program Files\Oracle\VirtualBox\VBoxManage.exe""")
    }
    return [ordered]@{
        Nom               = 'Oracle VirtualBox'
        Executable        = $script:VBoxExe
        ExtensionMachine  = '.vbox'
        # VirtualBox 7 fonctionne aux côtés d'Hyper-V, en mode dégradé lui aussi,
        # et le signale de lui-même au démarrage de la VM.
        SensibleHyperV    = $true
        # {0} = exécutable de l'hyperviseur, {1} = chemin de la machine
        ConseilInstantane = 'VM éteinte, dans VirtualBox : menu Machine > Instantanés > Prendre, nommez-le « base ». Ou en ligne de commande : "{0}" snapshot "{1}" take base'
        # Protocole de l'écran distant : VNC si l'extension est installée, RDP
        # sinon. La logique s'en sert pour construire le lien affiché.
        SchemaAffichageDistant = $(if (Test-ExtensionVnc) { 'vnc' } else { 'rdp' })
    }
}

function Get-MachineEnCours {
    $r = Invoke-VBoxManage @('list', 'runningvms') -Lecture
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de lister les machines en cours : $(Get-MessageVBox $r)" `
            'Ouvrez VirtualBox une fois pour vérifier qu''il fonctionne, puis réessayez.')
    }
    $chemins = @()
    foreach ($l in $r.Lignes) {
        if ($l -match '^"(.+)"\s+\{([0-9a-fA-F-]+)\}\s*$') {
            $config = Get-CheminConfigMachine -NomOuUuid $Matches[2]
            if ($config) { $chemins += $config }
        }
    }
    return $chemins
}

function Get-MachineInstantanes {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $nom = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('snapshot', $nom, 'list', '--machinereadable') -Lecture
    # Une machine sans aucun instantané fait sortir VBoxManage en erreur : ce
    # n'est pas une panne, c'est une liste vide.
    if ($r.Code -ne 0) {
        if ($r.Sortie -match '(?i)does not have any snapshots') { return @() }
        throw (New-ErreurPilote "Impossible de lire les instantanés de $Machine : $(Get-MessageVBox $r)" `
            'Vérifiez que la machine est bien enregistrée dans VirtualBox (VBoxManage list vms).')
    }
    $noms = @()
    foreach ($l in $r.Lignes) {
        if ($l -match '^SnapshotName(-[\d-]+)?="(.*)"\s*$') { $noms += $Matches[2] }
    }
    return $noms
}

# ----------------------------------------------------------------------------
#  Les six opérations
# ----------------------------------------------------------------------------

function New-MachineDepuisModele {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][string]$Instantane,
        [Parameter(Mandatory = $true)][string]$Dossier,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    $nomModele = Get-NomMachine -Machine $Modele
    # VirtualBox crée <basefolder>\<nom>\ : on lui donne donc le parent du
    # dossier demandé, et il reconstitue exactement le chemin attendu.
    $parent = Split-Path -Parent $Dossier
    if (-not $parent) {
        throw (New-ErreurPilote "Le dossier de destination $Dossier n'a pas de dossier parent." 'Indiquez un chemin complet dans vazy config dossierVms.')
    }
    if (-not $script:Simulation -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $r = Invoke-VBoxManage @('clonevm', $nomModele, '--snapshot', $Instantane, '--options', 'link',
                             '--name', $Nom, '--basefolder', $parent, '--register')
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le clone lié a échoué : $(Get-MessageVBox $r)" `
            ("Vérifiez que le modèle est éteint, que l'instantané « $Instantane » existe, et qu'aucune machine ne s'appelle déjà « $Nom » dans VirtualBox.`n" +
             "VirtualBox impose des noms de machines uniques sur toute l'installation, pas seulement dans un dossier."))
    }
    $chemin = Join-Path $Dossier ($Nom + '.vbox')
    $script:NomsMachines[$chemin.ToLower()] = $Nom
    return $chemin
}

function Set-MachineParametres {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [int]$RamMo = 0,
        [int]$Cpu = 0,
        [object[]]$Brut = @()
    )
    $nom = Get-NomMachine -Machine $Machine
    $arguments = @('modifyvm', $nom)
    if ($RamMo -gt 0) { $arguments += @('--memory', [string]$RamMo) }
    if ($Cpu -gt 0)   { $arguments += @('--cpus',   [string]$Cpu) }
    if ($arguments.Count -gt 2) {
        $r = Invoke-VBoxManage $arguments
        if ($r.Code -ne 0) {
            throw (New-ErreurPilote "Impossible d'appliquer les réglages à $Machine : $(Get-MessageVBox $r)" `
                'Vérifiez que la machine est éteinte : VirtualBox refuse de modifier la mémoire ou les processeurs d''une VM en marche.')
        }
    }
    # Réglages bruts (--set). Voir docs\PILOTE-VIRTUALBOX.md : ce ne sont PAS
    # des clés de configuration comme les clés .vmx de VMware, mais des données
    # supplémentaires attachées à la machine.
    foreach ($p in $Brut) {
        $r = Invoke-VBoxManage @('setextradata', $nom, [string]$p.Cle, [string]$p.Valeur)
        if ($r.Code -ne 0) {
            throw (New-ErreurPilote "Impossible d'écrire le réglage « $($p.Cle) » sur $Machine : $(Get-MessageVBox $r)" `
                'Sous VirtualBox, --set écrit dans les données supplémentaires de la machine (setextradata), pas dans un fichier de configuration en texte libre. Voir docs\PILOTE-VIRTUALBOX.md.')
        }
    }
}

# Première interface hôte utilisable pour un mode donné (bridged ou hostonly).
function Get-InterfaceHote {
    param([string]$Type)
    $commande = if ($Type -eq 'bridged') { 'bridgedifs' } else { 'hostonlyifs' }
    $r = Invoke-VBoxManage @('list', $commande) -Lecture
    if ($r.Code -ne 0) { return $null }
    foreach ($l in $r.Lignes) {
        if ($l -match '^Name:\s+(.+?)\s*$') { return $Matches[1] }
    }
    return $null
}

function Set-MachineReseau {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [string[]]$Modes = @()
    )
    $nom = Get-NomMachine -Machine $Machine
    $arguments = @('modifyvm', $nom)
    $index = 0
    foreach ($mode in $Modes) {
        $index++
        # « nomme:<identifiant> » désigne un segment personnalisé : chez
        # VirtualBox, un réseau interne, désigné par son seul nom.
        if ($mode -match '^(?i)nomme:(.+)$') {
            $arguments += @("--nic$index", 'intnet', "--intnet$index", $Matches[1])
            continue
        }
        switch ($mode.ToLower()) {
            'nat' { $arguments += @("--nic$index", 'nat') }
            'bridged' {
                $arguments += @("--nic$index", 'bridged')
                $interface = Get-InterfaceHote -Type 'bridged'
                if (-not $interface) {
                    throw (New-ErreurPilote "Aucune interface réseau de l'hôte n'est disponible pour le mode « bridged »." `
                        'Vérifiez que votre carte réseau est active : VBoxManage list bridgedifs')
                }
                $arguments += @("--bridgeadapter$index", $interface)
            }
            'hostonly' {
                $arguments += @("--nic$index", 'hostonly')
                $interface = Get-InterfaceHote -Type 'hostonly'
                if (-not $interface) {
                    throw (New-ErreurPilote "Aucun réseau « host-only » n'existe sur cette machine." `
                        ("VirtualBox ne crée pas de réseau host-only par défaut, contrairement à VMware qui fournit VMnet1.`n" +
                         "Créez-en un : `"$($script:VBoxExe)`" hostonlyif create"))
                }
                $arguments += @("--hostonlyadapter$index", $interface)
            }
            default {
                throw (New-ErreurPilote "Mode réseau inconnu : $mode" 'Modes possibles : nat, bridged, hostonly.')
            }
        }
    }
    # Les cartes au-delà de celles demandées sont débranchées, pour que la
    # machine reflète exactement ce qui a été demandé.
    for ($i = $index + 1; $i -le 4; $i++) { $arguments += @("--nic$i", 'none') }

    $r = Invoke-VBoxManage $arguments
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de configurer le réseau de $Machine : $(Get-MessageVBox $r)" `
            'Vérifiez que la machine est éteinte, et que les interfaces réseau demandées existent.')
    }
}

function Start-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$SansInterface
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'démarrer'
    $nom = Get-NomMachine -Machine $Machine
    $type = if ($SansInterface) { 'headless' } else { 'gui' }
    $r = Invoke-VBoxManage @('startvm', $nom, '--type', $type)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le démarrage de $Machine a échoué : $(Get-MessageVBox $r)" `
            'Ouvrez VirtualBox et essayez de démarrer la VM à la main : le message y sera plus complet.')
    }
}

function Stop-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$Brutal
    )
    $nom = Get-NomMachine -Machine $Machine
    # acpipowerbutton = appui sur le bouton d'alimentation (arrêt propre),
    # poweroff = coupure de courant.
    $action = if ($Brutal) { 'poweroff' } else { 'acpipowerbutton' }
    $r = Invoke-VBoxManage @('controlvm', $nom, $action)
    if ($r.Code -ne 0) {
        if ($r.Sortie -match '(?i)is not currently running') { return }
        throw (New-ErreurPilote "L'arrêt de $Machine a échoué : $(Get-MessageVBox $r)" `
            'Si la VM ne répond plus, forcez l''arrêt : vazy stop <nom> --hard')
    }
}

function Remove-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Assert-MachinePasModele -Machine $Machine -Operation 'supprimer'
    $dossier = Split-Path -Parent $Machine
    $nom = $null
    try { $nom = Get-NomMachine -Machine $Machine } catch { }

    if ($nom) {
        $r = Invoke-VBoxManage @('unregistervm', $nom, '--delete')
        if ($r.Code -ne 0) {
            throw (New-ErreurPilote "La suppression de $Machine a échoué : $(Get-MessageVBox $r)" `
                'Vérifiez que la VM est éteinte et qu''aucune fenêtre VirtualBox ne l''utilise, puis réessayez.')
        }
        $script:NomsMachines.Remove($Machine.ToLower())
    }

    if ($script:Simulation) { return $null }

    # VirtualBox laisse parfois le dossier en place (fichiers qu'il ne gère
    # pas : marque de modèle, journaux). On le signale plutôt que d'effacer
    # en silence un dossier dont on ne connaît pas le contenu.
    $marque = Get-CheminMarqueModele $Machine
    if (Test-Path -LiteralPath $marque -PathType Leaf) { Remove-Item -LiteralPath $marque -Force -ErrorAction SilentlyContinue }
    if ($dossier -and (Test-Path -LiteralPath $dossier)) {
        $restes = @(Get-ChildItem -LiteralPath $dossier -Force -ErrorAction SilentlyContinue)
        if ($restes.Count -eq 0) {
            Remove-Item -LiteralPath $dossier -Force -ErrorAction SilentlyContinue
            return $null
        }
        return @{ Type = 'attention'; Message = "Le dossier $dossier n'est pas vide après la suppression ($($restes.Count) fichier(s) restant(s)) : vérifiez son contenu et supprimez-le à la main." }
    }
    return $null
}

# ----------------------------------------------------------------------------
#  Instantanés
# ----------------------------------------------------------------------------

function New-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'prendre un instantané de'
    $nomVm = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('snapshot', $nomVm, 'take', $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "L'instantané « $Nom » n'a pas pu être pris : $(Get-MessageVBox $r)" `
            'Vérifiez qu''aucun instantané ne porte déjà ce nom et qu''aucune opération n''est en cours dans VirtualBox.')
    }
}

function Restore-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'revenir à un instantané de'
    $nomVm = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('snapshot', $nomVm, 'restore', $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le retour à l'instantané « $Nom » a échoué : $(Get-MessageVBox $r)" `
            'La machine doit être éteinte. Vérifiez aussi que l''instantané existe : vazy snaps <nom>')
    }
}

function Remove-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'supprimer un instantané de'
    $nomVm = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('snapshot', $nomVm, 'delete', $Nom)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suppression de l'instantané « $Nom » a échoué : $(Get-MessageVBox $r)" `
            'Vérifiez qu''il existe (vazy snaps <nom>) et qu''aucune opération n''est en cours dans VirtualBox.')
    }
}

# ----------------------------------------------------------------------------
#  Invité
# ----------------------------------------------------------------------------

# Équivalent VirtualBox de guestinfo : les propriétés d'invité, lues dans la
# machine avec VBoxControl. Le préfixe /vazy/ isole nos clés.
function Set-MachineVariableInvite {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom,
        [string]$Valeur = ''
    )
    $nomVm = Get-NomMachine -Machine $Machine
    $cle = '/vazy/' + $Nom
    if ($Valeur -eq '') {
        $r = Invoke-VBoxManage @('guestproperty', 'unset', $nomVm, $cle)
        # Retirer une propriété absente n'est pas une erreur.
        if ($r.Code -ne 0 -and $r.Sortie -notmatch '(?i)could not find') {
            throw (New-ErreurPilote "Impossible de retirer la variable d'invité « $Nom » : $(Get-MessageVBox $r)" `
                'Vérifiez que la machine est enregistrée dans VirtualBox.')
        }
        return
    }
    $r = Invoke-VBoxManage @('guestproperty', 'set', $nomVm, $cle, $Valeur)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de déposer la variable d'invité « $Nom » : $(Get-MessageVBox $r)" `
            'Vérifiez que la machine est enregistrée dans VirtualBox.')
    }
}

function Get-MachineSystemeInvite {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $nomVm = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('showvminfo', $nomVm, '--machinereadable') -Lecture
    if ($r.Code -ne 0) { return 'inconnu' }
    $type = [string](Get-ValeurMachineReadable -Resultat $r -Cle 'ostype')
    if ($type -match '(?i)windows') { return 'windows' }
    if ($type -match '(?i)linux|ubuntu|debian|fedora|red\s*hat|suse|arch|oracle|gentoo') { return 'linux' }
    return 'inconnu'
}

function Wait-MachineOutils {
    param([Parameter(Mandatory = $true)][string]$Machine, [int]$DelaiMaxSec = 120)
    if ($script:Simulation) { & $script:Observateur 'simulation' "attente des additions invité de $Machine (au plus $DelaiMaxSec s)"; return $true }
    $nomVm = Get-NomMachine -Machine $Machine
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $dernierSignal = 0
    while ($true) {
        # Les additions invité publient cette propriété dès qu'elles tournent.
        $r = Invoke-VBoxManage @('guestproperty', 'get', $nomVm, '/VirtualBox/GuestInfo/OS/Product') -Lecture
        if ($r.Code -eq 0 -and $r.Sortie -match '(?i)^\s*Value:\s*\S') { return $true }
        $ecoule = [int]$chrono.Elapsed.TotalSeconds
        if ($ecoule -ge $DelaiMaxSec) { return $false }
        if ($ecoule - $dernierSignal -ge 15) {
            $dernierSignal = $ecoule
            & $script:Observateur 'progression' ("additions invité pas encore prêtes ({0} s sur {1})..." -f $ecoule, $DelaiMaxSec)
        }
        Start-Sleep -Seconds 3
    }
}

function Invoke-MachineScript {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Identifiants,
        [Parameter(Mandatory = $true)][string]$Systeme,
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$Tentatives = 2
    )
    $nomVm = Get-NomMachine -Machine $Machine
    $exe = if ($Systeme -eq 'windows') { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } else { '/bin/sh' }
    $argumentsInvite = if ($Systeme -eq 'windows') {
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $Script)
    } else {
        @('-c', $Script)
    }

    # Le mot de passe part par fichier et non en argument : VBoxManage le
    # permet, et une ligne de commande est visible de toute la machine dans le
    # gestionnaire des tâches. Le fichier est effacé quoi qu'il arrive.
    $fichierSecret = Join-Path ([System.IO.Path]::GetTempPath()) ('vazy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $code = 1
    try {
        if (-not $script:Simulation) {
            $clair = $Identifiants.GetNetworkCredential().Password
            [System.IO.File]::WriteAllText($fichierSecret, $clair, (New-Object System.Text.UTF8Encoding($false)))
        }
        $essai = 0
        while ($true) {
            $essai++
            $arguments = @('guestcontrol', $nomVm, 'run',
                           '--exe', $exe,
                           '--username', $Identifiants.UserName,
                           '--password-file', $fichierSecret,
                           '--') + $argumentsInvite
            $r = Invoke-VBoxManage $arguments -Secrets @($fichierSecret)
            $code = $r.Code
            if ($code -eq 0 -or $essai -ge $Tentatives) { break }
            Start-Sleep -Seconds 5
        }
    } finally {
        if (Test-Path -LiteralPath $fichierSecret) { Remove-Item -LiteralPath $fichierSecret -Force -ErrorAction SilentlyContinue }
    }
    return $code
}

# ----------------------------------------------------------------------------
#  Affichage distant (VRDE)
# ----------------------------------------------------------------------------

function Set-MachineAffichageDistant {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][bool]$Actif,
        [int]$Port = 0,
        [string]$MotDePasse = ''
    )
    $nomVm = Get-NomMachine -Machine $Machine
    if (-not $Actif) {
        $r = Invoke-VBoxManage @('modifyvm', $nomVm, '--vrde', 'off')
        if ($r.Code -ne 0) {
            throw (New-ErreurPilote "Impossible de couper l'écran distant de $Machine : $(Get-MessageVBox $r)" 'Vérifiez que la machine est enregistrée dans VirtualBox.')
        }
        return
    }

    $arguments = @('modifyvm', $nomVm, '--vrde', 'on', '--vrdeaddress', '0.0.0.0')
    if ($Port -gt 0) { $arguments += @('--vrdeport', [string]$Port) }
    $r = Invoke-VBoxManage $arguments
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible d'activer l'écran distant de $Machine : $(Get-MessageVBox $r)" `
            ("L'écran distant de VirtualBox demande une extension : le pack Oracle pour RDP, le pack VNC pour VNC.`n" +
             'Installez-en une, ou renoncez à --vnc sous VirtualBox.'))
    }

    if (Test-ExtensionVnc) {
        # Le mot de passe est passé en argument : VBoxManage n'offre pas de
        # fichier pour cette propriété. Il est masqué dans le journal.
        $r = Invoke-VBoxManage @('modifyvm', $nomVm, '--vrdeproperty', ('VNCPassword=' + $MotDePasse)) -Secrets @($MotDePasse)
        if ($r.Code -ne 0) {
            throw (New-ErreurPilote "Impossible de poser le mot de passe de l'écran distant : $(Get-MessageVBox $r)" `
                'Vérifiez que l''extension VNC de VirtualBox est bien installée : VBoxManage list extpacks')
        }
    } else {
        # RDP : l'authentification par mot de passe simple n'existe pas. On le
        # dit, plutôt que de laisser croire à une protection inexistante.
        & $script:Observateur 'journal' ("écran distant en RDP sur $Machine : le mot de passe de vazy ne s'applique pas (voir docs\PILOTE-VIRTUALBOX.md)")
    }
}

# ----------------------------------------------------------------------------
#  Empreinte, autonomie, disques
# ----------------------------------------------------------------------------

# Disques de base du dossier de la machine. Les disques différentiels créés par
# les instantanés vivent dans le sous-dossier Snapshots\ : ils sont donc
# naturellement exclus par un balayage non récursif.
function Get-MachineEmpreinte {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $dossier = Split-Path -Parent $Machine
    $disques = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath $dossier -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in '.vdi', '.vmdk', '.vhd', '.vhdx' } | Sort-Object Name)) {
        $disques[$f.Name] = [ordered]@{ taille = [long]$f.Length; modifie = $f.LastWriteTimeUtc.ToString('o') }
    }
    return $disques
}

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

# Clone complet dans un dossier voisin, suppression de l'ancienne machine, puis
# le nouveau dossier prend la place de l'ancien. VirtualBox impose des noms
# uniques : le clone porte donc un nom temporaire, renommé ensuite.
function Convert-MachineEnComplete {
    param([Parameter(Mandatory = $true)][string]$Machine, [Parameter(Mandatory = $true)][string]$Nom)
    Assert-MachinePasModele -Machine $Machine -Operation 'convertir'
    $nomVm = Get-NomMachine -Machine $Machine
    $dossier = Split-Path -Parent $Machine
    $parent = Split-Path -Parent $dossier
    $nomTemporaire = $Nom + '.freeze'
    $dossierTemporaire = Join-Path $parent $nomTemporaire

    if (Test-Path -LiteralPath $dossierTemporaire) {
        throw (New-ErreurPilote "Le dossier $dossierTemporaire existe déjà (reste d'une conversion interrompue)." 'Vérifiez son contenu, supprimez-le à la main, puis réessayez.')
    }

    $r = Invoke-VBoxManage @('clonevm', $nomVm, '--mode', 'all', '--name', $nomTemporaire, '--basefolder', $parent, '--register')
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Le clone complet a échoué : $(Get-MessageVBox $r)" `
            "Vérifiez la place disponible et que la VM est éteinte ; le dossier $dossierTemporaire peut contenir des restes à supprimer.")
    }

    if ($script:Simulation) {
        & $script:Observateur 'simulation' "suppression de $dossier, renommage de $nomTemporaire en $Nom, puis de $dossierTemporaire en $dossier"
        return $Machine
    }

    # L'ancienne machine s'en va, ce qui libère son nom et son dossier.
    Remove-Machine -Machine $Machine | Out-Null
    if (Test-Path -LiteralPath $dossier) {
        throw (New-ErreurPilote "L'ancien dossier $dossier n'a pas pu être vidé ; la machine complète est prête dans $dossierTemporaire, sous le nom « $nomTemporaire »." `
            "Supprimez $dossier à la main, renommez $dossierTemporaire en $dossier, puis ré-enregistrez la machine.")
    }

    # Le clone doit être désenregistré avant que son dossier bouge : VirtualBox
    # garde le chemin du descripteur dans son registre.
    $r = Invoke-VBoxManage @('unregistervm', $nomTemporaire)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "Impossible de désenregistrer la machine temporaire « $nomTemporaire » : $(Get-MessageVBox $r)" `
            "La machine complète existe dans $dossierTemporaire ; terminez l'opération à la main.")
    }
    Rename-Item -LiteralPath $dossierTemporaire -NewName (Split-Path -Leaf $dossier)
    $descripteurTemporaire = Join-Path $dossier ($nomTemporaire + '.vbox')
    if (Test-Path -LiteralPath $descripteurTemporaire) {
        Rename-Item -LiteralPath $descripteurTemporaire -NewName ($Nom + '.vbox')
    }
    & $script:Observateur 'journal' "renommage de $dossierTemporaire en $dossier"

    $r = Invoke-VBoxManage @('registervm', $Machine)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La machine complète est en place dans $dossier mais n'a pas pu être ré-enregistrée : $(Get-MessageVBox $r)" `
            "Ajoutez-la à la main dans VirtualBox (Machine > Ajouter), en désignant $Machine.")
    }
    $script:NomsMachines.Remove($Machine.ToLower())
    $r = Invoke-VBoxManage @('modifyvm', $Nom + '.freeze', '--name', $Nom)
    if ($r.Code -ne 0) {
        # Le nom interne reste « <nom>.freeze » : gênant à l'œil, sans effet
        # sur le fonctionnement, et rattrapable à tout moment.
        & $script:Observateur 'journal' "la machine reste nommée « $nomTemporaire » dans VirtualBox : $(Get-MessageVBox $r)"
    }
    return $Machine
}

function Get-MachineDisqueGo {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $nomVm = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('showvminfo', $nomVm, '--machinereadable') -Lecture
    if ($r.Code -ne 0) { return 0.0 }
    $total = [double]0
    foreach ($l in $r.Lignes) {
        # Exemple : "SATA-0-0"="D:\VMs\poste1\poste1.vdi"
        if ($l -match '^"[^"]+-\d+-\d+"="(.+\.(vdi|vmdk|vhd|vhdx))"\s*$') {
            $total += Get-CapaciteDisque -Chemin $Matches[1]
        }
    }
    return [math]::Round($total / 1GB, 1)
}

# ============================================================================
#  Suspension : le socle du pool de VM chaudes
# ============================================================================
#  VirtualBox appelle ça « savestate » : la mémoire part dans un .sav et la
#  machine passe à l'état « saved ». Un startvm la reprend là où elle en était.
# ============================================================================

function Suspend-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Assert-MachinePasModele -Machine $Machine -Operation 'suspendre'
    $nom = Get-NomMachine -Machine $Machine
    $r = Invoke-VBoxManage @('controlvm', $nom, 'savestate')
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La suspension de $Machine a échoué : $(Get-MessageVBox $r)" `
            'Vérifiez que la machine est bien démarrée ; une VM qui n''a pas fini de démarrer refuse parfois de se suspendre.')
    }
}

function Resume-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$SansInterface
    )
    Assert-MachinePasModele -Machine $Machine -Operation 'reprendre'
    $nom = Get-NomMachine -Machine $Machine
    $type = if ($SansInterface) { 'headless' } else { 'gui' }
    $r = Invoke-VBoxManage @('startvm', $nom, '--type', $type)
    if ($r.Code -ne 0) {
        throw (New-ErreurPilote "La reprise de $Machine a échoué : $(Get-MessageVBox $r)" `
            'L''état sauvegardé est peut-être périmé. Reprenez la machine à la main dans VirtualBox pour voir le message complet.')
    }
}

function Test-MachineSuspendue {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $nom = $null
    try { $nom = Get-NomMachine -Machine $Machine } catch { return $false }
    $r = Invoke-VBoxManage @('showvminfo', $nom, '--machinereadable') -Lecture
    if ($r.Code -ne 0) { return $false }
    return ([string](Get-ValeurMachineReadable -Resultat $r -Cle 'VMState') -ieq 'saved')
}

function Get-MachineVariableInvite {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    $nom = $null
    try { $nom = Get-NomMachine -Machine $Machine } catch { return '' }
    $r = Invoke-VBoxManage @('guestproperty', 'get', $nom, ('/vazy/' + $Nom)) -Lecture
    if ($r.Code -ne 0) { return '' }
    foreach ($l in $r.Lignes) {
        if ($l -match '^\s*Value:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Get-MachineOccupationGo {
    param([Parameter(Mandatory = $true)][string]$Machine)
    $dossier = Split-Path -Parent $Machine
    $differentiel = [long]0
    $suspension   = [long]0
    $autres       = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $dossier -File -Recurse -ErrorAction SilentlyContinue)) {
        switch -Regex ($f.Extension) {
            '(?i)^\.(vdi|vmdk|vhd|vhdx)$' { $differentiel += [long]$f.Length; continue }
            '(?i)^\.sav$'                 { $suspension   += [long]$f.Length; continue }
            default                       { $autres       += [long]$f.Length }
        }
    }
    $total = $differentiel + $suspension + $autres
    return @{
        Differentiel = [math]::Round($differentiel / 1GB, 2)
        Suspension   = [math]::Round($suspension / 1GB, 2)
        Autres       = [math]::Round($autres / 1GB, 2)
        Total        = [math]::Round($total / 1GB, 2)
    }
}

# ============================================================================
#  Segments réseau personnalisés
# ============================================================================
#  Chez VirtualBox ce sont les « réseaux internes » (intnet), et c'est
#  beaucoup plus simple que chez VMware : un réseau interne n'existe que par
#  son nom. Il apparaît dès qu'une machine s'y rattache et disparaît quand
#  plus personne ne l'utilise. Rien à créer, rien à supprimer, et surtout
#  aucun droit d'administrateur — là où vnetlib les exige.
#
#  New-ReseauNomme et Remove-ReseauNomme n'ont donc presque rien à faire ; ce
#  n'est pas un oubli, c'est la nature du mécanisme.
# ============================================================================

function Get-ReseauxNommes {
    $r = Invoke-VBoxManage @('list', 'intnets') -Lecture
    $reseaux = @()
    if ($r.Code -ne 0) { return $reseaux }
    foreach ($l in $r.Lignes) {
        if ($l -match '^Name:\s+(.+?)\s*$') {
            # Un réseau interne ne porte ni adresse ni masque : c'est un
            # segment de niveau 2, l'adressage est l'affaire des invités.
            $reseaux += @{ Identifiant = $Matches[1]; Adresse = ''; Masque = ''; Dhcp = $false }
        }
    }
    return $reseaux
}

function New-ReseauNomme {
    param(
        [string]$Identifiant = '',
        [string]$Adresse = '',
        [string]$Masque = '255.255.255.0',
        [bool]$Dhcp = $false
    )
    if (-not $Identifiant) {
        # Aucun numéro à allouer : on fabrique un nom qui ne risque pas de
        # heurter un réseau interne existant.
        $Identifiant = 'vazy-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    if ($Adresse) {
        & $script:Observateur 'journal' "segment $Identifiant : l'adresse $Adresse est ignorée, un réseau interne VirtualBox n'a pas d'adressage propre (voir docs\PILOTE-VIRTUALBOX.md)"
    }
    if ($Dhcp) {
        & $script:Observateur 'journal' "segment $Identifiant : aucun serveur DHCP n'est fourni sur un réseau interne VirtualBox"
    }
    return $Identifiant
}

function Remove-ReseauNomme {
    param([Parameter(Mandatory = $true)][string]$Identifiant)
    # Un réseau interne disparaît de lui-même dès que plus aucune machine ne
    # s'y rattache. Rien à faire, et rien à signaler comme une erreur.
    & $script:Observateur 'journal' "segment $Identifiant : rien à supprimer, un réseau interne VirtualBox disparaît quand plus personne ne l'utilise"
}

# Capacité déclarée d'un disque, en octets (0 si illisible).
function Get-CapaciteDisque {
    param([string]$Chemin)
    if (-not (Test-Path -LiteralPath $Chemin -PathType Leaf)) { return [long]0 }
    try {
        $r = Invoke-VBoxManage @('showmediuminfo', 'disk', $Chemin) -Lecture
        if ($r.Code -ne 0) { return [long]0 }
        foreach ($l in $r.Lignes) {
            if ($l -match '^Capacity:\s+(\d+)\s+MBytes') { return ([long]$Matches[1] * 1MB) }
        }
    } catch { }
    return [long]0
}
