# Cout disque reel des clones (vazy disk).
#
# Ce qui doit etre juste : la divergence d'un clone par rapport a son modele,
# le seuil au-dela duquel il merite d'etre revu, le cas d'une VM autonome (qui
# n'a plus de modele), et le bilan -- disques de base comptes UNE fois par
# modele, puisqu'ils sont partages.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

# Un modele dont les disques de base font 10 Go, pour des pourcentages lisibles.
function New-ModeleDixGo {
    param([string]$Alias = 'ubuntu')
    $empreinte = [ordered]@{ 'base.vmdk' = [ordered]@{ taille = [long](10GB); modifie = '2026-01-01T00:00:00.0000000Z' } }
    New-ModeleTest -Alias $Alias -Empreinte $empreinte | Out-Null
}

function New-CloneOccupant {
    param([string]$Nom, [double]$Go, [string]$Modele = 'ubuntu')
    $vm = New-VmDepuisModele -Modele $Modele -Nom $Nom -SansDemarrage
    Set-OccupationFake -Chemin $vm.Chemin -Go $Go
    return $vm
}

Describe 'Cout disque - divergence' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleDixGo -Alias 'ubuntu'
    }

    It 'mesure la taille des disques de base du modele' {
        (Get-TailleBaseModeleGo -Alias 'ubuntu') | Should Be 10
    }

    It 'calcule la divergence d''un clone en pourcentage du modele' {
        New-CloneOccupant -Nom 'poste1' -Go 1 | Out-Null
        $c = @(Get-CoutDisque -Nom 'poste1')[0]
        $c.DivergencePct | Should Be 10
        $c.Divergent | Should Be $false
    }

    It 'signale un clone qui a depasse le seuil' {
        New-CloneOccupant -Nom 'gros' -Go 6 | Out-Null
        $c = @(Get-CoutDisque -Nom 'gros')[0]
        $c.DivergencePct | Should Be 60
        $c.Divergent | Should Be $true
    }

    It 'respecte le seuil configure' {
        New-CloneOccupant -Nom 'moyen' -Go 3 | Out-Null
        $script:Config['seuilDivergencePct'] = 25
        (@(Get-CoutDisque -Nom 'moyen')[0]).Divergent | Should Be $true
    }

    It 'ne parle pas de divergence pour une VM autonome' {
        New-CloneOccupant -Nom 'figee' -Go 9 | Out-Null
        Convert-VmEnAutonome -Nom 'figee' | Out-Null
        $c = @(Get-CoutDisque -Nom 'figee')[0]
        $c.Autonome | Should Be $true
        $c.Divergent | Should Be $false
        $c.DivergencePct | Should Be 0
    }

    It 'ne signale rien quand le modele a disparu' {
        $chemin = (Get-ModeleDuCatalogue -Alias 'ubuntu')['chemin']
        New-CloneOccupant -Nom 'orphelin' -Go 9 | Out-Null
        Remove-Item -LiteralPath $chemin -Force
        # Sans taille de base, un pourcentage serait une invention.
        (@(Get-CoutDisque -Nom 'orphelin')[0]).Divergent | Should Be $false
    }

    It 'refuse une VM inconnue' {
        { Get-CoutDisque -Nom 'jamais-vue' } | Should Throw
    }

    It 'lit l''empreinte du modele une seule fois pour tous ses clones' {
        1..4 | ForEach-Object { New-CloneOccupant -Nom ('poste' + $_) -Go 1 | Out-Null }
        $avant = @(Get-AppelsPilote -Fonction 'Get-MachineEmpreinte').Count
        Get-CoutDisque | Out-Null
        (@(Get-AppelsPilote -Fonction 'Get-MachineEmpreinte').Count - $avant) | Should Be 1
    }
}

Describe 'Cout disque - bilan' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleDixGo -Alias 'ubuntu'
    }

    It 'compte les disques de base une seule fois par modele' {
        1..3 | ForEach-Object { New-CloneOccupant -Nom ('poste' + $_) -Go 1 | Out-Null }
        $b = Get-BilanDisque -Couts @(Get-CoutDisque)

        $b.OccupeGo          | Should Be 3
        $b.PartageGo         | Should Be 10
        # Trois copies completes : 3 x (10 + 1) = 33 Go.
        $b.CopiesCompletesGo | Should Be 33
        # Reellement : 3 Go de differences + 10 Go partages = 13 Go. Soit 20 de gagnes.
        $b.EconomieGo        | Should Be 20
    }

    It 'compte les clones divergents' {
        New-CloneOccupant -Nom 'sage' -Go 1 | Out-Null
        New-CloneOccupant -Nom 'gros' -Go 7 | Out-Null
        (Get-BilanDisque -Couts @(Get-CoutDisque)).Divergents | Should Be 1
    }

    It 'tient debout sur un parc vide' {
        $b = Get-BilanDisque -Couts @()
        $b.OccupeGo   | Should Be 0
        $b.EconomieGo | Should Be 0
    }
}
