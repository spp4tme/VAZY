# ============================================================================
#  vazy - faux pilote pour les tests
# ============================================================================
#  Implémente le contrat décrit en tête de lib\pilote-vmware.ps1, mais sans
#  hyperviseur : l'état des machines est tenu en mémoire et chaque appel reçu
#  est journalisé (fonction et paramètres). Les tests interrogent ensuite ce
#  journal pour vérifier ce que la logique a demandé — et surtout ce qu'elle
#  n'a PAS demandé.
#
#  Il crée tout de même des fichiers vides sur le disque, dans un dossier
#  temporaire : la logique fait de vrais Test-Path sur les chemins de machines
#  (« la VM existe-t-elle encore ? »), et un pilote purement en mémoire la
#  ferait conclure que toutes les VM ont disparu.
#
#  L'état vit dans $global:VazyFake. Un global se justifie ici : ce fichier est
#  chargé par point-source à travers deux niveaux (le test charge logique.ps1
#  qui charge ce pilote), et $script: y désignerait des portées différentes
#  selon le niveau.
#
#  Chargé par $env:VAZY_PILOTE (voir la fin de lib\logique.ps1).
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
#  État et outils réservés aux tests
# ----------------------------------------------------------------------------

function Reset-PiloteFake {
    <#
        Remet le faux pilote à zéro. À appeler avant chaque test.
        -DossierTravail : où poser les fichiers témoins des machines.
    #>
    param([string]$DossierTravail = $env:TEMP)
    $global:VazyFake = @{
        DossierTravail  = $DossierTravail
        Appels          = New-Object System.Collections.Generic.List[object]
        Machines        = @{}      # chemin -> état de la machine
        Modeles         = @{}      # chemin -> @{ Instantanes ; Empreinte ; DisqueGo }
        Reseaux         = @{}      # identifiant -> @{ Adresse ; Masque ; Dhcp }
        ProchainSegment = 2        # numéro du prochain segment alloué
        Echecs          = @{}      # nom de fonction -> @{ Message ; Conseil ; Restant }
        Systeme         = 'linux'  # ce que renvoie Get-MachineSystemeInvite
        OutilsRepondent = $true    # ce que renvoie Wait-MachineOutils
        InvitePoolRepond = $true   # l'invité honore-t-il la poignée de main du pool ?
        CodeScript      = 0        # ce que renvoie Invoke-MachineScript
        Observateur     = { param($Type, $Message) }
        Simulation      = $false
    }
}

# ----------------------------------------------------------------------------
#  Persistance entre deux processus
#  Les tests unitaires chargent la logique dans leur propre processus : la
#  mémoire suffit. Les tests d'intégration lancent vazy.cmd, donc un processus
#  neuf par commande ; sans persistance, le faux pilote y oublierait les
#  modèles déclarés et les machines créées. Activée par $env:VAZY_FAKE_ETAT.
#  Export-Clixml plutôt que JSON : il rend les tables de hachage telles quelles.
# ----------------------------------------------------------------------------

function Save-EtatFake {
    if (-not $env:VAZY_FAKE_ETAT) { return }
    # L'observateur est un scriptblock : il ne se sérialise pas, et la logique
    # le rebranche de toute façon à chaque démarrage.
    $aGarder = @{
        DossierTravail  = $global:VazyFake.DossierTravail
        Machines        = $global:VazyFake.Machines
        Modeles         = $global:VazyFake.Modeles
        Reseaux         = $global:VazyFake.Reseaux
        ProchainSegment = $global:VazyFake.ProchainSegment
        Systeme         = $global:VazyFake.Systeme
        OutilsRepondent = $global:VazyFake.OutilsRepondent
        CodeScript      = $global:VazyFake.CodeScript
        Appels          = $global:VazyFake.Appels.ToArray()   # @() échouerait sur une liste vide
    }
    try { $aGarder | Export-Clixml -LiteralPath $env:VAZY_FAKE_ETAT -Depth 8 } catch { }
}

function Restore-EtatFake {
    if (-not $env:VAZY_FAKE_ETAT) { return }
    if (-not (Test-Path -LiteralPath $env:VAZY_FAKE_ETAT -PathType Leaf)) { return }
    try {
        $lu = Import-Clixml -LiteralPath $env:VAZY_FAKE_ETAT
        $global:VazyFake.DossierTravail  = $lu.DossierTravail
        $global:VazyFake.Machines        = $lu.Machines
        $global:VazyFake.Modeles         = $lu.Modeles
        if ($null -ne $lu.Reseaux)         { $global:VazyFake.Reseaux         = $lu.Reseaux }
        if ($null -ne $lu.ProchainSegment) { $global:VazyFake.ProchainSegment = $lu.ProchainSegment }
        $global:VazyFake.Systeme         = $lu.Systeme
        $global:VazyFake.OutilsRepondent = $lu.OutilsRepondent
        $global:VazyFake.CodeScript      = $lu.CodeScript
        if ($null -ne $lu.Appels) { foreach ($a in $lu.Appels) { $global:VazyFake.Appels.Add($a) } }
    } catch { }
}

# Journalise un appel puis déclenche l'échec programmé s'il y en a un.
function Write-AppelFake {
    param([string]$Fonction, [hashtable]$Parametres = @{})
    $global:VazyFake.Appels.Add([pscustomobject]@{
        Fonction   = $Fonction
        Parametres = $Parametres
        Rang       = $global:VazyFake.Appels.Count + 1
    })
    Save-EtatFake
    if ($global:VazyFake.Echecs.ContainsKey($Fonction)) {
        $e = $global:VazyFake.Echecs[$Fonction]
        if ($e.Saut -gt 0) {
            $e.Saut--            # on laisse passer les premiers appels
        } elseif ($e.Restant -gt 0) {
            $e.Restant--
            if ($e.Restant -eq 0) { $global:VazyFake.Echecs.Remove($Fonction) }
            throw (New-ErreurFake $e.Message $e.Conseil)
        }
    }
}

function New-ErreurFake {
    param([string]$Message, [string]$Conseil)
    $e = New-Object System.Exception($Message)
    $e.Data['Conseil'] = $Conseil
    return $e
}

function Get-AppelsPilote {
    <# Les appels reçus, éventuellement filtrés sur un nom de fonction. #>
    param([string]$Fonction = '')
    # .ToArray() et non @() : en PowerShell 5.1, @() sur une List[object] vide
    # lève « Les types des arguments ne correspondent pas ».
    $tous = $global:VazyFake.Appels.ToArray()
    if ($Fonction) { return @($tous | Where-Object { $_.Fonction -eq $Fonction }) }
    return $tous
}

function Test-AppelPilote {
    <# La fonction a-t-elle été appelée au moins une fois ? #>
    param([Parameter(Mandatory = $true)][string]$Fonction)
    # @() indispensable : PowerShell déballe un tableau d'un seul élément au
    # retour d'une fonction, et .Count sur un scalaire échoue en StrictMode.
    return (@(Get-AppelsPilote -Fonction $Fonction).Count -gt 0)
}

function Set-EchecPilote {
    <#
        Programme un échec : un prochain appel à $Fonction lèvera une erreur.
        -Fois : nombre d'appels à faire échouer (1 par défaut).
        -Saut : nombre d'appels à laisser passer avant de commencer à échouer
                (pour faire échouer la deuxième VM d'un labo, par exemple).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Fonction,
        [string]$Message = 'échec simulé par le faux pilote',
        [string]$Conseil = 'Ceci est un test.',
        [int]$Fois = 1,
        [int]$Saut = 0
    )
    $global:VazyFake.Echecs[$Fonction] = @{ Message = $Message; Conseil = $Conseil; Restant = $Fois; Saut = $Saut }
}

function Register-ModeleFake {
    <#
        Déclare un modèle : crée son fichier témoin et son instantané d'ancrage,
        pour que la logique le trouve valide.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Chemin,
        [string]$Instantane = 'base',
        [hashtable]$Empreinte = $null,
        [double]$DisqueGo = 40
    )
    $dossier = Split-Path -Parent $Chemin
    if (-not (Test-Path -LiteralPath $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Chemin)) { New-Item -ItemType File -Path $Chemin -Force | Out-Null }
    if ($null -eq $Empreinte) { $Empreinte = [ordered]@{ 'base.vmdk' = [ordered]@{ taille = [long]1024; modifie = '2026-01-01T00:00:00.0000000Z' } } }
    $global:VazyFake.Modeles[$Chemin] = @{
        Instantanes = @($Instantane)
        Empreinte   = $Empreinte
        DisqueGo    = $DisqueGo
    }
    Save-EtatFake
    return $Chemin
}

function Get-EtatMachineFake {
    <# L'état interne d'une machine, pour les vérifications fines. #>
    param([Parameter(Mandatory = $true)][string]$Chemin)
    if (-not $global:VazyFake.Machines.ContainsKey($Chemin)) { return $null }
    return $global:VazyFake.Machines[$Chemin]
}

function Set-MachineEnMarcheFake {
    <# Force l'état « en marche » d'une machine sans passer par Start-Machine. #>
    param([Parameter(Mandatory = $true)][string]$Chemin, [bool]$EnMarche = $true)
    if ($global:VazyFake.Machines.ContainsKey($Chemin)) { $global:VazyFake.Machines[$Chemin].EnMarche = $EnMarche }
}

# Refus miroir de celui du vrai pilote : une machine marquée modèle est
# intouchable, quoi que dise le catalogue.
function Assert-PasModeleFake {
    param([string]$Machine, [string]$Operation)
    # Comme le vrai pilote : on interroge Test-MachineModele, qui retombe sur le
    # fichier témoin. Un modèle enregistré n'existe pas forcément dans l'état
    # mémoire des machines (il n'a pas été créé par le faux pilote).
    if (Test-MachineModele -Machine $Machine) {
        throw (New-ErreurFake "Refus de $Operation : $Machine est marquée comme modèle." `
            "Un modèle sert uniquement de base aux clones liés.")
    }
}

# ----------------------------------------------------------------------------
#  Contrat : observation
# ----------------------------------------------------------------------------

function Set-PiloteObservateur {
    param([scriptblock]$Observateur, [bool]$Simulation = $false)
    if ($Observateur) { $global:VazyFake.Observateur = $Observateur }
    $global:VazyFake.Simulation = $Simulation
}

# ----------------------------------------------------------------------------
#  Contrat : description et lectures
# ----------------------------------------------------------------------------

function Initialize-Pilote {
    param([string]$CheminForce)
    Write-AppelFake 'Initialize-Pilote' @{ CheminForce = $CheminForce }
    return [ordered]@{
        Nom               = 'Faux hyperviseur (tests)'
        Executable        = 'faux-vmrun.exe'
        ExtensionMachine  = '.vmx'
        # $false : les tests ne dépendent pas de la présence d'Hyper-V sur la
        # machine qui les exécute (Invoke-AvertissementHyperV sort aussitôt).
        SensibleHyperV    = $false
        ConseilInstantane = 'Prenez un instantané nommé « base » ({0} sur {1}).'
        SchemaAffichageDistant = 'vnc'
    }
}

function Get-MachineEnCours {
    Write-AppelFake 'Get-MachineEnCours'
    $enCours = @()
    foreach ($chemin in @($global:VazyFake.Machines.Keys)) {
        if ($global:VazyFake.Machines[$chemin].EnMarche) { $enCours += $chemin }
    }
    return $enCours
}

function Get-MachineInstantanes {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Get-MachineInstantanes' @{ Machine = $Machine }
    if ($global:VazyFake.Modeles.ContainsKey($Machine)) { return @($global:VazyFake.Modeles[$Machine].Instantanes) }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { return @($global:VazyFake.Machines[$Machine].Instantanes) }
    return @()
}

# ----------------------------------------------------------------------------
#  Contrat : les six opérations
# ----------------------------------------------------------------------------

function New-MachineDepuisModele {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][string]$Instantane,
        [Parameter(Mandatory = $true)][string]$Dossier,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Write-AppelFake 'New-MachineDepuisModele' @{ Modele = $Modele; Instantane = $Instantane; Dossier = $Dossier; Nom = $Nom }
    $chemin = Join-Path $Dossier ($Nom + '.vmx')
    if (-not (Test-Path -LiteralPath $Dossier)) { New-Item -ItemType Directory -Path $Dossier -Force | Out-Null }
    New-Item -ItemType File -Path $chemin -Force | Out-Null
    $global:VazyFake.Machines[$chemin] = @{
        Chemin      = $chemin
        Nom         = $Nom
        Dossier     = $Dossier
        Modele      = $Modele
        Instantane  = $Instantane
        RamMo       = 0
        Cpu         = 0
        Modes       = @()
        Brut        = @{}
        Instantanes = @()
        EnMarche    = $false
        Suspendue   = $false      # pool : mémoire figée sur le disque
        EstModele   = $false
        Variables   = @{}         # ce que vazy a déposé pour l'invité
        VariablesInvite = @{}     # ce que l'invité a répondu à vazy
        OccupationGo = 0.5        # place prise sur le disque, hors suspension
        Vnc         = @{ Actif = $false; Port = 0; MotDePasse = '' }
        Complete    = $false
    }
    Save-EtatFake
    return $chemin
}

function Set-MachineParametres {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [int]$RamMo = 0,
        [int]$Cpu = 0,
        [object[]]$Brut = @()
    )
    Write-AppelFake 'Set-MachineParametres' @{ Machine = $Machine; RamMo = $RamMo; Cpu = $Cpu; Brut = $Brut }
    if (-not $global:VazyFake.Machines.ContainsKey($Machine)) { return }
    $etat = $global:VazyFake.Machines[$Machine]
    if ($RamMo -gt 0) { $etat.RamMo = $RamMo }
    if ($Cpu -gt 0) { $etat.Cpu = $Cpu }
    foreach ($p in $Brut) { $etat.Brut[$p.Cle] = $p.Valeur }
    Save-EtatFake
}

function Set-MachineReseau {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [string[]]$Modes = @()
    )
    Write-AppelFake 'Set-MachineReseau' @{ Machine = $Machine; Modes = $Modes }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { $global:VazyFake.Machines[$Machine].Modes = @($Modes) }
    Save-EtatFake
}

function Start-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$SansInterface
    )
    Write-AppelFake 'Start-Machine' @{ Machine = $Machine; SansInterface = [bool]$SansInterface }
    Assert-PasModeleFake -Machine $Machine -Operation 'démarrer'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        $etat.EnMarche = $true
        # Un invité coopératif : s'il reçoit « mode: pool », il fait son travail
        # puis s'annonce prêt à être figé. $global:VazyFake.InvitePoolRepond
        # permet de jouer l'inverse — un modèle dont le script est trop ancien.
        if ($global:VazyFake.InvitePoolRepond -and $etat.Variables.ContainsKey('vazy_config')) {
            $json = ''
            try { $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$etat.Variables['vazy_config'])) } catch { }
            if ($json -match '"mode"\s*:\s*"pool"') { $etat.VariablesInvite['vazy_pool_pret'] = '1' }
        }
    }
    Save-EtatFake
}

function Stop-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$Brutal
    )
    Write-AppelFake 'Stop-Machine' @{ Machine = $Machine; Brutal = [bool]$Brutal }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { $global:VazyFake.Machines[$Machine].EnMarche = $false }
    Save-EtatFake
}

function Remove-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Remove-Machine' @{ Machine = $Machine }
    Assert-PasModeleFake -Machine $Machine -Operation 'supprimer'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $dossier = $global:VazyFake.Machines[$Machine].Dossier
        $global:VazyFake.Machines.Remove($Machine)
        if ($dossier -and (Test-Path -LiteralPath $dossier)) { Remove-Item -LiteralPath $dossier -Recurse -Force -ErrorAction SilentlyContinue }
    } elseif (Test-Path -LiteralPath $Machine) {
        Remove-Item -LiteralPath $Machine -Force -ErrorAction SilentlyContinue
    }
    Save-EtatFake
    return $null
}

# ----------------------------------------------------------------------------
#  Contrat : instantanés
# ----------------------------------------------------------------------------

function New-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Write-AppelFake 'New-MachineInstantane' @{ Machine = $Machine; Nom = $Nom }
    Assert-PasModeleFake -Machine $Machine -Operation 'prendre un instantané de'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        if ($etat.Instantanes -notcontains $Nom) { $etat.Instantanes = @($etat.Instantanes) + $Nom }
    }
    Save-EtatFake
}

function Restore-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Write-AppelFake 'Restore-MachineInstantane' @{ Machine = $Machine; Nom = $Nom }
    Assert-PasModeleFake -Machine $Machine -Operation 'revenir à un instantané de'
}

function Remove-MachineInstantane {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Write-AppelFake 'Remove-MachineInstantane' @{ Machine = $Machine; Nom = $Nom }
    Assert-PasModeleFake -Machine $Machine -Operation 'supprimer un instantané de'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        $etat.Instantanes = @($etat.Instantanes | Where-Object { $_ -ne $Nom })
    }
    Save-EtatFake
}

# ----------------------------------------------------------------------------
#  Contrat : marque « modèle »
# ----------------------------------------------------------------------------

function Test-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { return [bool]$global:VazyFake.Machines[$Machine].EstModele }
    return (Test-Path -LiteralPath ($Machine + '.vazy-modele') -PathType Leaf)
}

function Protect-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Protect-MachineModele' @{ Machine = $Machine }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { $global:VazyFake.Machines[$Machine].EstModele = $true }
    New-Item -ItemType File -Path ($Machine + '.vazy-modele') -Force | Out-Null
    Save-EtatFake
}

function Unprotect-MachineModele {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Unprotect-MachineModele' @{ Machine = $Machine }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) { $global:VazyFake.Machines[$Machine].EstModele = $false }
    if (Test-Path -LiteralPath ($Machine + '.vazy-modele')) { Remove-Item -LiteralPath ($Machine + '.vazy-modele') -Force }
    Save-EtatFake
}

# ----------------------------------------------------------------------------
#  Contrat : invité
# ----------------------------------------------------------------------------

function Set-MachineVariableInvite {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom,
        [string]$Valeur = ''
    )
    Write-AppelFake 'Set-MachineVariableInvite' @{ Machine = $Machine; Nom = $Nom; Valeur = $Valeur }
    if (-not $global:VazyFake.Machines.ContainsKey($Machine)) { return }
    $vars = $global:VazyFake.Machines[$Machine].Variables
    if ($Valeur -eq '') { $vars.Remove($Nom) } else { $vars[$Nom] = $Valeur }
    Save-EtatFake
}

function Get-MachineSystemeInvite {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Get-MachineSystemeInvite' @{ Machine = $Machine }
    return $global:VazyFake.Systeme
}

function Wait-MachineOutils {
    param([Parameter(Mandatory = $true)][string]$Machine, [int]$DelaiMaxSec = 120)
    Write-AppelFake 'Wait-MachineOutils' @{ Machine = $Machine; DelaiMaxSec = $DelaiMaxSec }
    return $global:VazyFake.OutilsRepondent
}

function Invoke-MachineScript {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Identifiants,
        [Parameter(Mandatory = $true)][string]$Systeme,
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$Tentatives = 2
    )
    # Le mot de passe n'est volontairement pas journalisé : le contrat interdit
    # qu'il apparaisse où que ce soit, et un test le vérifie.
    Write-AppelFake 'Invoke-MachineScript' @{ Machine = $Machine; Utilisateur = $Identifiants.UserName; Systeme = $Systeme; Script = $Script }
    return $global:VazyFake.CodeScript
}

# ----------------------------------------------------------------------------
#  Contrat : affichage distant
# ----------------------------------------------------------------------------

function Set-MachineAffichageDistant {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][bool]$Actif,
        [int]$Port = 0,
        [string]$MotDePasse = ''
    )
    # Le mot de passe n'est pas journalisé, pour la même raison qu'au-dessus.
    Write-AppelFake 'Set-MachineAffichageDistant' @{ Machine = $Machine; Actif = $Actif; Port = $Port }
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $global:VazyFake.Machines[$Machine].Vnc = @{ Actif = $Actif; Port = $Port; MotDePasse = $MotDePasse }
    }
    Save-EtatFake
}

# ----------------------------------------------------------------------------
#  Contrat : empreinte, autonomie, disques
# ----------------------------------------------------------------------------

function Get-MachineEmpreinte {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Get-MachineEmpreinte' @{ Machine = $Machine }
    if ($global:VazyFake.Modeles.ContainsKey($Machine)) { return $global:VazyFake.Modeles[$Machine].Empreinte }
    return [ordered]@{}
}

function Test-MachineEmpreinte {
    param([Parameter(Mandatory = $true)][string]$Machine, [Parameter(Mandatory = $true)]$Empreinte)
    Write-AppelFake 'Test-MachineEmpreinte' @{ Machine = $Machine; Empreinte = $Empreinte }
    $erreurs = @(); $attentions = @()
    $actuelle = if ($global:VazyFake.Modeles.ContainsKey($Machine)) { $global:VazyFake.Modeles[$Machine].Empreinte } else { [ordered]@{} }
    foreach ($nom in @($Empreinte.Keys)) {
        if (-not $actuelle.Contains($nom)) { $erreurs += "disque de base manquant : $nom"; continue }
        if ([long]$actuelle[$nom]['taille'] -ne [long]$Empreinte[$nom]['taille']) {
            $erreurs += ("disque de base modifié : {0} ({1} octets à la création du clone, {2} maintenant)" -f $nom, $Empreinte[$nom]['taille'], $actuelle[$nom]['taille'])
        } elseif ([string]$actuelle[$nom]['modifie'] -ne [string]$Empreinte[$nom]['modifie']) {
            $attentions += "disque de base retouché sans changement de taille : $nom"
        }
    }
    return @{ Erreurs = $erreurs; Attentions = $attentions }
}

function Convert-MachineEnComplete {
    param([Parameter(Mandatory = $true)][string]$Machine, [Parameter(Mandatory = $true)][string]$Nom)
    Write-AppelFake 'Convert-MachineEnComplete' @{ Machine = $Machine; Nom = $Nom }
    Assert-PasModeleFake -Machine $Machine -Operation 'convertir'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        $etat.Complete    = $true
        $etat.Instantanes = @()    # un clone complet ne conserve pas les instantanés
    }
    Save-EtatFake
    return $Machine
}

function Get-MachineDisqueGo {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Get-MachineDisqueGo' @{ Machine = $Machine }
    if ($global:VazyFake.Modeles.ContainsKey($Machine)) { return [double]$global:VazyFake.Modeles[$Machine].DisqueGo }
    return 0.0
}

# ----------------------------------------------------------------------------
#  Contrat : suspension (pool de VM chaudes)
# ----------------------------------------------------------------------------

function Suspend-Machine {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Suspend-Machine' @{ Machine = $Machine }
    Assert-PasModeleFake -Machine $Machine -Operation 'suspendre'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        $etat.EnMarche  = $false
        $etat.Suspendue = $true
    }
    Save-EtatFake
}

function Resume-Machine {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [switch]$SansInterface
    )
    Write-AppelFake 'Resume-Machine' @{ Machine = $Machine; SansInterface = [bool]$SansInterface }
    Assert-PasModeleFake -Machine $Machine -Operation 'reprendre'
    if ($global:VazyFake.Machines.ContainsKey($Machine)) {
        $etat = $global:VazyFake.Machines[$Machine]
        $etat.EnMarche  = $true
        $etat.Suspendue = $false
    }
    Save-EtatFake
}

function Test-MachineSuspendue {
    param([Parameter(Mandatory = $true)][string]$Machine)
    if (-not $global:VazyFake.Machines.ContainsKey($Machine)) { return $false }
    return [bool]$global:VazyFake.Machines[$Machine].Suspendue
}

function Get-MachineVariableInvite {
    param(
        [Parameter(Mandatory = $true)][string]$Machine,
        [Parameter(Mandatory = $true)][string]$Nom
    )
    Write-AppelFake 'Get-MachineVariableInvite' @{ Machine = $Machine; Nom = $Nom }
    if (-not $global:VazyFake.Machines.ContainsKey($Machine)) { return '' }
    $vars = $global:VazyFake.Machines[$Machine].VariablesInvite
    if ($vars.ContainsKey($Nom)) { return [string]$vars[$Nom] }
    return ''
}

function Get-MachineOccupationGo {
    param([Parameter(Mandatory = $true)][string]$Machine)
    Write-AppelFake 'Get-MachineOccupationGo' @{ Machine = $Machine }
    if (-not $global:VazyFake.Machines.ContainsKey($Machine)) {
        return @{ Differentiel = 0.0; Suspension = 0.0; Autres = 0.0; Total = 0.0 }
    }
    $etat = $global:VazyFake.Machines[$Machine]
    $suspension = if ($etat.Suspendue) { [math]::Round($etat.RamMo / 1024.0, 2) } else { 0.0 }
    return @{
        Differentiel = [double]$etat.OccupationGo
        Suspension   = $suspension
        Autres       = 0.0
        Total        = [math]::Round([double]$etat.OccupationGo + $suspension, 2)
    }
}

# Réservé aux tests : ce que l'invité a « répondu » à vazy.
function Set-VariableInviteFake {
    param([Parameter(Mandatory = $true)][string]$Chemin, [Parameter(Mandatory = $true)][string]$Nom, [string]$Valeur = '1')
    if ($global:VazyFake.Machines.ContainsKey($Chemin)) {
        $global:VazyFake.Machines[$Chemin].VariablesInvite[$Nom] = $Valeur
    }
}

# Réservé aux tests : la place que prend une machine sur le disque.
function Set-OccupationFake {
    param([Parameter(Mandatory = $true)][string]$Chemin, [double]$Go = 1.0)
    if ($global:VazyFake.Machines.ContainsKey($Chemin)) {
        $global:VazyFake.Machines[$Chemin].OccupationGo = $Go
    }
}

# ----------------------------------------------------------------------------
#  Contrat : segments réseau personnalisés
# ----------------------------------------------------------------------------

function Get-ReseauxNommes {
    Write-AppelFake 'Get-ReseauxNommes'
    $reseaux = @()
    foreach ($id in @($global:VazyFake.Reseaux.Keys)) {
        $r = $global:VazyFake.Reseaux[$id]
        $reseaux += @{ Identifiant = $id; Adresse = $r.Adresse; Masque = $r.Masque; Dhcp = $r.Dhcp }
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
    Write-AppelFake 'New-ReseauNomme' @{ Identifiant = $Identifiant; Adresse = $Adresse; Masque = $Masque; Dhcp = $Dhcp }
    if (-not $Identifiant) {
        $Identifiant = 'segment' + $global:VazyFake.ProchainSegment
        $global:VazyFake.ProchainSegment++
    }
    $global:VazyFake.Reseaux[$Identifiant] = @{ Adresse = $Adresse; Masque = $Masque; Dhcp = $Dhcp }
    Save-EtatFake
    return $Identifiant
}

function Remove-ReseauNomme {
    param([Parameter(Mandatory = $true)][string]$Identifiant)
    Write-AppelFake 'Remove-ReseauNomme' @{ Identifiant = $Identifiant }
    $global:VazyFake.Reseaux.Remove($Identifiant)
    Save-EtatFake
}

# État initial, pour que le simple chargement du pilote suffise ; puis reprise
# de l'état laissé par le processus précédent quand la persistance est demandée
# (tests d'intégration : une commande vazy = un processus neuf).
Reset-PiloteFake
Restore-EtatFake
