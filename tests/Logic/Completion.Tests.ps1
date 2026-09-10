# Auto-completion : on teste la LOGIQUE de proposition, pas le branchement
# PowerShell lui-meme. Le fichier de completion est charge tel quel : il ne
# depend que du catalogue sur le disque, jamais de l'outil.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)
. (Join-Path (Get-RacineDepot) 'outils\completion.ps1')

Describe 'Completion - decoupage de la ligne' {

    It 'ignore le nom du programme' {
        $mots = @(Get-VazyMots -Ligne 'vazy start pos' -Position 15)
        $mots.Count | Should Be 1
        $mots[0] | Should Be 'start'
    }

    It 'ignore aussi vazy.cmd' {
        $mots = @(Get-VazyMots -Ligne 'vazy.cmd lab up ' -Position 16)
        ($mots -join ' ') | Should Be 'lab up'
    }

    It 'ecarte le mot en cours de frappe' {
        # « pos » n'est pas fini : il ne compte pas comme un mot place.
        $mots = @(Get-VazyMots -Ligne 'vazy start pos' -Position 14)
        ($mots -join ' ') | Should Be 'start'
    }

    It 'garde le dernier mot quand il est suivi d''un espace' {
        $mots = @(Get-VazyMots -Ligne 'vazy start ' -Position 11)
        ($mots -join ' ') | Should Be 'start'
    }
}

Describe 'Completion - ce qui est propose' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
    }

    It 'propose les commandes et les modeles en premier mot' {
        $p = @(Get-VazyPropositions -Mots @() -Amorce '')
        ($p -contains 'start')  | Should Be $true
        ($p -contains 'pool')   | Should Be $true
        ($p -contains 'ubuntu') | Should Be $true
    }

    It 'propose les VM apres start' {
        $p = @(Get-VazyPropositions -Mots @('start') -Amorce '')
        ($p -contains 'poste1') | Should Be $true
        ($p -contains 'ubuntu') | Should Be $false   # un modele n'est pas une VM
    }

    It 'propose les modeles apres pop' {
        $p = @(Get-VazyPropositions -Mots @('pop') -Amorce '')
        ($p -contains 'ubuntu') | Should Be $true
    }

    It 'ne propose pas une VM en reserve' {
        Set-MarqueModele -Alias 'ubuntu' -Guestinfo $true
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null
        $enReserve = @(Get-StatutPool)[0].Nom

        $p = @(Get-VazyPropositions -Mots @('start') -Amorce '')
        ($p -contains 'poste1')    | Should Be $true
        ($p -contains $enReserve)  | Should Be $false
    }

    It 'propose les sous-commandes' {
        $p = @(Get-VazyPropositions -Mots @('lab') -Amorce '')
        ($p -contains 'up') | Should Be $true
        $p = @(Get-VazyPropositions -Mots @('pool') -Amorce '')
        ($p -contains 'create') | Should Be $true
    }

    It 'propose les modeles apres pool create' {
        $p = @(Get-VazyPropositions -Mots @('pool', 'create') -Amorce '')
        ($p -contains 'ubuntu') | Should Be $true
    }

    It 'propose les segments apres net rm' {
        New-ReseauLabo -Nom 'labo-dmz' | Out-Null
        $p = @(Get-VazyPropositions -Mots @('net', 'rm') -Amorce '')
        ($p -contains 'labo-dmz') | Should Be $true
    }

    It 'propose des options quand on tape un tiret' {
        $p = @(Get-VazyPropositions -Mots @('ubuntu') -Amorce '--')
        ($p -contains '--name') | Should Be $true
        ($p -contains '--ip')   | Should Be $true
    }

    It 'ne propose rien apres un libelle libre' {
        @(Get-VazyPropositions -Mots @('snap', 'poste1') -Amorce '').Count | Should Be 0
    }
}

Describe 'Completion - robustesse' {

    It 'ne leve jamais, meme sans catalogue' {
        $garde = $env:VAZY_HOME
        try {
            $env:VAZY_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ('vazy-neant-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
            { Get-VazyPropositions -Mots @('start') -Amorce '' } | Should Not Throw
            @(Get-VazyNoms -Section 'modeles').Count | Should Be 0
            @(Get-VazyLabos).Count | Should Be 0
        } finally { $env:VAZY_HOME = $garde }
    }

    It 'ne leve pas sur un catalogue illisible' {
        Reset-EtatVazy
        [IO.File]::WriteAllText((Join-Path $env:VAZY_HOME 'catalogue.json'), 'ceci n''est pas du JSON')
        { Get-VazyPropositions -Mots @() -Amorce '' } | Should Not Throw
    }
}
