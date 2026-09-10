# ============================================================================
#  vazy - harnais de test
# ============================================================================
#  Fournit un environnement isolé : un %VAZY_HOME% jetable, le faux pilote à la
#  place du vrai, et un afficheur qui range les messages dans une liste au lieu
#  de les écrire à l'écran.
#
#  À charger par point-source AU PREMIER NIVEAU d'un fichier de test, avant
#  lib\logique.ps1 :
#
#      . "$PSScriptRoot\..\Aide\Environnement.ps1"
#      Initialize-VazyTest
#      . (Get-CheminLogique)
#
#  Le point-source au premier niveau est indispensable : chargée depuis
#  l'intérieur d'une fonction, la logique disparaîtrait avec la portée de
#  celle-ci. C'est aussi ce qui permet à Reset-EtatVazy d'atteindre les
#  variables $script: de la logique — elles vivent dans la même portée.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MessagesTest = New-Object System.Collections.Generic.List[object]
$script:RacineTest   = $null

function Get-RacineDepot {
    <# Racine du dépôt, déduite de l'emplacement de ce fichier (tests\Aide). #>
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-CheminLogique {
    return (Join-Path (Get-RacineDepot) 'lib\logique.ps1')
}

function Get-CheminPiloteFake {
    return (Join-Path (Get-RacineDepot) 'tests\Fakes\pilote-fake.ps1')
}

function Get-RacineTest {
    <# Le dossier jetable de l'exécution en cours. #>
    return $script:RacineTest
}

function Initialize-VazyTest {
    <#
        Crée le bac à sable et branche les variables d'environnement. À appeler
        UNE fois par fichier de test, avant de charger la logique : les chemins
        de config et de catalogue sont figés au chargement.
    #>
    $script:RacineTest = Join-Path ([System.IO.Path]::GetTempPath()) ('vazy-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:RacineTest -Force | Out-Null
    $env:VAZY_HOME   = Join-Path $script:RacineTest 'home'
    $env:VAZY_PILOTE = Get-CheminPiloteFake
    New-Item -ItemType Directory -Path $env:VAZY_HOME -Force | Out-Null
    return $script:RacineTest
}

function Remove-VazyTest {
    <# Efface le bac à sable et débranche les variables. #>
    $env:VAZY_HOME   = $null
    $env:VAZY_PILOTE = $null
    if ($script:RacineTest -and (Test-Path -LiteralPath $script:RacineTest)) {
        Remove-Item -LiteralPath $script:RacineTest -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:RacineTest = $null
}

function Reset-EtatVazy {
    <#
        Remet la logique et le faux pilote à neuf entre deux tests : catalogue
        vide, configuration par défaut, journal des appels vidé.

        Les affectations $script: ci-dessous visent les variables de
        logique.ps1 : le point-source au premier niveau les a placées dans
        cette même portée (voir l'en-tête).
    #>
    foreach ($f in @('config.json', 'catalogue.json', 'journal.log')) {
        $c = Join-Path $env:VAZY_HOME $f
        if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Force }
    }
    $dossierVms = Join-Path $script:RacineTest 'vms'
    if (Test-Path -LiteralPath $dossierVms) { Remove-Item -LiteralPath $dossierVms -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $dossierVms -Force | Out-Null

    Reset-PiloteFake -DossierTravail $script:RacineTest

    $script:Pilote           = $null    # forcera Connect-Pilote à réinterroger le pilote
    $script:InfosHote        = $null
    $script:RappelHyperVFait = $false
    $script:Simulation       = $false
    $script:Config           = Read-Config
    $script:Catalogue        = Read-Catalogue
    $script:Config['dossierVms'] = $dossierVms

    $script:MessagesTest.Clear()
    Set-Afficheur {
        param($Type, $Message)
        $script:MessagesTest.Add([pscustomobject]@{ Type = $Type; Message = $Message })
    }
    Set-ModeSimulation $false
}

function Get-MessagesTest {
    <# Les messages émis depuis le dernier Reset-EtatVazy, filtrables par type. #>
    param([string]$Type = '')
    if ($Type) { return @($script:MessagesTest | Where-Object { $_.Type -eq $Type }) }
    return @($script:MessagesTest)
}

function Test-MessageTest {
    <# Un message contenant ce fragment a-t-il été émis ? #>
    param([Parameter(Mandatory = $true)][string]$Fragment, [string]$Type = '')
    return (@(Get-MessagesTest -Type $Type | Where-Object { $_.Message -like ('*' + $Fragment + '*') }).Count -gt 0)
}

# ----------------------------------------------------------------------------
#  Raccourcis de mise en place
# ----------------------------------------------------------------------------

function New-ModeleTest {
    <#
        Déclare un modèle utilisable : fichier témoin, instantané d'ancrage,
        puis enregistrement par le vrai Add-Modele (le chemin de code réel est
        ainsi exercé, pas contourné).
    #>
    param(
        [string]$Alias = 'ubuntu',
        [string]$Instantane = 'base',
        [hashtable]$Empreinte = $null,
        [double]$DisqueGo = 40
    )
    $chemin = Join-Path $script:RacineTest ('modeles\' + $Alias + '\' + $Alias + '.vmx')
    Register-ModeleFake -Chemin $chemin -Instantane $Instantane -Empreinte $Empreinte -DisqueGo $DisqueGo | Out-Null
    Add-Modele -Chemin $chemin -Alias $Alias -Instantane $Instantane | Out-Null
    return $chemin
}

function New-FichierLaboTest {
    <# Écrit un fichier de labo JSON dans le bac à sable et renvoie son chemin. #>
    param([Parameter(Mandatory = $true)][string]$Nom, [Parameter(Mandatory = $true)][string]$Json)
    $dossier = Join-Path $script:RacineTest 'labos'
    if (-not (Test-Path -LiteralPath $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
    $chemin = Join-Path $dossier ($Nom + '.json')
    [System.IO.File]::WriteAllText($chemin, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $chemin
}
