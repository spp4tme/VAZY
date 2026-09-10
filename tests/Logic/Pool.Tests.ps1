# Pool de VM chaudes.
#
# Ce qui doit etre garanti : l'ordre des operations a la mise en reserve, la
# sortie ATOMIQUE d'une VM (deux commandes ne servent jamais la meme), le refus
# de servir une VM perimee, et le fait qu'une VM de reserve n'est ni ramassee
# par le nettoyage des ephemeres ni melangee aux VM de travail.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

# Un modele marque guestinfo : c'est la condition d'une reserve pleinement
# utilisable, puisque l'identite est deposee sans entrer dans la VM.
function New-ModeleGuestinfoTest {
    param([string]$Alias = 'ubuntu')
    $chemin = New-ModeleTest -Alias $Alias
    Set-MarqueModele -Alias $Alias -Guestinfo $true
    return $chemin
}

Describe 'Pool - mise en reserve' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfoTest -Alias 'ubuntu' | Out-Null
    }

    It 'cree, demarre puis fige chaque VM, dans cet ordre' {
        New-Pool -Modele 'ubuntu' -Taille 3 | Out-Null

        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be 3
        @(Get-AppelsPilote -Fonction 'Start-Machine').Count           | Should Be 3
        @(Get-AppelsPilote -Fonction 'Suspend-Machine').Count         | Should Be 3

        # L'ordre compte : on ne fige pas une machine qu'on n'a pas demarree.
        $rangs = @{}
        foreach ($f in @('New-MachineDepuisModele', 'Start-Machine', 'Suspend-Machine')) {
            $rangs[$f] = @(Get-AppelsPilote -Fonction $f)[0].Rang
        }
        ($rangs['New-MachineDepuisModele'] -lt $rangs['Start-Machine']) | Should Be $true
        ($rangs['Start-Machine'] -lt $rangs['Suspend-Machine'])         | Should Be $true
    }

    It 'depose « mode: pool » avant de demarrer' {
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null

        $depot = @(Get-AppelsPilote -Fonction 'Set-MachineVariableInvite')[0]
        $depot.Parametres.Nom | Should Be 'vazy_config'
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($depot.Parametres.Valeur))
        $json | Should Match '"mode"\s*:\s*"pool"'
    }

    It 'laisse les VM figees et pretes' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $statut = @(Get-StatutPool)
        $statut.Count | Should Be 2
        @($statut | Where-Object { $_.Etat -eq 'prête' }).Count | Should Be 2
    }

    It 'refuse de creer une seconde reserve pour le meme modele' {
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null
        { New-Pool -Modele 'ubuntu' -Taille 1 } | Should Throw
    }

    It 'avertit quand le modele n''est pas marque guestinfo' {
        Reset-EtatVazy
        New-ModeleTest -Alias 'brut' | Out-Null      # sans marque guestinfo
        $script:Config['delaiPoolSec'] = 1
        $script:Config['poolReposSec'] = 0

        New-Pool -Modele 'brut' -Taille 1 | Out-Null

        (Test-MessageTest 'guestinfo' 'attention') | Should Be $true
    }

    It 'complete une reserve entamee sans toucher aux VM presentes' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $avant = @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count

        Invoke-PoolRefill -Modele 'ubuntu' -Taille 4 | Out-Null

        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be ($avant + 2)
        @(Get-StatutPool).Count | Should Be 4
    }

    It 'ne cree rien si la reserve est deja complete' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $avant = @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count

        Invoke-PoolRefill -Modele 'ubuntu' -Taille 2 | Out-Null

        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be $avant
    }
}

Describe 'Pool - sortir une VM' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfoTest -Alias 'ubuntu' | Out-Null
    }

    It 'reprend la VM et lui donne son identite' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $r = Invoke-Pop -Modele 'ubuntu' -Nom 'poste1' -NomHote 'poste1'

        $r.Nom | Should Be 'poste1'
        (Test-AppelPilote 'Resume-Machine') | Should Be $true

        # La nouvelle identite est deposee AVANT la reprise.
        $depots = @(Get-AppelsPilote -Fonction 'Set-MachineVariableInvite')
        $dernier = $depots[-1]
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dernier.Parametres.Valeur))
        $json | Should Match 'poste1'
        ($dernier.Rang -lt @(Get-AppelsPilote -Fonction 'Resume-Machine')[0].Rang) | Should Be $true
    }

    It 'sort la VM de la reserve et la rend visible comme VM ordinaire' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        Invoke-Pop -Modele 'ubuntu' -Nom 'poste1' | Out-Null

        @(Get-StatutPool).Count | Should Be 1
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'poste1' }).Count | Should Be 1
    }

    It 'ne sert jamais deux fois la meme VM' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $a = Invoke-Pop -Modele 'ubuntu' -Nom 'poste1'
        $b = Invoke-Pop -Modele 'ubuntu' -Nom 'poste2'

        $a.Ancien | Should Not Be $b.Ancien
        $b.Restantes | Should Be 0
    }

    It 'refuse quand la reserve est vide, en disant quoi faire' {
        $message = ''
        try { Invoke-Pop -Modele 'ubuntu' -Nom 'poste1' } catch { $message = $_.Exception.Message + ' ' + [string]$_.Exception.Data['Conseil'] }
        $message | Should Match 'pool create'
    }

    It 'refuse quand toutes les VM de la reserve sont perimees' {
        $chemin = (Get-ModeleDuCatalogue -Alias 'ubuntu')['chemin']
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null

        # Le modele change : les VM figees ne correspondent plus a ses disques.
        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{
            'base.vmdk' = [ordered]@{ taille = [long]999999; modifie = '2026-01-01T00:00:00.0000000Z' }
        }

        { Invoke-Pop -Modele 'ubuntu' -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'Resume-Machine') | Should Be $false
    }

    It 'signale les VM perimees dans le statut' {
        $chemin = (Get-ModeleDuCatalogue -Alias 'ubuntu')['chemin']
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null
        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{}

        @(Get-StatutPool | Where-Object { $_.Etat -eq 'périmée' }).Count | Should Be 1
    }

    It 'refuse un nom deja pris' {
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null

        { Invoke-Pop -Modele 'ubuntu' -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'Resume-Machine') | Should Be $false
    }
}

Describe 'Pool - une VM de reserve n''est pas une VM comme les autres' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfoTest -Alias 'ubuntu' | Out-Null
    }

    It 'n''apparait pas dans la liste des VM' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'travail' -SansDemarrage | Out-Null

        $liste = @(Get-ListeVms)
        $liste.Count | Should Be 1
        $liste[0].Nom | Should Be 'travail'

        # Mais elle reste visible quand on la demande explicitement.
        @(Get-ListeVms -AvecPool).Count | Should Be 3
    }

    It 'n''est JAMAIS ramassee par le nettoyage des ephemeres' {
        New-Pool -Modele 'ubuntu' -Taille 2 | Out-Null
        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 0
        (Test-AppelPilote 'Remove-Machine') | Should Be $false
        @(Get-StatutPool).Count | Should Be 2
    }

    It 'refuse d''etre supprimee par la voie des ephemeres' {
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null
        $nom = @(Get-StatutPool)[0].Nom

        { Remove-VmEphemere -Nom $nom } | Should Throw
    }

    It 'refuse la suppression par la voie du pool pour une VM ordinaire' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'travail' -SansDemarrage | Out-Null
        { Remove-VmDuPool -Nom 'travail' } | Should Throw
    }

    It 'disparait entierement quand la reserve est detruite' {
        New-Pool -Modele 'ubuntu' -Taille 3 | Out-Null
        $r = Remove-Pool -Modele 'ubuntu'

        $r.Supprimees | Should Be 3
        @(Get-StatutPool).Count | Should Be 0
        @(Get-AppelsPilote -Fonction 'Remove-Machine').Count | Should Be 3
    }
}
