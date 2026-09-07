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
  vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]
                                     enregistre une VM éteinte, avec instantané, comme modèle
  vazy template list                 modèles enregistrés
  vazy template rm <alias>           retire un modèle du catalogue (aucun fichier supprimé)
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

EXEMPLES
  vazy ubuntu-server
  vazy ubuntu-server --name TP14 --ram 4 --cpu 2
  vazy win11 --mode nat --mode hostonly --nogui
  vazy ubuntu-server --set svga.autodetect=FALSE --set usb.present=TRUE

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
    $optionsAvecValeur = @('name', 'ram', 'cpu', 'reseau', 'mode', 'set', 'snapshot')
    $drapeaux          = @('nogui', 'nostart', 'hard', 'yes', 'help', 'version')
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

function Assert-AucunArgumentEnTrop {
    param($Analyse, [int]$Attendus)
    if ($Analyse.Positionnels.Count -gt $Attendus) {
        $enTrop = @($Analyse.Positionnels | Select-Object -Skip $Attendus)
        throw (New-ErreurUsage ('Argument inattendu : ' + ($enTrop -join ' ')))
    }
}

function Read-Confirmation {
    param([string]$Question)
    $reponse = $null
    try {
        $reponse = Read-Host ($Question + ' (o/N)')
    } catch { }
    if ($null -eq $reponse) {
        # Pas de console interactive (script, tâche planifiée...) : Read-Host ne renvoie rien.
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

    Write-Host ("vazy : création d'une VM depuis le modèle « {0} »" -f $modele) -ForegroundColor White
    # .ToArray() et non @(...) : en PowerShell 5.1, @() sur une List[object] vide échoue.
    $resultat = New-VmDepuisModele -Modele $modele -Nom $nom -RamGo $ramGo -Cpu $cpu -Modes $modes -Brut $Analyse.Sets.ToArray() `
                                   -SansInterface:$o.ContainsKey('nogui') -SansDemarrage:$o.ContainsKey('nostart')

    Write-Host ''
    $etat = if ($resultat.Demarree) { 'prête et démarrée' } else { 'créée (non démarrée)' }
    Write-Host ('VM « {0} » {1} en {2}.' -f $resultat.Nom, $etat, ('{0:0.0} s' -f $resultat.Duree)) -ForegroundColor Green
    Write-Host ('  dossier : {0}' -f $resultat.Dossier) -ForegroundColor Gray
    if ($resultat.Demarree) {
        Write-Host ('  arrêter : vazy stop {0}     supprimer : vazy rm {0}' -f $resultat.Nom) -ForegroundColor Gray
    } else {
        Write-Host ('  démarrer : vazy start {0}     supprimer : vazy rm {0}' -f $resultat.Nom) -ForegroundColor Gray
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
        $lignes.Add(@($vm.Nom, $vm.Etat, $vm.Modele, ('{0} Go' -f $vm.RamGo), [string]$vm.Cpu, $vm.Reseau, $date))
    }
    Write-Tableau -EnTetes @('NOM', 'ÉTAT', 'MODÈLE', 'RAM', 'CPU', 'RÉSEAU', 'CRÉÉE LE') -Lignes $lignes.ToArray() -Couleurs {
        param($colonne, $valeur)
        if ($colonne -ne 1) { return $null }
        switch ($valeur) { 'en marche' { 'Green' } 'absente' { 'Red' } default { 'DarkGray' } }
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
                $lignes.Add(@($m.Alias, $m.Instantane, [string]$m.Clones, $(if ($m.Present) { $m.Chemin } else { $m.Chemin + '  (INTROUVABLE)' })))
            }
            Write-Tableau -EnTetes @('ALIAS', 'INSTANTANÉ', 'CLONES', 'FICHIER') -Lignes $lignes.ToArray() -Couleurs {
                param($colonne, $valeur)
                if ($colonne -eq 3 -and $valeur -like '*(INTROUVABLE)') { 'Red' } else { $null }
            }
        }
        'rm' {
            if ($Analyse.Positionnels.Count -lt 3) { throw (New-ErreurUsage 'Usage : vazy template rm <alias>') }
            Assert-AucunArgumentEnTrop -Analyse $Analyse -Attendus 3
            Remove-Modele -Alias $Analyse.Positionnels[2]
        }
        default {
            throw (New-ErreurUsage 'Usage : vazy template add <chemin.vmx> [--name <alias>] | vazy template list | vazy template rm <alias>')
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

try {
    . (Join-Path $PSScriptRoot 'logique.ps1')
    Set-Afficheur { param($Type, $Message) Write-MessageOutil -Type $Type -Message $Message }

    $analyse = ConvertFrom-Arguments -Jetons ([string[]]$args)
    $commande = if ($analyse.Positionnels.Count -gt 0) { $analyse.Positionnels[0].ToLower() } else { 'help' }
    if ($analyse.Options.ContainsKey('help'))    { $commande = 'help' }
    if ($analyse.Options.ContainsKey('version')) { $commande = 'version' }

    switch ($commande) {
        'help'     { Show-Aide }
        'version'  { Write-Host ('vazy {0}' -f $script:VersionOutil) }
        'list'     { Invoke-CommandeList     -Analyse $analyse }
        'start'    { Invoke-CommandeStart    -Analyse $analyse }
        'stop'     { Invoke-CommandeStop     -Analyse $analyse }
        'rm'       { Invoke-CommandeRm       -Analyse $analyse }
        'template' { Invoke-CommandeTemplate -Analyse $analyse }
        'config'   { Invoke-CommandeConfig   -Analyse $analyse }
        default    { Invoke-CommandeCreation -Analyse $analyse }
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
