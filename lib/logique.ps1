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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NomOutil       = 'vazy'
$script:VersionOutil   = '1.9.0'
$script:VersionCatalogue = 11         # schéma de catalogue.json (voir Read-Catalogue)
$script:SeuilNettoyage = 3            # au-delà de ce nombre de VM éphémères à supprimer d'un coup, on demande confirmation
$script:InstantaneNeuf = 'vazy-neuf'  # point de retour pris à la création, cible de « vazy reset »
$script:DossierDonnees = if ($env:VAZY_HOME) { $env:VAZY_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'vazy' }
$script:CheminConfig    = Join-Path $script:DossierDonnees 'config.json'
$script:CheminCatalogue = Join-Path $script:DossierDonnees 'catalogue.json'
$script:DossierIdentifiants = Join-Path $script:DossierDonnees 'creds'   # identifiants d'invité par modèle, chiffrés (DPAPI)
$script:CheminJournal  = Join-Path $script:DossierDonnees 'journal.log'  # trace de chaque opération (voir Write-Journal)
$script:Simulation     = $false     # --dry-run : rien n'est modifié
$script:DossierLib     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Config         = $null
$script:Catalogue      = $null
$script:Pilote         = $null      # description renvoyée par Initialize-Pilote (chargée à la demande)
$script:InfosHote      = $null      # résultat de l'interrogation WMI (une seule fois par exécution)
$script:RappelHyperVFait = $false   # le rappel court Hyper-V a-t-il déjà été affiché dans cette exécution ?
$script:ApiCheminsChargee = $false  # API Windows de résolution des chemins courts (chargée à la demande)
$script:Afficheur      = { param($Type, $Message) }   # remplacé par l'interface
$script:MotsReserves   = @('list', 'start', 'stop', 'rm', 'template', 'config', 'help', 'version',
                           'reset', 'snap', 'snaps', 'back', 'unsnap', 'gc', 'lab', 'doctor', 'freeze', 'vnc', 'net',
                           'pool', 'pop')

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

# ----------------------------------------------------------------------------
#  Journal et mode simulation (--dry-run)
#  Chaque opération est écrite dans journal.log avec sa commande complète (mot
#  de passe masqué par le pilote). En simulation, les commandes qui
#  modifieraient quelque chose sont affichées au lieu d'être exécutées.
# ----------------------------------------------------------------------------

function Write-Journal {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:DossierDonnees)) { New-Item -ItemType Directory -Path $script:DossierDonnees -Force | Out-Null }
        $ligne = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $PID, $Message
        [System.IO.File]::AppendAllText($script:CheminJournal, $ligne + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        # Rotation simple : au-delà de 2 Mo, on garde la seconde moitié.
        $f = Get-Item -LiteralPath $script:CheminJournal -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt 2MB) {
            $lignes = @([System.IO.File]::ReadAllLines($script:CheminJournal))
            [System.IO.File]::WriteAllLines($script:CheminJournal, @($lignes | Select-Object -Last ([int]($lignes.Count / 2))))
        }
    } catch { }   # un journal illisible ne doit jamais empêcher de travailler
}

# Branche le pilote sur le journal, et active la simulation le cas échéant.
function Set-ModeSimulation {
    param([bool]$Actif)
    $script:Simulation = $Actif
    Set-PiloteObservateur -Observateur {
        param($Type, $Message)
        # « progression » : signe de vie pendant une opération longue. Il va à
        # l'écran et non au journal, qui n'a que faire d'une attente en cours.
        if ($Type -eq 'simulation')      { Publish-Message 'simulation' $Message }
        elseif ($Type -eq 'progression') { Publish-Message 'info' $Message }
        else { Write-Journal $Message }
    } -Simulation $Actif
}

function Test-Simulation { return $script:Simulation }

# Écriture d'un fichier de données : ignorée en simulation.
function Assert-PasSimulation {
    param([string]$Quoi)
    if ($script:Simulation) {
        Publish-Message 'simulation' $Quoi
        return $true
    }
    return $false
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
    $c['delaiOutilsSec']    = 120        # attente maximale des outils invité avant de personnaliser (phase 4)
    $c['delaiPoolSec']      = 180        # attente maximale que l'invité s'annonce prêt à être figé (pool)
    $c['poolReposSec']      = 20         # repli : temps laissé à l'invité avant de le figer, faute de poignée de main
    $c['vncPortMin']        = 5901       # plage de ports réservée à l'affichage distant des VM
    $c['vncPortMax']        = 5999
    $c['dossierLabos']      = ''         # où sont rangés les fichiers de labo (vide = <données>\labos)
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
    if ($script:Simulation) { return }
    Write-FichierJson -Chemin $script:CheminConfig -Objet $script:Config
}

# Charge le catalogue et le met au niveau du schéma courant : les catalogues
# plus anciens sont migrés automatiquement, sans perte d'entrée.
#   version 1 : modeles, vms
#   version 2 : + vms.<nom>.instantaneNeuf (point de retour de « vazy reset » ;
#                 vide pour une VM créée avant la phase 1)
#   version 3 : + vms.<nom>.ephemere (VM jetable créée avec --tmp, supprimée
#                 dès qu'elle est trouvée éteinte ; $false pour les autres)
#   version 4 : + vms.<nom>.labo (nom du labo qui a créé la VM via
#                 « vazy lab up » ; vide pour une VM créée à la main)
#   version 5 : + modeles.<alias>.os ('linux' | 'windows' | '' = détecté)
#               + vms.<nom>.nomHote (nom d'hôte demandé, '' = aucun)
#               Les identifiants d'invité ne sont PAS dans le catalogue : voir
#               le dossier creds (fichiers chiffrés par Export-CliXml).
#   version 6 : + modeles.<alias>.guestinfo ($true = le modèle embarque le
#                 script vazy-guestinfo ; la configuration est déposée avant
#                 chaque démarrage, sans identifiant)
#               - vms.<nom>.nomHoteApplique retiré (plus de réapplication)
#   version 7 : + vms.<nom>.empreinte (disques de base du modèle au moment du
#                 clonage : nom -> taille et date ; vérifiée avant démarrage)
#               + vms.<nom>.sets (réglages bruts --set, pour « lab export »)
#               + vms.<nom>.autonome (clone complet après « vazy freeze »)
#               + modeles.<alias>.alias (noms standards de ce modèle, pour les
#                 prérequis d'un labo partagé : « vazy template alias »)
#   version 8 : + vms.<nom>.vnc { actif, port, motDePasse } : affichage distant
#                 de l'écran de la VM (voir la section « écran à distance »)
#   version 9 : + reseaux : segments réseau personnalisés, nom parlant ->
#                 { identifiant rendu par le pilote, adresse, dhcp, creeLe }.
#                 Une carte branchée sur un segment apparaît dans
#                 vms.<nom>.reseau sous la forme « nomme:<identifiant> ».
#   version 10 : + vms.<nom>.pool (alias du modèle dont cette VM est une
#                 réserve chaude, '' pour une VM ordinaire). Une VM de pool
#                 n'apparaît pas dans « vazy list » et n'est jamais ramassée
#                 par le nettoyage des éphémères.
#   version 11 : + vms.<nom>.invite { ip, masque, passerelle, dns, cle_ssh } :
#                 configuration réseau statique et clé SSH déposées dans
#                 l'invité par guestinfo. Vide = adressage laissé au DHCP,
#                 comportement d'avant.
#   Les entrées gardent toute clé inconnue : de futurs champs s'ajoutent sans
#   migration destructive.
function Read-Catalogue {
    $lu = Read-FichierJson -Chemin $script:CheminCatalogue
    $c = New-Dictionnaire
    $c['version'] = $script:VersionCatalogue
    $c['modeles'] = New-Dictionnaire
    $c['vms']     = New-Dictionnaire
    $c['reseaux'] = New-Dictionnaire
    if ($null -eq $lu) { return $c }
    if ($lu.Contains('modeles') -and $lu['modeles'] -is [System.Collections.IDictionary]) { $c['modeles'] = $lu['modeles'] }
    if ($lu.Contains('vms')     -and $lu['vms']     -is [System.Collections.IDictionary]) { $c['vms']     = $lu['vms'] }
    if ($lu.Contains('reseaux') -and $lu['reseaux'] -is [System.Collections.IDictionary]) { $c['reseaux'] = $lu['reseaux'] }

    $versionLue = if ($lu.Contains('version')) { [int]$lu['version'] } else { 1 }
    $modifie = ($versionLue -lt $script:VersionCatalogue)
    foreach ($nom in @($c['vms'].Keys)) {
        $vm = $c['vms'][$nom]
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('instantaneNeuf')) {
            $vm['instantaneNeuf'] = ''   # VM d'avant la phase 1 : pas de point de retour (voir vazy reset)
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('ephemere')) {
            $vm['ephemere'] = $false     # VM d'avant la phase 2 : jamais éphémère
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('labo')) {
            $vm['labo'] = ''             # VM d'avant la phase 3 : créée à la main
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('pool')) {
            $vm['pool'] = ''             # VM d'avant la v10 : jamais en réserve
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('invite')) {
            $vm['invite'] = New-Dictionnaire   # VM d'avant la v11 : adressage laissé au DHCP
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('nomHote')) {
            $vm['nomHote'] = ''          # VM d'avant la phase 4 : pas de nom d'hôte demandé
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and $vm.Contains('nomHoteApplique')) {
            $vm.Remove('nomHoteApplique')   # v6 : la réapplication après reset/back n'existe plus
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('vnc')) {
            $v = New-Dictionnaire
            $v['actif'] = $false; $v['port'] = 0; $v['motDePasse'] = ''
            $vm['vnc'] = $v          # VM d'avant la v8 : pas d'affichage distant
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('empreinte')) {
            $vm['empreinte'] = New-Dictionnaire   # VM d'avant la v7 : empreinte du modèle inconnue
            $vm['sets'] = @()                     # réglages --set non mémorisés à l'époque
            $vm['autonome'] = $false
            $modifie = $true
        }
    }
    foreach ($alias in @($c['modeles'].Keys)) {
        $m = $c['modeles'][$alias]
        if ($m -is [System.Collections.IDictionary] -and -not $m.Contains('os')) {
            $m['os'] = ''                # système invité : détecté par le pilote tant que non précisé
            $modifie = $true
        }
        if ($m -is [System.Collections.IDictionary] -and -not $m.Contains('guestinfo')) {
            $m['guestinfo'] = $false     # modèle d'avant la v6 : pas de script vazy-guestinfo connu
            $modifie = $true
        }
        if ($m -is [System.Collections.IDictionary] -and -not $m.Contains('alias')) {
            $m['alias'] = @()            # noms standards auxquels ce modèle répond (labos partagés)
            $modifie = $true
        }
    }
    if ($modifie) { Write-FichierJson -Chemin $script:CheminCatalogue -Objet $c }
    return $c
}

function Save-Catalogue {
    if ($script:Simulation) { return }   # --dry-run : le catalogue n'est jamais modifié
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
        Invoke-MarquageModeles
    }
    return $script:Pilote
}

# Pose la marque « modèle » du pilote sur chaque modèle du catalogue qui ne
# l'a pas encore (modèles enregistrés avant la phase 1, ou marque effacée).
# Un test d'existence de fichier par modèle : coût négligeable.
function Invoke-MarquageModeles {
    foreach ($alias in @($script:Catalogue['modeles'].Keys)) {
        $chemin = $script:Catalogue['modeles'][$alias]['chemin']
        if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { continue }
        if (Test-MachineModele -Machine $chemin) { continue }
        try { Protect-MachineModele -Machine $chemin }
        catch { Publish-Message 'attention' "Impossible de marquer le modèle « $alias » comme protégé : $($_.Exception.Message)" }
    }
}

function Get-CheminsOutil {
    $pilote = try { (Connect-Pilote).Executable } catch { 'introuvable (' + $_.Exception.Message + ')' }
    return [ordered]@{
        'Configuration' = $script:CheminConfig
        'Catalogue'     = $script:CheminCatalogue
        'Journal'       = $script:CheminJournal
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
    } elseif (-not $script:RappelHyperVFait) {
        # Une seule fois par exécution, même si plusieurs VM sont créées ou démarrées (labo).
        Publish-Message 'attention' "Hyper-V est actif : $($pilote.Nom) tourne en mode dégradé (voir README, section Hyper-V)."
    }
    $script:RappelHyperVFait = $true
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

# Premier nom libre de la forme <modele>-1, <modele>-2... (ou <modele>-tmp-1
# pour une VM éphémère, reconnaissable au premier coup d'œil).
function Get-NomLibre {
    param([string]$Modele, [string]$DossierRacine, [string]$Suffixe = '')
    $i = 1
    do {
        $candidat = '{0}{1}-{2}' -f $Modele, $Suffixe, $i
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

# Forme longue et canonique d'un chemin : « C:\Users\ANTHON~1.CER\... » et
# « C:\Users\anthony.cernon\... » désignent le même fichier. Sans cela, une VM
# du catalogue paraîtrait absente du catalogue lors d'un balayage du disque.
function Get-CheminLong {
    param([string]$Chemin)
    if (-not $Chemin) { return '' }
    try { $Chemin = [System.IO.Path]::GetFullPath($Chemin) } catch { }
    if ($Chemin -notmatch '~\d') { return $Chemin }   # pas de forme courte : rien à résoudre
    if (-not $script:ApiCheminsChargee) {
        try {
            Add-Type -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetLongPathName(string court, System.Text.StringBuilder tampon, uint taille);
'@ -Name 'Chemins' -Namespace 'Vazy' -ErrorAction Stop
            $script:ApiCheminsChargee = $true
        } catch { $script:ApiCheminsChargee = 'echec' }
    }
    if ($script:ApiCheminsChargee -ne $true) { return $Chemin }
    try {
        $tampon = New-Object System.Text.StringBuilder 32767
        $n = [Vazy.Chemins]::GetLongPathName($Chemin, $tampon, [uint32]$tampon.Capacity)
        if ($n -gt 0) { return $tampon.ToString() }
    } catch { }
    return $Chemin
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
    param([string]$Dossier, [double]$RamGo, [string]$Libelle = 'la VM')
    $marge = [double]$script:Config['espaceDisqueMinGo']
    $requis = $RamGo + $marge
    $libre = Get-EspaceLibreGo -Dossier $Dossier
    if ($null -eq $libre) {
        Publish-Message 'attention' "Impossible de mesurer l'espace libre de $Dossier ; on continue sans vérification."
        return $null
    }
    if ($libre -lt $requis) {
        throw (New-ErreurOutil ("Espace disque insuffisant pour créer {5} dans {0} : {1:0.#} Go libres, il en faut au moins {2:0.#} Go ({3:0.#} Go pour la mémoire + {4:0.#} Go de marge)." -f $Dossier, $libre, $requis, $RamGo, $marge, $Libelle) `
            'Libérez de la place, demandez moins de RAM (--ram), ou créez les VM sur un autre disque : vazy config dossierVms D:\VMs')
    }
    return $libre
}

# La VM du catalogue tourne-t-elle ? (nom, pas chemin)
function Test-VmEnMarche {
    param([string]$Nom)
    try {
        $vm = Get-VmDuCatalogue -Nom $Nom
        return (Test-MachineEnCours -Chemin $vm.Chemin)
    } catch { return $false }
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

# Nom réel d'un modèle : son alias au catalogue, ou un nom standard qu'un
# modèle local déclare servir (« vazy template alias win2022 windows-server »).
# C'est ce qui permet de monter le labo d'un camarade sans renommer ses VM.
function Resolve-AliasModele {
    param([string]$Alias)
    if ($script:Catalogue['modeles'].Contains($Alias)) { return $Alias }
    foreach ($k in @($script:Catalogue['modeles'].Keys)) {
        foreach ($a in @($script:Catalogue['modeles'][$k]['alias'])) {
            if ([string]$a -ieq $Alias) { return $k }
        }
    }
    return $Alias
}

function Get-ModeleDuCatalogue {
    param([string]$Alias)
    $Alias = Resolve-AliasModele -Alias $Alias
    if ($script:Catalogue['modeles'].Contains($Alias)) { return $script:Catalogue['modeles'][$Alias] }
    $connus = @($script:Catalogue['modeles'].Keys)
    if ($connus.Count -eq 0) {
        throw (New-ErreurOutil "Modèle inconnu : « $Alias ». Aucun modèle n'est encore enregistré." `
            "Préparez une VM propre, éteinte, avec un instantané (voir README, « Préparer un modèle »), puis enregistrez-la : vazy template add <chemin de la VM> --name $Alias")
    }
    throw (New-ErreurOutil "Modèle inconnu : « $Alias »." `
        ("Modèles enregistrés : " + ($connus -join ', ') + ".`n" +
         "Pour en ajouter un : vazy template add <chemin de la VM> --name $Alias`n" +
         "Si vous avez déjà un modèle équivalent sous un autre nom : vazy template alias <votre modèle> $Alias"))
}

function Get-VmDuCatalogue {
    param([string]$Nom)
    if ($script:Catalogue['vms'].Contains($Nom)) {
        $vm = $script:Catalogue['vms'][$Nom]
        # On renvoie aussi le nom tel qu'il a été enregistré (casse d'origine).
        foreach ($k in $script:Catalogue['vms'].Keys) { if ($k -ieq $Nom) { $Nom = $k } }
        return [pscustomobject]@{
            Nom = $Nom; Chemin = $vm['chemin']; Dossier = $vm['dossier']; Modele = $vm['modele']
            RamGo = $vm['ramGo']; Cpu = $vm['cpu']; Reseau = @($vm['reseau']); CreeeLe = $vm['creeeLe']
            InstantaneNeuf = [string]$vm['instantaneNeuf']
            Ephemere = ($vm['ephemere'] -eq $true)
            Labo = [string]$vm['labo']
            Pool = [string]$vm['pool']          # alias du modèle si la VM est en réserve, sinon ''
            ConfigInvite = $vm['invite']        # ip, masque, passerelle, dns, cle_ssh
            NomHote = [string]$vm['nomHote']
            Empreinte = $vm['empreinte']
            Sets = @($vm['sets'])
            Autonome = ($vm['autonome'] -eq $true)
            Vnc = $vm['vnc']
            VncActif = ($vm['vnc'] -and $vm['vnc']['actif'] -eq $true)
            VncPort = [int]$(if ($vm['vnc']) { $vm['vnc']['port'] } else { 0 })
        }
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
        [switch]$SansDemarrage,
        [switch]$Ephemere,              # --tmp : VM jetable, supprimée dès qu'elle est trouvée éteinte
        [string]$Labo = '',             # nom du labo propriétaire (vazy lab up), vide sinon
        [string]$Pool = '',             # alias du modèle si la VM part en réserve chaude, vide sinon
        $ConfigInvite = $null,          # ip, masque, passerelle, dns, cle_ssh (guestinfo)
        [string]$NomHote = '',          # nom d'hôte à appliquer dans l'invité après démarrage (phase 4), vide = rien
        [switch]$Vnc                    # --vnc : écran de la VM accessible à distance
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Ephemere -and $SansDemarrage) {
        throw (New-ErreurOutil "--tmp et --nostart sont incompatibles : une VM éphémère est supprimée dès qu'elle est éteinte, la créer sans la démarrer la condamnerait au prochain lancement de vazy." `
            "Retirez l'une des deux options.")
    }
    Connect-Pilote | Out-Null
    # Un labo partagé peut désigner le modèle par un nom standard : on retient
    # le nom réel au catalogue, pour que la VM ne devienne pas orpheline si
    # l'alias est retiré plus tard.
    $demande = $Modele
    $Modele = Resolve-AliasModele -Alias $Modele
    if ($Modele -ine $demande) { Publish-Message 'info' "« $demande » désigne votre modèle « $Modele »." }
    $infosModele = Get-ModeleDuCatalogue -Alias $Modele
    $methode = if ($NomHote) { Get-MethodePersonnalisation -Alias $Modele } else { 'aucune' }

    $total = 5   # vérifications, clone, réglages, réseau, point de retour
    if ($Brut.Count -gt 0) { $total++ }
    if (-not $SansDemarrage) { $total++ }
    if (-not $SansDemarrage -and $methode -eq 'identifiants') { $total++ }   # repli : étape visible en plus
    $etape = 1

    # --- Étape 1 : vérifications --------------------------------------------
    Publish-Etape $etape $total "Vérifications"
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

    Test-ReseauxDemandes -Modes $Modes
    Test-ConfigInvite -Config $ConfigInvite
    $dossierRacine = Get-DossierVms -Modele $infosModele
    if ($Nom) {
        Test-NomValide -Nom $Nom
        if (Test-NomPris $Nom) {
            throw (New-ErreurOutil "Le nom « $Nom » est déjà utilisé." "Choisissez un autre nom (--name), ou supprimez l'ancienne VM : vazy rm $Nom")
        }
    } else {
        $Nom = Get-NomLibre -Modele $Modele -DossierRacine $dossierRacine -Suffixe $(if ($Ephemere) { '-tmp' } else { '' })
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

    # --- Étape : point de retour « vazy-neuf », VM éteinte et avant tout
    #     démarrage, pour que « vazy reset » soit propre et rapide -------------
    $etape++
    Publish-Etape $etape $total "Point de retour « $($script:InstantaneNeuf) »"
    $debut = $chrono.Elapsed.TotalSeconds
    $instantaneNeuf = ''
    try {
        New-MachineInstantane -Machine $chemin -Nom $script:InstantaneNeuf
        $instantaneNeuf = $script:InstantaneNeuf
        Publish-Message 'ok' ("instantané pris en {0} (retour à cet état : vazy reset {1})" -f (Format-Duree ($chrono.Elapsed.TotalSeconds - $debut)), $Nom)
    } catch {
        # Non bloquant : la VM est utilisable, seul « vazy reset » manquera.
        Publish-Message 'attention' ("Instantané impossible : $($_.Exception.Message) La VM reste utilisable, mais « vazy reset $Nom » ne marchera pas tant qu'il manque. Pour réessayer, VM éteinte : vazy snap $Nom $($script:InstantaneNeuf)")
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
    $fiche['instantaneNeuf'] = $instantaneNeuf
    $fiche['ephemere'] = $false      # posé à $true seulement une fois la VM démarrée (voir ci-dessous)
    $fiche['labo']     = $Labo
    $fiche['pool']     = $Pool
    $fiche['invite']   = $(if ($null -ne $ConfigInvite) { $ConfigInvite } else { New-Dictionnaire })
    $fiche['nomHote']  = $NomHote    # appliqué à chaque démarrage par vazy (voir Start-VmAvecPersonnalisation)
    # Empreinte des disques de base du modèle : un clone lié y lit en
    # permanence. Vérifiée avant chaque démarrage (voir Test-ModeleIntact).
    $fiche['empreinte'] = Get-MachineEmpreinte -Machine $infosModele['chemin']
    $fiche['sets']      = @($Brut | ForEach-Object { '{0}={1}' -f $_.Cle, $_.Valeur })   # pour « vazy lab export »
    $fiche['autonome']  = $false
    $vncFiche = New-Dictionnaire
    $vncFiche['actif'] = $false; $vncFiche['port'] = 0; $vncFiche['motDePasse'] = ''
    $fiche['vnc'] = $vncFiche
    $script:Catalogue['vms'][$Nom] = $fiche
    Save-Catalogue

    # Écran distant : écrit avant le démarrage, car la machine relit sa
    # configuration à ce moment-là.
    $lienVnc = $null
    if ($Vnc) {
        try { $lienVnc = Enable-AffichageDistant -Nom $Nom }
        catch { Publish-Message 'attention' ("écran distant non activé : {0} {1}" -f $_.Exception.Message, [string]$_.Exception.Data['Conseil']) }
    }

    # --- Étape 6 : démarrage (avec dépôt de la personnalisation) -------------
    if (-not $SansDemarrage) {
        $etape++
        Publish-Etape $etape $total $(if ($SansInterface) { "Démarrage sans fenêtre" } else { "Démarrage" })
        try {
            $titreRepli = '[{0}/{1}] Personnalisation de l''invité (repli par identifiants)' -f ($etape + 1), $total
            Start-VmAvecPersonnalisation -Vm (Get-VmDuCatalogue -Nom $Nom) -SansInterface:$SansInterface -TitreEtapeIdentifiants $titreRepli | Out-Null
        } catch {
            $conseil = "La VM « $Nom » a bien été créée. " + $_.Exception.Data['Conseil'] + " Pour réessayer : vazy start $Nom"
            if ($Ephemere) { $conseil += ". Elle n'a PAS été marquée éphémère (elle ne sera pas supprimée automatiquement) : vazy rm $Nom pour l'effacer." }
            $_.Exception.Data['Conseil'] = $conseil
            throw
        }
        if ($Ephemere) {
            # Marquée éphémère seulement maintenant : une VM dont le démarrage a
            # échoué reste une VM normale, à examiner ou à supprimer à la main.
            # Cela évite aussi qu'une autre commande vazy lancée pendant le
            # démarrage ne la trouve « éteinte » et ne la supprime.
            $script:Catalogue['vms'][$Nom]['ephemere'] = $true
            Save-Catalogue
            Publish-Message 'info' "VM éphémère : supprimée automatiquement dès qu'elle sera trouvée éteinte (vazy stop $Nom, ou arrêt depuis l'intérieur puis n'importe quelle commande vazy)."
        }
    }

    return [pscustomobject]@{
        Nom      = $Nom
        Chemin   = $chemin
        Dossier  = $dossierVm
        Demarree = (-not $SansDemarrage)
        Ephemere = [bool]$Ephemere
        Vnc      = $lienVnc
        Duree    = $chrono.Elapsed.TotalSeconds
    }
}

# ----------------------------------------------------------------------------
#  Commandes secondaires sur les VM
# ----------------------------------------------------------------------------

# Toutes les VM du catalogue avec leur état : en marche, arrêtée, ou absente
# (fichiers supprimés en dehors de vazy).
function Get-ListeVms {
    # Les VM en réserve (pool) sont écartées par défaut : elles sont un stock,
    # pas des machines de travail, et noieraient la liste utile.
    param([switch]$AvecPool)
    Connect-Pilote | Out-Null
    $enCours = @(Get-MachineEnCours)
    $liste = @()
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $vm = $script:Catalogue['vms'][$nom]
        if (-not $AvecPool -and [string]$vm['pool']) { continue }
        $etat = 'arrêtée'
        if (-not (Test-Path -LiteralPath $vm['chemin'] -PathType Leaf)) {
            $etat = 'absente'
        } else {
            foreach ($c in $enCours) { if ($c -ieq $vm['chemin']) { $etat = 'en marche' } }
        }
        $liste += [pscustomobject]@{
            Nom      = $nom
            Etat     = $etat
            Modele   = $vm['modele']
            RamGo    = $vm['ramGo']
            Cpu      = $vm['cpu']
            Reseau   = (@($vm['reseau']) -join ',')
            CreeeLe  = $vm['creeeLe']
            Chemin   = $vm['chemin']
            Ephemere = ($vm['ephemere'] -eq $true)
            Labo     = [string]$vm['labo']
            Pool     = [string]$vm['pool']
            VncPort  = [int]$(if ($vm['vnc'] -and $vm['vnc']['actif'] -eq $true) { $vm['vnc']['port'] } else { 0 })
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
    Start-VmAvecPersonnalisation -Vm $vm -SansInterface:$SansInterface | Out-Null
    return $vm
}

function Stop-VmParNom {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$Brutal)
    Connect-Pilote | Out-Null
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (-not (Test-MachineEnCours -Chemin $vm.Chemin)) {
        Publish-Message 'info' "La VM « $($vm.Nom) » est déjà arrêtée."
    } else {
        $chrono = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-Machine -Machine $vm.Chemin -Brutal:$Brutal
        $comment = if ($Brutal) { 'arrêtée brutalement' } else { 'arrêtée proprement' }
        Publish-Message 'ok' ("VM « {0} » {1} en {2}" -f $vm.Nom, $comment, (Format-Duree $chrono.Elapsed.TotalSeconds))
    }
    # VM éphémère : « je ferme, il ne reste rien ». Supprimée dans la foulée.
    if ($vm.Ephemere) { Remove-VmEphemere -Nom $vm.Nom | Out-Null }
    return $vm
}

# ----------------------------------------------------------------------------
#  VM éphémères (phase 2) : nettoyage paresseux
#  Une VM créée avec --tmp est marquée « ephemere » au catalogue une fois
#  démarrée. Elle est supprimée dès qu'on la trouve éteinte : au début de
#  chaque commande (Invoke-Nettoyage), après « vazy stop », ou sur « vazy gc ».
#  Garde-fou : Remove-VmEphemere refuse toute VM non marquée, quel que soit
#  l'appelant.
# ----------------------------------------------------------------------------

# Supprime une VM éphémère (fichiers + fiche). L'appelant garantit qu'elle est
# éteinte ; si elle tourne encore, l'hyperviseur refuse et l'erreur remonte.
function Remove-VmEphemere {
    param([Parameter(Mandatory = $true)][string]$Nom)
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (-not $vm.Ephemere) {
        throw (New-ErreurOutil "Refus : « $($vm.Nom) » n'est pas une VM éphémère, le nettoyage automatique ne la supprime jamais." `
            "Pour la supprimer volontairement : vazy rm $($vm.Nom)")
    }
    if (Test-Path -LiteralPath $vm.Chemin -PathType Leaf) {
        $reste = Remove-Machine -Machine $vm.Chemin
        if ($reste -and $reste.Type -eq 'attention') { Publish-Message 'attention' $reste.Message }
        $bilan = "éteinte : supprimée ($($vm.Dossier))"
    } else {
        $bilan = 'fichiers déjà disparus : fiche retirée du catalogue'
    }
    $script:Catalogue['vms'].Remove($vm.Nom)
    Save-Catalogue
    Publish-Message 'info' ("VM éphémère « {0} » {1}" -f $vm.Nom, $bilan)
    return $vm
}

# Balayage paresseux, appelé au début de chaque commande. Sans VM éphémère au
# catalogue, il ne coûte rien (aucun appel à l'hyperviseur). Sinon : une
# interrogation de l'état, puis suppression des VM éphémères éteintes, une
# ligne par VM. Au-delà de $script:SeuilNettoyage VM d'un coup, signe probable
# d'anomalie : demande confirmation via $Confirmer (scriptblock recevant la
# liste des noms, renvoyant $true ou $false), sauf -Forcer.
# Renvoie les noms des VM supprimées.
function Invoke-Nettoyage {
    param([scriptblock]$Confirmer = $null, [switch]$Forcer, [switch]$Verbeux)
    $ephemeres = @()
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        # Une VM de réserve est un stock, jamais un déchet : elle est écartée
        # explicitement, même si son drapeau « ephemere » est déjà à faux.
        if ([string]$script:Catalogue['vms'][$nom]['pool']) { continue }
        if ($script:Catalogue['vms'][$nom]['ephemere'] -eq $true) { $ephemeres += $nom }
    }
    if ($ephemeres.Count -eq 0) {
        if ($Verbeux) { Publish-Message 'info' 'Aucune VM éphémère au catalogue : rien à nettoyer.' }
        return @()
    }
    Connect-Pilote | Out-Null
    $enCours = @(Get-MachineEnCours)
    $eteintes = @()
    foreach ($nom in $ephemeres) {
        $chemin = $script:Catalogue['vms'][$nom]['chemin']
        $tourne = $false
        foreach ($c in $enCours) { if ($c -ieq $chemin) { $tourne = $true } }
        if (-not $tourne) { $eteintes += $nom }
    }
    if ($eteintes.Count -eq 0) {
        if ($Verbeux) { Publish-Message 'info' ("{0} VM éphémère(s) en marche ({1}) : rien à nettoyer." -f $ephemeres.Count, ($ephemeres -join ', ')) }
        return @()
    }
    if ($eteintes.Count -gt $script:SeuilNettoyage -and -not $Forcer) {
        $accord = $false
        if ($Confirmer) { $accord = [bool](& $Confirmer $eteintes) }
        if (-not $accord) {
            Publish-Message 'attention' ("{0} VM éphémères éteintes à supprimer ({1}) : c'est beaucoup pour un nettoyage automatique, rien n'a été supprimé. Vérifiez avec vazy list, puis : vazy gc --yes" -f $eteintes.Count, ($eteintes -join ', '))
            return @()
        }
    }
    $supprimees = @()
    foreach ($nom in $eteintes) {
        # Double vérification du marquage juste avant d'agir (Remove-VmEphemere refuse sinon).
        try {
            Remove-VmEphemere -Nom $nom | Out-Null
            $supprimees += $nom
        } catch {
            Publish-Message 'attention' ("VM éphémère « {0} » : suppression impossible ({1})" -f $nom, $_.Exception.Message)
        }
    }
    return $supprimees
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
        if ($reste) { Publish-Message $reste.Type $reste.Message }
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
#  Où vivent les fichiers de labo
#  « vazy lab up tp14 » doit retrouver le TP de la semaine dernière depuis
#  n'importe quel dossier, y compris une session SSH : les fichiers sont donc
#  rangés à un endroit fixe, à côté du catalogue.
# ----------------------------------------------------------------------------

function Get-DossierLabos {
    if ($script:Config['dossierLabos']) { return [Environment]::ExpandEnvironmentVariables($script:Config['dossierLabos']) }
    return (Join-Path $script:DossierDonnees 'labos')
}

# Chemin du fichier d'un labo désigné par un nom court ou par un chemin.
# Ordre de recherche : le chemin tel quel, le dossier courant, le dossier des
# labos de vazy. -PourEcriture renvoie où il serait créé s'il n'existe pas.
function Resolve-CheminLabo {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$PourEcriture)
    $candidats = New-Object 'System.Collections.Generic.List[string]'
    $aExtension = ([System.IO.Path]::GetExtension($Nom) -ne '')
    $aChemin = ($Nom -match '[\\/]' -or $Nom -match '^[A-Za-z]:')
    try { $candidats.Add($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Nom)) } catch { }
    if (-not $aExtension) {
        try { $candidats.Add($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Nom + '.json')) } catch { }
    }
    if (-not $aChemin) {
        $dossier = Get-DossierLabos
        $candidats.Add((Join-Path $dossier $Nom))
        if (-not $aExtension) { $candidats.Add((Join-Path $dossier ($Nom + '.json'))) }
    }
    foreach ($c in $candidats) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
    if (-not $PourEcriture) { return $null }
    # Création : un nom court va dans le dossier des labos, un chemin reste où il est.
    if ($aChemin) { return $candidats[0] }
    return (Join-Path (Get-DossierLabos) $(if ($aExtension) { $Nom } else { $Nom + '.json' }))
}

# Nom de labo déduit de ce que l'utilisateur a tapé : « tp14 », « tp14.json »
# ou « D:\TP\tp14.json » donnent tous « tp14 ».
function Get-NomLabo {
    param([Parameter(Mandatory = $true)][string]$Entree)
    return [System.IO.Path]::GetFileNameWithoutExtension($Entree.TrimEnd('\', '/'))
}

# Écrit une description de labo (objet ordonné) dans un fichier.
function Save-DescriptionLabo {
    param([Parameter(Mandatory = $true)]$Description, [Parameter(Mandatory = $true)][string]$Chemin)
    $json = ConvertTo-Json -InputObject $Description -Depth 8
    if (Assert-PasSimulation "écriture du fichier de labo $Chemin") { return $json }
    try {
        $dossier = Split-Path -Parent $Chemin
        if ($dossier -and -not (Test-Path -LiteralPath $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
        [System.IO.File]::WriteAllText($Chemin, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        throw (New-ErreurOutil "Impossible d'écrire le fichier de labo $Chemin : $($_.Exception.Message)" "Vérifiez le chemin et vos droits d'écriture.")
    }
    return $json
}

# ----------------------------------------------------------------------------
#  Fichier de labo (phase 3)
#  L'interface lit et valide le fichier JSON (Read-FichierLabo) et fournit un
#  objet Labo : Nom, Fichier, Delai (secondes entre deux démarrages), Machines
#  = liste d'objets { Nom, Modele, RamGo, Cpu, Modes, Brut, SansInterface,
#  SansDemarrage, Apres (noms des machines à démarrer avant) }.
#  Les VM s'appellent <labo>-<machine> et portent le nom du labo au catalogue,
#  ce qui isole les labos entre eux et permet d'en monter plusieurs.
# ----------------------------------------------------------------------------

function Get-NomVmLabo {
    param($Labo, [string]$Machine)
    return ('{0}-{1}' -f $Labo.Nom, $Machine)
}

# Ordre de démarrage : tri topologique stable (à égalité, l'ordre du fichier).
# Refuse une dépendance inconnue, une machine qui dépend d'elle-même, et les
# cycles, en nommant les machines concernées.
function Get-OrdreLabo {
    param($Labo)
    $noms = @($Labo.Machines | ForEach-Object { $_.Nom })
    foreach ($m in $Labo.Machines) {
        foreach ($dep in @($m.Apres)) {
            if ($dep -ieq $m.Nom) {
                throw (New-ErreurOutil "Labo « $($Labo.Nom) » : la machine « $($m.Nom) » dépend d'elle-même (clé « apres »)." "Retirez « $($m.Nom) » de sa propre clé « apres » dans $($Labo.Fichier).")
            }
            if ($noms -notcontains $dep) {
                throw (New-ErreurOutil "Labo « $($Labo.Nom) » : la machine « $($m.Nom) » doit démarrer après « $dep », qui n'existe pas dans le fichier." ("Machines du fichier : " + ($noms -join ', ') + ". Corrigez la clé « apres » dans $($Labo.Fichier)."))
            }
        }
    }
    $restantes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($m in $Labo.Machines) { $restantes.Add($m) }
    $ordre = @()
    while ($restantes.Count -gt 0) {
        $prete = $null
        $faits = @($ordre | ForEach-Object { $_.Nom })
        foreach ($m in $restantes) {
            $ok = $true
            foreach ($dep in @($m.Apres)) { if ($faits -notcontains $dep) { $ok = $false } }
            if ($ok) { $prete = $m; break }
        }
        if ($null -eq $prete) {
            $cycle = @($restantes | ForEach-Object { $_.Nom }) -join ', '
            throw (New-ErreurOutil "Labo « $($Labo.Nom) » : dépendances circulaires entre $cycle (chacune attend une autre)." "Corrigez les clés « apres » de ces machines dans $($Labo.Fichier) : l'une d'elles doit pouvoir démarrer sans attendre les autres.")
        }
        $ordre += $prete
        $restantes.Remove($prete) | Out-Null
    }
    return $ordre
}

# Vérifications avant toute action. Si l'une échoue, rien n'a été créé :
# modèles au catalogue (fichier et instantané présents), noms valides et
# libres ou appartenant déjà à ce labo, ordre de démarrage calculable.
# Renvoie l'ordre de démarrage.
function Test-Labo {
    param($Labo)
    Connect-Pilote | Out-Null
    Test-NomValide -Nom $Labo.Nom -Role 'nom de labo'
    if (@($Labo.Machines).Count -eq 0) {
        throw (New-ErreurOutil "Labo « $($Labo.Nom) » : aucune machine dans le fichier." "Ajoutez au moins une entrée sous « machines » dans $($Labo.Fichier) (voir README, section « Fichier de labo »).")
    }
    $ordre = Get-OrdreLabo -Labo $Labo
    Test-RequisLabo -Labo $Labo
    $modeles = @($Labo.Machines | ForEach-Object { $_.Modele } | Select-Object -Unique)
    foreach ($alias in $modeles) {
        $m = Get-ModeleDuCatalogue -Alias $alias
        if (-not (Test-Path -LiteralPath $m['chemin'] -PathType Leaf)) {
            throw (New-ErreurOutil "Le fichier du modèle « $alias » est introuvable : $($m['chemin'])" "Ré-enregistrez-le : vazy template rm $alias puis vazy template add <chemin de la VM> --name $alias")
        }
        $instantanes = @(Get-MachineInstantanes -Machine $m['chemin'])
        if ($instantanes -cnotcontains $m['instantane']) {
            throw (New-ErreurOutil "L'instantané « $($m['instantane']) » du modèle « $alias » n'existe plus." "Voir vazy template list ; recréez l'instantané puis ré-enregistrez le modèle (vazy template rm / add).")
        }
    }
    foreach ($mach in $Labo.Machines) {
        $nomVm = Get-NomVmLabo -Labo $Labo -Machine $mach.Nom
        Test-NomValide -Nom $nomVm
        if ($script:Catalogue['modeles'].Contains($nomVm)) {
            throw (New-ErreurOutil "Le nom « $nomVm » est celui d'un modèle." "Renommez le labo ou la machine dans $($Labo.Fichier).")
        }
        if ($script:Catalogue['vms'].Contains($nomVm)) {
            $proprietaire = [string]$script:Catalogue['vms'][$nomVm]['labo']
            if ($proprietaire -ine $Labo.Nom) {
                $origine = if ($proprietaire) { "au labo « $proprietaire »" } else { 'à une VM créée à la main' }
                throw (New-ErreurOutil "La VM « $nomVm » existe déjà mais appartient $origine, pas au labo « $($Labo.Nom) »." "Renommez le labo ou la machine dans $($Labo.Fichier), ou supprimez cette VM : vazy rm $nomVm")
            }
        }
    }
    return $ordre
}

# Prérequis d'un labo partagé : le fichier vient d'ailleurs et référence des
# modèles sous des noms standards. On vérifie AVANT toute action, et le
# message dit exactement quoi préparer (ou quel alias poser).
function Test-RequisLabo {
    param($Labo)
    if (@($Labo.Requis).Count -eq 0) { return }
    $manquants = @()
    foreach ($r in $Labo.Requis) {
        $reel = Resolve-AliasModele -Alias $r.Modele
        if (-not $script:Catalogue['modeles'].Contains($reel)) {
            $details = @()
            if ($r.Os) { $details += "système $($r.Os)" }
            if ($r.Version) { $details += "version $($r.Version)" }
            if ($r.DisqueMinGo -gt 0) { $details += ("disque de {0} Go au moins" -f $r.DisqueMinGo) }
            $manquants += [pscustomobject]@{ Modele = $r.Modele; Details = ($details -join ', ') }
            continue
        }
        # Le modèle existe : on vérifie ce qui est vérifiable sans le démarrer.
        $fiche = $script:Catalogue['modeles'][$reel]
        if ($r.Os) {
            $osReel = Get-SystemeModele -Alias $reel
            if ($osReel -ne 'inconnu' -and $osReel -ne $r.Os.ToLower()) {
                Publish-Message 'attention' ("le labo demande « {0} » sous {1} ; votre modèle « {2} » est un {3}." -f $r.Modele, $r.Os, $reel, $osReel)
            }
        }
        if ($r.DisqueMinGo -gt 0 -and (Test-Path -LiteralPath $fiche['chemin'] -PathType Leaf)) {
            $disque = Get-MachineDisqueGo -Machine $fiche['chemin']
            if ($disque -gt 0 -and $disque -lt $r.DisqueMinGo) {
                Publish-Message 'attention' ("le labo demande « {0} » avec au moins {1} Go de disque ; votre modèle « {2} » en déclare {3}." -f $r.Modele, $r.DisqueMinGo, $reel, $disque)
            }
        }
    }
    if ($manquants.Count -gt 0) {
        $liste = ($manquants | ForEach-Object { if ($_.Details) { "« $($_.Modele) » ($($_.Details))" } else { "« $($_.Modele) »" } }) -join ', '
        $connus = @($script:Catalogue['modeles'].Keys)
        $conseil = "Préparez le ou les modèles manquants (README, « Préparer un modèle »), puis : vazy template add <chemin de la VM> --name <nom>.`n"
        if ($connus.Count -gt 0) {
            $conseil += "Si vous avez déjà un modèle équivalent sous un autre nom, faites-le répondre au nom attendu : vazy template alias <votre modèle> $($manquants[0].Modele)`n"
            $conseil += "Vos modèles : " + ($connus -join ', ') + "."
        }
        throw (New-ErreurOutil ("Labo « {0} » : {1} modèle(s) requis manquant(s) : {2}. Aucune VM n'a été créée." -f $Labo.Nom, $manquants.Count, $liste) $conseil)
    }
}

# État de chaque machine du labo, plus les VM du catalogue rattachées au labo
# mais absentes du fichier (retirées du fichier après un « lab up »).
function Get-StatutLabo {
    param($Labo)
    Connect-Pilote | Out-Null
    $enCours = @(Get-MachineEnCours)
    $lignes = @()
    foreach ($m in $Labo.Machines) {
        $nomVm = Get-NomVmLabo -Labo $Labo -Machine $m.Nom
        $etat = 'à créer'; $ram = $m.RamGo; $cpu = $m.Cpu; $reseau = (@($m.Modes) -join ',')
        if ($script:Catalogue['vms'].Contains($nomVm)) {
            $vm = $script:Catalogue['vms'][$nomVm]
            $etat = 'arrêtée'
            if (-not (Test-Path -LiteralPath $vm['chemin'] -PathType Leaf)) { $etat = 'absente' }
            else { foreach ($c in $enCours) { if ($c -ieq $vm['chemin']) { $etat = 'en marche' } } }
            if ([string]$vm['labo'] -ine $Labo.Nom) { $etat = 'hors labo' }
            $ram = $vm['ramGo']; $cpu = $vm['cpu']; $reseau = (@($vm['reseau']) -join ',')
        }
        $lignes += [pscustomobject]@{ Machine = $m.Nom; Vm = $nomVm; Etat = $etat; Modele = $m.Modele; RamGo = $ram; Cpu = $cpu; Reseau = $reseau; Apres = (@($m.Apres) -join ','); DansFichier = $true }
    }
    $connues = @($lignes | ForEach-Object { $_.Vm })
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $vm = $script:Catalogue['vms'][$nom]
        if ([string]$vm['labo'] -ine $Labo.Nom -or $connues -contains $nom) { continue }
        $etat = 'arrêtée'
        if (-not (Test-Path -LiteralPath $vm['chemin'] -PathType Leaf)) { $etat = 'absente' }
        else { foreach ($c in $enCours) { if ($c -ieq $vm['chemin']) { $etat = 'en marche' } } }
        $lignes += [pscustomobject]@{ Machine = '(hors fichier)'; Vm = $nom; Etat = $etat; Modele = $vm['modele']; RamGo = $vm['ramGo']; Cpu = $vm['cpu']; Reseau = (@($vm['reseau']) -join ','); Apres = ''; DansFichier = $false }
    }
    return $lignes   # l'appelant entoure de @()
}

# Défait les créations d'un montage de labo interrompu en cours de route.
#
# C'est la seule suppression automatique de vazy en dehors des VM éphémères,
# et elle est volontairement étroite : elle ne porte QUE sur les VM créées par
# l'appel en cours. Une VM qui existait avant le montage contient peut-être le
# travail de l'utilisateur ; personne n'a demandé sa suppression, elle reste.
function Undo-CreationsLabo {
    param([string[]]$Noms, [string]$Labo)
    $liste = @($Noms)
    if ($liste.Count -eq 0) { return }
    Publish-Message 'attention' ("Montage interrompu : suppression des {0} VM créées par ce « lab up » ({1}). Les VM du labo antérieures à cette commande sont conservées." -f $liste.Count, ($liste -join ', '))
    foreach ($nom in $liste) {
        try { Remove-VmParNom -Nom $nom | Out-Null }
        catch { Publish-Message 'attention' ("« {0} » n'a pas pu être supprimée ({1}). Supprimez-la à la main : vazy rm {0}" -f $nom, $_.Exception.Message) }
    }
}

# Monte le labo : crée les VM manquantes, démarre les VM éteintes dans l'ordre
# des dépendances avec un délai entre deux démarrages, laisse le reste
# tranquille. Relançable à volonté.
function Invoke-LaboUp {
    param($Labo)
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Publish-Message 'etape' "Vérifications du labo « $($Labo.Nom) »"
    $ordre = @(Test-Labo -Labo $Labo)
    $statut = @(Get-StatutLabo -Labo $Labo)

    # Fiches dont les fichiers ont disparu : on les retire pour recréer la VM.
    foreach ($s in $statut) {
        if ($s.DansFichier -and $s.Etat -eq 'absente') {
            Publish-Message 'attention' "« $($s.Vm) » : fichiers disparus en dehors de vazy, la VM sera recréée."
            $script:Catalogue['vms'].Remove($s.Vm)
            Save-Catalogue
            $s.Etat = 'à créer'
        }
    }
    $aCreer = @($statut | Where-Object { $_.DansFichier -and $_.Etat -eq 'à créer' } | ForEach-Object { $_.Machine })

    # Espace disque : la somme des VM à créer, par disque de destination.
    $parDossier = @{}
    foreach ($m in $Labo.Machines) {
        if ($aCreer -notcontains $m.Nom) { continue }
        $dossier = Get-DossierVms -Modele (Get-ModeleDuCatalogue -Alias $m.Modele)
        if (-not $parDossier.ContainsKey($dossier)) { $parDossier[$dossier] = 0.0 }
        $parDossier[$dossier] += [double]$m.RamGo
    }
    foreach ($dossier in $parDossier.Keys) {
        Test-EspaceDisque -Dossier $dossier -RamGo $parDossier[$dossier] -Libelle ("les {0} VM du labo" -f $aCreer.Count) | Out-Null
    }
    $modelesTexte = (@($ordre | ForEach-Object { $_.Modele } | Select-Object -Unique) -join ', ')
    $ordreTexte   = (@($ordre | ForEach-Object { $_.Nom }) -join ' > ')
    Publish-Message 'ok' ("{0} machine(s), modèles {1}, ordre de démarrage : {2}" -f @($Labo.Machines).Count, $modelesTexte, $ordreTexte)
    Publish-Message 'ok' ("à créer : {0}" -f $(if ($aCreer.Count -gt 0) { $aCreer -join ', ' } else { 'rien, toutes les VM existent' }))
    Invoke-AvertissementHyperV

    # --- Création des VM manquantes (sans les démarrer : l'ordre vient après) --
    # Un labo monté à moitié n'est bon à rien et laisse l'utilisateur devant un
    # ménage à faire : si une création échoue, on défait celles de ce montage-ci.
    $n = 0
    $creeesIci = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in $ordre) {
        if ($aCreer -notcontains $m.Nom) { continue }
        $n++
        $nomVm = Get-NomVmLabo -Labo $Labo -Machine $m.Nom
        Publish-Message 'etape' ("Création {0}/{1} : {2} -> VM « {3} »" -f $n, $aCreer.Count, $m.Nom, $nomVm)
        try {
            New-VmDepuisModele -Modele $m.Modele -Nom $nomVm -RamGo $m.RamGo -Cpu $m.Cpu -Modes @($m.Modes) -Brut @($m.Brut) `
                               -SansDemarrage -Labo $Labo.Nom -NomHote $m.NomHote -ConfigInvite $m.ConfigInvite -Vnc:$m.Vnc | Out-Null
            $creeesIci.Add($nomVm)
        } catch {
            $defaites = $creeesIci.Count
            Undo-CreationsLabo -Noms $creeesIci.ToArray() -Labo $Labo.Nom
            $fait = if ($defaites -gt 0) { " Les $defaites VM déjà créées par ce montage ont été supprimées." } else { '' }
            $_.Exception.Data['Conseil'] = [string]$_.Exception.Data['Conseil'] +
                " Le labo « $($Labo.Nom) » n'a pas été monté.$fait Corrigez la cause, puis relancez : vazy lab up $($Labo.Nom)"
            throw
        }
    }

    # --- Démarrage dans l'ordre des dépendances -----------------------------
    $enCours = @(Get-MachineEnCours)
    $demarrees = 0
    $dejaDemarreIci = $false
    foreach ($m in $ordre) {
        $nomVm = Get-NomVmLabo -Labo $Labo -Machine $m.Nom
        if ($m.SansDemarrage) {
            Publish-Message 'info' "$($m.Nom) ($nomVm) : non démarrée (nostart)."
            continue
        }
        $chemin = $script:Catalogue['vms'][$nomVm]['chemin']
        $tourne = $false
        foreach ($c in $enCours) { if ($c -ieq $chemin) { $tourne = $true } }
        if ($tourne) {
            Publish-Message 'info' "$($m.Nom) ($nomVm) : déjà en marche."
            continue
        }
        if ($dejaDemarreIci -and $Labo.Delai -gt 0) {
            Publish-Message 'info' ("attente de {0} s avant {1}" -f $Labo.Delai, $m.Nom)
            if (-not $script:Simulation) { Start-Sleep -Seconds $Labo.Delai }
        }
        $apres = if (@($m.Apres).Count -gt 0) { ' (après ' + (@($m.Apres) -join ', ') + ')' } else { '' }
        Publish-Message 'etape' ("Démarrage de {0} -> VM « {1} »{2}" -f $m.Nom, $nomVm, $apres)
        Start-VmAvecPersonnalisation -Vm (Get-VmDuCatalogue -Nom $nomVm) -SansInterface:$m.SansInterface | Out-Null
        $demarrees++
        $dejaDemarreIci = $true
    }
    return [pscustomobject]@{ Nom = $Labo.Nom; Creees = $aCreer.Count; Demarrees = $demarrees; Duree = $chrono.Elapsed.TotalSeconds }
}

# Démonte le labo : arrêt de toutes ses VM dans l'ordre inverse du démarrage,
# puis suppression (sauf -StopSeulement). La confirmation est demandée par
# l'interface. Avec -StopSeulement, l'arrêt est propre, avec repli en arrêt
# forcé si les outils de l'invité ne répondent pas (ou -Brutal d'emblée).
function Invoke-LaboDown {
    param($Labo, [switch]$StopSeulement, [switch]$Brutal)
    Connect-Pilote | Out-Null
    $statut = @(Get-StatutLabo -Labo $Labo | Where-Object { $_.Etat -notin 'à créer', 'hors labo' })
    $ordreNoms = @()
    try { $ordreNoms = @((Get-OrdreLabo -Labo $Labo) | ForEach-Object { Get-NomVmLabo -Labo $Labo -Machine $_.Nom }) }
    catch { $ordreNoms = @($Labo.Machines | ForEach-Object { Get-NomVmLabo -Labo $Labo -Machine $_.Nom }) }
    [array]::Reverse($ordreNoms)
    $cibles = @()
    foreach ($nom in $ordreNoms) { foreach ($s in $statut) { if ($s.Vm -ieq $nom) { $cibles += $s } } }
    foreach ($s in $statut) { if (-not $s.DansFichier) { $cibles += $s } }

    $arretees = 0; $supprimees = 0
    foreach ($s in $cibles) {
        if ($script:Simulation -and -not $script:Catalogue['vms'].Contains($s.Vm)) { continue }
        if ($StopSeulement) {
            if ($s.Etat -ne 'en marche') { Publish-Message 'info' "« $($s.Vm) » : déjà arrêtée."; continue }
            $chemin = $script:Catalogue['vms'][$s.Vm]['chemin']
            Publish-Message 'etape' "Arrêt de « $($s.Vm) »"
            if ($Brutal) {
                Stop-Machine -Machine $chemin -Brutal
                Publish-Message 'ok' 'arrêt forcé'
            } else {
                try {
                    Stop-Machine -Machine $chemin
                    Publish-Message 'ok' 'arrêt propre'
                } catch {
                    if ($_.Exception.Message -notmatch 'Tools') { throw }
                    Publish-Message 'attention' "les outils de l'invité ne répondent pas : arrêt forcé"
                    Stop-Machine -Machine $chemin -Brutal
                }
            }
            $arretees++
        } else {
            Publish-Message 'etape' "Suppression de « $($s.Vm) »"
            Remove-VmParNom -Nom $s.Vm | Out-Null
            $supprimees++
        }
    }
    return [pscustomobject]@{ Nom = $Labo.Nom; Arretees = $arretees; Supprimees = $supprimees; Total = $cibles.Count }
}

# ----------------------------------------------------------------------------
#  Export d'un labo : l'inverse de « lab up ». On lit les VM du catalogue et on
#  reconstruit la description qui les recréerait à l'identique.
# ----------------------------------------------------------------------------

# Construit la description d'un labo à partir des VM du catalogue :
#   -Labo <nom>     : les VM rattachées à ce labo (« lab up » précédent)
#   -Prefixe <p>    : les VM dont le nom commence par « p- » (TP monté à la main)
#   -Vms <noms>     : une liste explicite
# Le nom court de chaque machine est le nom de la VM sans son préfixe.
function Export-Labo {
    param(
        [string]$Labo = '',
        [string]$Prefixe = '',
        [string[]]$Vms = @(),
        [int]$Delai = 5,
        [switch]$AvecRequis,
        [string[]]$Ordre = @()      # noms courts, dans l'ordre de démarrage voulu
    )
    Connect-Pilote | Out-Null
    $nomLabo = if ($Labo) { $Labo } elseif ($Prefixe) { $Prefixe } else { 'labo' }
    $choisies = @()
    if ($Vms.Count -gt 0) {
        # Liste explicite : elle peut restreindre un labo à certaines de ses VM.
        foreach ($n in $Vms) { $choisies += (Get-VmDuCatalogue -Nom $n) }
    } else {
        foreach ($n in @($script:Catalogue['vms'].Keys)) {
            $vm = Get-VmDuCatalogue -Nom $n
            if ($Labo -and $vm.Labo -ieq $Labo) { $choisies += $vm }
            elseif ($Prefixe -and $n -ilike ($Prefixe + '-*')) { $choisies += $vm }
        }
    }
    if ($choisies.Count -eq 0) {
        $conseil = if ($Labo) { "Aucune VM n'est rattachée au labo « $Labo » (colonne LABO de vazy list)." }
                   elseif ($Prefixe) { "Aucune VM ne commence par « $Prefixe- » (voir vazy list)." }
                   else { 'Indiquez les VM à exporter.' }
        throw (New-ErreurOutil "Rien à exporter." ($conseil + "`nUsage : vazy lab export <fichier.json> --labo <nom> | --prefixe <p> | --vms a,b,c"))
    }

    # L'ordre des machines dans le fichier EST l'ordre de démarrage : on
    # respecte celui demandé, sinon l'ordre de création, à défaut le nom.
    $prefixeReel = if ($Labo) { $Labo } else { $Prefixe }
    $rang = @{}
    for ($i = 0; $i -lt $Ordre.Count; $i++) { $rang[$Ordre[$i].ToLower()] = $i }
    $triees = @($choisies | Sort-Object @{ Expression = {
            $court = $_.Nom
            if ($prefixeReel -and $court -ilike ($prefixeReel + '-*')) { $court = $court.Substring($prefixeReel.Length + 1) }
            if ($rang.ContainsKey($court.ToLower())) { $rang[$court.ToLower()] } else { 1000 }
        } }, @{ Expression = { $_.CreeeLe } }, @{ Expression = { $_.Nom } })

    $machines = [ordered]@{}
    $requis = @{}
    foreach ($vm in $triees) {
        $court = $vm.Nom
        if ($prefixeReel -and $court -ilike ($prefixeReel + '-*')) { $court = $court.Substring($prefixeReel.Length + 1) }
        $entree = [ordered]@{ modele = $vm.Modele; ram = $vm.RamGo; cpu = $vm.Cpu }
        # Les segments personnalisés sont stockés sous l'identifiant du pilote
        # (« nomme:vmnet2ptr ») : on les réécrit sous leur nom parlant, sinon le
        # fichier exporté ne serait relisible que sur cette machine-ci.
        $modes = @()
        $segments = @()
        foreach ($m in @($vm.Reseau)) {
            if ([string]$m -match '^(?i)nomme:(.+)$') {
                $identifiant = $Matches[1]
                $parlant = Get-NomReseauParIdentifiant -Identifiant $identifiant
                if (-not $parlant) {
                    Publish-Message 'attention' ("la VM « {0} » utilise le segment {1}, inconnu du catalogue de vazy : il est exporté tel quel et devra être recréé à la main." -f $vm.Nom, $identifiant)
                    $parlant = $identifiant
                }
                $segments += $parlant
            } else { $modes += [string]$m }
        }
        $total = $modes.Count + $segments.Count
        if ($total -eq 0) { $entree['reseau'] = 0 }
        elseif ($modes.Count -eq 1) { $entree['mode'] = $modes[0] }
        elseif ($modes.Count -gt 1) { $entree['mode'] = $modes }
        if ($segments.Count -eq 1) { $entree['reseau-nomme'] = $segments[0] }
        elseif ($segments.Count -gt 1) { $entree['reseau-nomme'] = $segments }
        # Adressage statique : réexporté tel quel, c'est souvent le cœur du TP.
        $invite = $vm.ConfigInvite
        if ($null -ne $invite) {
            foreach ($cle in @('ip', 'masque', 'passerelle', 'cle_ssh')) {
                if ($invite.Contains($cle) -and [string]$invite[$cle]) { $entree[$cle] = [string]$invite[$cle] }
            }
            $dns = @($invite['dns'] | Where-Object { $_ })
            if ($dns.Count -eq 1) { $entree['dns'] = $dns[0] } elseif ($dns.Count -gt 1) { $entree['dns'] = $dns }
        }
        if ($vm.NomHote -and $vm.NomHote -ine $court) { $entree['hostname'] = $vm.NomHote }
        elseif (-not $vm.NomHote) { $entree['hostname'] = $false }
        if ($vm.VncActif) { $entree['vnc'] = $true }
        $sets = @($vm.Sets)
        if ($sets.Count -gt 0) {
            $objet = [ordered]@{}
            foreach ($s in $sets) { $i = ([string]$s).IndexOf('='); if ($i -gt 0) { $objet[([string]$s).Substring(0, $i)] = ([string]$s).Substring($i + 1) } }
            if ($objet.Count -gt 0) { $entree['set'] = $objet }
        }
        $machines[$court] = $entree
        if (-not $requis.ContainsKey($vm.Modele)) {
            $bloc = [ordered]@{ modele = $vm.Modele }
            $os = try { Get-SystemeModele -Alias $vm.Modele } catch { 'inconnu' }
            if ($os -ne 'inconnu') { $bloc['os'] = $os }
            try {
                $fiche = Get-ModeleDuCatalogue -Alias $vm.Modele
                if (Test-Path -LiteralPath $fiche['chemin'] -PathType Leaf) {
                    $disque = Get-MachineDisqueGo -Machine $fiche['chemin']
                    if ($disque -gt 0) { $bloc['disque_min'] = [math]::Floor($disque) }
                }
            } catch { }
            $requis[$vm.Modele] = $bloc
        }
    }
    $description = [ordered]@{ labo = $nomLabo; delai = $Delai }
    if ($AvecRequis) { $description['requis'] = @($requis.Keys | Sort-Object | ForEach-Object { $requis[$_] }) }
    $description['machines'] = $machines

    # Les VM exportées deviennent celles de ce labo : sans cela, rejouer le
    # fichier bloquerait sur « la VM existe mais n'appartient pas au labo », et
    # « lab down » ne les reconnaîtrait pas. Elles gardent leur nom.
    $adoptees = @()
    foreach ($vm in $choisies) {
        if ([string]$vm.Labo -ine $nomLabo) {
            $script:Catalogue['vms'][$vm.Nom]['labo'] = $nomLabo
            $adoptees += $vm.Nom
        }
    }
    if ($adoptees.Count -gt 0) {
        Save-Catalogue
        Publish-Message 'info' ("{0} VM rattachée(s) au labo « {1} » : {2}. Elles seront désormais gérées par vazy lab up / down avec ce fichier." -f $adoptees.Count, $nomLabo, ($adoptees -join ', '))
    }
    return [pscustomobject]@{ Description = $description; Machines = @($machines.Keys); Nom = $nomLabo; Adoptees = $adoptees }
}

# ----------------------------------------------------------------------------
#  Diagnostic : la dérive entre le catalogue et le disque est certaine, pas
#  probable. « doctor » la rend visible.
#  Renvoie une liste de constats : Categorie, Etat (ok | attention | erreur),
#  Objet, Message, Conseil.
# ----------------------------------------------------------------------------

function Invoke-Doctor {
    $constats = New-Object 'System.Collections.Generic.List[object]'
    function Ajouter([string]$Categorie, [string]$Etat, [string]$Objet, [string]$Message, [string]$Conseil = '') {
        $constats.Add([pscustomobject]@{ Categorie = $Categorie; Etat = $Etat; Objet = $Objet; Message = $Message; Conseil = $Conseil })
    }

    # --- Hyperviseur ---------------------------------------------------------
    $pilote = $null
    try {
        $pilote = Connect-Pilote
        Ajouter 'Hyperviseur' 'ok' $pilote.Nom $pilote.Executable
    } catch {
        Ajouter 'Hyperviseur' 'erreur' 'introuvable' $_.Exception.Message ([string]$_.Exception.Data['Conseil'])
    }
    if ($pilote) {
        try {
            $enCours = @(Get-MachineEnCours)
            Ajouter 'Hyperviseur' 'ok' 'dialogue' ("répond ; {0} machine(s) en marche" -f $enCours.Count)
        } catch {
            Ajouter 'Hyperviseur' 'erreur' 'dialogue' $_.Exception.Message ([string]$_.Exception.Data['Conseil'])
        }
    }

    # --- Hyper-V -------------------------------------------------------------
    $infos = Get-InfosHote
    if ($infos.HyperviseurPresent -eq $true -and (-not $pilote -or $pilote.SensibleHyperV)) {
        Ajouter 'Hôte' 'attention' 'Hyper-V' 'actif : VMware tourne en mode dégradé (VM plus lentes, pas de virtualisation imbriquée)' 'Invite de commandes administrateur puis redémarrage : bcdedit /set hypervisorlaunchtype off (WSL2 et Docker Desktop cesseront de fonctionner). Voir README, section Hyper-V.'
    } elseif ($infos.HyperviseurPresent -eq $false) {
        Ajouter 'Hôte' 'ok' 'Hyper-V' 'inactif : VMware a la main sur le processeur'
    }
    if ($infos.RamPhysiqueGo -gt 0) { Ajouter 'Hôte' 'ok' 'mémoire' ("{0} Go de RAM physique" -f $infos.RamPhysiqueGo) }

    # --- Espace disque -------------------------------------------------------
    $dossiers = New-Object 'System.Collections.Generic.List[string]'
    if ($script:Config['dossierVms']) { $dossiers.Add([Environment]::ExpandEnvironmentVariables($script:Config['dossierVms'])) }
    foreach ($alias in @($script:Catalogue['modeles'].Keys)) {
        try { $d = Get-DossierVms -Modele $script:Catalogue['modeles'][$alias]; if ($dossiers -notcontains $d) { $dossiers.Add($d) } } catch { }
    }
    foreach ($d in $dossiers) {
        $libre = Get-EspaceLibreGo -Dossier $d
        if ($null -eq $libre) { Ajouter 'Disque' 'attention' $d 'espace libre impossible à mesurer' 'Le dossier existe-t-il encore ?' }
        elseif ($libre -lt 10) { Ajouter 'Disque' 'erreur' $d ("{0:0.#} Go libres" -f $libre) 'Il n''y a plus de quoi créer une VM. Libérez de la place, ou changez de dossier : vazy config dossierVms <chemin>' }
        elseif ($libre -lt 30) { Ajouter 'Disque' 'attention' $d ("{0:0.#} Go libres" -f $libre) 'De quoi tenir encore quelques VM seulement.' }
        else { Ajouter 'Disque' 'ok' $d ("{0:0.#} Go libres" -f $libre) }
    }

    # --- Modèles -------------------------------------------------------------
    $enCours = @()
    if ($pilote) { try { $enCours = @(Get-MachineEnCours) } catch { } }
    foreach ($alias in @($script:Catalogue['modeles'].Keys)) {
        $m = $script:Catalogue['modeles'][$alias]
        $chemin = [string]$m['chemin']
        $clones = @()
        foreach ($n in $script:Catalogue['vms'].Keys) {
            if ($script:Catalogue['vms'][$n]['modele'] -ieq $alias -and $script:Catalogue['vms'][$n]['autonome'] -ne $true) { $clones += $n }
        }
        $suffixe = if ($clones.Count -gt 0) { " ; {0} clone(s) lié(s) en dépendent : {1}" -f $clones.Count, ($clones -join ', ') } else { ' ; aucun clone lié' }
        if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) {
            Ajouter 'Modèle' 'erreur' $alias ("fichier introuvable : $chemin" + $suffixe) "Remettez le modèle à cet emplacement exact, ou restaurez-le depuis une sauvegarde. Sans lui, ses clones liés ne démarrent plus. S'il a été déplacé volontairement : vazy template rm $alias puis vazy template add <nouveau chemin> --name $alias"
            continue
        }
        $etatModele = 'ok'; $messages = @()
        foreach ($c in $enCours) { if ($c -ieq $chemin) { $etatModele = 'erreur'; $messages += 'EN MARCHE (un modèle ne se démarre jamais)' } }
        if (-not (Test-MachineModele -Machine $chemin)) {
            if ($etatModele -eq 'ok') { $etatModele = 'attention' }
            $messages += 'marque de protection absente'
        }
        try {
            $instantanes = @(Get-MachineInstantanes -Machine $chemin)
            if ($instantanes -cnotcontains [string]$m['instantane']) {
                $etatModele = 'erreur'
                $messages += ("instantané « {0} » absent (présents : {1})" -f $m['instantane'], $(if ($instantanes.Count) { $instantanes -join ', ' } else { 'aucun' }))
            } else {
                $messages += ("instantané « {0} » présent" -f $m['instantane'])
            }
        } catch {
            $etatModele = 'erreur'; $messages += "instantanés illisibles : $($_.Exception.Message)"
        }
        $conseil = ''
        if ($etatModele -eq 'erreur') {
            $conseil = "Éteignez le modèle s'il tourne. Si son instantané a disparu, les clones liés existants sont probablement perdus : recréez l'instantané puis ré-enregistrez le modèle (vazy template rm $alias ; vazy template add ""$chemin"" --snapshot <nom>)."
        } elseif ($etatModele -eq 'attention') {
            $conseil = "La marque se repose seule au prochain lancement ; si elle disparaît de nouveau, vérifiez les droits sur le dossier du modèle."
        }
        Ajouter 'Modèle' $etatModele $alias (($messages -join ' ; ') + $suffixe) $conseil
    }
    if (@($script:Catalogue['modeles'].Keys).Count -eq 0) {
        Ajouter 'Modèle' 'attention' '(aucun)' 'aucun modèle enregistré' 'Préparez-en un (README, « Préparer un modèle ») puis : vazy template add <chemin de la VM>'
    }

    # --- VM du catalogue -----------------------------------------------------
    $dossiersConnus = New-Object 'System.Collections.Generic.List[string]'
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $vm = Get-VmDuCatalogue -Nom $nom
        if ($vm.Dossier) { $dossiersConnus.Add([string]$vm.Dossier) }
        if (-not (Test-Path -LiteralPath $vm.Chemin -PathType Leaf)) {
            Ajouter 'VM' 'erreur' $nom "fichiers disparus : $($vm.Chemin)" "Supprimée en dehors de vazy. Retirez la fiche : vazy rm $nom"
            continue
        }
        $messages = @(); $etat = 'ok'
        $enMarche = $false
        foreach ($c in $enCours) { if ($c -ieq $vm.Chemin) { $enMarche = $true } }
        $messages += $(if ($enMarche) { 'en marche' } else { 'arrêtée' })
        if ($vm.Autonome) { $messages += 'autonome (clone complet)' }
        else {
            if (-not $script:Catalogue['modeles'].Contains($vm.Modele)) {
                $etat = 'attention'; $messages += "modèle « $($vm.Modele) » retiré du catalogue"
            } else {
                $cheminModele = [string]$script:Catalogue['modeles'][$vm.Modele]['chemin']
                if (-not (Test-Path -LiteralPath $cheminModele -PathType Leaf)) {
                    $etat = 'erreur'; $messages += "modèle « $($vm.Modele) » introuvable : la VM ne démarrera pas"
                } elseif ($vm.Empreinte -and @($vm.Empreinte.Keys).Count -gt 0) {
                    $bilan = Test-MachineEmpreinte -Machine $cheminModele -Empreinte $vm.Empreinte
                    if ($bilan.Erreurs.Count -gt 0) { $etat = 'erreur'; $messages += $bilan.Erreurs }
                    elseif ($bilan.Attentions.Count -gt 0) { if ($etat -eq 'ok') { $etat = 'attention' }; $messages += $bilan.Attentions }
                } else {
                    if ($etat -eq 'ok') { $etat = 'attention' }
                    $messages += 'créée avant le suivi du modèle : intégrité non vérifiable'
                }
            }
            if ($vm.InstantaneNeuf) {
                try {
                    $s = @(Get-MachineInstantanes -Machine $vm.Chemin)
                    if ($s -cnotcontains $vm.InstantaneNeuf) { if ($etat -eq 'ok') { $etat = 'attention' }; $messages += "point de retour « $($vm.InstantaneNeuf) » absent" }
                } catch { }
            }
        }
        if ($vm.Ephemere) { $messages += 'éphémère' }
        if ($vm.VncActif) {
            # Un port pris par un autre programme empêche la VM de démarrer.
            $messages += ("écran distant sur le port {0}" -f $vm.VncPort)
            $occupePar = @()
            foreach ($autre in @($script:Catalogue['vms'].Keys)) {
                if ($autre -ieq $nom) { continue }
                $v = $script:Catalogue['vms'][$autre]['vnc']
                if ($v -and $v['actif'] -eq $true -and [int]$v['port'] -eq $vm.VncPort) { $occupePar += $autre }
            }
            if ($occupePar.Count -gt 0) {
                $etat = 'erreur'
                $messages += ("port partagé avec : " + ($occupePar -join ', ') + " (ces VM ne peuvent pas tourner ensemble)")
            }
        }
        $conseil = ''
        if ($messages -join ' ' -match 'port partagé') { $conseil = "Réattribuez un port : vazy vnc $nom off puis vazy vnc $nom" }
        if ($etat -eq 'erreur') { $conseil = "Le modèle a changé ou disparu : cette VM ne peut plus démarrer. Restaurez le modèle, ou supprimez la VM (vazy rm $nom). Pour l'avenir : vazy freeze <nom> rend une VM importante autonome." }
        elseif ($messages -contains "point de retour « $($vm.InstantaneNeuf) » absent") { $conseil = "Pour le recréer, VM éteinte : vazy stop $nom ; vazy snap $nom $($script:InstantaneNeuf)" }
        Ajouter 'VM' $etat $nom ($messages -join ' ; ') $conseil
    }

    # --- VM présentes sur le disque mais absentes du catalogue ---------------
    if ($pilote) {
        $racines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($d in $dossiers) { if (Test-Path -LiteralPath $d) { $racines.Add($d) } }
        $cheminsConnus = @()
        foreach ($nom in @($script:Catalogue['vms'].Keys)) { $cheminsConnus += (Get-CheminLong ([string]$script:Catalogue['vms'][$nom]['chemin'])) }
        foreach ($alias in @($script:Catalogue['modeles'].Keys)) { $cheminsConnus += (Get-CheminLong ([string]$script:Catalogue['modeles'][$alias]['chemin'])) }
        $inconnues = @()
        foreach ($racine in $racines) {
            foreach ($f in @(Get-ChildItem -LiteralPath $racine -Filter ('*' + $pilote.ExtensionMachine) -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
                $chemin = Get-CheminLong $f.FullName
                $connue = $false
                foreach ($c in $cheminsConnus) { if ($c -ieq $chemin) { $connue = $true } }
                if (-not $connue) { $inconnues += $chemin }
            }
        }
        if ($inconnues.Count -gt 0) {
            Ajouter 'Cohérence' 'attention' 'VM hors catalogue' (("{0} machine(s) trouvée(s) dans vos dossiers mais absentes du catalogue : " -f $inconnues.Count) + ($inconnues -join ' ; ')) 'Créées en dehors de vazy, ou restes d''une suppression interrompue. vazy ne les touchera jamais ; supprimez-les dans VMware Workstation si elles ne servent plus.'
        } else {
            Ajouter 'Cohérence' 'ok' 'disque et catalogue' 'aucune machine inconnue dans les dossiers de vazy'
        }
    }

    return $constats.ToArray()
}

# ----------------------------------------------------------------------------
#  Écran de la VM à distance (téléphone, autre poste)
#  VMware Workstation Pro embarque un serveur VNC, activé par trois lignes du
#  .vmx : rien à installer. vazy choisit un port libre dans une plage réservée,
#  tire un mot de passe au hasard, et affiche un lien vnc:// prêt à ouvrir.
#  Le protocole VNC limite le mot de passe à 8 caractères et ne chiffre rien :
#  ce port ne doit jamais être exposé à internet (voir README).
# ----------------------------------------------------------------------------

# Mot de passe VNC : exactement 8 caractères (limite du protocole), tirés au
# sort dans un alphabet sans caractère ambigu ni caractère qui casserait le
# lien vnc:// (pas de @ : / ? # % &).
function New-MotDePasseVnc {
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $octets = New-Object byte[] 8
    $tirage = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $tirage.GetBytes($octets) } finally { $tirage.Dispose() }
    $texte = ''
    foreach ($o in $octets) { $texte += $alphabet[$o % $alphabet.Length] }
    return $texte
}

# Ports TCP en écoute sur cette machine : un port déjà pris par un autre
# programme ferait échouer le démarrage de la VM sans message clair.
function Get-PortsEcoutes {
    try {
        $proprietes = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        return @($proprietes.GetActiveTcpListeners() | ForEach-Object { $_.Port })
    } catch {
        Publish-Message 'attention' "Impossible de lister les ports en écoute ($($_.Exception.Message)) : vazy ne peut pas vérifier que le port choisi est libre."
        return @()
    }
}

# Premier port libre de la plage réservée : ni attribué à une autre VM du
# catalogue, ni en écoute sur la machine.
function Get-PortVncLibre {
    param([string]$Sauf = '')
    $min = [int]$script:Config['vncPortMin']
    $max = [int]$script:Config['vncPortMax']
    $pris = @{}
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        if ($Sauf -and $nom -ieq $Sauf) { continue }
        $vnc = $script:Catalogue['vms'][$nom]['vnc']
        if ($vnc -and $vnc['actif'] -eq $true -and [int]$vnc['port'] -gt 0) { $pris[[int]$vnc['port']] = $nom }
    }
    $ecoutes = @{}
    foreach ($p in (Get-PortsEcoutes)) { $ecoutes[[int]$p] = $true }
    for ($port = $min; $port -le $max; $port++) {
        if ($pris.ContainsKey($port)) { continue }
        if ($ecoutes.ContainsKey($port)) { continue }
        return $port
    }
    throw (New-ErreurOutil "Aucun port libre entre $min et $max pour l'affichage distant." `
        ("Chaque VM avec écran distant occupe un port. Retirez-le d'une VM qui n'en a plus besoin (vazy vnc <nom> off), ou élargissez la plage : vazy config vncPortMax " + ($max + 100)))
}

# Adresse à donner au client VNC. Priorité à Tailscale : c'est la seule qui
# fonctionne aussi bien depuis le réseau local que depuis l'extérieur, sans
# ouvrir de port sur la box. Sinon l'adresse du réseau local, sinon localhost.
function Get-AdresseAffichage {
    $candidates = @()
    # Interface qui porte la route par défaut : la seule dont on sait qu'elle
    # relie la machine au reste du monde. Les réseaux internes des hyperviseurs
    # (VMnet, Host-Only) ont une adresse mais ne mènent nulle part.
    $interfacePrincipale = 0
    try {
        $route = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1)
        if ($route.Count -gt 0) { $interfacePrincipale = [int]$route[0].InterfaceIndex }
    } catch { }
    try {
        $adresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' })
        foreach ($a in $adresses) {
            $tailscale = ($a.InterfaceAlias -match '(?i)tailscale')
            $octets = $a.IPAddress -split '\.'
            # 100.64.0.0/10 : plage utilisée par Tailscale pour ses adresses
            if (-not $tailscale -and [int]$octets[0] -eq 100 -and [int]$octets[1] -ge 64 -and [int]$octets[1] -le 127) { $tailscale = $true }
            $candidates += [pscustomobject]@{
                Adresse = $a.IPAddress; Tailscale = $tailscale; Interface = $a.InterfaceAlias
                Principale = ($interfacePrincipale -ne 0 -and [int]$a.InterfaceIndex -eq $interfacePrincipale)
                Virtuelle = ($a.InterfaceAlias -match '(?i)vmnet|vmware|virtualbox|host-only|hyper-v|loopback|wsl|docker')
            }
        }
    } catch {
        try {
            foreach ($ip in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
                if ($ip.AddressFamily -eq 'InterNetwork' -and $ip.ToString() -ne '127.0.0.1') {
                    $candidates += [pscustomobject]@{ Adresse = $ip.ToString(); Tailscale = $false; Interface = ''; Principale = $false; Virtuelle = $false }
                }
            }
        } catch { }
    }
    $ts = @($candidates | Where-Object { $_.Tailscale })
    if ($ts.Count -gt 0) { return [pscustomobject]@{ Adresse = $ts[0].Adresse; Source = 'Tailscale'; Interface = $ts[0].Interface } }
    $principale = @($candidates | Where-Object { $_.Principale -and -not $_.Virtuelle })
    if ($principale.Count -gt 0) { return [pscustomobject]@{ Adresse = $principale[0].Adresse; Source = 'réseau local'; Interface = $principale[0].Interface } }
    $reelles = @($candidates | Where-Object { -not $_.Virtuelle })
    if ($reelles.Count -gt 0) { return [pscustomobject]@{ Adresse = $reelles[0].Adresse; Source = 'réseau local'; Interface = $reelles[0].Interface } }
    return [pscustomobject]@{ Adresse = '127.0.0.1'; Source = 'cette machine seulement'; Interface = '' }
}

# Lien prêt à ouvrir depuis un téléphone. Le mot de passe y figure : il ne
# doit aller ni au journal ni dans un fichier.
function Get-LienVnc {
    param([Parameter(Mandatory = $true)]$Vm)
    if (-not $Vm.VncActif) { return $null }
    $adresse = Get-AdresseAffichage
    # Le protocole vient du pilote : tous les hyperviseurs n'offrent pas VNC
    # (VirtualBox parle RDP sans son extension VNC). Repli sur vnc pour un
    # pilote antérieur à cette clé.
    $pilote = Connect-Pilote
    $schema = 'vnc'
    if ($pilote.Contains('SchemaAffichageDistant') -and $pilote['SchemaAffichageDistant']) {
        $schema = [string]$pilote['SchemaAffichageDistant']
    }
    return [pscustomobject]@{
        Lien    = ('{0}://:{1}@{2}:{3}' -f $schema, $Vm.Vnc['motDePasse'], $adresse.Adresse, $Vm.VncPort)
        Adresse = $adresse.Adresse
        Source  = $adresse.Source
        Port    = $Vm.VncPort
        MotDePasse = [string]$Vm.Vnc['motDePasse']
    }
}

# Active l'affichage distant d'une VM : port libre, mot de passe, écriture
# dans la machine. Renvoie les informations d'accès.
function Enable-AffichageDistant {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$Silencieux)
    Connect-Pilote | Out-Null
    # En simulation, la machine n'existe pas sur le disque : on montre quand
    # même ce qui serait écrit.
    $vm = if ($script:Simulation) { Get-VmDuCatalogue -Nom $Nom } else { Get-VmPresente -Nom $Nom }
    $fiche = $script:Catalogue['vms'][$vm.Nom]
    $vnc = $fiche['vnc']
    if (-not $vnc) { $vnc = New-Dictionnaire; $fiche['vnc'] = $vnc }
    $port = [int]$vnc['port']
    $ecoutes = @{}
    foreach ($p in (Get-PortsEcoutes)) { $ecoutes[[int]$p] = $true }
    # Port déjà attribué à cette VM : on le garde, sauf s'il est hors plage, ou
    # occupé par un autre programme (s'il l'est alors que l'écran distant était
    # déjà actif, c'est la VM elle-même qui écoute : on le garde).
    $horsPlage = ($port -lt [int]$script:Config['vncPortMin'] -or $port -gt [int]$script:Config['vncPortMax'])
    $occupeAilleurs = ($ecoutes.ContainsKey($port) -and -not ($vnc['actif'] -eq $true))
    if ($port -le 0 -or $horsPlage -or $occupeAilleurs) { $port = Get-PortVncLibre -Sauf $vm.Nom }
    $motDePasse = [string]$vnc['motDePasse']
    if ($motDePasse.Length -ne 8) { $motDePasse = New-MotDePasseVnc }
    Set-MachineAffichageDistant -Machine $vm.Chemin -Actif $true -Port $port -MotDePasse $motDePasse
    $vnc['actif'] = $true; $vnc['port'] = $port; $vnc['motDePasse'] = $motDePasse
    Save-Catalogue
    if (-not $Silencieux) { Publish-Message 'ok' ("écran distant activé sur le port {0}" -f $port) }
    return (Get-LienVnc -Vm (Get-VmDuCatalogue -Nom $vm.Nom))
}

# Retire l'affichage distant et libère le port.
function Disable-AffichageDistant {
    param([Parameter(Mandatory = $true)][string]$Nom)
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    $fiche = $script:Catalogue['vms'][$vm.Nom]
    if (-not $vm.VncActif) {
        Publish-Message 'info' "La VM « $($vm.Nom) » n'a pas d'écran distant."
        return $false
    }
    Set-MachineAffichageDistant -Machine $vm.Chemin -Actif $false
    $vnc = $fiche['vnc']
    $vnc['actif'] = $false; $vnc['port'] = 0; $vnc['motDePasse'] = ''
    Save-Catalogue
    Publish-Message 'ok' "Écran distant retiré de « $($vm.Nom) » ; le port est de nouveau libre."
    return $true
}

# ----------------------------------------------------------------------------
#  Protection du modèle : un clone lié lit en permanence dans les disques de
#  base de son modèle. Si le modèle disparaît, est déplacé, ou si l'un de ses
#  instantanés a été supprimé ou consolidé dans VMware, tous ses clones
#  meurent d'un coup. On vérifie avant chaque démarrage.
# ----------------------------------------------------------------------------

# Refuse le démarrage d'un clone lié dont le modèle a disparu ou changé.
# Une VM autonome (vazy freeze) ne dépend plus de rien : rien à vérifier.
function Test-ModeleIntact {
    param([Parameter(Mandatory = $true)]$Vm)
    if ($Vm.Autonome) { return }
    if (-not $script:Catalogue['modeles'].Contains($Vm.Modele)) {
        # Modèle retiré du catalogue : les fichiers sont peut-être toujours là.
        Publish-Message 'attention' "le modèle « $($Vm.Modele) » de cette VM n'est plus au catalogue : impossible de vérifier qu'il est intact. Si ses fichiers ont disparu, la VM ne démarrera pas."
        return
    }
    $modele = $script:Catalogue['modeles'][$Vm.Modele]
    $cheminModele = [string]$modele['chemin']
    if (-not (Test-Path -LiteralPath $cheminModele -PathType Leaf)) {
        throw (New-ErreurOutil "Le modèle « $($Vm.Modele) » de la VM « $($Vm.Nom) » est introuvable : $cheminModele" `
            ("Cette VM est un clone lié : elle lit en permanence les disques du modèle et ne peut pas démarrer sans lui.`n" +
             "Si le modèle a été déplacé, remettez-le à cet emplacement exact, ou restaurez-le depuis une sauvegarde.`n" +
             "Pour vérifier l'état général : vazy doctor. Pour rendre une VM autonome à l'avenir : vazy freeze <nom>"))
    }
    $empreinte = $Vm.Empreinte
    if ($null -eq $empreinte -or @($empreinte.Keys).Count -eq 0) { return }   # VM d'avant la v7 : rien à comparer
    $bilan = Test-MachineEmpreinte -Machine $cheminModele -Empreinte $empreinte
    foreach ($a in $bilan.Attentions) { Publish-Message 'attention' $a }
    if ($bilan.Erreurs.Count -gt 0) {
        throw (New-ErreurOutil ("Le modèle « {0} » a changé depuis la création de « {1} » : {2}" -f $Vm.Modele, $Vm.Nom, ($bilan.Erreurs -join ' ; ')) `
            ("Un clone lié lit dans les disques du modèle : s'ils changent, il casse. Cause habituelle : un instantané du modèle a été supprimé ou consolidé dans VMware Workstation (Snapshot Manager), ou le disque a été compacté.`n" +
             "Si vous avez une sauvegarde du modèle, restaurez-la. Sinon cette VM est probablement perdue : vazy rm $($Vm.Nom).`n" +
             "Pour l'ensemble : vazy doctor. Pour protéger une VM importante à l'avenir : vazy freeze <nom>"))
    }
}

# Convertit un clone lié en VM complète : elle ne dépend plus du modèle, mais
# occupe toute sa taille sur le disque. VM arrêtée obligatoire ; les
# instantanés ne survivent pas, le point de retour est repris ensuite.
function Convert-VmEnAutonome {
    param([Parameter(Mandatory = $true)][string]$Nom)
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    if ($vm.Autonome) {
        Publish-Message 'info' "La VM « $($vm.Nom) » est déjà autonome : elle ne dépend d'aucun modèle."
        return $vm
    }
    if (Test-MachineEnCours -Chemin $vm.Chemin) {
        throw (New-ErreurOutil "La VM « $($vm.Nom) » est en marche : une conversion en VM complète exige une VM arrêtée." "Arrêtez-la puis recommencez : vazy stop $($vm.Nom) ; vazy freeze $($vm.Nom)")
    }
    $instantanes = @(Get-MachineInstantanes -Machine $vm.Chemin)
    $avaitNeuf = ($instantanes -ccontains $script:InstantaneNeuf)
    Publish-Etape 1 3 "Copie complète du disque"
    Publish-Message 'info' "la VM va occuper toute sa taille sur le disque au lieu de ses seules différences ; cela peut prendre plusieurs minutes."
    Convert-MachineEnComplete -Machine $vm.Chemin -Nom $vm.Nom | Out-Null
    Publish-Message 'ok' ("copie terminée en {0}" -f (Format-Duree $chrono.Elapsed.TotalSeconds))

    Publish-Etape 2 3 "Point de retour"
    if ($avaitNeuf) {
        # Un clone complet ne conserve pas les instantanés : on reprend le point
        # de retour sur l'état actuel, qui devient le nouvel état « neuf ».
        try {
            New-MachineInstantane -Machine $vm.Chemin -Nom $script:InstantaneNeuf
            Publish-Message 'ok' "« $($script:InstantaneNeuf) » repris sur l'état actuel de la VM (les instantanés ne survivent pas à une copie complète)."
        } catch {
            Publish-Message 'attention' "point de retour non repris ($($_.Exception.Message)). Pour le recréer, VM éteinte : vazy snap $($vm.Nom) $($script:InstantaneNeuf)"
        }
    } else {
        Publish-Message 'info' 'aucun point de retour à reprendre.'
    }

    Publish-Etape 3 3 "Catalogue"
    $script:Catalogue['vms'][$vm.Nom]['autonome'] = $true
    $script:Catalogue['vms'][$vm.Nom]['empreinte'] = New-Dictionnaire
    Save-Catalogue
    Publish-Message 'ok' "VM « $($vm.Nom) » autonome : elle ne dépend plus du modèle « $($vm.Modele) »."
    return [pscustomobject]@{ Nom = $vm.Nom; Duree = $chrono.Elapsed.TotalSeconds }
}

# ----------------------------------------------------------------------------
#  Personnalisation de l'invité (phase 4) : nom d'hôte
#  Identifiants d'invité par modèle, chiffrés par Export-CliXml (DPAPI : le
#  fichier n'est lisible que par ce compte Windows sur cette machine). Le mot
#  de passe n'est jamais écrit en clair, jamais affiché, et masqué par le
#  pilote dans toute sortie de l'hyperviseur.
#  Règle absolue : si la personnalisation échoue, la VM reste créée et
#  démarrée ; on avertit, on n'annule rien.
# ----------------------------------------------------------------------------

function Get-CheminIdentifiants {
    param([string]$Alias)
    return (Join-Path $script:DossierIdentifiants ($Alias + '.xml'))
}

# Identifiants enregistrés pour un modèle (PSCredential), ou $null.
function Get-IdentifiantsModele {
    param([Parameter(Mandatory = $true)][string]$Alias)
    $chemin = Get-CheminIdentifiants -Alias $Alias
    if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { return $null }
    try {
        $c = Import-Clixml -LiteralPath $chemin
        if ($c -isnot [System.Management.Automation.PSCredential]) { throw 'contenu inattendu' }
        return $c
    } catch {
        throw (New-ErreurOutil "Les identifiants d'invité du modèle « $Alias » sont illisibles ($($_.Exception.Message))." `
            "Ils sont chiffrés pour votre compte Windows sur cette machine : s'ils viennent d'un autre compte ou d'un autre PC, recréez-les : vazy template creds $Alias")
    }
}

# Enregistre les identifiants (chiffrés) et le système invité du modèle.
function Set-IdentifiantsModele {
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Identifiants,
        [string]$Os = ''
    )
    $modele = Get-ModeleDuCatalogue -Alias $Alias
    if ($Os) {
        $modele['os'] = $Os.ToLower()
    } elseif (-not $modele['os']) {
        $detecte = 'inconnu'
        if (Test-Path -LiteralPath $modele['chemin'] -PathType Leaf) { $detecte = Get-MachineSystemeInvite -Machine $modele['chemin'] }
        if ($detecte -eq 'inconnu') {
            throw (New-ErreurOutil "Impossible de deviner le système invité du modèle « $Alias »." "Précisez-le : vazy template creds $Alias --os linux   ou   --os windows")
        }
        $modele['os'] = $detecte
    }
    Save-Catalogue
    try {
        if (-not (Test-Path -LiteralPath $script:DossierIdentifiants)) { New-Item -ItemType Directory -Path $script:DossierIdentifiants -Force | Out-Null }
        $Identifiants | Export-Clixml -LiteralPath (Get-CheminIdentifiants -Alias $Alias) -Force
    } catch {
        throw (New-ErreurOutil "Impossible d'enregistrer les identifiants : $($_.Exception.Message)" "Vérifiez les droits d'écriture sur $($script:DossierIdentifiants).")
    }
    Publish-Message 'ok' ("Identifiants d'invité du modèle « {0} » enregistrés : utilisateur « {1} », système {2}, mot de passe chiffré pour votre compte Windows ({3})." -f $Alias, $Identifiants.UserName, $modele['os'], (Get-CheminIdentifiants -Alias $Alias))
}

function Remove-IdentifiantsModele {
    param([Parameter(Mandatory = $true)][string]$Alias)
    $chemin = Get-CheminIdentifiants -Alias $Alias
    if (Test-Path -LiteralPath $chemin -PathType Leaf) {
        Remove-Item -LiteralPath $chemin -Force
        Publish-Message 'ok' "Identifiants d'invité du modèle « $Alias » supprimés."
    } else {
        Publish-Message 'info' "Aucun identifiant d'invité enregistré pour « $Alias »."
    }
}

# Utilisateur enregistré pour un modèle (sans lire le mot de passe), ou ''.
function Get-UtilisateurInvite {
    param([string]$Alias)
    try { $c = Get-IdentifiantsModele -Alias $Alias; if ($c) { return $c.UserName } } catch { return '(illisibles)' }
    return ''
}

# Système invité d'un modèle : celui déclaré, sinon détecté par le pilote.
function Get-SystemeModele {
    param([string]$Alias)
    $modele = Get-ModeleDuCatalogue -Alias $Alias
    if ($modele['os']) { return [string]$modele['os'] }
    if (Test-Path -LiteralPath $modele['chemin'] -PathType Leaf) { return (Get-MachineSystemeInvite -Machine $modele['chemin']) }
    return 'inconnu'
}

# Vérifie un nom d'hôte : renvoie le problème (texte) ou $null.
function Test-NomHote {
    param([string]$NomHote, [string]$Systeme = 'linux')
    if ($NomHote -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
        return "« $NomHote » n'est pas un nom d'hôte valide (lettres, chiffres et tirets, ni au début ni à la fin, 63 caractères max, pas de point ni d'underscore)."
    }
    if ($Systeme -eq 'windows' -and $NomHote.Length -gt 15) {
        return "« $NomHote » dépasse 15 caractères, la limite d'un nom d'ordinateur Windows."
    }
    return $null
}

# Script de renommage, par famille de système. Idempotent : ne fait rien si
# l'invité porte déjà ce nom. Linux : hostnamectl + /etc/hosts, via sudo sans
# mot de passe si le compte n'est pas root. Windows : Rename-Computer, qui
# exige un compte administrateur élevé, puis redémarrage (obligatoire pour
# qu'un nouveau nom soit pris en compte).
function Get-ScriptNomHote {
    param([string]$Systeme, [string]$NomHote)
    switch ($Systeme) {
        'linux' {
            # Une seule ligne : insensible à tout traitement des retours à la ligne
            # entre vazy, l'hyperviseur et l'invité.
            return (@(
                'set -e',
                "NOM='$NomHote'",
                '[ "$(hostname)" = "$NOM" ] && exit 0',
                'if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -n"; else SUDO=""; fi',
                '$SUDO hostnamectl set-hostname "$NOM"',
                'if grep -q "^127\.0\.1\.1" /etc/hosts; then $SUDO sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NOM/" /etc/hosts; else printf "127.0.1.1\t%s\n" "$NOM" | $SUDO tee -a /etc/hosts >/dev/null; fi'
            ) -join '; ')
        }
        'windows' {
            # Renomme sans redémarrer et rend la main avec le code 3 : c'est vazy
            # qui pilote ensuite l'arrêt propre et le redémarrage (état déterministe).
            return @(
                "`$nom = '$NomHote'",
                'if ($env:COMPUTERNAME -ieq $nom) { exit 0 }',
                'Rename-Computer -NewName $nom -Force -ErrorAction Stop',
                'exit 3'
            ) -join "`n"
        }
    }
    return ''
}

# Méthode de personnalisation d'un modèle :
#   guestinfo    : recommandée. Le modèle embarque le script vazy-guestinfo ;
#                  vazy dépose la configuration avant chaque démarrage, sans
#                  aucun identifiant, et le script l'applique à chaque boot.
#   identifiants : repli pour un modèle qu'on ne peut pas modifier : script
#                  exécuté dans l'invité avec un compte (vazy template creds).
#   aucune       : rien de configuré.
function Get-MethodePersonnalisation {
    param([Parameter(Mandatory = $true)][string]$Alias)
    $modele = Get-ModeleDuCatalogue -Alias $Alias
    if ($modele['guestinfo'] -eq $true) { return 'guestinfo' }
    if (Test-Path -LiteralPath (Get-CheminIdentifiants -Alias $Alias) -PathType Leaf) { return 'identifiants' }
    return 'aucune'
}

# Marque un modèle comme embarquant (ou non) le script vazy-guestinfo.
function Set-MarqueModele {
    param([Parameter(Mandatory = $true)][string]$Alias, [bool]$Guestinfo)
    $modele = Get-ModeleDuCatalogue -Alias $Alias
    $modele['guestinfo'] = $Guestinfo
    Save-Catalogue
    if ($Guestinfo) {
        Publish-Message 'ok' "Modèle « $Alias » marqué guestinfo : vazy déposera la configuration (nom d'hôte) avant chaque démarrage de ses clones, sans aucun identifiant."
        Publish-Message 'info' "Cela suppose que le script vazy-guestinfo est installé dans le modèle (dossier « invite » de vazy, README section « Préparer un modèle »)."
    } else {
        $repli = if (Test-Path -LiteralPath (Get-CheminIdentifiants -Alias $Alias) -PathType Leaf) { 'personnalisation par identifiants (repli)' } else { 'aucune personnalisation' }
        Publish-Message 'ok' "Modèle « $Alias » marqué classique : $repli."
    }
}

# Charge utile déposée pour le script invité : JSON en base64 (aucun problème
# d'échappement, quelle que soit la chaîne d'outils). Clés prévues : hostname
# (seule appliquée aujourd'hui), puis ip, masque, passerelle, dns, cle_ssh.
# Le script invité ignore toute clé qu'il ne connaît pas.
# Une adresse IPv4 en quatre octets valides. Le format seul : on ne juge pas de
# la cohérence entre adresse, masque et passerelle, qui dépend du TP.
function Test-AdresseIpv4 {
    param([string]$Adresse)
    if ($Adresse -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($octet in ($Adresse -split '\.')) { if ([int]$octet -gt 255) { return $false } }
    return $true
}

# Contrôle du bloc réseau demandé, avec des refus qui disent quoi corriger.
# Accepte un masque en notation pointée (255.255.255.0) ou en longueur (24).
function Test-ConfigInvite {
    param($Config)
    if ($null -eq $Config) { return }
    foreach ($cle in @('ip', 'passerelle')) {
        $valeur = [string]$Config[$cle]
        if ($valeur -and -not (Test-AdresseIpv4 $valeur)) {
            throw (New-ErreurOutil "Adresse invalide pour « $cle » : $valeur" 'Quatre nombres de 0 à 255 séparés par des points, par exemple 192.168.100.10.')
        }
    }
    $masque = [string]$Config['masque']
    if ($masque) {
        $longueur = 0
        if ([int]::TryParse($masque, [ref]$longueur)) {
            if ($longueur -lt 1 -or $longueur -gt 32) {
                throw (New-ErreurOutil "Longueur de masque invalide : $masque" 'Entre 1 et 32, par exemple 24. La notation pointée (255.255.255.0) est acceptée aussi.')
            }
        } elseif (-not (Test-AdresseIpv4 $masque)) {
            throw (New-ErreurOutil "Masque invalide : $masque" 'Indiquez 255.255.255.0, ou la longueur du préfixe : 24.')
        }
    }
    foreach ($serveur in @($Config['dns'])) {
        if ($serveur -and -not (Test-AdresseIpv4 ([string]$serveur))) {
            throw (New-ErreurOutil "Serveur DNS invalide : $serveur" 'Une adresse IPv4 par serveur, séparées par des virgules : --dns 192.168.100.1,1.1.1.1')
        }
    }
    if ([string]$Config['ip'] -and -not $masque) {
        throw (New-ErreurOutil "Une adresse IP est demandée sans masque." 'Ajoutez --masque 24 (ou 255.255.255.0) : sans lui, l''invité ne sait pas quelle est l''étendue du réseau.')
    }
    $cle = [string]$Config['cle_ssh']
    if ($cle -and $cle -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-\S+)\s+\S+') {
        throw (New-ErreurOutil "La clé SSH ne ressemble pas à une clé publique." 'Attendu : le contenu d''un fichier .pub, par exemple « ssh-ed25519 AAAA... commentaire ».')
    }
}

# Masque en longueur de préfixe : 255.255.255.0 -> 24. Rendu tel quel si c'est
# déjà une longueur. L'invité n'a ainsi qu'une seule forme à traiter.
function ConvertTo-LongueurPrefixe {
    param([string]$Masque)
    if (-not $Masque) { return '' }
    $longueur = 0
    if ([int]::TryParse($Masque, [ref]$longueur)) { return [string]$longueur }
    $bits = 0
    foreach ($octet in ($Masque -split '\.')) {
        $v = [int]$octet
        while ($v -gt 0) { $bits += ($v -band 1); $v = $v -shr 1 }
    }
    return [string]$bits
}

# Y a-t-il quelque chose à déposer dans l'invité, en dehors du nom d'hôte ?
function Test-ConfigInviteRenseignee {
    param($Config)
    if ($null -eq $Config) { return $false }
    foreach ($cle in @('ip', 'masque', 'passerelle', 'dns', 'cle_ssh')) {
        if ($Config.Contains($cle) -and @($Config[$cle] | Where-Object { $_ }).Count -gt 0) { return $true }
    }
    return $false
}

# Résumé lisible de l'adressage demandé, pour les messages.
function Format-ConfigInvite {
    param($Config)
    if ($null -eq $Config) { return 'aucun' }
    $morceaux = @()
    if ([string]$Config['ip']) {
        $ip = [string]$Config['ip']
        $masque = ConvertTo-LongueurPrefixe ([string]$Config['masque'])
        $morceaux += $(if ($masque) { "$ip/$masque" } else { $ip })
    }
    if ([string]$Config['passerelle']) { $morceaux += ('passerelle ' + [string]$Config['passerelle']) }
    $dns = @($Config['dns'] | Where-Object { $_ })
    if ($dns.Count -gt 0) { $morceaux += ('DNS ' + ($dns -join ', ')) }
    if ([string]$Config['cle_ssh']) { $morceaux += 'clé SSH' }
    if ($morceaux.Count -eq 0) { return 'aucun' }
    return ($morceaux -join ', ')
}

function Get-ChargeUtileInvite {
    param(
        [string]$NomHote,
        [string]$Mode = '',     # 'pool' : l'invité s'arrête avant de fixer son identité
        $Config = $null         # ip, masque, passerelle, dns, cle_ssh
    )
    $charge = [ordered]@{}
    if ($Mode) { $charge['mode'] = $Mode }
    $charge['hostname'] = $NomHote
    if ($null -ne $Config) {
        # Seules les clés renseignées partent : l'invité distingue « non
        # demandé » (ne touche à rien) de « demandé vide ».
        if ([string]$Config['ip'])         { $charge['ip']         = [string]$Config['ip'] }
        if ([string]$Config['masque'])     { $charge['masque']     = ConvertTo-LongueurPrefixe ([string]$Config['masque']) }
        if ([string]$Config['passerelle']) { $charge['passerelle'] = [string]$Config['passerelle'] }
        $dns = @($Config['dns'] | Where-Object { $_ })
        if ($dns.Count -gt 0)              { $charge['dns']        = ($dns -join ',') }
        if ([string]$Config['cle_ssh'])    { $charge['cle_ssh']    = [string]$Config['cle_ssh'] }
    }
    $json = ConvertTo-Json -InputObject $charge -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

# Démarre une VM en appliquant sa personnalisation (nom d'hôte demandé à la
# création ou par le labo), selon la méthode de son modèle :
#   guestinfo    : la configuration est déposée dans la machine AVANT le
#                  démarrage ; le script du modèle l'applique à chaque boot.
#                  Rien à réappliquer après reset ou back : le nom revient seul.
#   identifiants : repli, script exécuté dans l'invité APRÈS le démarrage, à
#                  chaque démarrage par vazy (idempotent) ; sous Windows un
#                  renommage exige un redémarrage, que vazy pilote.
# Jamais bloquant : un échec de personnalisation laisse la VM démarrée.
# Renvoie la méthode utilisée.
function Start-VmAvecPersonnalisation {
    param(
        [Parameter(Mandatory = $true)]$Vm,
        [switch]$SansInterface,
        [string]$TitreEtapeIdentifiants = "Personnalisation de l'invité (repli par identifiants)"
    )
    Test-ModeleIntact -Vm $Vm
    $modele = Get-ModeleDuCatalogue -Alias $Vm.Modele
    $reseauDemande = Test-ConfigInviteRenseignee -Config $Vm.ConfigInvite
    $aDeposer = ([bool]$Vm.NomHote -or $reseauDemande)
    $methode = if ($aDeposer) { Get-MethodePersonnalisation -Alias $Vm.Modele } else { 'aucune' }
    if ($aDeposer) {
        switch ($methode) {
            'guestinfo' {
                Set-MachineVariableInvite -Machine $Vm.Chemin -Nom 'vazy_config' `
                    -Valeur (Get-ChargeUtileInvite -NomHote $Vm.NomHote -Config $Vm.ConfigInvite)
                $quoi = @()
                if ($Vm.NomHote)    { $quoi += ("nom d'hôte « {0} »" -f $Vm.NomHote) }
                if ($reseauDemande) { $quoi += ("adressage {0}" -f (Format-ConfigInvite -Config $Vm.ConfigInvite)) }
                Publish-Message 'info' ("configuration déposée pour l'invité (guestinfo) : {0}, appliquée par le script du modèle à chaque démarrage." -f ($quoi -join ', '))
            }
            'aucune' {
                Publish-Message 'info' ("configuration non appliquée : le modèle « {0} » n'est ni marqué guestinfo (vazy template mark {0} --guestinfo) ni doté d'identifiants (vazy template creds {0})." -f $Vm.Modele)
            }
            'identifiants' {
                if ($reseauDemande) {
                    Publish-Message 'attention' ("l'adressage statique n'est appliqué que par un modèle guestinfo. Le modèle « {0} » utilise le repli par identifiants : seul le nom d'hôte sera posé, l'adresse restera en DHCP." -f $Vm.Modele)
                }
            }
        }
    } elseif ($modele['guestinfo'] -eq $true) {
        # Rien à demander : ne laisse traîner aucune configuration antérieure.
        Set-MachineVariableInvite -Machine $Vm.Chemin -Nom 'vazy_config' -Valeur ''
    }
    # Le démarrage n'affiche rien tant que la VM n'est pas allumée : quelques
    # secondes en général, davantage quand l'interface de l'hyperviseur doit
    # être lancée. Un mot avant l'appel, pour que le silence qui suit soit
    # attendu plutôt qu'inquiétant.
    Publish-Message 'info' ("démarrage de « {0} » en cours..." -f $Vm.Nom)
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Machine -Machine $Vm.Chemin -SansInterface:$SansInterface
    Publish-Message 'ok' ("VM « {0} » démarrée en {1}" -f $Vm.Nom, (Format-Duree $chrono.Elapsed.TotalSeconds))
    if ($methode -eq 'identifiants') {
        Publish-Message 'etape' $TitreEtapeIdentifiants
        Invoke-PersonnalisationParIdentifiants -Vm $Vm -SansInterface:$SansInterface | Out-Null
    }
    return $methode
}

# Repli par identifiants : attend les outils invité puis exécute le script de
# renommage avec le compte enregistré. Sous Windows, après un renommage
# effectif (code 3), vazy arrête proprement la VM et la redémarre lui-même.
# Ne lève jamais d'exception liée à l'invité.
function Invoke-PersonnalisationParIdentifiants {
    param([Parameter(Mandatory = $true)]$Vm, [switch]$SansInterface)
    $nomHote = $Vm.NomHote
    $identifiants = $null
    try { $identifiants = Get-IdentifiantsModele -Alias $Vm.Modele }
    catch { Publish-Message 'attention' ("nom d'hôte « {0} » non appliqué : {1} {2}" -f $nomHote, $_.Exception.Message, $_.Exception.Data['Conseil']); return $false }
    if ($null -eq $identifiants) { return $false }
    $systeme = Get-SystemeModele -Alias $Vm.Modele
    if ($systeme -eq 'inconnu') {
        Publish-Message 'attention' ("nom d'hôte « {0} » non appliqué : système invité du modèle « {1} » inconnu. Précisez-le : vazy template creds {1} --os linux|windows" -f $nomHote, $Vm.Modele)
        return $false
    }
    $probleme = Test-NomHote -NomHote $nomHote -Systeme $systeme
    if ($probleme) {
        Publish-Message 'attention' "nom d'hôte non appliqué : $probleme"
        return $false
    }
    $delai = [int]$script:Config['delaiOutilsSec']
    Publish-Message 'info' ("attente des outils invité de « {0} » (au plus {1} s)..." -f $Vm.Nom, $delai)
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $pret = $false
    try { $pret = Wait-MachineOutils -Machine $Vm.Chemin -DelaiMaxSec $delai }
    catch { Publish-Message 'attention' ("nom d'hôte « {0} » non appliqué : {1}" -f $nomHote, $_.Exception.Message); return $false }
    if (-not $pret) {
        Publish-Message 'attention' ("outils invité injoignables après {0} s : nom d'hôte « {1} » non appliqué. Vérifiez qu'open-vm-tools (Linux) ou VMware Tools (Windows) sont installés dans le modèle ; pour attendre plus longtemps : vazy config delaiOutilsSec 300. La VM reste utilisable ; nouvel essai au prochain démarrage par vazy." -f $delai, $nomHote)
        return $false
    }
    try {
        $code = Invoke-MachineScript -Machine $Vm.Chemin -Identifiants $identifiants -Systeme $systeme -Script (Get-ScriptNomHote -Systeme $systeme -NomHote $nomHote)
        switch ($code) {
            0 {
                Publish-Message 'ok' ("nom d'hôte « {0} » en place ({1})" -f $nomHote, (Format-Duree $chrono.Elapsed.TotalSeconds))
            }
            3 {
                Publish-Message 'ok' ("nom d'hôte « {0} » enregistré dans l'invité ; redémarrage pour l'appliquer" -f $nomHote)
                try { Stop-Machine -Machine $Vm.Chemin }
                catch {
                    if ($_.Exception.Message -notmatch 'Tools') { throw }
                    Publish-Message 'attention' "arrêt propre impossible, arrêt forcé"
                    Stop-Machine -Machine $Vm.Chemin -Brutal
                }
                Start-Machine -Machine $Vm.Chemin -SansInterface:$SansInterface
                Publish-Message 'ok' ("VM « {0} » redémarrée avec le nom « {1} » ({2})" -f $Vm.Nom, $nomHote, (Format-Duree $chrono.Elapsed.TotalSeconds))
            }
            default {
                Publish-Message 'attention' ("nom d'hôte « {0} » non appliqué : le script a échoué dans l'invité (code {1}). Droits insuffisants ? Sous Linux, le compte doit pouvoir faire sudo sans mot de passe (ou être root) ; sous Windows, il doit être administrateur sans invite UAC. La VM reste démarrée." -f $nomHote, $code)
                return $false
            }
        }
        return $true
    } catch {
        $conseil = [string]$_.Exception.Data['Conseil']
        Publish-Message 'attention' ("nom d'hôte « {0} » non appliqué : {1} {2} La VM reste créée et démarrée ; nouvel essai au prochain démarrage par vazy." -f $nomHote, $_.Exception.Message, $conseil)
        return $false
    } finally {
        $identifiants = $null
    }
}

# ----------------------------------------------------------------------------
#  Instantanés et remise à zéro (phase 1)
#  L'instantané « vazy-neuf » est le point de retour pris à la création ; les
#  autres sont des jalons manuels. Aucune de ces fonctions n'accepte un modèle :
#  Get-VmDuCatalogue les refuse, et le pilote les refuse une seconde fois.
# ----------------------------------------------------------------------------

# VM du catalogue dont les fichiers existent encore.
function Get-VmPresente {
    param([string]$Nom)
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (-not (Test-Path -LiteralPath $vm.Chemin -PathType Leaf)) {
        throw (New-ErreurOutil "Les fichiers de la VM « $($vm.Nom) » ont disparu : $($vm.Chemin)" "Retirez-la du catalogue : vazy rm $($vm.Nom)")
    }
    return $vm
}

function Test-LibelleInstantane {
    param([string]$Libelle)
    if ($Libelle -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$') {
        throw (New-ErreurOutil "Le libellé d'instantané « $Libelle » est invalide." `
            "Utilisez lettres, chiffres, espaces, points, tirets et underscores (64 caractères max), sans accent ni guillemet.")
    }
}

# Instantanés d'une VM, avec leur rôle.
function Get-InstantanesVm {
    param([Parameter(Mandatory = $true)][string]$Nom)
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    $liste = @()
    foreach ($s in @(Get-MachineInstantanes -Machine $vm.Chemin)) {
        $role = if ($s -ceq $script:InstantaneNeuf) { 'point de retour (vazy reset)' } else { 'manuel' }
        $liste += [pscustomobject]@{ Vm = $vm.Nom; Libelle = $s; Role = $role }
    }
    return $liste   # l'appelant entoure de @()
}

# Prend un instantané manuel. Le libellé « vazy-neuf » n'est accepté que s'il
# manque (VM créée avant la phase 1) et VM éteinte : il ne s'écrase jamais.
function New-InstantaneVm {
    param([Parameter(Mandatory = $true)][string]$Nom, [string]$Libelle = '')
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    if (-not $Libelle) { $Libelle = 'snap-' + (Get-Date).ToString('yyyyMMdd-HHmmss') }
    Test-LibelleInstantane -Libelle $Libelle
    $estNeuf = ($Libelle -ieq $script:InstantaneNeuf)
    if ($estNeuf) { $Libelle = $script:InstantaneNeuf }
    $existants = @(Get-MachineInstantanes -Machine $vm.Chemin)
    $enMarche = Test-MachineEnCours -Chemin $vm.Chemin
    if ($estNeuf) {
        if ($existants -ccontains $Libelle) {
            throw (New-ErreurOutil "« $Libelle » existe déjà sur « $($vm.Nom) » : c'est le point de retour de « vazy reset », il ne s'écrase pas." `
                "Pour un jalon manuel, choisissez un autre libellé : vazy snap $($vm.Nom) <libelle>")
        }
        if ($enMarche) {
            throw (New-ErreurOutil "« $Libelle » doit être pris VM éteinte, pour que « vazy reset » soit propre et rapide." `
                "Arrêtez-la puis recommencez : vazy stop $($vm.Nom) ; vazy snap $($vm.Nom) $Libelle")
        }
    } elseif ($existants -ccontains $Libelle) {
        throw (New-ErreurOutil "Un instantané « $Libelle » existe déjà sur « $($vm.Nom) »." `
            ("Choisissez un autre libellé, ou supprimez l'ancien : vazy unsnap $($vm.Nom) ""$Libelle"". Existants : " + ($existants -join ', ')))
    }
    if ($enMarche) {
        Publish-Message 'info' "VM en marche : l'instantané inclut la mémoire (plus long à prendre ; « vazy back » la ramènera en marche dans cet état)."
    }
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    New-MachineInstantane -Machine $vm.Chemin -Nom $Libelle
    if ($estNeuf) {
        $script:Catalogue['vms'][$vm.Nom]['instantaneNeuf'] = $Libelle
        Save-Catalogue
    }
    Publish-Message 'ok' ("Instantané « {0} » pris sur « {1} » en {2}" -f $Libelle, $vm.Nom, (Format-Duree $chrono.Elapsed.TotalSeconds))
    return [pscustomobject]@{ Vm = $vm.Nom; Libelle = $Libelle }
}

# Retour à un instantané (« vazy reset » = retour à vazy-neuf, redémarrage
# ensuite sauf -SansDemarrage). Si la VM tourne, elle est arrêtée brutalement :
# tout ce qui s'est passé depuis l'instantané est abandonné par le retour, un
# arrêt propre ne protégerait rien et coûterait 10 à 30 secondes.
function Restore-InstantaneVm {
    param(
        [Parameter(Mandatory = $true)][string]$Nom,
        [Parameter(Mandatory = $true)][string]$Libelle,
        [switch]$SansDemarrage,
        [switch]$SansInterface
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    $estReset = ($Libelle -ieq $script:InstantaneNeuf)
    if ($estReset) { $Libelle = $script:InstantaneNeuf }
    $existants = @(Get-MachineInstantanes -Machine $vm.Chemin)
    if ($existants -cnotcontains $Libelle) {
        if ($estReset) {
            throw (New-ErreurOutil "La VM « $($vm.Nom) » n'a pas de point de retour « $Libelle » (créée avant que vazy ne le prenne automatiquement, ou instantané perdu)." `
                "Créez-le une fois, VM éteinte et dans l'état que vous voulez retrouver : vazy stop $($vm.Nom) ; vazy snap $($vm.Nom) $Libelle")
        }
        $liste = if ($existants.Count -gt 0) { 'Instantanés existants (respectez la casse) : ' + ($existants -join ', ') + '.' } else { 'Cette VM n''a aucun instantané.' }
        throw (New-ErreurOutil "Aucun instantané « $Libelle » sur « $($vm.Nom) »." "$liste Voir : vazy snaps $($vm.Nom)")
    }

    $enMarche = Test-MachineEnCours -Chemin $vm.Chemin
    $total = 1
    if ($enMarche) { $total++ }
    if (-not $SansDemarrage) { $total++ }
    $etape = 0
    if ($enMarche) {
        $etape++
        Publish-Etape $etape $total "Arrêt"
        Stop-Machine -Machine $vm.Chemin -Brutal
        Publish-Message 'ok' "VM en marche : arrêt forcé (son état actuel est abandonné par le retour)"
    }
    $etape++
    Publish-Etape $etape $total "Retour à l'instantané « $Libelle »"
    $debut = $chrono.Elapsed.TotalSeconds
    Restore-MachineInstantane -Machine $vm.Chemin -Nom $Libelle
    Publish-Message 'ok' ("terminé en {0}" -f (Format-Duree ($chrono.Elapsed.TotalSeconds - $debut)))
    if (-not $SansDemarrage) {
        # Le nom d'hôte demandé revient tout seul : modèle guestinfo, la
        # configuration est redéposée avant ce démarrage et le script du modèle
        # l'applique ; repli par identifiants, le script idempotent repasse.
        $etape++
        Publish-Etape $etape $total $(if ($SansInterface) { "Démarrage sans fenêtre" } else { "Démarrage" })
        Invoke-AvertissementHyperV
        try {
            Start-VmAvecPersonnalisation -Vm $vm -SansInterface:$SansInterface | Out-Null
        } catch {
            $_.Exception.Data['Conseil'] = "Le retour à « $Libelle » a bien eu lieu. " + $_.Exception.Data['Conseil'] + " Pour réessayer : vazy start $($vm.Nom)"
            throw
        }
    } elseif ($vm.Ephemere) {
        Publish-Message 'attention' "VM éphémère laissée éteinte : elle sera supprimée au prochain lancement de vazy, quelle que soit la commande."
    }
    return [pscustomobject]@{ Vm = $vm.Nom; Libelle = $Libelle; Reset = $estReset; Demarree = (-not $SansDemarrage); Duree = $chrono.Elapsed.TotalSeconds }
}

# « vazy reset » : retour au point de retour pris à la création.
function Reset-VmParNom {
    param([Parameter(Mandatory = $true)][string]$Nom, [switch]$SansDemarrage, [switch]$SansInterface)
    return (Restore-InstantaneVm -Nom $Nom -Libelle $script:InstantaneNeuf -SansDemarrage:$SansDemarrage -SansInterface:$SansInterface)
}

# Supprime un instantané manuel. « vazy-neuf » est protégé.
function Remove-InstantaneVm {
    param([Parameter(Mandatory = $true)][string]$Nom, [Parameter(Mandatory = $true)][string]$Libelle)
    Connect-Pilote | Out-Null
    $vm = Get-VmPresente -Nom $Nom
    if ($Libelle -ieq $script:InstantaneNeuf) {
        throw (New-ErreurOutil "« $($script:InstantaneNeuf) » est le point de retour de « vazy reset » : vazy refuse de le supprimer." `
            "Pour repartir d'un autre état de référence, supprimez la VM et recréez-la : vazy rm $($vm.Nom) ; vazy $($vm.Modele) --name $($vm.Nom)")
    }
    $existants = @(Get-MachineInstantanes -Machine $vm.Chemin)
    if ($existants -cnotcontains $Libelle) {
        $liste = if ($existants.Count -gt 0) { 'Instantanés existants (respectez la casse) : ' + ($existants -join ', ') + '.' } else { 'Cette VM n''a aucun instantané.' }
        throw (New-ErreurOutil "Aucun instantané « $Libelle » sur « $($vm.Nom) »." "$liste Voir : vazy snaps $($vm.Nom)")
    }
    if (Test-MachineEnCours -Chemin $vm.Chemin) {
        Publish-Message 'info' "VM en marche : la suppression fusionne les disques en arrière-plan, cela peut prendre un moment."
    }
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Remove-MachineInstantane -Machine $vm.Chemin -Nom $Libelle
    Publish-Message 'ok' ("Instantané « {0} » supprimé de « {1} » en {2}" -f $Libelle, $vm.Nom, (Format-Duree $chrono.Elapsed.TotalSeconds))
    return [pscustomobject]@{ Vm = $vm.Nom; Libelle = $Libelle }
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
    $fiche['os']         = ''      # système invité, détecté par le pilote ou précisé par « template creds --os »
    $fiche['guestinfo']  = $false  # « vazy template mark <alias> --guestinfo » une fois le script installé dans le modèle
    $fiche['alias']      = @()     # noms standards servis par ce modèle (« vazy template alias »)
    $script:Catalogue['modeles'][$Alias] = $fiche
    Save-Catalogue
    # Marque de protection vérifiée par le pilote lui-même (démarrage,
    # suppression et instantanés refusés sur cette VM).
    try { Protect-MachineModele -Machine $cheminComplet }
    catch { Publish-Message 'attention' "Modèle enregistré, mais impossible de poser sa marque de protection : $($_.Exception.Message)" }
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
            Os         = [string]$m['os']
            Invite     = (Get-UtilisateurInvite -Alias $alias)
            Guestinfo  = ($m['guestinfo'] -eq $true)
            Methode    = (Get-MethodePersonnalisation -Alias $alias)
            NomsStandards = @($m['alias'])
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
    $chemin = $script:Catalogue['modeles'][$Alias]['chemin']
    if (Test-Path -LiteralPath $chemin -PathType Leaf) {
        try { Unprotect-MachineModele -Machine $chemin }
        catch { Publish-Message 'attention' "Impossible de retirer la marque de protection posée à côté de la VM : $($_.Exception.Message)" }
    }
    $script:Catalogue['modeles'].Remove($Alias)
    Save-Catalogue
    $identifiants = Get-CheminIdentifiants -Alias $Alias
    if (Test-Path -LiteralPath $identifiants -PathType Leaf) { Remove-Item -LiteralPath $identifiants -Force -ErrorAction SilentlyContinue }
    Publish-Message 'ok' "Modèle « $Alias » retiré du catalogue (aucun fichier de VM supprimé ; ses identifiants d'invité éventuels sont effacés)."
    if ($clones.Count -gt 0) {
        Publish-Message 'attention' ("{0} VM en dépendent toujours ({1}) : ne supprimez pas ses fichiers ni son instantané, sinon elles cassent." -f $clones.Count, ($clones -join ', '))
    }
}

# Ajoute ou retire un nom standard servi par un modèle local.
function Set-AliasModele {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][string]$NomStandard,
        [switch]$Retirer
    )
    $reel = Resolve-AliasModele -Alias $Modele
    $fiche = Get-ModeleDuCatalogue -Alias $reel
    Test-NomValide -Nom $NomStandard -Role 'nom standard'
    $liste = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in @($fiche['alias'])) { if ($a -and $a -ine $NomStandard) { $liste.Add([string]$a) } }
    if ($Retirer) {
        $fiche['alias'] = $liste.ToArray()
        Save-Catalogue
        Publish-Message 'ok' "Le nom « $NomStandard » ne pointe plus vers le modèle « $reel »."
        return
    }
    if ($script:Catalogue['modeles'].Contains($NomStandard) -and $NomStandard -ine $reel) {
        throw (New-ErreurOutil "« $NomStandard » est déjà le nom d'un modèle enregistré." "Un alias ne peut pas masquer un modèle existant ; choisissez un autre nom standard.")
    }
    foreach ($k in @($script:Catalogue['modeles'].Keys)) {
        if ($k -ieq $reel) { continue }
        foreach ($a in @($script:Catalogue['modeles'][$k]['alias'])) {
            if ([string]$a -ieq $NomStandard) {
                throw (New-ErreurOutil "Le nom « $NomStandard » pointe déjà vers le modèle « $k »." "Retirez-le d'abord : vazy template alias $k $NomStandard --rm")
            }
        }
    }
    $liste.Add($NomStandard)
    $fiche['alias'] = $liste.ToArray()
    Save-Catalogue
    Publish-Message 'ok' "Le modèle « $reel » répond désormais au nom « $NomStandard » : un labo qui demande « $NomStandard » utilisera votre modèle."
}

# ----------------------------------------------------------------------------
#  Configuration
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
#  Pool de VM chaudes
#
#  Créer une VM prend une trentaine de secondes, dont l'essentiel est le
#  démarrage du système. L'idée : payer ce démarrage à l'avance. Des clones sont
#  créés, démarrés, puis SUSPENDUS — leur mémoire part sur le disque. Les
#  reprendre ne redémarre rien : deux à trois secondes.
#
#  Le vrai problème n'est pas la suspension, c'est l'IDENTITÉ. Une machine
#  suspendue fige tout : nom d'hôte, bail DHCP, clés SSH, identifiant machine.
#  Réveiller deux VM du même pool donnerait deux jumelles sur le réseau. Et
#  comme il n'y a pas de redémarrage, le service guestinfo de l'invité, qui
#  s'exécute au boot, ne se relance pas tout seul.
#
#  D'où la poignée de main : au moment de garnir le pool, vazy dépose
#  « mode: pool » dans la configuration de l'invité. Le script du modèle
#  reconnaît ce mode, fait le strict nécessaire (régénération des clés SSH et de
#  l'identifiant machine, qui ne dépendent pas de l'identité demandée), puis
#  ANNONCE qu'il est prêt en posant une variable, et attend. vazy voit cette
#  variable, suspend. Au « pop », vazy dépose la vraie identité et reprend :
#  l'invité, qui attendait, la lit et l'applique — sans redémarrage.
#
#  Si le modèle porte un script d'ancienne génération qui ne connaît pas ce
#  mode, la variable n'arrive jamais : vazy retombe alors sur l'attente des
#  outils invité plus un délai de repos, et prévient que l'identité au réveil
#  sera celle du modèle. La réserve reste utilisable, elle est simplement moins
#  bien tenue.
# ----------------------------------------------------------------------------

$script:VariablePoolPret = 'vazy_pool_pret'   # posée par l'invité quand il est prêt à être figé

# Premier nom libre de la forme <modele>-pool-1, -2...
function Get-NomVmPool {
    param([Parameter(Mandatory = $true)][string]$Modele, [string]$DossierRacine)
    $i = 1
    do {
        $candidat = '{0}-pool-{1}' -f $Modele, $i
        $i++
    } while ((Test-NomPris $candidat) -or ($DossierRacine -and (Test-Path -LiteralPath (Join-Path $DossierRacine $candidat))))
    return $candidat
}

# Une VM de réserve est périmée si le modèle dont elle sort a changé : elle
# démarrerait sur des disques qui ne sont plus les siens.
function Test-VmPoolPerimee {
    param([Parameter(Mandatory = $true)]$Vm)
    if (-not $script:Catalogue['modeles'].Contains($Vm.Modele)) { return $true }
    $chemin = [string]$script:Catalogue['modeles'][$Vm.Modele]['chemin']
    if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { return $true }
    $empreinte = $Vm.Empreinte
    if ($null -eq $empreinte -or @($empreinte.Keys).Count -eq 0) { return $false }   # rien à comparer
    return (@((Test-MachineEmpreinte -Machine $chemin -Empreinte $empreinte).Erreurs).Count -gt 0)
}

# Les VM en réserve, toutes ou pour un modèle donné.
function Get-VmsDuPool {
    param([string]$Modele = '')
    $liste = @()
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $pool = [string]$script:Catalogue['vms'][$nom]['pool']
        if (-not $pool) { continue }
        if ($Modele -and $pool -ine $Modele) { continue }
        $liste += (Get-VmDuCatalogue -Nom $nom)
    }
    return $liste
}

# Attend que l'invité annonce qu'il peut être figé.
# Renvoie 'signal' (poignée de main réussie), 'outils' (repli : les outils
# invité répondent, on laisse reposer) ou 'delai' (rien n'a répondu).
function Wait-InvitePretPourSuspension {
    param([Parameter(Mandatory = $true)]$Vm, [int]$DelaiMaxSec = 180)
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $outilsVus = $false
    while ($chrono.Elapsed.TotalSeconds -lt $DelaiMaxSec) {
        $valeur = ''
        try { $valeur = [string](Get-MachineVariableInvite -Machine $Vm.Chemin -Nom $script:VariablePoolPret) } catch { }
        if ($valeur -and $valeur -ne '0') { return 'signal' }
        if (-not $outilsVus) {
            try { $outilsVus = [bool](Wait-MachineOutils -Machine $Vm.Chemin -DelaiMaxSec 5) } catch { }
        }
        if ($script:Simulation) { return 'signal' }
        Start-Sleep -Seconds 3
    }
    if ($outilsVus) { return 'outils' }
    return 'delai'
}

# Garnit la réserve d'un modèle jusqu'à la taille voulue. Chaque VM est créée,
# démarrée, attendue, puis suspendue. Renvoie le nombre de VM ajoutées.
function Add-VmsAuPool {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][int]$Nombre,
        [double]$RamGo = 2,
        [int]$Cpu = 2,
        [string[]]$Modes = @('nat'),
        [object[]]$Brut = @()
    )
    if ($Nombre -le 0) { return 0 }
    Connect-Pilote | Out-Null
    $alias = Resolve-AliasModele -Alias $Modele
    $infosModele = Get-ModeleDuCatalogue -Alias $alias
    $methode = Get-MethodePersonnalisation -Alias $alias

    if ($methode -ne 'guestinfo') {
        Publish-Message 'attention' ("le modèle « {0} » n'est pas marqué guestinfo : les VM de la réserve garderont l'identité du modèle au réveil (même nom d'hôte, même bail DHCP). Pour une réserve pleinement utilisable : installez le script d'invité puis vazy template mark {0} --guestinfo" -f $alias)
    }

    # Une VM suspendue garde sa mémoire sur le disque : le coût est la RAM
    # multipliée par la taille de la réserve, en plus des disques.
    $dossierRacine = Get-DossierVms -Modele $infosModele
    Test-EspaceDisque -Dossier $dossierRacine -RamGo ($RamGo * $Nombre) -Libelle ("les {0} VM de la réserve" -f $Nombre) | Out-Null

    $ajoutees = 0
    for ($i = 1; $i -le $Nombre; $i++) {
        $nomVm = Get-NomVmPool -Modele $alias -DossierRacine $dossierRacine
        Publish-Message 'etape' ("Réserve {0}/{1} : {2}" -f $i, $Nombre, $nomVm)
        $vm = $null
        try {
            $vm = New-VmDepuisModele -Modele $alias -Nom $nomVm -RamGo $RamGo -Cpu $Cpu -Modes $Modes `
                                     -Brut $Brut -SansDemarrage -Pool $alias
        } catch {
            Publish-Message 'attention' ("« {0} » n'a pas pu être créée ({1}). Réserve garnie de {2} VM." -f $nomVm, $_.Exception.Message, $ajoutees)
            break
        }
        try {
            if ($methode -eq 'guestinfo') {
                Set-MachineVariableInvite -Machine $vm.Chemin -Nom 'vazy_config' -Valeur (Get-ChargeUtileInvite -NomHote '' -Mode 'pool')
            }
            Publish-Message 'info' 'démarrage, puis attente que l''invité soit prêt à être figé...'
            Start-Machine -Machine $vm.Chemin -SansInterface
            $issue = Wait-InvitePretPourSuspension -Vm (Get-VmDuCatalogue -Nom $nomVm) -DelaiMaxSec ([int]$script:Config['delaiPoolSec'])
            switch ($issue) {
                'signal' { Publish-Message 'ok' 'l''invité s''est annoncé prêt' }
                'outils' {
                    $repos = [int]$script:Config['poolReposSec']
                    Publish-Message 'attention' ("l'invité n'a pas répondu à la poignée de main (script d'ancienne génération ?) : on laisse reposer {0} s avant de figer. L'identité au réveil sera celle du modèle." -f $repos)
                    if (-not $script:Simulation) { Start-Sleep -Seconds $repos }
                }
                default {
                    Publish-Message 'attention' 'ni poignée de main ni outils invité : la VM est figée telle quelle, elle sera peut-être inutilisable au réveil.'
                }
            }
            Suspend-Machine -Machine $vm.Chemin
            Publish-Message 'ok' ("« {0} » figée et mise en réserve" -f $nomVm)
            $ajoutees++
        } catch {
            Publish-Message 'attention' ("« {0} » n'a pas pu être mise en réserve ({1}) : elle est supprimée." -f $nomVm, $_.Exception.Message)
            try { Remove-VmDuPool -Nom $nomVm } catch { }
            break
        }
    }
    return $ajoutees
}

# Supprime une VM de réserve, fichiers compris. Refuse tout ce qui n'est pas
# une VM de réserve : même garde-fou que pour les éphémères.
function Remove-VmDuPool {
    param([Parameter(Mandatory = $true)][string]$Nom)
    $vm = Get-VmDuCatalogue -Nom $Nom
    if (-not $vm.Pool) {
        throw (New-ErreurOutil "Refus : « $($vm.Nom) » n'est pas une VM de réserve." "Pour la supprimer volontairement : vazy rm $($vm.Nom)")
    }
    if (Test-Path -LiteralPath $vm.Chemin -PathType Leaf) {
        $reste = Remove-Machine -Machine $vm.Chemin
        if ($reste -and $reste.Type -eq 'attention') { Publish-Message 'attention' $reste.Message }
    }
    $script:Catalogue['vms'].Remove($vm.Nom)
    Save-Catalogue
}

function New-Pool {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [Parameter(Mandatory = $true)][int]$Taille,
        [double]$RamGo = 2,
        [int]$Cpu = 2,
        [string[]]$Modes = @('nat'),
        [object[]]$Brut = @()
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    $alias = Resolve-AliasModele -Alias $Modele
    $existantes = @(Get-VmsDuPool -Modele $alias)
    if ($existantes.Count -gt 0) {
        throw (New-ErreurOutil "Une réserve existe déjà pour « $alias » ($($existantes.Count) VM)." `
            "Pour la compléter : vazy pool refill $alias --size <n>. Pour repartir de zéro : vazy pool destroy $alias puis vazy pool create $alias --size $Taille")
    }
    $ajoutees = Add-VmsAuPool -Modele $alias -Nombre $Taille -RamGo $RamGo -Cpu $Cpu -Modes $Modes -Brut $Brut
    Publish-Message 'ok' ("Réserve « {0} » : {1} VM prêtes en {2}" -f $alias, $ajoutees, (Format-Duree $chrono.Elapsed.TotalSeconds))
    return [pscustomobject]@{ Modele = $alias; Creees = $ajoutees; Duree = $chrono.Elapsed.TotalSeconds }
}

function Invoke-PoolRefill {
    param([Parameter(Mandatory = $true)][string]$Modele, [int]$Taille = 0)
    $alias = Resolve-AliasModele -Alias $Modele
    $existantes = @(Get-VmsDuPool -Modele $alias)
    $utilisables = @($existantes | Where-Object { -not (Test-VmPoolPerimee -Vm $_) })
    if ($Taille -le 0) { $Taille = $existantes.Count }
    if ($Taille -le 0) {
        throw (New-ErreurOutil "Aucune réserve pour « $alias », et aucune taille demandée." "Indiquez-la : vazy pool refill $alias --size 3, ou créez la réserve : vazy pool create $alias --size 3")
    }
    $manquantes = $Taille - $utilisables.Count
    if ($manquantes -le 0) {
        Publish-Message 'ok' ("Réserve « {0} » déjà complète : {1} VM utilisables sur {2} demandées." -f $alias, $utilisables.Count, $Taille)
        return [pscustomobject]@{ Modele = $alias; Creees = 0 }
    }
    # Le gabarit est repris d'une VM existante, pour que la réserve reste homogène.
    $ramGo = 2; $cpu = 2; $modes = @('nat')
    if ($existantes.Count -gt 0) {
        $ramGo = [double]$existantes[0].RamGo; $cpu = [int]$existantes[0].Cpu; $modes = @($existantes[0].Reseau)
    }
    $ajoutees = Add-VmsAuPool -Modele $alias -Nombre $manquantes -RamGo $ramGo -Cpu $cpu -Modes $modes
    Publish-Message 'ok' ("Réserve « {0} » complétée : {1} VM ajoutées." -f $alias, $ajoutees)
    return [pscustomobject]@{ Modele = $alias; Creees = $ajoutees }
}

function Get-StatutPool {
    param([string]$Modele = '')
    Connect-Pilote | Out-Null
    $alias = if ($Modele) { Resolve-AliasModele -Alias $Modele } else { '' }
    $liste = @()
    foreach ($vm in @(Get-VmsDuPool -Modele $alias)) {
        $presente = Test-Path -LiteralPath $vm.Chemin -PathType Leaf
        $perimee = if ($presente) { Test-VmPoolPerimee -Vm $vm } else { $true }
        $suspendue = $false
        $occupation = @{ Total = 0.0; Suspension = 0.0 }
        if ($presente) {
            try { $suspendue = [bool](Test-MachineSuspendue -Machine $vm.Chemin) } catch { }
            try { $occupation = Get-MachineOccupationGo -Machine $vm.Chemin } catch { }
        }
        $etat = if (-not $presente) { 'absente' } elseif ($perimee) { 'périmée' } elseif ($suspendue) { 'prête' } else { 'non figée' }
        $liste += [pscustomobject]@{
            Nom          = $vm.Nom
            Modele       = $vm.Pool
            Etat         = $etat
            RamGo        = $vm.RamGo
            Cpu          = $vm.Cpu
            Reseau       = (@($vm.Reseau) -join ',')
            SuspensionGo = [double]$occupation.Suspension
            TotalGo      = [double]$occupation.Total
            CreeeLe      = $vm.CreeeLe
        }
    }
    return $liste
}

# Sort une VM de la réserve et lui donne sa vraie identité.
function Invoke-Pop {
    param(
        [Parameter(Mandatory = $true)][string]$Modele,
        [string]$Nom = '',
        [string]$NomHote = '',
        $ConfigInvite = $null,
        [switch]$SansInterface
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    Connect-Pilote | Out-Null
    Test-ConfigInvite -Config $ConfigInvite
    $alias = Resolve-AliasModele -Alias $Modele
    $candidates = @(Get-VmsDuPool -Modele $alias)
    if ($candidates.Count -eq 0) {
        throw (New-ErreurOutil "Aucune réserve pour le modèle « $alias »." `
            ("Garnissez-la : vazy pool create $alias --size 3`n" +
             "Ou créez une VM comme d'habitude : vazy $alias"))
    }
    $utilisables = @()
    $perimees = 0
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Chemin -PathType Leaf)) { continue }
        if (Test-VmPoolPerimee -Vm $c) { $perimees++; continue }
        $utilisables += $c
    }
    if ($utilisables.Count -eq 0) {
        $cause = if ($perimees -gt 0) {
            "Les $perimees VM de la réserve sont périmées : le modèle « $alias » a changé depuis leur création, elles démarreraient sur des disques qui ne sont plus les leurs."
        } else {
            "La réserve de « $alias » est vide."
        }
        throw (New-ErreurOutil $cause `
            ("Reconstituez-la : vazy pool destroy $alias puis vazy pool create $alias --size <n>`n" +
             "Ou créez une VM comme d'habitude : vazy $alias"))
    }

    $choisie = $utilisables[0]
    if ($Nom) {
        Test-NomValide -Nom $Nom
        if (Test-NomPris $Nom) {
            throw (New-ErreurOutil "Le nom « $Nom » est déjà utilisé." "Choisissez-en un autre (--name), ou supprimez l'ancienne VM : vazy rm $Nom")
        }
    } else {
        $Nom = Get-NomLibre -Modele $alias -DossierRacine (Split-Path -Parent $choisie.Dossier)
    }

    # Sortie du catalogue AVANT la reprise : une seconde commande ne doit jamais
    # servir la même VM, même si la reprise échoue ensuite.
    $fiche = $script:Catalogue['vms'][$choisie.Nom]
    $fiche['pool']    = ''
    $fiche['nomHote'] = $NomHote
    if ($null -ne $ConfigInvite) { $fiche['invite'] = $ConfigInvite }
    $script:Catalogue['vms'].Remove($choisie.Nom)
    $script:Catalogue['vms'][$Nom] = $fiche
    Save-Catalogue

    Publish-Message 'ok' ("« {0} » sortie de la réserve, devient « {1} »" -f $choisie.Nom, $Nom)

    # Nouvelle identité déposée avant la reprise : l'invité, qui attend, la lira.
    if ((Get-MethodePersonnalisation -Alias $alias) -eq 'guestinfo') {
        try { Set-MachineVariableInvite -Machine $choisie.Chemin -Nom 'vazy_config' -Valeur (Get-ChargeUtileInvite -NomHote $NomHote -Config $ConfigInvite) }
        catch { Publish-Message 'attention' ("configuration non déposée ({0}) : la VM gardera l'identité du modèle." -f $_.Exception.Message) }
    } elseif ($NomHote) {
        Publish-Message 'attention' ("le modèle « {0} » n'est pas marqué guestinfo : le nom d'hôte « {1} » ne sera pas appliqué au réveil (une VM reprise ne redémarre pas)." -f $alias, $NomHote)
    }

    Resume-Machine -Machine $choisie.Chemin -SansInterface:$SansInterface
    Publish-Message 'ok' ("VM « {0} » réveillée en {1}" -f $Nom, (Format-Duree $chrono.Elapsed.TotalSeconds))

    return [pscustomobject]@{
        Nom = $Nom; Ancien = $choisie.Nom; Chemin = $choisie.Chemin
        Restantes = ($utilisables.Count - 1); Duree = $chrono.Elapsed.TotalSeconds
    }
}

function Remove-Pool {
    param([Parameter(Mandatory = $true)][string]$Modele)
    Connect-Pilote | Out-Null
    $alias = Resolve-AliasModele -Alias $Modele
    $vms = @(Get-VmsDuPool -Modele $alias)
    if ($vms.Count -eq 0) {
        throw (New-ErreurOutil "Aucune réserve pour « $alias »." 'Voir les réserves existantes : vazy pool status')
    }
    $supprimees = 0
    foreach ($vm in $vms) {
        try { Remove-VmDuPool -Nom $vm.Nom; $supprimees++ }
        catch { Publish-Message 'attention' ("« {0} » n'a pas pu être supprimée ({1})." -f $vm.Nom, $_.Exception.Message) }
    }
    Publish-Message 'ok' ("Réserve « {0} » détruite : {1} VM supprimées." -f $alias, $supprimees)
    return [pscustomobject]@{ Modele = $alias; Supprimees = $supprimees }
}

# ----------------------------------------------------------------------------
#  Segments réseau personnalisés
#  « hostonly » met TOUTES les VM sur le même segment : deux labos montés en
#  même temps se voient mutuellement, et on ne peut pas faire de TP de routage
#  ou de segmentation sérieux. Un segment nommé est un réseau isolé auquel on
#  rattache les machines de son choix.
#
#  vazy tient la correspondance entre un nom parlant (« labo-dmz ») et
#  l'identifiant que le pilote lui a rendu. Cet identifiant est opaque pour
#  cette couche : elle le transporte, elle ne l'interprète jamais.
# ----------------------------------------------------------------------------

# Fiche d'un segment, ou $null. Le nom est insensible à la casse.
function Get-ReseauDuCatalogue {
    param([Parameter(Mandatory = $true)][string]$Nom)
    foreach ($k in @($script:Catalogue['reseaux'].Keys)) {
        if ($k -ieq $Nom) { return $script:Catalogue['reseaux'][$k] }
    }
    return $null
}

# Nom parlant d'un segment à partir de l'identifiant du pilote, ou '' si vazy
# ne le connaît pas (segment créé à la main dans l'hyperviseur).
function Get-NomReseauParIdentifiant {
    param([Parameter(Mandatory = $true)][string]$Identifiant)
    foreach ($k in @($script:Catalogue['reseaux'].Keys)) {
        if ([string]$script:Catalogue['reseaux'][$k]['identifiant'] -ieq $Identifiant) { return $k }
    }
    return ''
}

# Noms des VM rattachées à un segment, d'après leur fiche au catalogue.
function Get-VmsSurReseau {
    param([Parameter(Mandatory = $true)][string]$Identifiant)
    $noms = @()
    foreach ($nom in @($script:Catalogue['vms'].Keys)) {
        $modes = @($script:Catalogue['vms'][$nom]['reseau'])
        foreach ($m in $modes) {
            if ([string]$m -ieq ('nomme:' + $Identifiant)) { $noms += $nom; break }
        }
    }
    return $noms
}

# Traduit un nom parlant en mode réseau utilisable par le pilote.
# Vérifie au passage que le segment existe toujours côté hyperviseur : un
# segment supprimé à la main dans l'éditeur de réseaux virtuels ne doit pas
# donner une VM branchée dans le vide.
function Resolve-ReseauNomme {
    param([Parameter(Mandatory = $true)][string]$Nom)
    $fiche = Get-ReseauDuCatalogue -Nom $Nom
    if ($null -eq $fiche) {
        $connus = @($script:Catalogue['reseaux'].Keys)
        $conseil = if ($connus.Count -gt 0) {
            'Segments connus : ' + ($connus -join ', ') + ". Pour en créer un : vazy net add $Nom"
        } else {
            "Aucun segment n'est déclaré. Créez-le : vazy net add $Nom"
        }
        throw (New-ErreurOutil "Le segment réseau « $Nom » n'existe pas." $conseil)
    }
    $identifiant = [string]$fiche['identifiant']
    Connect-Pilote | Out-Null
    $existants = @(Get-ReseauxNommes | ForEach-Object { $_.Identifiant })
    if ($existants -notcontains $identifiant) {
        throw (New-ErreurOutil "Le segment « $Nom » est au catalogue de vazy, mais l'hyperviseur ne le connaît plus (identifiant $identifiant)." `
            ("Il a probablement été supprimé en dehors de vazy.`n" +
             "Recréez-le : vazy net rm $Nom puis vazy net add $Nom`n" +
             "Pour l'état général : vazy doctor"))
    }
    return ('nomme:' + $identifiant)
}

# Garde-fou avant de créer ou de démarrer : chaque segment nommé demandé
# existe-t-il encore ? Sans lui, la VM démarrerait branchée dans le vide, ce
# qui est bien plus long à diagnostiquer qu'un refus immédiat.
function Test-ReseauxDemandes {
    param([string[]]$Modes)
    $nommes = @($Modes | Where-Object { [string]$_ -match '^(?i)nomme:' })
    if ($nommes.Count -eq 0) { return }
    $existants = @(Get-ReseauxNommes | ForEach-Object { [string]$_.Identifiant })
    foreach ($m in $nommes) {
        $identifiant = ([string]$m) -replace '^(?i)nomme:', ''
        if ($existants -notcontains $identifiant) {
            $connu = @($script:Catalogue['reseaux'].Keys | Where-Object { [string]$script:Catalogue['reseaux'][$_]['identifiant'] -ieq $identifiant })
            $quel = if ($connu.Count -gt 0) { "« $($connu[0]) » (identifiant $identifiant)" } else { "d'identifiant $identifiant" }
            throw (New-ErreurOutil "Le segment réseau $quel n'existe plus côté hyperviseur." `
                ("Il a été supprimé en dehors de vazy. Voyez l'état : vazy net list`n" +
                 'Recréez-le, ou demandez un autre réseau (--mode, --reseau-nomme).'))
        }
    }
}

# Tous les segments déclarés, avec leur état réel et leurs VM.
function Get-ListeReseaux {
    Connect-Pilote | Out-Null
    $existants = @{}
    foreach ($r in @(Get-ReseauxNommes)) { $existants[[string]$r.Identifiant] = $r }
    $liste = @()
    foreach ($nom in @($script:Catalogue['reseaux'].Keys)) {
        $fiche = $script:Catalogue['reseaux'][$nom]
        $identifiant = [string]$fiche['identifiant']
        $present = $existants.ContainsKey($identifiant)
        $liste += [pscustomobject]@{
            Nom         = $nom
            Identifiant = $identifiant
            Adresse     = [string]$fiche['adresse']
            Dhcp        = [bool]$fiche['dhcp']
            Etat        = $(if ($present) { 'actif' } else { 'absent de l''hyperviseur' })
            Vms         = @(Get-VmsSurReseau -Identifiant $identifiant)
            CreeLe      = [string]$fiche['creeLe']
        }
    }
    return $liste
}

# Crée un segment et l'enregistre sous un nom parlant.
function New-ReseauLabo {
    param(
        [Parameter(Mandatory = $true)][string]$Nom,
        [string]$Adresse = '',
        [switch]$Dhcp
    )
    Connect-Pilote | Out-Null
    Test-NomValide -Nom $Nom -Role 'nom de segment réseau'
    if ($null -ne (Get-ReseauDuCatalogue -Nom $Nom)) {
        throw (New-ErreurOutil "Le segment « $Nom » existe déjà." "Voyez-le avec vazy net list, ou supprimez-le d'abord : vazy net rm $Nom")
    }
    if (Test-NomPris $Nom) {
        throw (New-ErreurOutil "« $Nom » est déjà le nom d'une VM ou d'un modèle." 'Choisissez un autre nom : il sert à désigner le segment dans --reseau-nomme et dans les fichiers de labo.')
    }
    if ($Adresse -and $Adresse -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw (New-ErreurOutil "Adresse de segment invalide : $Adresse" 'Indiquez une adresse de réseau, par exemple 192.168.100.0.')
    }

    $identifiant = New-ReseauNomme -Adresse $Adresse -Dhcp ([bool]$Dhcp)
    $fiche = New-Dictionnaire
    $fiche['identifiant'] = $identifiant
    $fiche['adresse']     = $Adresse
    $fiche['dhcp']        = [bool]$Dhcp
    $fiche['creeLe']      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $script:Catalogue['reseaux'][$Nom] = $fiche
    Save-Catalogue
    Publish-Message 'ok' ("Segment « {0} » créé ({1}){2}." -f $Nom, $identifiant, $(if ($Adresse) { ", réseau $Adresse" } else { '' }))
    return [pscustomobject]@{ Nom = $Nom; Identifiant = $identifiant; Adresse = $Adresse; Dhcp = [bool]$Dhcp }
}

# Supprime un segment. Refuse tant qu'une VM du catalogue y est rattachée :
# la débrancher sans prévenir laisserait une VM muette au prochain démarrage.
function Remove-ReseauLabo {
    param([Parameter(Mandatory = $true)][string]$Nom)
    Connect-Pilote | Out-Null
    $fiche = Get-ReseauDuCatalogue -Nom $Nom
    if ($null -eq $fiche) {
        throw (New-ErreurOutil "Le segment « $Nom » n'existe pas." 'Voyez les segments déclarés : vazy net list')
    }
    $identifiant = [string]$fiche['identifiant']
    $utilisatrices = @(Get-VmsSurReseau -Identifiant $identifiant)
    if ($utilisatrices.Count -gt 0) {
        throw (New-ErreurOutil ("{0} VM sont encore branchées sur le segment « {1} » : {2}" -f $utilisatrices.Count, $Nom, ($utilisatrices -join ', ')) `
            ("Supprimez ces VM, ou rebranchez-les ailleurs, avant de retirer le segment.`n" +
             'Sans cela elles démarreraient sur un réseau inexistant.'))
    }
    try { Remove-ReseauNomme -Identifiant $identifiant }
    catch {
        # L'hyperviseur refuse ou ne connaît plus le segment : la fiche part
        # quand même, sinon elle resterait coincée au catalogue pour toujours.
        Publish-Message 'attention' ("le segment {0} n'a pas pu être retiré de l'hyperviseur ({1}). Sa fiche est retirée du catalogue ; vérifiez l'éditeur de réseaux virtuels." -f $identifiant, $_.Exception.Message)
    }
    foreach ($k in @($script:Catalogue['reseaux'].Keys)) {
        if ($k -ieq $Nom) { $script:Catalogue['reseaux'].Remove($k); break }
    }
    Save-Catalogue
    Publish-Message 'ok' "Segment « $Nom » supprimé."
}

function Get-ConfigAffichable {
    return [ordered]@{
        'hyperviseur'       = $script:Config['hyperviseur']
        'outilHyperviseur'  = $(if ($script:Config['outilHyperviseur']) { $script:Config['outilHyperviseur'] } else { '(détection automatique)' })
        'dossierVms'        = $(if ($script:Config['dossierVms']) { $script:Config['dossierVms'] } else { '(à côté du modèle)' })
        'espaceDisqueMinGo' = $script:Config['espaceDisqueMinGo']
        'delaiOutilsSec'    = $script:Config['delaiOutilsSec']
        'vncPortMin'        = $script:Config['vncPortMin']
        'vncPortMax'        = $script:Config['vncPortMax']
        'dossierLabos'      = $(if ($script:Config['dossierLabos']) { $script:Config['dossierLabos'] } else { (Get-DossierLabos) + '  (défaut)' })
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
        'dossierlabos' {
            if ($Valeur) { $Valeur = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Valeur) }
            $script:Config['dossierLabos'] = $Valeur
        }
        'vncportmin' {
            $n = 0
            if (-not [int]::TryParse($Valeur, [ref]$n) -or $n -lt 1024 -or $n -gt 65535) {
                throw (New-ErreurOutil "Valeur invalide pour vncPortMin : $Valeur" 'Indiquez un port entre 1024 et 65535, par exemple 5901.')
            }
            $script:Config['vncPortMin'] = $n
        }
        'vncportmax' {
            $n = 0
            if (-not [int]::TryParse($Valeur, [ref]$n) -or $n -lt 1024 -or $n -gt 65535 -or $n -lt [int]$script:Config['vncPortMin']) {
                throw (New-ErreurOutil "Valeur invalide pour vncPortMax : $Valeur" ("Indiquez un port entre " + $script:Config['vncPortMin'] + " et 65535."))
            }
            $script:Config['vncPortMax'] = $n
        }
        'delaioutilssec' {
            $n = 0
            if (-not [int]::TryParse($Valeur, [ref]$n) -or $n -lt 5 -or $n -gt 1800) {
                throw (New-ErreurOutil "Valeur invalide pour delaiOutilsSec : $Valeur" 'Indiquez un nombre de secondes entre 5 et 1800, par exemple 180.')
            }
            $script:Config['delaiOutilsSec'] = $n
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
            throw (New-ErreurOutil "Clé de configuration inconnue : $Cle" 'Clés possibles : dossierVms, dossierLabos, outilHyperviseur, espaceDisqueMinGo, delaiOutilsSec, vncPortMin, vncPortMax, hyperviseur.')
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
#
# $env:VAZY_PILOTE impose un fichier de pilote précis, en court-circuitant la
# configuration. C'est le seul point d'entrée des tests : ils y placent un faux
# pilote qui tient l'état en mémoire, ce qui permet de vérifier toute la
# logique sans hyperviseur installé (voir tests\README.md). En usage normal la
# variable n'est jamais définie et rien ne change.
$cheminPilote = if ($env:VAZY_PILOTE) { $env:VAZY_PILOTE } else { Join-Path $script:DossierLib ('pilote-' + $script:Config['hyperviseur'] + '.ps1') }
if (-not (Test-Path -LiteralPath $cheminPilote -PathType Leaf)) {
    throw (New-ErreurOutil "Le pilote « $($script:Config['hyperviseur']) » n'existe pas ($cheminPilote)." `
        "Corrigez la clé hyperviseur dans $($script:CheminConfig) (valeur attendue : vmware).")
}
. $cheminPilote
