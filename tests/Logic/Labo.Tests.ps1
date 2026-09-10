# Labos : ordre de demarrage, dependances, idempotence, et retour arriere
# quand une creation echoue en cours de route.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

# Une machine de labo telle que l'interface la fournit a la logique.
function New-MachineLaboTest {
    param(
        [Parameter(Mandatory = $true)][string]$Nom,
        [string]$Modele = 'ubuntu',
        [double]$RamGo = 2,
        [int]$Cpu = 2,
        [string[]]$Modes = @('nat'),
        [string[]]$Apres = @(),
        [switch]$SansDemarrage,
        $ConfigInvite = $null
    )
    return [pscustomobject]@{
        Nom           = $Nom
        Modele        = $Modele
        RamGo         = $RamGo
        Cpu           = $Cpu
        Modes         = $Modes
        Brut          = @()
        NomHote       = ''
        Vnc           = $false
        SansInterface = $false
        SansDemarrage = [bool]$SansDemarrage
        Apres         = $Apres
        ConfigInvite  = $ConfigInvite
    }
}

function New-LaboTest {
    param([string]$Nom = 'tp', [object[]]$Machines = @(), [int]$Delai = 0, [object[]]$Requis = @())
    return [pscustomobject]@{
        Nom      = $Nom
        Fichier  = (Join-Path (Get-RacineTest) ($Nom + '.json'))
        Delai    = $Delai
        Machines = $Machines
        Requis   = $Requis
    }
}

# Noms des VM demarrees, dans l'ordre ou le pilote les a recues.
function Get-OrdreDemarrageObserve {
    return @(Get-AppelsPilote -Fonction 'Start-Machine' | ForEach-Object {
        [System.IO.Path]::GetFileNameWithoutExtension($_.Parametres.Machine)
    })
}

Describe 'Labo - ordre de demarrage' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'demarre les machines dans l''ordre des dependances, pas celui du fichier' {
        # « poste » est declare en premier mais depend de « srv ».
        $labo = New-LaboTest -Nom 'tp' -Machines @(
            (New-MachineLaboTest -Nom 'poste' -Apres @('srv')),
            (New-MachineLaboTest -Nom 'srv')
        )
        $ordre = @(Get-OrdreLabo -Labo $labo | ForEach-Object { $_.Nom })
        $ordre[0] | Should Be 'srv'
        $ordre[1] | Should Be 'poste'
    }

    It 'garde l''ordre du fichier entre machines independantes' {
        $labo = New-LaboTest -Nom 'tp' -Machines @(
            (New-MachineLaboTest -Nom 'aaa'),
            (New-MachineLaboTest -Nom 'bbb')
        )
        $ordre = @(Get-OrdreLabo -Labo $labo | ForEach-Object { $_.Nom })
        $ordre[0] | Should Be 'aaa'
        $ordre[1] | Should Be 'bbb'
    }

    It 'respecte une chaine de trois dependances' {
        $labo = New-LaboTest -Nom 'tp' -Machines @(
            (New-MachineLaboTest -Nom 'client' -Apres @('proxy')),
            (New-MachineLaboTest -Nom 'proxy'  -Apres @('srv')),
            (New-MachineLaboTest -Nom 'srv')
        )
        $ordre = @(Get-OrdreLabo -Labo $labo | ForEach-Object { $_.Nom })
        ($ordre -join '>') | Should Be 'srv>proxy>client'
    }

    It 'demarre reellement dans cet ordre lors du montage' {
        $labo = New-LaboTest -Nom 'tp' -Machines @(
            (New-MachineLaboTest -Nom 'poste' -Apres @('srv')),
            (New-MachineLaboTest -Nom 'srv')
        )
        Invoke-LaboUp -Labo $labo | Out-Null

        $observe = Get-OrdreDemarrageObserve
        $observe.Count | Should Be 2
        $observe[0] | Should Be 'tp-srv'
        $observe[1] | Should Be 'tp-poste'
    }
}

Describe 'Labo - dependances invalides' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'refuse une machine qui depend d''elle-meme' {
        $labo = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'srv' -Apres @('srv')) )
        { Get-OrdreLabo -Labo $labo } | Should Throw
    }

    It 'refuse une dependance vers une machine absente du fichier' {
        $labo = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'poste' -Apres @('fantome')) )
        { Get-OrdreLabo -Labo $labo } | Should Throw
    }

    It 'refuse deux machines qui s''attendent l''une l''autre' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'a' -Apres @('b')),
            (New-MachineLaboTest -Nom 'b' -Apres @('a'))
        )
        { Get-OrdreLabo -Labo $labo } | Should Throw
    }

    It 'refuse un cycle de trois machines' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'a' -Apres @('c')),
            (New-MachineLaboTest -Nom 'b' -Apres @('a')),
            (New-MachineLaboTest -Nom 'c' -Apres @('b'))
        )
        { Get-OrdreLabo -Labo $labo } | Should Throw
    }

    It 'refuse un labo sans aucune machine' {
        $labo = New-LaboTest -Machines @()
        { Test-Labo -Labo $labo } | Should Throw
    }

    It 'ne cree rien quand une dependance est invalide' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste' -Apres @('fantome'))
        )
        { Invoke-LaboUp -Labo $labo } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un modele requis absent, sans rien creer' {
        $labo = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'srv') ) -Requis @(
            [pscustomobject]@{ Modele = 'debian-13'; Os = 'linux'; Version = ''; DisqueMinGo = 0 }
        )
        { Invoke-LaboUp -Labo $labo } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }
}

Describe 'Labo - idempotence' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'ne recree rien au second montage' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste')
        )
        $premier = Invoke-LaboUp -Labo $labo
        $premier.Creees | Should Be 2

        $second = Invoke-LaboUp -Labo $labo
        $second.Creees | Should Be 0
        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be 2
    }

    It 'ne redemarre pas une VM deja en marche' {
        $labo = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'srv') )
        Invoke-LaboUp -Labo $labo | Out-Null

        $second = Invoke-LaboUp -Labo $labo
        $second.Demarrees | Should Be 0
        @(Get-AppelsPilote -Fonction 'Start-Machine').Count | Should Be 1
    }

    It 'redemarre uniquement la VM qui s''est eteinte' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste')
        )
        Invoke-LaboUp -Labo $labo | Out-Null
        $cheminSrv = $script:Catalogue['vms']['tp-srv']['chemin']
        Set-MachineEnMarcheFake -Chemin $cheminSrv -EnMarche $false

        $second = Invoke-LaboUp -Labo $labo
        $second.Creees    | Should Be 0
        $second.Demarrees | Should Be 1

        $demarrages = Get-OrdreDemarrageObserve
        $demarrages[-1] | Should Be 'tp-srv'
    }

    It 'cree la machine ajoutee au fichier sans toucher aux autres' {
        $labo1 = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'srv') )
        Invoke-LaboUp -Labo $labo1 | Out-Null

        $labo2 = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste')
        )
        $second = Invoke-LaboUp -Labo $labo2
        $second.Creees | Should Be 1

        $creations = @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele')
        $creations.Count | Should Be 2
        $creations[-1].Parametres.Nom | Should Be 'tp-poste'
    }
}

Describe 'Labo - retour arriere quand une creation echoue' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'detruit les VM deja creees si la creation d''une suivante echoue' {
        $labo = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste')
        )
        # La premiere creation passe, la seconde echoue.
        Set-EchecPilote -Fonction 'New-MachineDepuisModele' -Saut 1 -Message 'plus de place'

        { Invoke-LaboUp -Labo $labo } | Should Throw

        # La VM deja creee ne doit pas survivre a un montage rate.
        $restantes = @(Get-ListeVms | Where-Object { $_.Nom -like 'tp-*' })
        $restantes.Count | Should Be 0
    }

    It 'ne touche pas aux VM qui existaient avant le montage rate' {
        # Premier montage complet.
        $labo1 = New-LaboTest -Machines @( (New-MachineLaboTest -Nom 'srv') )
        Invoke-LaboUp -Labo $labo1 | Out-Null

        # Second montage qui ajoute « poste » et echoue dessus.
        $labo2 = New-LaboTest -Machines @(
            (New-MachineLaboTest -Nom 'srv'),
            (New-MachineLaboTest -Nom 'poste')
        )
        Set-EchecPilote -Fonction 'New-MachineDepuisModele' -Message 'plus de place'
        { Invoke-LaboUp -Labo $labo2 } | Should Throw

        # « tp-srv » preexistait : le retour arriere ne doit pas l'emporter.
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'tp-srv' }).Count | Should Be 1
    }
}
