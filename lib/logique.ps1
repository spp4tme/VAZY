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
$script:VersionOutil   = '1.5.0'
$script:VersionCatalogue = 6          # schéma de catalogue.json (voir Read-Catalogue)
$script:SeuilNettoyage = 3            # au-delà de ce nombre de VM éphémères à supprimer d'un coup, on demande confirmation
$script:InstantaneNeuf = 'vazy-neuf'  # point de retour pris à la création, cible de « vazy reset »
$script:DossierDonnees = if ($env:VAZY_HOME) { $env:VAZY_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'vazy' }
$script:CheminConfig    = Join-Path $script:DossierDonnees 'config.json'
$script:CheminCatalogue = Join-Path $script:DossierDonnees 'catalogue.json'
$script:DossierIdentifiants = Join-Path $script:DossierDonnees 'creds'   # identifiants d'invité par modèle, chiffrés (DPAPI)
$script:DossierLib     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Config         = $null
$script:Catalogue      = $null
$script:Pilote         = $null      # description renvoyée par Initialize-Pilote (chargée à la demande)
$script:InfosHote      = $null      # résultat de l'interrogation WMI (une seule fois par exécution)
$script:RappelHyperVFait = $false   # le rappel court Hyper-V a-t-il déjà été affiché dans cette exécution ?
$script:Afficheur      = { param($Type, $Message) }   # remplacé par l'interface
$script:MotsReserves   = @('list', 'start', 'stop', 'rm', 'template', 'config', 'help', 'version',
                           'reset', 'snap', 'snaps', 'back', 'unsnap', 'gc', 'lab')

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
    $c['delaiOutilsSec']    = 120        # attente maximale des outils invité avant de personnaliser (phase 4)
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
#   Les entrées gardent toute clé inconnue : de futurs champs (alias de
#   modèles, empreinte du modèle...) s'ajoutent sans migration destructive.
function Read-Catalogue {
    $lu = Read-FichierJson -Chemin $script:CheminCatalogue
    $c = New-Dictionnaire
    $c['version'] = $script:VersionCatalogue
    $c['modeles'] = New-Dictionnaire
    $c['vms']     = New-Dictionnaire
    if ($null -eq $lu) { return $c }
    if ($lu.Contains('modeles') -and $lu['modeles'] -is [System.Collections.IDictionary]) { $c['modeles'] = $lu['modeles'] }
    if ($lu.Contains('vms')     -and $lu['vms']     -is [System.Collections.IDictionary]) { $c['vms']     = $lu['vms'] }

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
        if ($vm -is [System.Collections.IDictionary] -and -not $vm.Contains('nomHote')) {
            $vm['nomHote'] = ''          # VM d'avant la phase 4 : pas de nom d'hôte demandé
            $modifie = $true
        }
        if ($vm -is [System.Collections.IDictionary] -and $vm.Contains('nomHoteApplique')) {
            $vm.Remove('nomHoteApplique')   # v6 : la réapplication après reset/back n'existe plus
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
    }
    if ($modifie) { Write-FichierJson -Chemin $script:CheminCatalogue -Objet $c }
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
        return [pscustomobject]@{
            Nom = $Nom; Chemin = $vm['chemin']; Dossier = $vm['dossier']; Modele = $vm['modele']
            RamGo = $vm['ramGo']; Cpu = $vm['cpu']; Reseau = @($vm['reseau']); CreeeLe = $vm['creeeLe']
            InstantaneNeuf = [string]$vm['instantaneNeuf']
            Ephemere = ($vm['ephemere'] -eq $true)
            Labo = [string]$vm['labo']
            NomHote = [string]$vm['nomHote']
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
        [string]$NomHote = ''           # nom d'hôte à appliquer dans l'invité après démarrage (phase 4), vide = rien
    )
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Ephemere -and $SansDemarrage) {
        throw (New-ErreurOutil "--tmp et --nostart sont incompatibles : une VM éphémère est supprimée dès qu'elle est éteinte, la créer sans la démarrer la condamnerait au prochain lancement de vazy." `
            "Retirez l'une des deux options.")
    }
    Connect-Pilote | Out-Null
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
    $fiche['nomHote']  = $NomHote    # appliqué à chaque démarrage par vazy (voir Start-VmAvecPersonnalisation)
    $script:Catalogue['vms'][$Nom] = $fiche
    Save-Catalogue

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
    $n = 0
    foreach ($m in $ordre) {
        if ($aCreer -notcontains $m.Nom) { continue }
        $n++
        $nomVm = Get-NomVmLabo -Labo $Labo -Machine $m.Nom
        Publish-Message 'etape' ("Création {0}/{1} : {2} -> VM « {3} »" -f $n, $aCreer.Count, $m.Nom, $nomVm)
        New-VmDepuisModele -Modele $m.Modele -Nom $nomVm -RamGo $m.RamGo -Cpu $m.Cpu -Modes @($m.Modes) -Brut @($m.Brut) -SansDemarrage -Labo $Labo.Nom -NomHote $m.NomHote | Out-Null
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
            Start-Sleep -Seconds $Labo.Delai
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
function Get-ChargeUtileInvite {
    param([string]$NomHote)
    $config = [ordered]@{ hostname = $NomHote }
    $json = ConvertTo-Json -InputObject $config -Compress
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
    $modele = Get-ModeleDuCatalogue -Alias $Vm.Modele
    $methode = if ($Vm.NomHote) { Get-MethodePersonnalisation -Alias $Vm.Modele } else { 'aucune' }
    if ($Vm.NomHote) {
        switch ($methode) {
            'guestinfo' {
                Set-MachineVariableInvite -Machine $Vm.Chemin -Nom 'vazy_config' -Valeur (Get-ChargeUtileInvite -NomHote $Vm.NomHote)
                Publish-Message 'info' ("configuration déposée pour l'invité (guestinfo) : nom d'hôte « {0} », appliquée par le script du modèle à chaque démarrage." -f $Vm.NomHote)
            }
            'aucune' {
                Publish-Message 'info' ("nom d'hôte « {0} » non appliqué : le modèle « {1} » n'est ni marqué guestinfo (vazy template mark {1} --guestinfo) ni doté d'identifiants (vazy template creds {1})." -f $Vm.NomHote, $Vm.Modele)
            }
        }
    } elseif ($modele['guestinfo'] -eq $true) {
        # Aucun nom demandé : ne laisse traîner aucune configuration antérieure.
        Set-MachineVariableInvite -Machine $Vm.Chemin -Nom 'vazy_config' -Valeur ''
    }
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

# ----------------------------------------------------------------------------
#  Configuration
# ----------------------------------------------------------------------------

function Get-ConfigAffichable {
    return [ordered]@{
        'hyperviseur'       = $script:Config['hyperviseur']
        'outilHyperviseur'  = $(if ($script:Config['outilHyperviseur']) { $script:Config['outilHyperviseur'] } else { '(détection automatique)' })
        'dossierVms'        = $(if ($script:Config['dossierVms']) { $script:Config['dossierVms'] } else { '(à côté du modèle)' })
        'espaceDisqueMinGo' = $script:Config['espaceDisqueMinGo']
        'delaiOutilsSec'    = $script:Config['delaiOutilsSec']
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
            throw (New-ErreurOutil "Clé de configuration inconnue : $Cle" 'Clés possibles : dossierVms, outilHyperviseur, espaceDisqueMinGo, delaiOutilsSec, hyperviseur.')
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
