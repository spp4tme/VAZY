# ============================================================================
#  vazy - couche 1 : interface en ligne de commande
# ============================================================================
#  Rôle : lire les arguments, les valider, afficher les messages et les
#  erreurs. Aucune décision métier ici (couche 2 : lib\logique.ps1), aucune
#  connaissance de l'hyperviseur (couche 3 : lib\pilote-vmware.ps1).
#
#  Usage rapide :  vazy <modele> [options]     |     vazy help
#
#  Ce fichier est lancé par vazy.cmd (powershell -File), l'unique point
#  d'entrée : ainsi la politique d'exécution des scripts n'entre pas en jeu.
#  Les arguments arrivent bruts dans $args et sont analysés ici
#  (--option valeur, --option=valeur).
# ============================================================================
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$codeSortie = 0

# ----------------------------------------------------------------------------
#  Affichage
# ----------------------------------------------------------------------------

# Afficheur branché sur la couche logique (voir Set-Afficheur).
function Write-MessageOutil {
    param([string]$Type, [string]$Message)
    switch ($Type) {
        'etape'     { Write-Host $Message -ForegroundColor Cyan }
        'ok'        { Write-Host ('      ' + $Message) -ForegroundColor Green }
        'info'      { Write-Host ('      ' + $Message) -ForegroundColor Gray }
        'detail'    { Write-Host ('      ' + $Message) -ForegroundColor DarkGray }
        'attention' {
            $lignes = $Message -split "`n"
            Write-Host ('ATTENTION : ' + $lignes[0]) -ForegroundColor Yellow
            foreach ($l in ($lignes | Select-Object -Skip 1)) { Write-Host ('            ' + $l) -ForegroundColor Yellow }
        }
        default     { Write-Host $Message }
    }
}

function Write-Erreur {
    param([string]$Message, [string]$Conseil)
    Write-Host ''
    Write-Host ('Erreur : ' + $Message) -ForegroundColor Red
    if ($Conseil) {
        $lignes = $Conseil -split "`n"
        Write-Host ('  -> ' + $lignes[0]) -ForegroundColor Yellow
        foreach ($l in ($lignes | Select-Object -Skip 1)) { Write-Host ('     ' + $l) -ForegroundColor Yellow }
    }
}

# Tableau texte aligné. $Lignes : tableaux de chaînes ; $Couleurs : fonction
# facultative (index de colonne, valeur) -> couleur ou $null.
function Write-Tableau {
    param([string[]]$EnTetes, [object[]]$Lignes, [scriptblock]$Couleurs = $null)
    $largeurs = @()
    for ($c = 0; $c -lt $EnTetes.Count; $c++) {
        $max = $EnTetes[$c].Length
        foreach ($l in $Lignes) { if ([string]$l[$c] -and ([string]$l[$c]).Length -gt $max) { $max = ([string]$l[$c]).Length } }
        $largeurs += $max
    }
    $entete = ''
    for ($c = 0; $c -lt $EnTetes.Count; $c++) { $entete += $EnTetes[$c].PadRight($largeurs[$c] + 2) }
    Write-Host $entete.TrimEnd() -ForegroundColor White
    foreach ($l in $Lignes) {
        for ($c = 0; $c -lt $EnTetes.Count; $c++) {
            $valeur = ([string]$l[$c]).PadRight($largeurs[$c] + 2)
            $couleur = if ($Couleurs) { & $Couleurs $c ([string]$l[$c]) } else { $null }
            if ($couleur) { Write-Host $valeur -NoNewline -ForegroundColor $couleur } else { Write-Host $valeur -NoNewline }
        }
        Write-Host ''
    }
}

function Show-Aide {
    Write-Host @'
vazy - crée une VM en une commande : clone lié d'un modèle, réglages, démarrage.

USAGE
  vazy <modele> [options]            crée un clone lié du modèle et le démarre
  vazy list                          VM créées par vazy, avec leur état
  vazy start <nom> [--nogui]         démarre une VM
  vazy stop <nom> [--hard]           arrête une VM proprement (--hard : coupe le courant)
  vazy rm <nom> [--yes]              supprime une VM et ses fichiers (demande confirmation)
  vazy reset <nom> [--nostart] [--nogui]
                                     remet la VM à neuf (retour à l'instantané vazy-neuf pris
                                     à la création) puis la redémarre
  vazy snap <nom> [libelle]          prend un instantané manuel (jalon d'un TP)
  vazy snaps <nom>                   liste les instantanés d'une VM
  vazy back <nom> <libelle> [--nostart] [--nogui]
                                     revient à un instantané manuel puis redémarre
  vazy unsnap <nom> <libelle> [--yes]
                                     supprime un instantané manuel (vazy-neuf est protégé)
  vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]
                                     enregistre une VM éteinte, avec instantané, comme modèle
  vazy template list                 modèles enregistrés
  vazy template rm <alias>           retire un modèle du catalogue (aucun fichier supprimé)
  vazy template creds <alias> [--user <nom>] [--os linux|windows] [--rm]
                                     identifiants d'un compte de l'invité (mot de passe saisi masqué,
                                     stocké chiffré pour votre compte Windows), pour --hostname
  vazy gc [--yes]                    supprime les VM éphémères éteintes (fait aussi automatiquement
                                     au début de chaque commande)
  vazy lab up <fichier.json>         monte un labo entier décrit par un fichier (relançable :
                                     crée ce qui manque, démarre ce qui est éteint, dans l'ordre)
  vazy lab status <fichier.json>     état de chaque machine du labo
  vazy lab down <fichier.json> [--yes] [--stop-only] [--hard]
                                     arrête et supprime tout le labo (--stop-only : arrête sans supprimer)
  vazy config [<cle> <valeur>]       affiche ou modifie la configuration
  vazy help | version

OPTIONS DE CRÉATION (toutes facultatives)
  --name <nom>       nom de la VM                 défaut : <modele>-1, <modele>-2, ...
  --ram <Go>         mémoire en Go (décimales ok) défaut : 2
  --cpu <n>          nombre de cœurs              défaut : 2
  --reseau <n>       nombre de cartes réseau      défaut : 1 (0 = aucune)
  --mode <m>         nat | bridged | hostonly     défaut : nat
                     un mode par carte, en répétant l'option : --mode nat --mode hostonly
                     (ou --mode "nat,hostonly" : les guillemets sont obligatoires sous PowerShell)
  --set <cle>=<val>  écrit une ligne brute dans la configuration de la VM, répétable ;
                     appliqué après les autres options, il peut donc les écraser
  --nogui            démarre sans fenêtre
  --nostart          crée sans démarrer
  --tmp              VM éphémère : supprimée automatiquement dès qu'elle est trouvée éteinte
                     (incompatible avec --nostart)
  --hostname <nom>   nom d'hôte à appliquer dans l'invité après le démarrage (nécessite les
                     identifiants du modèle : vazy template creds <modele>)

EXEMPLES
  vazy ubuntu-server
  vazy ubuntu-server --tmp           je teste un truc, j'éteins, il ne reste rien
  vazy ubuntu-server --name TP14 --ram 4 --cpu 2
  vazy win11 --mode nat --mode hostonly --nogui
  vazy ubuntu-server --set svga.autodetect=FALSE --set usb.present=TRUE
  vazy reset TP14                    le TP est cassé : retour à l'état neuf en quelques secondes
  vazy snap TP14 avant-dhcp          jalon, puis plus tard : vazy back TP14 avant-dhcp
  vazy lab up tp14-ad.json           un fichier décrit le TP entier (voir README, « Fichier de labo »)
  vazy template creds ubuntu-server  puis  vazy ubuntu-server --hostname web1   (nom d'hôte dans l'invité)

RÈGLE ABSOLUE
  Un modèle ne se démarre jamais et son instantané ne se supprime jamais :
  tous les clones qui en dépendent casseraient. vazy refuse de démarrer un modèle.
'@
    Write-Host 'FICHIERS' -ForegroundColor White
    $chemins = Get-CheminsOutil
    foreach ($k in $chemins.Keys) { Write-Host ('  {0,-14} {1}' -f $k, $chemins[$k]) }
}

# ----------------------------------------------------------------------------
#  Lecture et validation des arguments
# ----------------------------------------------------------------------------

function New-ErreurUsage {
    param([string]$Message)
    $e = New-ErreurOutil -Message $Message -Conseil 'Tapez « vazy help » pour voir la syntaxe.'
    $e.Data['CodeSortie'] = 2
    return $e
}

# Sépare les mots de la ligne de commande en : positionnels, options nommées
# et liste des --set (dans l'ordre). Accepte --option valeur et --option=valeur.
function ConvertFrom-Arguments {
    param([string[]]$Jetons)
    $optionsAvecValeur = @('name', 'ram', 'cpu', 'reseau', 'mode', 'set', 'snapshot', 'hostname', 'user', 'os')
    $drapeaux          = @('nogui', 'nostart', 'hard', 'yes', 'help', 'version', 'tmp', 'stop-only', 'rm')
    $resultat = @{
        Positionnels = New-Object 'System.Collections.Generic.List[string]'
        Options      = @{}
        Sets         = New-Object 'System.Collections.Generic.List[object]'
    }
    $i = 0
    while ($i -lt $Jetons.Count) {
        $jeton = $Jetons[$i]
        if ($jeton -in '-h', '-?', '/?') { $resultat.Options['help'] = $true; $i++; continue }
        if ($jeton -eq '-y')             { $resultat.Options['yes'] = $true;  $i++; continue }
        if ($jeton -like '--*') {
            $nom = $jeton.Substring(2)
            $valeur = $null
            $egal = $nom.IndexOf('=')
            if ($egal -ge 0) { $valeur = $nom.Substring($egal + 1); $nom = $nom.Substring(0, $egal) }
            $nom = $nom.ToLower()
            if ($drapeaux -contains $nom) {
                if ($null -ne $valeur) { throw (New-ErreurUsage "L'option --$nom ne prend pas de valeur.") }
                $resultat.Options[$nom] = $true
                $i++; continue
            }
            if ($optionsAvecValeur -contains $nom) {
                if ($null -eq $valeur) {
                    if ($i + 1 -ge $Jetons.Count) { throw (New-ErreurUsage "L'option --$nom attend une valeur.") }
                    $valeur = $Jetons[$i + 1]
                    $i++
                }
                if ($nom -eq 'set') {
                    $resultat.Sets.Add((ConvertTo-ReglageBrut -Texte $valeur))
                } elseif ($nom -eq 'mode' -and $resultat.Options.ContainsKey('mode')) {
                    # --mode répétable : un mode par carte, dans l'ordre (équivaut à --mode a,b)
                    $resultat.Options['mode'] = $resultat.Options['mode'] + ',' + $valeur
                } else {
                    $resultat.Options[$nom] = $valeur
                }
                $i++; continue
            }
            throw (New-ErreurUsage "Option inconnue : $jeton")
        }
        $resultat.Positionnels.Add($jeton)
        $i++
    }
    return $resultat
}

# "cle=valeur" -> objet Cle/Valeur. Les guillemets autour de la valeur sont retirés.
function ConvertTo-ReglageBrut {
    param([string]$Texte)
    $egal = $Texte.IndexOf('=')
    if ($egal -lt 1) { throw (New-ErreurUsage "--set attend la forme cle=valeur (reçu : « $Texte »).") }
    $cle = $Texte.Substring(0, $egal).Trim()
    $valeur = $Texte.Substring($egal + 1).Trim()
    if ($cle -match '[\s"=]') { throw (New-ErreurUsage "Clé invalide pour --set : « $cle » (pas d'espace ni de guillemet).") }
    if ($valeur.Length -ge 2 -and (($valeur[0] -eq '"' -and $valeur[-1] -eq '"') -or ($valeur[0] -eq "'" -and $valeur[-1] -eq "'"))) {
        $valeur = $valeur.Substring(1, $valeur.Length - 2)
    }
    return [pscustomobject]@{ Cle = $cle; Valeur = $valeur }
}

function ConvertTo-Entier {
    param([string]$Texte, [string]$Option, [int]$Min, [int]$Max)
    $n = 0
    if (-not [int]::TryParse($Texte.Trim(), [ref]$n) -or $n -lt $Min -or $n -gt $Max) {
        throw (New-ErreurUsage "--$Option attend un entier entre $Min et $Max (reçu : « $Texte »).")
    }
    return $n
}

# "4", "1,5", "1.5", "8Go", "512m" -> Go (nombre décimal).
function ConvertTo-RamGo {
    param([string]$Texte)
    $t = $Texte.Trim().ToLower() -replace ',', '.'
    $facteur = 1.0
    if ($t -match '^(.*?)\s*(mo|mb|m)$') { $t = $Matches[1]; $facteur = 1.0 / 1024 }
    elseif ($t -match '^(.*?)\s*(go|gb|g)$') { $t = $Matches[1] }
    $n = 0.0
    if (-not [double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        throw (New-ErreurUsage "--ram attend un nombre de Go, par exemple 4 ou 1.5 (reçu : « $Texte »).")
    }
    $n = $n * $facteur
    if ($n -lt 0.25 -or $n -gt 512) { throw (New-ErreurUsage "--ram doit être entre 0.25 et 512 Go (reçu : $Texte).") }
    return [math]::Round($n, 3)
}

# Combine --reseau et --mode en une liste : un mode par carte.
function ConvertTo-ListeModes {
    param($ModeTexte, $ReseauTexte)   # $null quand l'option n'a pas été donnée
    $synonymes = @{
        'nat' = 'nat'
        'bridged' = 'bridged'; 'bridge' = 'bridged'; 'pont' = 'bridged'
        'hostonly' = 'hostonly'; 'host-only' = 'hostonly'; 'host' = 'hostonly'
    }
    $modes = @()
    if ($null -ne $ModeTexte) {
        foreach ($m in ($ModeTexte -split ',')) {
            $k = $m.Trim().ToLower()
            if ($k -eq '') { continue }
            if (-not $synonymes.ContainsKey($k)) { throw (New-ErreurUsage "Mode réseau inconnu : « $m ». Valeurs possibles : nat, bridged, hostonly.") }
            $modes += $synonymes[$k]
        }
    }
    if ($modes.Count -eq 0) { $modes = @('nat') }
    $nombre = if ($null -ne $ReseauTexte) { ConvertTo-Entier -Texte $ReseauTexte -Option 'reseau' -Min 0 -Max 10 } else { $modes.Count }
    if ($nombre -eq 0) { return , @() }
    if ($null -ne $ModeTexte -and $modes.Count -gt $nombre) {
        throw (New-ErreurUsage "--reseau $nombre mais $($modes.Count) modes indiqués (--mode $ModeTexte) : précisez au plus un mode par carte.")
    }
    $liste = @()
    for ($i = 0; $i -lt $nombre; $i++) {
        $liste += $(if ($i -lt $modes.Count) { $modes[$i] } else { $modes[-1] })   # les cartes en plus reprennent le dernier mode
    }
    return , $liste
}

# true / false / "oui" / "non" / 1 / 0 -> booléen.
function ConvertTo-Booleen {
    param($Valeur, [string]$Cle)
    if ($Valeur -is [bool]) { return $Valeur }
    if ($Valeur -is [int] -or $Valeur -is [long] -or $Valeur -is [double]) { return ($Valeur -ne 0) }
    $t = ([string]$Valeur).Trim().ToLower()
    if ($t -in 'true', 'oui', 'yes', '1') { return $true }
    if ($t -in 'false', 'non', 'no', '0', '') { return $false }
    throw (New-ErreurUsage "la clé « $Cle » attend true ou false (reçu : « $Valeur »).")
}

# Lit et valide un fichier de labo (JSON). Clés du labo : labo (nom, sinon
# celui du fichier), delai (secondes entre deux démarrages, défaut 5),
# machines. Chaque machine accepte exactement les clés des options de
# création : modele, ram, cpu, reseau, mode, set, nogui, nostart, plus apres
# (machine(s) à démarrer avant). Les valeurs passent par les mêmes
# convertisseurs que la ligne de commande.
function Read-FichierLabo {
    param([string]$Chemin)
    $fichier = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Chemin)
    if (-not (Test-Path -LiteralPath $fichier -PathType Leaf) -and (Test-Path -LiteralPath ($fichier + '.json') -PathType Leaf)) { $fichier += '.json' }
    if (-not (Test-Path -LiteralPath $fichier -PathType Leaf)) {
        throw (New-ErreurOutil "Fichier de labo introuvable : $Chemin" "Indiquez le chemin d'un fichier JSON décrivant le labo ; un exemple est fourni dans le dossier « exemples » de vazy.")
    }
    $conseilFormat = "Corrigez le fichier $fichier (voir README, section « Fichier de labo », ou l'exemple dans le dossier « exemples » de vazy)."
    try {
        $json = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($fichier))
    } catch {
        $e = New-ErreurOutil "Le fichier $fichier n'est pas du JSON valide : $($_.Exception.Message)" 'Vérifiez les virgules, guillemets et accolades (pas de virgule après le dernier élément).'
        $e.Data['CodeSortie'] = 2; throw $e
    }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        $e = New-ErreurOutil "Le fichier $fichier doit contenir un objet JSON { ... }." $conseilFormat; $e.Data['CodeSortie'] = 2; throw $e
    }
    $clesLabo = @('labo', 'machines', 'delai')
    foreach ($p in $json.PSObject.Properties) {
        if ($clesLabo -notcontains $p.Name) {
            $e = New-ErreurOutil "Fichier $fichier : clé inconnue « $($p.Name) » au niveau du labo." ("Clés possibles : " + ($clesLabo -join ', ') + ". " + $conseilFormat); $e.Data['CodeSortie'] = 2; throw $e
        }
    }
    $nom = if ($json.PSObject.Properties['labo'] -and $json.labo) { ([string]$json.labo).Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($fichier) }
    if ($nom -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') {
        $e = New-ErreurOutil "Fichier $fichier : nom de labo invalide « $nom »." 'Lettres, chiffres, points, tirets et underscores, 32 caractères max, sans espace ni accent : il préfixe le nom de chaque VM.'; $e.Data['CodeSortie'] = 2; throw $e
    }
    $delai = 5
    if ($json.PSObject.Properties['delai'] -and $null -ne $json.delai) {
        try { $delai = ConvertTo-Entier -Texte ([string]$json.delai) -Option 'delai' -Min 0 -Max 600 }
        catch { $e = New-ErreurOutil "Fichier $fichier : la clé « delai » attend un nombre de secondes entre 0 et 600 (reçu : « $($json.delai) »)." $conseilFormat; $e.Data['CodeSortie'] = 2; throw $e }
    }
    if (-not $json.PSObject.Properties['machines'] -or $json.machines -isnot [System.Management.Automation.PSCustomObject]) {
        $e = New-ErreurOutil "Fichier $fichier : la clé « machines » manque ou n'est pas un objet { \"nom\": { ... }, ... }." $conseilFormat; $e.Data['CodeSortie'] = 2; throw $e
    }

    $clesMachine = @('modele', 'ram', 'cpu', 'reseau', 'mode', 'set', 'nogui', 'nostart', 'apres', 'hostname')
    $machines = @()
    foreach ($p in $json.machines.PSObject.Properties) {
        $nomMachine = $p.Name
        $def = $p.Value
        try {
            if ($nomMachine -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { throw (New-ErreurUsage 'nom de machine invalide (lettres, chiffres, points, tirets, underscores, 32 caractères max).') }
            if ($def -isnot [System.Management.Automation.PSCustomObject]) { throw (New-ErreurUsage 'la machine doit être décrite par un objet { "modele": "...", ... }.') }
            foreach ($k in $def.PSObject.Properties) {
                if ($clesMachine -notcontains $k.Name) {
                    $indice = if ($k.Name -eq 'tmp') { ' Une machine de labo ne peut pas être éphémère : le labo se démonte avec « vazy lab down ».' } elseif ($k.Name -eq 'name') { ' Le nom de la VM est la clé de la machine, préfixée par le nom du labo.' } else { '' }
                    throw (New-ErreurUsage ("clé inconnue « {0} ». Clés possibles : {1}.{2}" -f $k.Name, ($clesMachine -join ', '), $indice))
                }
            }
            if (-not $def.PSObject.Properties['modele'] -or -not ([string]$def.modele).Trim()) { throw (New-ErreurUsage 'la clé « modele » est obligatoire (alias d''un modèle : vazy template list).') }
            $ramGo = if ($def.PSObject.Properties['ram']) { ConvertTo-RamGo -Texte ([string]$def.ram) } else { 2 }
            $cpu   = if ($def.PSObject.Properties['cpu']) { ConvertTo-Entier -Texte ([string]$def.cpu) -Option 'cpu' -Min 1 -Max 64 } else { 2 }
            $modeTexte = $null
            if ($def.PSObject.Properties['mode']) { $modeTexte = if ($def.mode -is [array]) { (@($def.mode | ForEach-Object { [string]$_ }) -join ',') } else { [string]$def.mode } }
            $reseauTexte = if ($def.PSObject.Properties['reseau']) { [string]$def.reseau } else { $null }
            $modes = ConvertTo-ListeModes -ModeTexte $modeTexte -ReseauTexte $reseauTexte
            $brut = @()
            if ($def.PSObject.Properties['set'] -and $null -ne $def.set) {
                if ($def.set -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($s in $def.set.PSObject.Properties) { $brut += (ConvertTo-ReglageBrut -Texte ('{0}={1}' -f $s.Name, [string]$s.Value)) }
                } elseif ($def.set -is [array]) {
                    foreach ($s in $def.set) { $brut += (ConvertTo-ReglageBrut -Texte ([string]$s)) }
                } else {
                    throw (New-ErreurUsage 'la clé « set » attend un objet { "cle": "valeur", ... } ou une liste [ "cle=valeur", ... ].')
                }
            }
            $nogui   = if ($def.PSObject.Properties['nogui'])   { ConvertTo-Booleen -Valeur $def.nogui -Cle 'nogui' }     else { $false }
            $nostart = if ($def.PSObject.Properties['nostart']) { ConvertTo-Booleen -Valeur $def.nostart -Cle 'nostart' } else { $false }
            $apres = @()
            if ($def.PSObject.Properties['apres'] -and $null -ne $def.apres) {
                $apres = @($(if ($def.apres -is [array]) { $def.apres } else { @($def.apres) }) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            }
            # Nom d'hôte : le nom court de la machine par défaut ; false ou "" pour ne rien appliquer.
            $nomHote = $nomMachine
            if ($def.PSObject.Properties['hostname']) {
                if ($def.hostname -is [bool]) { $nomHote = if ($def.hostname) { $nomMachine } else { '' } }
                else { $nomHote = ([string]$def.hostname).Trim() }
                if ($nomHote) {
                    $probleme = Test-NomHote -NomHote $nomHote
                    if ($probleme) { throw (New-ErreurUsage "clé « hostname » : $probleme") }
                }
            } elseif (Test-NomHote -NomHote $nomHote) {
                $nomHote = ''   # nom de machine impossible comme nom d'hôte (point, underscore...) : pas de renommage par défaut
            }
            $machines += [pscustomobject]@{
                Nom = $nomMachine; Modele = ([string]$def.modele).Trim(); RamGo = $ramGo; Cpu = $cpu; Modes = @($modes); Brut = @($brut)
                SansInterface = $nogui; SansDemarrage = $nostart; Apres = @($apres); NomHote = $nomHote
            }
        } catch {
            $e = New-ErreurOutil ("Fichier {0}, machine « {1} » : {2}" -f $fichier, $nomMachine, $_.Exception.Message) $conseilFormat
            $e.Data['CodeSortie'] = 2
            throw $e
        }
    }
    return [pscustomobject]@{ Nom = $nom; Fichier = $fichier; Delai = $delai; Machines = @($machines) }
}

function Assert-AucunArgumentEnTrop {
    param($Analyse, [int]$Attendus)
    if ($Analyse.Positionnels.Count -gt $Attendus) {
        $enTrop = @($Analyse.Positionnels | Select-Object -Skip $Attendus)
        throw (New-ErreurUsage ('Argument inattendu : ' + ($enTrop -join ' ')))
    }
}

# Vrai si un humain peut répondre à une question au clavier. Quand l'entrée
# standard est redirigée (script, tâche planifiée, autre programme), un
# Read-Host bloquerait ou renverrait du vide : on refuse de demander.
function Test-ConsoleInteractive {
    try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

function Read-Confirmation {
    param([string]$Question)
    if (-not (Test-ConsoleInteractive)) {
        throw (New-ErreurOutil "Impossible de demander confirmation : la console n'est pas interactive." "Relancez avec --yes pour confirmer d'avance.")
    }
    $reponse = $null
    try { $reponse = Read-Host ($Question + ' (o/N)') } catch { }
    if ($null -eq $reponse) {
        throw (New-ErreurOutil "Impossible de demander confirmation : la console n'est pas interactive." "Relancez avec --yes pour confirmer d'avance.")
    }
    return (([string]$reponse).Trim().ToLower() -in 'o', 'oui', 'y', 'yes')
}

# ----------------------------------------------------------------------------
#  Commandes
# ----------------------------------------------------------------------------

function Invoke-CommandeCreation {
    param($Analyse)
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 1
    $o = $Analyse.Options
    $modele = $Analyse.Positionnels[0]
    $nom    = if ($o.ContainsKey('name')) { $o['name'].Trim() } else { '' }
    $ramGo  = if ($o.ContainsKey('ram')) { ConvertTo-RamGo -Texte $o['ram'] } else { 2 }
    $cpu    = if ($o.ContainsKey('cpu')) { ConvertTo-Entier -Texte $o['cpu'] -Option 'cpu' -Min 1 -Max 64 } else { 2 }
    $modes  = ConvertTo-ListeModes -ModeTexte $(if ($o.ContainsKey('mode')) { $o['mode'] } else { $null }) `
                                   -ReseauTexte $(if ($o.ContainsKey('reseau')) { $o['reseau'] } else { $null })

    if ($o.ContainsKey('tmp') -and $o.ContainsKey('nostart')) {
        throw (New-ErreurUsage "--tmp et --nostart sont incompatibles : une VM éphémère est supprimée dès qu'elle est trouvée éteinte, la créer sans la démarrer la condamnerait au prochain lancement de vazy. Retirez l'une des deux options.")
    }
    $nomHote = if ($o.ContainsKey('hostname')) { $o['hostname'].Trim() } else { '' }
    if ($nomHote) {
        $probleme = Test-NomHote -NomHote $nomHote
        if ($probleme) { throw (New-ErreurUsage "--hostname : $probleme") }
    }

    Write-Host ("vazy : création d'une VM {1}depuis le modèle « {0} »" -f $modele, $(if ($o.ContainsKey('tmp')) { 'éphémère ' } else { '' })) -ForegroundColor White
    # .ToArray() et non @(...) : en PowerShell 5.1, @() sur une List[object] vide échoue.
    $resultat = New-VmDepuisModele -Modele $modele -Nom $nom -RamGo $ramGo -Cpu $cpu -Modes $modes -Brut $Analyse.Sets.ToArray() `
                                   -SansInterface:$o.ContainsKey('nogui') -SansDemarrage:$o.ContainsKey('nostart') -Ephemere:$o.ContainsKey('tmp') -NomHote $nomHote

    Write-Host ''
    $etat = if ($resultat.Demarree) { 'prête et démarrée' } else { 'créée (non démarrée)' }
    $tmp = if ($resultat.Ephemere) { ' (éphémère)' } else { '' }
    Write-Host ('VM « {0} » {1} en {2}{3}.' -f $resultat.Nom, $etat, ('{0:0.0} s' -f $resultat.Duree), $tmp) -ForegroundColor Green
    Write-Host ('  dossier : {0}' -f $resultat.Dossier) -ForegroundColor Gray
    if ($resultat.Ephemere) {
        Write-Host ('  quand vous avez fini : vazy stop {0} (la supprime), ou éteignez-la de l''intérieur' -f $resultat.Nom) -ForegroundColor Gray
    } elseif ($resultat.Demarree) {
        Write-Host ('  arrêter : vazy stop {0}     supprimer : vazy rm {0}' -f $resultat.Nom) -ForegroundColor Gray
    } else {
        Write-Host ('  démarrer : vazy start {0}     supprimer : vazy rm {0}' -f $resultat.Nom) -ForegroundColor Gray
    }
}

function Invoke-CommandeGc {
    param($Analyse)
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 1
    $supprimees = @(Invoke-Nettoyage -Verbeux -Forcer:$Analyse.Options.ContainsKey('yes') -Confirmer $script:ConfirmerNettoyage)
    if ($supprimees.Count -gt 0) {
        Write-Host ('{0} VM éphémère(s) supprimée(s).' -f $supprimees.Count) -ForegroundColor Green
    }
}

function Invoke-CommandeList {
    param($Analyse)
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 1
    $vms = @(Get-ListeVms)
    if ($vms.Count -eq 0) {
        Write-Host 'Aucune VM créée par vazy pour le moment.' -ForegroundColor Gray
        Write-Host '  Créez-en une : vazy <modele>     Modèles disponibles : vazy template list' -ForegroundColor Gray
        return
    }
    $lignes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($vm in $vms) {
        $date = try { ([datetime]::Parse($vm.CreeeLe)).ToString('dd/MM/yyyy HH:mm') } catch { [string]$vm.CreeeLe }
        $lignes.Add(@($vm.Nom, $vm.Etat, $vm.Modele, ('{0} Go' -f $vm.RamGo), [string]$vm.Cpu, $vm.Reseau, $(if ($vm.Ephemere) { 'oui' } else { '' }), [string]$vm.Labo, $date))
    }
    Write-Tableau -EnTetes @('NOM', 'ÉTAT', 'MODÈLE', 'RAM', 'CPU', 'RÉSEAU', 'TMP', 'LABO', 'CRÉÉE LE') -Lignes $lignes.ToArray() -Couleurs {
        param($colonne, $valeur)
        if ($colonne -eq 6 -and $valeur -eq 'oui') { return 'Yellow' }
        if ($colonne -ne 1) { return $null }
        switch ($valeur) { 'en marche' { 'Green' } 'absente' { 'Red' } default { 'DarkGray' } }
    }
    $ephemeres = @($vms | Where-Object { $_.Ephemere })
    if ($ephemeres.Count -gt 0) {
        Write-Host ''
        Write-Host '  TMP « oui » : VM éphémère, supprimée automatiquement dès qu''elle est trouvée éteinte.' -ForegroundColor Gray
    }
    $absentes = @($vms | Where-Object { $_.Etat -eq 'absente' })
    if ($absentes.Count -gt 0) {
        Write-Host ''
        Write-Host ('  « absente » : fichiers disparus en dehors de vazy. Nettoyez avec : vazy rm <nom>') -ForegroundColor Gray
    }
}

function Invoke-CommandeStart {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy start <nom> [--nogui]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
    Start-VmParNom -Nom $Analyse.Positionnels[1] -SansInterface:$Analyse.Options.ContainsKey('nogui') | Out-Null
}

function Invoke-CommandeStop {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy stop <nom> [--hard]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
    Stop-VmParNom -Nom $Analyse.Positionnels[1] -Brutal:$Analyse.Options.ContainsKey('hard') | Out-Null
}

function Invoke-CommandeRm {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy rm <nom> [--yes]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
    $vm = Get-VmDuCatalogue -Nom $Analyse.Positionnels[1]
    if (-not $Analyse.Options.ContainsKey('yes')) {
        Write-Host ('Suppression définitive de la VM « {0} » et de tous ses fichiers ({1}).' -f $vm.Nom, $vm.Dossier) -ForegroundColor Yellow
        Write-Host '  Si elle est en marche, elle sera arrêtée brutalement.' -ForegroundColor Yellow
        if (-not (Read-Confirmation -Question 'Confirmer ?')) {
            Write-Host 'Annulé, rien n''a été supprimé.' -ForegroundColor Gray
            return
        }
    }
    Remove-VmParNom -Nom $vm.Nom | Out-Null
}

function Invoke-CommandeTemplate {
    param($Analyse)
    $sousCommande = if ($Analyse.Positionnels.Count -ge 2) { $Analyse.Positionnels[1].ToLower() } else { '' }
    switch ($sousCommande) {
        'add' {
            if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage 'Usage : vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]') }
            Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
            $alias = if ($Analyse.Options.ContainsKey('name')) { $Analyse.Options['name'].Trim() } else { '' }
            $snap  = if ($Analyse.Options.ContainsKey('snapshot')) { $Analyse.Options['snapshot'] } else { '' }
            $m = Add-Modele -Chemin $Analyse.Positionnels[2] -Alias $alias -Instantane $snap
            Write-Host ('  Créez maintenant des VM avec : vazy {0}' -f $m.Alias) -ForegroundColor Gray
        }
        'list' {
            Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
            $modeles = @(Get-ListeModeles)
            if ($modeles.Count -eq 0) {
                Write-Host 'Aucun modèle enregistré.' -ForegroundColor Gray
                Write-Host '  Préparez une VM (voir README) puis : vazy template add <chemin.vmx> --name <alias>' -ForegroundColor Gray
                return
            }
            $lignes = New-Object 'System.Collections.Generic.List[object]'
            foreach ($m in $modeles) {
                $lignes.Add(@($m.Alias, $m.Instantane, [string]$m.Clones, $(if ($m.Os) { $m.Os } else { '(détecté)' }), $(if ($m.Invite) { $m.Invite } else { '-' }), $(if ($m.Present) { $m.Chemin } else { $m.Chemin + '  (INTROUVABLE)' })))
            }
            Write-Tableau -EnTetes @('ALIAS', 'INSTANTANÉ', 'CLONES', 'SYSTÈME', 'INVITÉ', 'FICHIER') -Lignes $lignes.ToArray() -Couleurs {
                param($colonne, $valeur)
                if ($colonne -eq 5 -and $valeur -like '*(INTROUVABLE)') { 'Red' } else { $null }
            }
            Write-Host ''
            Write-Host '  INVITÉ : compte de l''invité enregistré pour la personnalisation (vazy template creds <alias>), « - » si aucun.' -ForegroundColor Gray
        }
        'creds' {
            $usageCreds = 'Usage : vazy template creds <alias> [--user <nom>] [--os linux|windows] [--rm]'
            if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage $usageCreds) }
            Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
            $alias = $Analyse.Positionnels[2]
            Get-ModeleDuCatalogue -Alias $alias | Out-Null
            if ($Analyse.Options.ContainsKey('rm')) {
                Remove-IdentifiantsModele -Alias $alias
                return
            }
            $os = ''
            if ($Analyse.Options.ContainsKey('os')) {
                $os = $Analyse.Options['os'].Trim().ToLower()
                if ($os -notin 'linux', 'windows') { throw (New-ErreurUsage "--os attend linux ou windows (reçu : « $($Analyse.Options['os']) »).") }
            }
            if (-not (Test-ConsoleInteractive)) {
                throw (New-ErreurOutil "Impossible de saisir les identifiants : la console n'est pas interactive." "Lancez cette commande dans un terminal. Le mot de passe est toujours saisi au clavier, masqué, jamais passé sur la ligne de commande.")
            }
            $actuel = Get-UtilisateurInvite -Alias $alias
            Write-Host ("Identifiants d'un compte de l'invité pour le modèle « {0} »." -f $alias) -ForegroundColor White
            Write-Host '  Le mot de passe est saisi masqué et stocké chiffré pour votre compte Windows sur ce PC (DPAPI) ; vazy ne l''affiche jamais.' -ForegroundColor Gray
            Write-Host '  Linux : un compte pouvant faire sudo sans mot de passe (ou root). Windows : un compte administrateur sans invite UAC.' -ForegroundColor Gray
            if ($actuel) { Write-Host ("  Identifiants actuels : utilisateur « {0} ». Ils seront remplacés." -f $actuel) -ForegroundColor Yellow }
            $utilisateur = if ($Analyse.Options.ContainsKey('user')) { $Analyse.Options['user'].Trim() } else { $null }
            if (-not $utilisateur) {
                try { $utilisateur = Read-Host "  Utilisateur de l'invité" } catch { $utilisateur = $null }
                if ($null -eq $utilisateur) { throw (New-ErreurOutil "Impossible de saisir les identifiants : la console n'est pas interactive." "Lancez cette commande dans un terminal ; l'utilisateur peut être passé avec --user, le mot de passe est toujours saisi au clavier.") }
                $utilisateur = $utilisateur.Trim()
            }
            if (-not $utilisateur) { throw (New-ErreurUsage "L'utilisateur de l'invité ne peut pas être vide.") }
            $secret = $null
            try { $secret = Read-Host "  Mot de passe de « $utilisateur » (saisie masquée)" -AsSecureString } catch { $secret = $null }
            if ($null -eq $secret) { throw (New-ErreurOutil "Impossible de saisir le mot de passe : la console n'est pas interactive." "Lancez cette commande dans un terminal ; le mot de passe est toujours saisi au clavier, jamais sur la ligne de commande.") }
            if ($secret.Length -eq 0) { throw (New-ErreurUsage "Le mot de passe ne peut pas être vide.") }
            $identifiants = New-Object System.Management.Automation.PSCredential($utilisateur, $secret)
            Set-IdentifiantsModele -Alias $alias -Identifiants $identifiants -Os $os
            Write-Host ('  Essai : vazy {0} --hostname test1     (un labo applique par défaut le nom court de chaque machine)' -f $alias) -ForegroundColor Gray
        }
        'rm' {
            if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage 'Usage : vazy template rm <alias>') }
            Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
            Remove-Modele -Alias $Analyse.Positionnels[2]
        }
        default {
            throw (New-ErreurUsage 'Usage : vazy template add <chemin.vmx> [--name <alias>] | vazy template list | vazy template rm <alias> | vazy template creds <alias>')
        }
    }
}

function Invoke-CommandeReset {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy reset <nom> [--nostart] [--nogui]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
    $nom = $Analyse.Positionnels[1]
    Write-Host ("vazy : remise à zéro de « {0} »" -f $nom) -ForegroundColor White
    $r = Reset-VmParNom -Nom $nom -SansDemarrage:$Analyse.Options.ContainsKey('nostart') -SansInterface:$Analyse.Options.ContainsKey('nogui')
    Write-Host ''
    $suite = if ($r.Demarree) { 'et redémarrée' } else { '(non démarrée : vazy start ' + $r.Vm + ')' }
    Write-Host ('VM « {0} » remise à neuf {1} en {2}.' -f $r.Vm, $suite, ('{0:0.0} s' -f $r.Duree)) -ForegroundColor Green
}

function Invoke-CommandeSnap {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy snap <nom> [libelle]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
    $libelle = if ($Analyse.Positionnels.Count -ge 3) { $Analyse.Positionnels[2] } else { '' }
    $r = New-InstantaneVm -Nom $Analyse.Positionnels[1] -Libelle $libelle
    Write-Host ('  Pour y revenir : vazy back {0} "{1}"' -f $r.Vm, $r.Libelle) -ForegroundColor Gray
}

function Invoke-CommandeSnaps {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 2) { throw (New-ErreurUsage 'Usage : vazy snaps <nom>') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 2
    $liste = @(Get-InstantanesVm -Nom $Analyse.Positionnels[1])
    if ($liste.Count -eq 0) {
        Write-Host ('Aucun instantané sur « {0} ».' -f $Analyse.Positionnels[1]) -ForegroundColor Gray
        Write-Host ('  Point de retour manquant : VM éteinte, vazy snap {0} vazy-neuf     Jalon : vazy snap {0} <libelle>' -f $Analyse.Positionnels[1]) -ForegroundColor Gray
        return
    }
    $lignes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $liste) { $lignes.Add(@($s.Libelle, $s.Role)) }
    Write-Tableau -EnTetes @('LIBELLÉ', 'RÔLE') -Lignes $lignes.ToArray() -Couleurs {
        param($colonne, $valeur)
        if ($colonne -eq 1 -and $valeur -like 'point de retour*') { 'Cyan' } else { $null }
    }
    Write-Host ''
    Write-Host ('  Revenir : vazy back {0} <libelle>     Remise à neuf : vazy reset {0}' -f $liste[0].Vm) -ForegroundColor Gray
}

function Invoke-CommandeBack {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage 'Usage : vazy back <nom> <libelle> [--nostart] [--nogui]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
    $nom = $Analyse.Positionnels[1]; $libelle = $Analyse.Positionnels[2]
    Write-Host ("vazy : retour de « {0} » à l'instantané « {1} »" -f $nom, $libelle) -ForegroundColor White
    $r = Restore-InstantaneVm -Nom $nom -Libelle $libelle -SansDemarrage:$Analyse.Options.ContainsKey('nostart') -SansInterface:$Analyse.Options.ContainsKey('nogui')
    Write-Host ''
    $suite = if ($r.Demarree) { 'et redémarrée' } else { '(non démarrée : vazy start ' + $r.Vm + ')' }
    Write-Host ('VM « {0} » revenue à « {1} » {2} en {3}.' -f $r.Vm, $r.Libelle, $suite, ('{0:0.0} s' -f $r.Duree)) -ForegroundColor Green
}

function Invoke-CommandeUnsnap {
    param($Analyse)
    if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage 'Usage : vazy unsnap <nom> <libelle> [--yes]') }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
    $nom = $Analyse.Positionnels[1]; $libelle = $Analyse.Positionnels[2]
    if (-not $Analyse.Options.ContainsKey('yes')) {
        Write-Host ('Suppression de l''instantané « {0} » de la VM « {1} » : ce point de retour sera perdu.' -f $libelle, $nom) -ForegroundColor Yellow
        if (-not (Read-Confirmation -Question 'Confirmer ?')) {
            Write-Host 'Annulé, rien n''a été supprimé.' -ForegroundColor Gray
            return
        }
    }
    Remove-InstantaneVm -Nom $nom -Libelle $libelle | Out-Null
}

function Write-TableauLabo {
    param($Lignes)
    $tab = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in $Lignes) { $tab.Add(@($l.Machine, $l.Vm, $l.Etat, $l.Modele, ('{0} Go' -f $l.RamGo), [string]$l.Cpu, $l.Reseau, $l.Apres)) }
    Write-Tableau -EnTetes @('MACHINE', 'VM', 'ÉTAT', 'MODÈLE', 'RAM', 'CPU', 'RÉSEAU', 'APRÈS') -Lignes $tab.ToArray() -Couleurs {
        param($colonne, $valeur)
        if ($colonne -ne 2) { return $null }
        switch ($valeur) { 'en marche' { 'Green' } 'absente' { 'Red' } 'hors labo' { 'Red' } 'à créer' { 'Yellow' } default { 'DarkGray' } }
    }
}

function Invoke-CommandeLab {
    param($Analyse)
    $usage = 'Usage : vazy lab up <fichier.json> | vazy lab status <fichier.json> | vazy lab down <fichier.json> [--yes] [--stop-only] [--hard]'
    if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage $usage) }
    Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
    $sousCommande = $Analyse.Positionnels[1].ToLower()
    if ($sousCommande -notin 'up', 'status', 'down') { throw (New-ErreurUsage $usage) }
    $labo = Read-FichierLabo -Chemin $Analyse.Positionnels[2]
    switch ($sousCommande) {
        'up' {
            Write-Host ("vazy : montage du labo « {0} » ({1})" -f $labo.Nom, $labo.Fichier) -ForegroundColor White
            $r = Invoke-LaboUp -Labo $labo
            Write-Host ''
            Write-Host ('Labo « {0} » monté en {1} : {2} VM créée(s), {3} démarrée(s).' -f $r.Nom, ('{0:0.0} s' -f $r.Duree), $r.Creees, $r.Demarrees) -ForegroundColor Green
            Write-TableauLabo -Lignes @(Get-StatutLabo -Labo $labo)
            Write-Host ('  démonter : vazy lab down {0}     arrêter seulement : vazy lab down {0} --stop-only' -f $Analyse.Positionnels[2]) -ForegroundColor Gray
        }
        'status' {
            Write-Host ("Labo « {0} » ({1})" -f $labo.Nom, $labo.Fichier) -ForegroundColor White
            Write-TableauLabo -Lignes @(Get-StatutLabo -Labo $labo)
        }
        'down' {
            $existantes = @(Get-StatutLabo -Labo $labo | Where-Object { $_.Etat -notin 'à créer', 'hors labo' })
            if ($existantes.Count -eq 0) {
                Write-Host ("Labo « {0} » : aucune VM à arrêter ni à supprimer." -f $labo.Nom) -ForegroundColor Gray
                return
            }
            $stopSeulement = $Analyse.Options.ContainsKey('stop-only')
            if (-not $stopSeulement -and -not $Analyse.Options.ContainsKey('yes')) {
                Write-Host ('Démontage du labo « {0} » : arrêt et suppression définitive de {1} VM ({2}).' -f $labo.Nom, $existantes.Count, (($existantes | ForEach-Object { $_.Vm }) -join ', ')) -ForegroundColor Yellow
                if (-not (Read-Confirmation -Question 'Confirmer ?')) {
                    Write-Host 'Annulé, rien n''a été touché.' -ForegroundColor Gray
                    return
                }
            }
            $r = Invoke-LaboDown -Labo $labo -StopSeulement:$stopSeulement -Brutal:$Analyse.Options.ContainsKey('hard')
            Write-Host ''
            if ($stopSeulement) { Write-Host ('Labo « {0} » arrêté : {1} VM arrêtée(s), {2} conservée(s).' -f $r.Nom, $r.Arretees, $r.Total) -ForegroundColor Green }
            else { Write-Host ('Labo « {0} » démonté : {1} VM supprimée(s).' -f $r.Nom, $r.Supprimees) -ForegroundColor Green }
        }
    }
}

function Invoke-CommandeConfig {
    param($Analyse)
    if ($Analyse.Positionnels.Count -eq 1) {
        $config = Get-ConfigAffichable
        foreach ($k in $config.Keys) { Write-Host ('  {0,-18} {1}' -f $k, $config[$k]) }
        Write-Host ''
        Write-Host '  Modifier : vazy config <cle> <valeur>     Exemple : vazy config dossierVms D:\VMs' -ForegroundColor Gray
        return
    }
    if ($Analyse.Positionnels.Count -ne 3) { throw (New-ErreurUsage 'Usage : vazy config <cle> <valeur>   (valeur "" pour revenir au défaut)') }
    Set-ConfigValeur -Cle $Analyse.Positionnels[1] -Valeur $Analyse.Positionnels[2]
    Write-Host ('  {0} = {1}' -f $Analyse.Positionnels[1], $(if ($Analyse.Positionnels[2]) { $Analyse.Positionnels[2] } else { '(défaut)' })) -ForegroundColor Green
}

# ----------------------------------------------------------------------------
#  Point d'entrée
# ----------------------------------------------------------------------------

# Demande de confirmation du nettoyage quand il porte sur beaucoup de VM.
# Sans console interactive, la réponse est « non » : rien n'est supprimé.
$script:ConfirmerNettoyage = {
    param($noms)
    Write-Host ('Nettoyage : {0} VM éphémères éteintes à supprimer ({1}). C''est beaucoup pour un nettoyage automatique.' -f $noms.Count, ($noms -join ', ')) -ForegroundColor Yellow
    try { return (Read-Confirmation -Question 'Les supprimer toutes ?') } catch { return $false }
}

try {
    . (Join-Path $PSScriptRoot 'logique.ps1')
    Set-Afficheur { param($Type, $Message) Write-MessageOutil -Type $Type -Message $Message }

    $analyse = ConvertFrom-Arguments -Jetons ([string[]]$args)
    $commande = if ($analyse.Positionnels.Count -gt 0) { $analyse.Positionnels[0].ToLower() } else { 'help' }
    if ($analyse.Options.ContainsKey('help'))    { $commande = 'help' }
    if ($analyse.Options.ContainsKey('version')) { $commande = 'version' }

    # Nettoyage paresseux des VM éphémères, avant toute autre chose (« gc » le
    # lance lui-même, en mode détaillé). Sans VM éphémère, ne coûte rien.
    $nettoyees = @()
    if ($commande -ne 'gc') {
        try {
            $nettoyees = @(Invoke-Nettoyage -Confirmer $script:ConfirmerNettoyage)
        } catch {
            $detail = $_.Exception.Message
            if ($_.Exception.Data.Contains('Conseil')) { $detail += ' ' + $_.Exception.Data['Conseil'] }
            Write-MessageOutil -Type 'attention' -Message ('Nettoyage des VM éphémères impossible : ' + $detail)
        }
    }

    $ciblesVm = @('start', 'stop', 'rm', 'reset', 'snap', 'snaps', 'back', 'unsnap')
    if ($nettoyees.Count -gt 0 -and $ciblesVm -contains $commande -and $analyse.Positionnels.Count -ge 2 -and $nettoyees -contains $analyse.Positionnels[1]) {
        # La VM visée était éphémère et éteinte : le nettoyage vient de l'effacer.
        Write-Host ("La VM éphémère « {0} » était éteinte : le nettoyage automatique vient de la supprimer, il n'y a plus rien à faire." -f $analyse.Positionnels[1]) -ForegroundColor Gray
    } else {
        switch ($commande) {
            'help'     { Show-Aide }
            'version'  { Write-Host ('vazy {0}' -f $script:VersionOutil) }
            'list'     { Invoke-CommandeList     -Analyse $analyse }
            'start'    { Invoke-CommandeStart    -Analyse $analyse }
            'stop'     { Invoke-CommandeStop     -Analyse $analyse }
            'rm'       { Invoke-CommandeRm       -Analyse $analyse }
            'reset'    { Invoke-CommandeReset    -Analyse $analyse }
            'snap'     { Invoke-CommandeSnap     -Analyse $analyse }
            'snaps'    { Invoke-CommandeSnaps    -Analyse $analyse }
            'back'     { Invoke-CommandeBack     -Analyse $analyse }
            'unsnap'   { Invoke-CommandeUnsnap   -Analyse $analyse }
            'gc'       { Invoke-CommandeGc       -Analyse $analyse }
            'lab'      { Invoke-CommandeLab      -Analyse $analyse }
            'template' { Invoke-CommandeTemplate -Analyse $analyse }
            'config'   { Invoke-CommandeConfig   -Analyse $analyse }
            default    { Invoke-CommandeCreation -Analyse $analyse }
        }
    }
} catch {
    $ex = $_.Exception
    if ($ex.Data.Contains('Conseil')) {
        Write-Erreur -Message $ex.Message -Conseil $ex.Data['Conseil']
        $codeSortie = if ($ex.Data.Contains('CodeSortie')) { [int]$ex.Data['CodeSortie'] } else { 1 }
    } else {
        # Erreur non prévue : on la montre proprement, avec l'endroit du script concerné.
        Write-Erreur -Message $ex.Message -Conseil 'Erreur inattendue. Si elle se reproduit, relancez avec la variable d''environnement VAZY_DEBUG=1 pour obtenir le détail.'
        Write-Host ('  ({0}:{1})' -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
        if ($env:VAZY_DEBUG) {
            Write-Host ('  Type : ' + $ex.GetType().FullName) -ForegroundColor DarkGray
            Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        }
        $codeSortie = 1
    }
}
exit $codeSortie
