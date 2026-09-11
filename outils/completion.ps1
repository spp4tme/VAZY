# ============================================================================
#  vazy - auto-complétion pour PowerShell
# ============================================================================
#  À charger dans votre profil :
#
#      . "C:\chemin\vers\vazy\outils\completion.ps1"
#
#  Ensuite, la touche Tab propose les commandes, vos VM, vos modèles, vos labos
#  et vos segments réseau, selon l'endroit de la ligne où vous êtes.
#
#  Ce fichier lit le catalogue de vazy DIRECTEMENT, il n'appelle jamais vazy :
#  une complétion doit répondre instantanément, et surtout n'avoir aucun effet
#  de bord — lancer vazy déclencherait le nettoyage des VM éphémères à chaque
#  appui sur Tab.
#
#  Il ne modifie le comportement d'aucune commande : sans lui, tout fonctionne
#  exactement pareil, en tapant les noms en entier.
# ============================================================================

Set-StrictMode -Version Latest

function Get-VazyCatalogue {
    <# Le catalogue, ou $null s'il est absent ou illisible. Ne lève jamais. #>
    try {
        $dossier = if ($env:VAZY_HOME) { $env:VAZY_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'vazy' }
        $chemin = Join-Path $dossier 'catalogue.json'
        if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { return $null }
        return (Get-Content -LiteralPath $chemin -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Get-VazyNoms {
    <# Noms d'une section du catalogue : vms, modeles ou reseaux. #>
    param([string]$Section)
    $catalogue = Get-VazyCatalogue
    if ($null -eq $catalogue) { return @() }
    try {
        if (-not $catalogue.PSObject.Properties[$Section]) { return @() }
        $bloc = $catalogue.$Section
        if ($null -eq $bloc) { return @() }
        return @($bloc.PSObject.Properties | ForEach-Object { $_.Name })
    } catch { return @() }
}

function Get-VazyVmsHorsReserve {
    <# Les VM de travail. Une VM en réserve ne se démarre pas par son nom. #>
    $catalogue = Get-VazyCatalogue
    if ($null -eq $catalogue) { return @() }
    try {
        if (-not $catalogue.PSObject.Properties['vms']) { return @() }
        return @($catalogue.vms.PSObject.Properties | Where-Object {
            -not ($_.Value.PSObject.Properties['pool'] -and $_.Value.pool)
        } | ForEach-Object { $_.Name })
    } catch { return @() }
}

function Get-VazyLabos {
    try {
        $dossier = if ($env:VAZY_HOME) { $env:VAZY_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'vazy' }
        $labos = Join-Path $dossier 'labos'
        if (-not (Test-Path -LiteralPath $labos)) { return @() }
        return @(Get-ChildItem -LiteralPath $labos -Filter *.json -File -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.BaseName })
    } catch { return @() }
}

$script:VazyCommandes = @(
    'list', 'start', 'stop', 'rm', 'reset', 'snap', 'snaps', 'back', 'unsnap',
    'gc', 'lab', 'net', 'pool', 'pop', 'top', 'report', 'disk', 'doctor', 'freeze', 'vnc',
    'template', 'config', 'help', 'version'
)

# Ce que chaque commande attend comme premier argument.
$script:VazyAttendVm     = @('start', 'stop', 'rm', 'reset', 'snap', 'snaps', 'back', 'unsnap', 'freeze', 'vnc')
$script:VazyAttendModele = @('pop')

$script:VazySousCommandes = @{
    'lab'      = @('up', 'new', 'status', 'down', 'export')
    'net'      = @('list', 'ls', 'add', 'create', 'rm')
    'pool'     = @('create', 'status', 'refill', 'destroy')
    'template' = @('add', 'list', 'rm', 'mark', 'alias', 'creds')
    'config'   = @('dossierVms', 'dossierLabos', 'outilHyperviseur', 'espaceDisqueMinGo',
                   'delaiOutilsSec', 'delaiPoolSec', 'poolReposSec', 'seuilDivergencePct', 'vncPortMin', 'vncPortMax', 'hyperviseur')
}

$script:VazyOptions = @(
    '--name', '--ram', '--cpu', '--reseau', '--mode', '--reseau-nomme', '--set', '--nogui',
    '--nostart', '--tmp', '--hostname', '--ip', '--masque', '--passerelle', '--dns', '--cle-ssh',
    '--vnc', '--snapshot', '--size', '--vm', '--save', '--labo', '--prefixe', '--vms', '--delai',
    '--adresse', '--dhcp', '--yes', '--hard', '--stop-only', '--dry-run', '--requis', '--tout',
    '--guestinfo', '--classique', '--out', '--help', '--version'
)

# Découpe la ligne en mots, sans le mot en cours de frappe.
function Get-VazyMots {
    param([string]$Ligne, [int]$Position)
    $avant = $Ligne.Substring(0, [Math]::Min($Position, $Ligne.Length))
    $mots = @($avant -split '\s+' | Where-Object { $_ })
    # Le dernier mot est en cours de frappe s'il n'est pas suivi d'un espace.
    if ($avant -notmatch '\s$' -and $mots.Count -gt 0) { $mots = $mots[0..($mots.Count - 2)] }
    if ($mots.Count -gt 0 -and $mots[0] -match '(?i)^vazy(\.cmd)?$') { $mots = @($mots | Select-Object -Skip 1) }
    return $mots
}

function Get-VazyPropositions {
    param([string[]]$Mots, [string]$Amorce)

    # Une option en cours de frappe : on propose des options.
    if ($Amorce.StartsWith('-')) { return $script:VazyOptions }

    if ($Mots.Count -eq 0) {
        # Premier mot : les commandes, et les modèles (« vazy ubuntu » crée une VM).
        return @($script:VazyCommandes + (Get-VazyNoms -Section 'modeles'))
    }

    $commande = $Mots[0].ToLower()

    if ($Mots.Count -eq 1) {
        if ($script:VazySousCommandes.ContainsKey($commande)) { return $script:VazySousCommandes[$commande] }
        if ($script:VazyAttendVm -contains $commande)         { return (Get-VazyVmsHorsReserve) }
        if ($script:VazyAttendModele -contains $commande)     { return (Get-VazyNoms -Section 'modeles') }
        return @()
    }

    $sous = $Mots[1].ToLower()
    if ($Mots.Count -eq 2) {
        switch ($commande) {
            'lab' {
                if ($sous -in 'up', 'status', 'down') { return (Get-VazyLabos) }
                return @()
            }
            'net'  { if ($sous -eq 'rm') { return (Get-VazyNoms -Section 'reseaux') }; return @() }
            'pool' { if ($sous -in 'create', 'refill', 'destroy', 'status') { return (Get-VazyNoms -Section 'modeles') }; return @() }
            'template' {
                if ($sous -in 'rm', 'mark', 'alias', 'creds') { return (Get-VazyNoms -Section 'modeles') }
                return @()
            }
            'snap'   { return @() }   # le libellé est libre
            'unsnap' { return @() }
            'back'   { return @() }
        }
    }
    return @()
}

Register-ArgumentCompleter -Native -CommandName @('vazy', 'vazy.cmd') -ScriptBlock {
    param($amorce, $commandeAst, $position)
    try {
        $ligne = $commandeAst.ToString()
        $mots = Get-VazyMots -Ligne $ligne -Position $position
        $texte = [string]$amorce
        @(Get-VazyPropositions -Mots $mots -Amorce $texte |
            Where-Object { $_ -and $_.ToString().StartsWith($texte, [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object -Unique |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            })
    } catch {
        # Une complétion ne doit jamais faire de bruit dans la console.
        @()
    }
}
