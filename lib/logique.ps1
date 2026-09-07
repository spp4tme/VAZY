# ============================================================================
#  vazy - couche 2 : logique
# ============================================================================
#  Décide quoi faire : catalogue des modèles et des VM, vérifications
#  (Hyper-V, espace disque, noms), enchaînement des opérations du pilote.
#
#  Cette couche ne connaît ni la ligne de commande (couche 1 : interface.ps1),
#  ni l'hyperviseur (couche 3 : pilote-*.ps1). Elle parle au pilote via
#  le contrat décrit en tête de pilote-vmware.ps1, et à l'interface via
#  Publish-Message (l'interface fournit l'afficheur avec Set-Afficheur).
#
#  Données de l'outil (dans %LOCALAPPDATA%\vazy, ou $env:VAZY_HOME) :
#    config.json     réglages (hyperviseur, dossier des VM, outil de l'hyperviseur...)
#    catalogue.json  modèles enregistrés et VM créées
# ============================================================================

$script:NomOutil       = 'vazy'
$script:VersionOutil   = '1.0.0'
$script:DossierDonnees = if ($env:VAZY_HOME) { $env:VAZY_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'vazy' }
$script:CheminConfig    = Join-Path $script:DossierDonnees 'config.json'
$script:CheminCatalogue = Join-Path $script:DossierDonnees 'catalogue.json'
$script:DossierLib     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Config         = $null
$script:Catalogue      = $null
$script:Pilote         = $null      # description renvoyée par Initialize-Pilote (chargée à la demande)
$script:InfosHote      = $null      # résultat de l'interrogation WMI (une seule fois par exécution)
$script:Afficheur      = { param($Type, $Message) }   # remplacé par l'interface
$script:MotsReserves   = @('list', 'start', 'stop', 'rm', 'template', 'config', 'help', 'version')

# ----------------------------------------------------------------------------
#  Messages et erreurs
# ----------------------------------------------------------------------------

# L'interface enregistre ici la fonction qui affiche les messages.
# Types émis : etape, ok, info, detail, attention.
function Set-Afficheur {
    param([scriptblock]$Afficheur)
    $script:Afficheur = $Afficheur
}

function Publish-Message {
    param([string]$Type, [string]$Message)
    & $script:Afficheur $Type $Message
}

function Publish-Etape {
    param([int]$Numero, [int]$Total, [string]$Titre)
    Publish-Message 'etape' ('[{0}/{1}] {2}' -f $Numero, $Total, $Titre)
}

# Exception "propre" : message (ce qui a raté) + conseil (quoi faire).
function New-ErreurOutil {
    param([string]$Message, [string]$Conseil)
    $e = New-Object System.Exception($Message)
    $e.Data['Conseil'] = $Conseil
    return $e
}

function Format-Duree {
    param([double]$Secondes)
    return ('{0:0.0} s' -f $Secondes)
}

# ----------------------------------------------------------------------------
#  Fichiers JSON : configuration et catalogue
# ----------------------------------------------------------------------------

# Dictionnaire ordonné et insensible à la casse (les noms de VM le sont aussi).
function New-Dictionnaire {
    return New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
}

# ConvertFrom-Json produit des PSCustomObject ; on les transforme en
# dictionnaires, plus pratiques à modifier et à parcourir.
function ConvertTo-Dictionnaire {
    param($Objet)
    if ($null -eq $Objet) { return $null }
    if ($Objet -is [System.Management.Automation.PSCustomObject]) {
        $d = New-Dictionnaire
        foreach ($p in $Objet.PSObject.Properties) { $d[$p.Name] = ConvertTo-Dictionnaire $p.Value }
        return $d
    }
    if ($Objet -is [System.Collections.IDictionary]) {
        $d = New-Dictionnaire
        foreach ($k in $Objet.Keys) { $d[$k] = ConvertTo-Dictionnaire $Objet[$k] }
        return $d
    }
    if ($Objet -is [array]) {
        $liste = @()
        foreach ($e in $Objet) { $liste += , (ConvertTo-Dictionnaire $e) }
        return , $liste
    }
    return $Objet
}

function Read-FichierJson {
    param([string]$Chemin)
    if (-not (Test-Path -LiteralPath $Chemin -PathType Leaf)) { return $null }
    try {
        $texte = [System.IO.File]::ReadAllText($Chemin)
        if ([string]::IsNullOrWhiteSpace($texte)) { return $null }
        return ConvertTo-Dictionnaire (ConvertFrom-Json -InputObject $texte)
    } catch {
        throw (New-ErreurOutil "Le fichier $Chemin est illisible : $($_.Exception.Message)" `
            "Corrigez-le (c'est du JSON) ou supprimez-le : il sera recréé avec les valeurs par défaut.")
    }
}

function Write-FichierJson {
    param([string]$Chemin, $Objet)
    try {
        $dossier = Split-Path -Parent $Chemin
        if (-not (Test-Path -LiteralPath $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
        $json = ConvertTo-Json -InputObject $Objet -Depth 10
        [System.IO.File]::WriteAllText($Chemin, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        throw (New-ErreurOutil "Impossible d'enregistrer $Chemin : $($_.Exception.Message)" `
            "Vérifiez les droits d'écriture sur le dossier $($script:DossierDonnees).")
    }
}

function Get-ConfigParDefaut {
    $c = New-Dictionnaire
    $c['hyperviseur']       = 'vmware'   # nom du pilote : lib\pilote-<hyperviseur>.ps1
    $c['outilHyperviseur']  = ''         # chemin forcé de l'outil de l'hyperviseur (vide = détection automatique par le pilote)
    $c['dossierVms']        = ''         # dossier où créer les VM (vide = à côté du modèle)
    $c['espaceDisqueMinGo'] = 1          # marge d'espace libre exigée, en plus de la RAM de la VM
    $h = New-Dictionnaire
    $h['avertissementAffiche'] = $false  # l'avertissement Hyper-V complet a-t-il déjà été montré ?
    $c['hyperv'] = $h
    return $c
}

# Fusionne un fichier lu avec les valeurs par défaut (les clés manquantes
# sont complétées, les clés inconnues conservées).
function Merge-Dictionnaire {
    param($Defaut, $Lu)
    if ($null -eq $Lu) { return $Defaut }
    $r = New-Dictionnaire
    foreach ($k in $Defaut.Keys) {
        if ($Lu.Contains($k)) {
            if ($Defaut[$k] -is [System.Collections.IDictionary] -and $Lu[$k] -is [System.Collections.IDictionary]) {
                $r[$k] = Merge-Dictionnaire $Defaut[$k] $Lu[$k]
            } else {
                $r[$k] = $Lu[$k]
            }
        } else {
            $r[$k] = $Defaut[$k]
        }
    }
    foreach ($k in $Lu.Keys) { if (-not $r.Contains($k)) { $r[$k] = $Lu[$k] } }
    return $r
}

function Read-Config {
    return Merge-Dictionnaire (Get-ConfigParDefaut) (Read-FichierJson -Chemin $script:CheminConfig)
}

function Save-Config {
    Write-FichierJson -Chemin $script:CheminConfig -Objet $script:Config
}

function Read-Catalogue {
    $lu = Read-FichierJson -Chemin $script:CheminCatalogue
    $c = New-Dictionnaire
    $c['modeles'] = New-Dictionnaire
    $c['vms']     = New-Dictionnaire
    if ($null -ne $lu) {
        if ($lu.Contains('modeles') -and $lu['modeles'] -is [System.Collections.IDictionary]) { $c['modeles'] = $lu['modeles'] }
        if ($lu.Contains('vms')     -and $lu['vms']     -is [System.Collections.IDictionary]) { $c['vms']     = $lu['vms'] }
    }
    return $c
}

function Save-Catalogue {
    Write-FichierJson -Chemin $script:CheminCatalogue -Objet $script:Catalogue
}

# ----------------------------------------------------------------------------
#  Pilote et machine hôte
# ----------------------------------------------------------------------------

# Initialise le pilote à la première demande (les commandes qui n'ont pas
# besoin de l'hyperviseur, comme help ou config, restent utilisables sans lui).
function Connect-Pilote {
    if ($null -eq $script:Pilote) {
        $script:Pilote = Initialize-Pilote -CheminForce $script:Config['outilHyperviseur']
    }
    return $script:Pilote
}

function Get-CheminsOutil {
    $pilote = try { (Connect-Pilote).Executable } catch { 'introuvable (' + $_.Exception.Message + ')' }
    return [ordered]@{
        'Configuration' = $script:CheminConfig
        'Catalogue'     = $script:CheminCatalogue
        'Hyperviseur'   = $pilote
    }
}

# Interroge Windows une seule fois : hyperviseur Hyper-V actif ? RAM physique ?
# Win32_ComputerSystem.HypervisorPresent est exactement ce que lit
# Get-ComputerInfo (propriété HyperVisorPresent), en une fraction de seconde
# au lieu de plusieurs.
function Get-InfosHote {
    if ($null -eq $script:InfosHote) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $script:InfosHote = @{ HyperviseurPresent = [bool]$cs.HypervisorPresent; RamPhysiqueGo = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }
        } catch {
            $script:InfosHote = @{ HyperviseurPresent = $null; RamPhysiqueGo = 0 }
        }
    }
    return $script:InfosHote
}

# Avertit si Hyper-V est actif (l'hyperviseur tiers passe en mode dégradé).
# Ne bloque jamais. Le message complet est montré une fois, puis un rappel
# d'une ligne. Sans objet pour un pilote qui s'appuie sur Hyper-V.
function Invoke-AvertissementHyperV {
    $pilote = Connect-Pilote
    if (-not $pilote.SensibleHyperV) { return }
    $infos = Get-InfosHote
    if ($infos.HyperviseurPresent -ne $true) { return }
    if (-not $script:Config['hyperv']['avertissementAffiche']) {
        Publish-Message 'attention' (@(
            'Un hyperviseur Windows (Hyper-V) est actif sur cette machine.',
            "$($pilote.Nom) fonctionne alors en mode dégradé : VM plus lentes, pas de",
            'virtualisation imbriquée. Causes habituelles : WSL2, Docker Desktop, Windows Sandbox,',
            'ou « Intégrité de la mémoire » (Sécurité Windows > Isolation du noyau).',
            'Pour le désactiver (invite de commandes administrateur, puis redémarrage) :',
            '    bcdedit /set hypervisorlaunchtype off',
            '(WSL2 et Docker Desktop cesseront de fonctionner ; « auto » à la place de « off » pour revenir en arrière.)',
            'vazy continue quand même. Ce message complet ne sera plus affiché.'
        ) -join "`n")
        $script:Config['hyperv']['avertissementAffiche'] = $true
        Save-Config
    } else {
        Publish-Message 'attention' "Hyper-V est actif : $($pilote.Nom) tourne en mode dégradé (voir README, section Hyper-V)."
    }
}

# ----------------------------------------------------------------------------
#  Vérifications
# ----------------------------------------------------------------------------

function Test-NomValide {
    param([string]$Nom, [string]$Role = 'nom de VM')
    if ($Nom -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw (New-ErreurOutil "Le $Role « $Nom » est invalide." `
            "Utilisez uniquement lettres, chiffres, points, tirets et underscores (64 caractères max), sans espace ni accent : il sert aussi de nom de dossier.")
    }
    if ($script:MotsReserves -contains $Nom.ToLower()) {
        throw (New-ErreurOutil "« $Nom » est un mot réservé de vazy et ne peut pas servir de $Role." `
            ('Mots réservés : ' + ($script:MotsReserves -join ', ') + '.'))
    }
}

function Test-NomPris {
    param([string]$Nom)
    return ($script:Catalogue['vms'].Contains($Nom) -or $script:Catalogue['modeles'].Contains($Nom))
}

# Premier nom libre de la forme <modele>-1, <modele>-2...
function Get-NomLibre {
    param([string]$Modele, [string]$DossierRacine)
    $i = 1
    do {
        $candidat = '{0}-{1}' -f $Modele, $i
        $i++
    } while ((Test-NomPris $candidat) -or (Test-Path -LiteralPath (Join-Path $DossierRacine $candidat)))
    return $candidat
}

# Dossier racine où sont créées les VM : celui de la configuration, sinon le
# dossier parent du modèle (même disque, même organisation que l'hyperviseur).
function Get-DossierVms {
    param($Modele)
    if ($script:Config['dossierVms']) {
        return [Environment]::ExpandEnvironmentVariables($script:Config['dossierVms'])
    }
    return (Split-Path -Parent (Split-Path -Parent $Modele['chemin']))
}

# Espace libre du disque qui contient le dossier, en Go ($null si inconnu).
function Get-EspaceLibreGo {
    param([string]$Dossier)
    try {
        $racine = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Dossier))
        $lecteur = New-Object System.IO.DriveInfo($racine)
        return [math]::Round($lecteur.AvailableFreeSpace / 1GB, 1)
    } catch {
        return $null
    }
}

# Refuse proprement s'il n'y a pas assez de place : la VM a besoin de sa RAM
# sur le disque (fichier de mémoire pendant l'exécution) plus une marge.
function Test-EspaceDisque {
    param([string]$Dossier, [double]$RamGo)
    $marge = [double]$script:Config['espaceDisqueMinGo']
    $requis = $RamGo + $marge
    $libre = Get-EspaceLibreGo -Dossier $Dossier
    if ($null -eq $libre) {
        Publish-Message 'attention' "Impossible de mesurer l'espace libre de $Dossier ; on continue sans vérification."
        return $null
    }
    if ($libre -lt $requis) {
        throw (New-ErreurOutil ("Espace disque insuffisant pour créer la VM dans {0} : {1:0.#} Go libres, il en faut au moins {2:0.#} Go ({3:0.#} Go pour la mémoire de la VM + {4:0.#} Go de marge)." -f $Dossier, $libre, $requis, $RamGo, $marge) `
            'Libérez de la place, demandez moins de RAM (--ram), ou créez les VM sur un autre disque : vazy config dossierVms D:\VMs')
    }
    return $libre
}

function Test-MachineEnCours {
    param([string]$Chemin)
    $enCours = @(Get-MachineEnCours)
    foreach ($c in $enCours) { if ($c -ieq $Chemin) { return $true } }
    return $false
}

# ----------------------------------------------------------------------------
#  Catalogue : accès
# ----------------------------------------------------------------------------

function Get-ModeleDuCatalogue {
    param([string]$Alias)
    if ($script:Catalogue['modeles'].Contains($Alias)) { return $script:Catalogue['modeles'][$Alias] }
    $connus = @($script:Catalogue['modeles'].Keys)
    if ($connus.Count -eq 0) {
        throw (New-ErreurOutil "Modèle inconnu : « $Alias ». Aucun modèle n'est encore enregistré." `
            "Préparez une VM propre, éteinte, avec un instantané (voir README, « Préparer un modèle »), puis enregistrez-la : vazy template add <chemin de la VM> --name $Alias")
    }
    throw (New-ErreurOutil "Modèle inconnu : « $Alias »." `
        ('Modèles enregistrés : ' + ($connus -join ', ') + ". Pour en ajouter un : vazy template add <chemin de la VM> --name $Alias"))
}

function Get-VmDuCatalogue {
    param([string]$Nom)
    if ($script:Catalogue['vms'].Contains($Nom)) {
        $vm = $script:Catalogue['vms'][$Nom]
        # On renvoie aussi le nom tel qu'il a été enregistré (casse d'origine).
        foreach ($k in $script:Catalogue['vms'].Keys) { if ($k -ieq $Nom) { $Nom = $k } }
        return [pscustomobject]@{ Nom = $Nom; Chemin = $vm['chemin']; Dossier = $vm['dossier']; Modele = $vm['modele']; RamGo = $vm['ramGo']; Cpu = $vm['cpu']; Reseau = @($vm['reseau']); CreeeLe = $vm['creeeLe'] }
    }
    if ($script:Catalogue['modeles'].Contains($Nom)) {
        throw (New-ErreurOutil "« $Nom » est un modèle, pas une VM." `
            "Un modèle ne se démarre, ne s'arrête et ne se supprime jamais : il sert uniquement de base aux clones. Pour créer une VM à partir de lui : vazy $Nom")
    }
    $connues = @($script:Catalogue['vms'].Keys)
    $liste = if ($connues.Count -gt 0) { 'VM connues : ' + ($connues -join ', ') + '.' } else { 'Aucune VM n''a encore été créée.' }
    throw (New-ErreurOutil "VM inconnue : « $Nom »." "$liste Voir : vazy list")
}

# ----------------------------------------------------------------------------
#  Commande principale : créer une VM depuis un modèle
# ----------------------------------------------------------------------------

function New-VmDepuisModele {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [string]$Nom = '',
        [double]$RamGo = 2,
        [int]$Cpu = 2,
        [string[]]$Modes = @('nat'),    # un mode par carte réseau
        [object[]]$Brut = @(),          # réglages bruts (--set) : objets avec Cle et Valeur
        [switch]$SansInterface,
        [switch]$SansDemarrage
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Connect-Pilote | Out-Null

    $total = 4
    if ($Brut.Count -gt 0) { $total++ }
    if (-not $SansDemarrage) { $total++ }
    $etape = 1

    # --- Étape 1 : vérifications --------------------------------------------
    Publish-Etape $etape $total "Vérifications"
    $infosModele = Get-ModeleDuCatalogue -Alias $Modele
    if (-not (Test-Path -LiteralPath $infosModele['chemin'] -PathType Leaf)) {
        throw (New-ErreurOutil "Le fichier du modèle « $Modele » est introuvable : $($infosModele['chemin'])" `
            "Le modèle a été déplacé ou supprimé. Retirez-le du catalogue (vazy template rm $Modele) puis ré-enregistrez-le depuis son nouvel emplacement (vazy template add ...).")
    }
    if (Test-MachineEnCours -Chemin $infosModele['chemin']) {
        throw (New-ErreurOutil "Le modèle « $Modele » est en cours d'exécution." `
            "Éteignez-le dans $($script:Pilote.Nom) avant de cloner. Rappel : un modèle ne doit jamais être démarré, et surtout jamais voir son instantané supprimé, sinon tous ses clones cassent.")
    }
    $instantanes = @(Get-MachineInstantanes -Machine $infosModele['chemin'])
    if ($instantanes -cnotcontains $infosModele['instantane']) {
        $existants = if ($instantanes.Count -gt 0) { 'Instantanés existants : ' + ($instantanes -join ', ') + '.' } else { 'Ce modèle n''a plus aucun instantané.' }
        throw (New-ErreurOutil "L'instantané « $($infosModele['instantane']) » du modèle « $Modele » n'existe plus. $existants" `
            ("Un clone lié doit s'appuyer sur un instantané. " + ($script:Pilote.ConseilInstantane -f $script:Pilote.Executable, $infosModele['chemin']) + "`nPuis ré-enregistrez le modèle : vazy template rm $Modele ; vazy template add ""$($infosModele['chemin'])"" --name $Modele"))
    }

    $dossierRacine = Get-DossierVms -Modele $infosModele
    if ($Nom) {
        Test-NomValide -Nom $Nom
        if (Test-NomPris $Nom) {
            throw (New-ErreurOutil "Le nom « $Nom » est déjà utilisé." "Choisissez un autre nom (--name), ou supprimez l'ancienne VM : vazy rm $Nom")
        }
    } else {
        $Nom = Get-NomLibre -Modele $Modele -DossierRacine $dossierRacine
    }
    $dossierVm = Join-Path $dossierRacine $Nom
    if (Test-Path -LiteralPath $dossierVm) {
        throw (New-ErreurOutil "Le dossier $dossierVm existe déjà ; vazy n'écrase jamais rien." `
            "Choisissez un autre nom (--name), ou supprimez ce dossier s'il s'agit d'un reste d'une ancienne VM.")
    }
    $libre = Test-EspaceDisque -Dossier $dossierRacine -RamGo $RamGo
    $infosHote = Get-InfosHote
    if ($infosHote.RamPhysiqueGo -gt 0 -and $RamGo -ge $infosHote.RamPhysiqueGo) {
        Publish-Message 'attention' ("La VM demande {0} Go de RAM, la machine n'en a que {1} Go : elle risque de ne pas démarrer." -f $RamGo, $infosHote.RamPhysiqueGo)
    }
    Invoke-AvertissementHyperV
    $libreTexte = if ($null -ne $libre) { ', {0:0.#} Go libres' -f $libre } else { '' }
    Publish-Message 'ok' ("modèle « {0} » (instantané « {1} »), destination {2}{3}" -f $Modele, $infosModele['instantane'], $dossierVm, $libreTexte)

    # --- Étape 2 : clone lié ------------------------------------------------
    $etape++
    Publish-Etape $etape $total "Clonage lié"
    $debut = $chrono.Elapsed.TotalSeconds
    $chemin = New-MachineDepuisModele -Modele $infosModele['chemin'] -Instantane $infosModele['instantane'] -Dossier $dossierVm -Nom $Nom
    Publish-Message 'ok' ("{0} créé en {1}" -f $chemin, (Format-Duree ($chrono.Elapsed.TotalSeconds - $debut)))

    # --- Étapes 3 à 5 : réglages, réseau, réglages personnalisés ------------
    try {
        $etape++
        Publish-Etape $etape $total "Réglages"
        $ramMo = [int][math]::Round($RamGo * 1024)
        Set-MachineParametres -Machine $chemin -RamMo $ramMo -Cpu $Cpu
        Publish-Message 'ok' ("{0} Go de RAM ({1} Mo), {2} CPU" -f $RamGo, $ramMo, $Cpu)

        $etape++
        Publish-Etape $etape $total "Réseau"
        Set-MachineReseau -Machine $chemin -Modes $Modes
        $texteReseau = switch ($Modes.Count) {
            0       { 'aucune carte réseau' }
            1       { '1 carte : ' + $Modes[0] }
            default { "$($Modes.Count) cartes : " + ($Modes -join ', ') }
        }
        Publish-Message 'ok' $texteReseau

        if ($Brut.Count -gt 0) {
            $etape++
            Publish-Etape $etape $total "Réglages personnalisés (--set)"
            Set-MachineParametres -Machine $chemin -Brut $Brut
            foreach ($p in $Brut) { Publish-Message 'ok' ('{0} = {1}' -f $p.Cle, $p.Valeur) }
        }
    } catch {
        # La VM est incomplète : on la supprime pour ne pas laisser de reste
        # inutilisable, puis on remonte l'erreur d'origine.
        Publish-Message 'attention' "Échec après le clonage : suppression de la VM incomplète..."
        try { Remove-Machine -Machine $chemin | Out-Null }
        catch { Publish-Message 'attention' "Nettoyage impossible ($($_.Exception.Message)). Supprimez le dossier à la main : $dossierVm" }
        throw
    }

    # --- Enregistrement au catalogue (avant le démarrage : même si celui-ci
    #     échoue, la VM existe et reste gérable avec vazy) -------------------
    $fiche = New-Dictionnaire
    $fiche['chemin']  = $chemin
    $fiche['dossier'] = $dossierVm
    $fiche['modele']  = $Modele
    $fiche['ramGo']   = $RamGo
    $fiche['cpu']     = $Cpu
    $fiche['reseau']  = @($Modes)
    $fiche['creeeLe'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $script:Catalogue['vms'][$Nom] = $fiche
    Save-Catalogue

    # --- Étape 6 : démarrage ------------------------------------------------
    if (-not $SansDemarrage) {
        $etape++
        Publish-Etape $etape $total $(if ($SansInterface) { "Démarrage sans fenêtre" } else { "Démarrage" })
        $debut = $chrono.Elapsed.TotalSeconds
        try {
            Start-Machine -Machine $chemin -SansInterface:$SansInterface
        } catch {
            $_.Exception.Data['Conseil'] = "La VM « $Nom » a bien été créée. " + $_.Exception.Data['Conseil'] + " Pour réessayer : vazy start $Nom"
            throw
        }
        Publish-Message 'ok' ("VM démarrée en {0}" -f (Format-Duree ($chrono.Elapsed.TotalSeconds - $debut)))
    }

    return [pscustomobject]@{
        Nom      = $Nom
        Chemin   = $chemin
        Dossier  = $dossierVm
        Demarree = (-not $SansDemarrage)
        Duree    = $chrono.Elapsed.TotalSeconds
    }
}

# ----------------------------------------------------------------------------
#  Commandes secondaires sur les VM
# ----------------------------------------------------------------------------

# Toutes les VM du catalogue avec leur état : en marche, arrêtée, ou absente
# (fichiers supprimés en dehors de vazy).
function Get-ListeVms {
    Connect-Pilote | Out-Null
    $enCours = @(Get-MachineEnCours)
    $liste = @()
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $vm = $script:Catalogue['vms'][$nom]
        $etat = 'arrêtée'
        if (-not (Test-Path -LiteralPath $vm['chemin'] -PathType Leaf)) {
            $etat = 'absente'
        } else {
            foreach ($c in $enCours) { if ($c -ieq $vm['chemin']) { $etat = 'en marche' } }
        }
        $liste += [pscustomobject]@{
            Nom     = $nom
            Etat    = $etat
            Modele  = $vm['modele']
            RamGo   = $vm['ramGo']
            Cpu     = $vm['cpu']
            Reseau  = (@($vm['reseau']) -join ',')
            CreeeLe = $vm['creeeLe']
            Chemin  = $vm['chemin']
        }
    }
    return $liste   # l'appelant entoure de @() : vide -> tableau vide
}

function Start-VmParNom {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$SansInterface)
    Connect-Pilote | Out-Null
    $vm = Get-VmDuCatalogue -Nom $Nom     # refuse explicitement les modèles
    if (-not (Test-Path -LiteralPath $vm.Chemin -PathType Leaf)) {
        throw (New-ErreurOutil "Les fichiers de la VM « $($vm.Nom) » ont disparu : $($vm.Chemin)" "Retirez-la du catalogue : vazy rm $($vm.Nom)")
    }
    if (Test-MachineEnCours -Chemin $vm.Chemin) {
        Publish-Message 'info' "La VM « $($vm.Nom) » est déjà en marche."
        return $vm
    }
    Invoke-AvertissementHyperV
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Machine -Machine $vm.Chemin -SansInterface:$SansInterface
    Publish-Message 'ok' ("VM « {0} » démarrée en {1}" -f $vm.Nom, (Format-Duree $chrono.Elapsed.TotalSeconds))
    return $vm
}

function Stop-VmParNom {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$Brutal)
    Connect-Pilote | Out-Null
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (-not (Test-MachineEnCours -Chemin $vm.Chemin)) {
        Publish-Message 'info' "La VM « $($vm.Nom) » est déjà arrêtée."
        return $vm
    }
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-Machine -Machine $vm.Chemin -Brutal:$Brutal
    $comment = if ($Brutal) { 'arrêtée brutalement' } else { 'arrêtée proprement' }
    Publish-Message 'ok' ("VM « {0} » {1} en {2}" -f $vm.Nom, $comment, (Format-Duree $chrono.Elapsed.TotalSeconds))
    return $vm
}

# Supprime la VM (arrêt forcé si nécessaire), ses fichiers, et sa fiche.
# La confirmation est demandée par l'interface avant l'appel.
function Remove-VmParNom {
    param([Parameter(Mandatory = $true)][string]$Nom)
    Connect-Pilote | Out-Null
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (Test-Path -LiteralPath $vm.Chemin -PathType Leaf) {
        if (Test-MachineEnCours -Chemin $vm.Chemin) {
            Publish-Message 'info' "La VM est en marche : arrêt forcé."
            Stop-Machine -Machine $vm.Chemin -Brutal
        }
        $reste = Remove-Machine -Machine $vm.Chemin
        if ($reste) { Publish-Message 'attention' $reste }
        Publish-Message 'ok' "Fichiers supprimés : $($vm.Dossier)"
    } else {
        Publish-Message 'info' "Les fichiers avaient déjà disparu ($($vm.Chemin)) : seule la fiche du catalogue est retirée."
    }
    $script:Catalogue['vms'].Remove($vm.Nom)
    Save-Catalogue
    Publish-Message 'ok' "VM « $($vm.Nom) » supprimée."
    return $vm
}

# ----------------------------------------------------------------------------
#  Modèles
# ----------------------------------------------------------------------------

function Add-Modele {
    param(
        [Parameter(Mandatory = $true)][string]$Chemin,
        [string]$Alias = '',
        [string]$Instantane = ''
    )
    $pilote = Connect-Pilote
    try {
        $cheminComplet = (Resolve-Path -LiteralPath $Chemin -ErrorAction Stop).ProviderPath
    } catch {
        throw (New-ErreurOutil "Fichier introuvable : $Chemin" `
            "Indiquez le chemin complet du fichier $($pilote.ExtensionMachine) de la VM modèle, par exemple : vazy template add ""D:\VMs\ubuntu-server\ubuntu-server$($pilote.ExtensionMachine)""")
    }
    if (Test-Path -LiteralPath $cheminComplet -PathType Container) {
        $dedans = @(Get-ChildItem -LiteralPath $cheminComplet -Filter ('*' + $pilote.ExtensionMachine) -File)
        if ($dedans.Count -eq 1) { $cheminComplet = $dedans[0].FullName }   # on accepte le dossier de la VM
        else {
            throw (New-ErreurOutil "$Chemin est un dossier." "Indiquez le fichier $($pilote.ExtensionMachine) de la VM qui se trouve dedans.")
        }
    }
    if ([System.IO.Path]::GetExtension($cheminComplet) -ne $pilote.ExtensionMachine) {
        throw (New-ErreurOutil "$cheminComplet n'est pas un fichier $($pilote.ExtensionMachine)." "Indiquez le fichier de configuration de la VM ($($pilote.Nom) : extension $($pilote.ExtensionMachine)).")
    }
    if (-not $Alias) { $Alias = [System.IO.Path]::GetFileNameWithoutExtension($cheminComplet) }
    Test-NomValide -Nom $Alias -Role 'alias de modèle'
    if (Test-NomPris $Alias) {
        throw (New-ErreurOutil "Le nom « $Alias » est déjà utilisé (par un modèle ou une VM)." "Choisissez un autre alias : vazy template add ""$cheminComplet"" --name <alias>")
    }
    foreach ($k in $script:Catalogue['modeles'].Keys) {
        if ($script:Catalogue['modeles'][$k]['chemin'] -ieq $cheminComplet) {
            throw (New-ErreurOutil "Cette VM est déjà enregistrée comme modèle sous l'alias « $k »." "Utilisez-la directement : vazy $k. Pour changer l'alias : vazy template rm $k puis vazy template add ... --name <nouvel alias>")
        }
    }

    if (Test-MachineEnCours -Chemin $cheminComplet) {
        Publish-Message 'attention' "Cette VM est en cours d'exécution. Éteignez-la et ne la redémarrez plus : un modèle ne se démarre jamais, il sert uniquement de base aux clones."
    }
    $instantanes = @(Get-MachineInstantanes -Machine $cheminComplet)
    if ($instantanes.Count -eq 0) {
        throw (New-ErreurOutil "La VM $cheminComplet n'a aucun instantané : un clone lié doit obligatoirement s'appuyer sur un instantané." `
            (($pilote.ConseilInstantane -f $pilote.Executable, $cheminComplet) + "`nPuis relancez : vazy template add ""$cheminComplet"" --name $Alias"))
    }
    if ($Instantane) {
        if ($instantanes -cnotcontains $Instantane) {
            throw (New-ErreurOutil "L'instantané « $Instantane » n'existe pas dans cette VM." ('Instantanés existants (respectez la casse) : ' + ($instantanes -join ', ')))
        }
    } else {
        $Instantane = $instantanes[-1]
        if ($instantanes.Count -gt 1) {
            Publish-Message 'info' ("Plusieurs instantanés ({0}) : le dernier de la liste, « {1} », servira de base. Pour en choisir un autre : --snapshot <nom>" -f ($instantanes -join ', '), $Instantane)
        }
    }

    $fiche = New-Dictionnaire
    $fiche['chemin']     = $cheminComplet
    $fiche['instantane'] = $Instantane
    $fiche['ajouteLe']   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $script:Catalogue['modeles'][$Alias] = $fiche
    Save-Catalogue
    Publish-Message 'ok' "Modèle « $Alias » enregistré (instantané « $Instantane »)."
    return [pscustomobject]@{ Alias = $Alias; Chemin = $cheminComplet; Instantane = $Instantane }
}

function Get-ListeModeles {
    $liste = @()
    foreach ($alias in @($script:Catalogue['modeles'].Keys)) {
        $m = $script:Catalogue['modeles'][$alias]
        $clones = 0
        foreach ($nom in $script:Catalogue['vms'].Keys) { if ($script:Catalogue['vms'][$nom]['modele'] -ieq $alias) { $clones++ } }
        $liste += [pscustomobject]@{
            Alias      = $alias
            Instantane = $m['instantane']
            Clones     = $clones
            Present    = (Test-Path -LiteralPath $m['chemin'] -PathType Leaf)
            Chemin     = $m['chemin']
        }
    }
    return $liste   # l'appelant entoure de @() : vide -> tableau vide
}

# Retire un modèle du catalogue. Ne touche jamais aux fichiers : les clones
# existants continuent d'en dépendre.
function Remove-Modele {
    param([Parameter(Mandatory = $true)][string]$Alias)
    if (-not $script:Catalogue['modeles'].Contains($Alias)) {
        $connus = @($script:Catalogue['modeles'].Keys)
        $liste = if ($connus.Count -gt 0) { 'Modèles enregistrés : ' + ($connus -join ', ') + '.' } else { 'Aucun modèle n''est enregistré.' }
        throw (New-ErreurOutil "Modèle inconnu : « $Alias »." "$liste Voir : vazy template list")
    }
    $clones = @()
    foreach ($nom in $script:Catalogue['vms'].Keys) { if ($script:Catalogue['vms'][$nom]['modele'] -ieq $Alias) { $clones += $nom } }
    $script:Catalogue['modeles'].Remove($Alias)
    Save-Catalogue
    Publish-Message 'ok' "Modèle « $Alias » retiré du catalogue (aucun fichier supprimé)."
    if ($clones.Count -gt 0) {
        Publish-Message 'attention' ("{0} VM en dépendent toujours ({1}) : ne supprimez pas ses fichiers ni son instantané, sinon elles cassent." -f $clones.Count, ($clones -join ', '))
    }
}

# ----------------------------------------------------------------------------
#  Configuration
# ----------------------------------------------------------------------------

function Get-ConfigAffichable {
    return [ordered]@{
        'hyperviseur'       = $script:Config['hyperviseur']
        'outilHyperviseur'  = $(if ($script:Config['outilHyperviseur']) { $script:Config['outilHyperviseur'] } else { '(détection automatique)' })
        'dossierVms'        = $(if ($script:Config['dossierVms']) { $script:Config['dossierVms'] } else { '(à côté du modèle)' })
        'espaceDisqueMinGo' = $script:Config['espaceDisqueMinGo']
    }
}

function Set-ConfigValeur {
    param([Parameter(Mandatory = $true)][string]$Cle, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Valeur)
    switch ($Cle.ToLower()) {
        'dossiervms' {
            if ($Valeur) { $Valeur = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Valeur) }
            $script:Config['dossierVms'] = $Valeur
        }
        'outilhyperviseur' {
            if ($Valeur -and -not (Test-Path -LiteralPath $Valeur -PathType Leaf)) {
                throw (New-ErreurOutil "Fichier introuvable : $Valeur" 'Indiquez le chemin complet de l''outil en ligne de commande de l''hyperviseur (voir README), ou une valeur vide ("") pour revenir à la détection automatique.')
            }
            $script:Config['outilHyperviseur'] = $Valeur
        }
        'espacedisquemingo' {
            $n = 0.0
            if (-not [double]::TryParse(($Valeur -replace ',', '.'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or $n -lt 0) {
                throw (New-ErreurOutil "Valeur invalide pour espaceDisqueMinGo : $Valeur" 'Indiquez un nombre de Go positif, par exemple 2.')
            }
            $script:Config['espaceDisqueMinGo'] = $n
        }
        'hyperviseur' {
            $fichier = Join-Path $script:DossierLib ('pilote-' + $Valeur.ToLower() + '.ps1')
            if (-not (Test-Path -LiteralPath $fichier -PathType Leaf)) {
                $disponibles = @(Get-ChildItem -LiteralPath $script:DossierLib -Filter 'pilote-*.ps1' | ForEach-Object { $_.BaseName -replace '^pilote-', '' })
                throw (New-ErreurOutil "Aucun pilote nommé « $Valeur »." ('Pilotes disponibles : ' + ($disponibles -join ', ') + '.'))
            }
            $script:Config['hyperviseur'] = $Valeur.ToLower()
        }
        default {
            throw (New-ErreurOutil "Clé de configuration inconnue : $Cle" 'Clés possibles : dossierVms, outilHyperviseur, espaceDisqueMinGo, hyperviseur.')
        }
    }
    Save-Config
}

# ----------------------------------------------------------------------------
#  Chargement (exécuté quand l'interface charge ce fichier)
# ----------------------------------------------------------------------------

$script:Config    = Read-Config
$script:Catalogue = Read-Catalogue

# Le pilote est choisi par la configuration : lib\pilote-<hyperviseur>.ps1.
# Il est chargé ici, au niveau du script, pour que ses fonctions restent
# visibles ensuite (un chargement dans une fonction les ferait disparaître).
$cheminPilote = Join-Path $script:DossierLib ('pilote-' + $script:Config['hyperviseur'] + '.ps1')
if (-not (Test-Path -LiteralPath $cheminPilote -PathType Leaf)) {
    throw (New-ErreurOutil "Le pilote « $($script:Config['hyperviseur']) » n'existe pas ($cheminPilote)." `
        "Corrigez la clé hyperviseur dans $($script:CheminConfig) (valeur attendue : vmware).")
}
. $cheminPilote
