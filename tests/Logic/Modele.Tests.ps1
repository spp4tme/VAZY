# Protection du modele et empreinte des disques de base.
# Un clone lie lit en permanence dans les disques du modele : si le modele
# bouge, le clone casse. Ces deux garde-fous sont ce qui empeche de perdre
# toutes les VM d'un coup.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

Describe 'Protection du modele' {

    BeforeEach { Reset-EtatVazy }

    It 'pose la marque de protection des l''enregistrement du modele' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        (Test-AppelPilote 'Protect-MachineModele') | Should Be $true
        (Test-MachineModele -Machine $chemin) | Should Be $true
    }

    It 'fait refuser au pilote lui-meme la suppression d''une machine marquee modele' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        # Appel direct de la couche 3 : le refus ne depend pas du catalogue.
        { Remove-Machine -Machine $chemin } | Should Throw
    }

    It 'fait refuser au pilote lui-meme le demarrage d''une machine marquee modele' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        { Start-Machine -Machine $chemin } | Should Throw
    }

    It 'refuse au niveau de la logique de demarrer un modele par son alias' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { Start-VmParNom -Nom 'ubuntu' } | Should Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $false
    }

    It 'refuse au niveau de la logique de supprimer un modele par son alias' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { Remove-VmParNom -Nom 'ubuntu' } | Should Throw
        (Test-AppelPilote 'Remove-Machine') | Should Be $false
    }

    It 'refuse d''enregistrer deux fois la meme VM comme modele' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        { Add-Modele -Chemin $chemin -Alias 'ubuntu2' -Instantane 'base' } | Should Throw
    }

    It 'refuse un modele sans aucun instantane' {
        $chemin = Join-Path (Get-RacineTest) 'modeles\vide\vide.vmx'
        Register-ModeleFake -Chemin $chemin -Instantane 'base' | Out-Null
        $global:VazyFake.Modeles[$chemin].Instantanes = @()

        { Add-Modele -Chemin $chemin -Alias 'vide' } | Should Throw
    }
}

Describe 'Empreinte du modele' {

    BeforeEach { Reset-EtatVazy }

    It 'laisse demarrer tant que les disques de base n''ont pas bouge' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage
        Start-VmParNom -Nom 'poste1' | Out-Null

        (Test-AppelPilote 'Start-Machine') | Should Be $true
    }

    It 'refuse de demarrer un clone dont le modele a change de taille' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null

        # Le disque de base a ete consolide ou compacte : taille differente.
        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{
            'base.vmdk' = [ordered]@{ taille = [long]999999; modifie = '2026-01-01T00:00:00.0000000Z' }
        }

        { Start-VmParNom -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $false
    }

    It 'refuse de demarrer un clone dont un disque de base a disparu' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{}

        { Start-VmParNom -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $false
    }

    It 'avertit mais laisse demarrer si seule la date a change' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null

        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{
            'base.vmdk' = [ordered]@{ taille = [long]1024; modifie = '2026-06-30T12:00:00.0000000Z' }
        }

        { Start-VmParNom -Nom 'poste1' } | Should Not Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $true
        (Test-MessageTest 'sans changement de taille' 'attention') | Should Be $true
    }

    It 'refuse de demarrer si le fichier du modele a disparu' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        Remove-Item -LiteralPath $chemin -Force

        { Start-VmParNom -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $false
    }

    It 'ne verifie plus l''empreinte d''une VM rendue autonome' {
        $chemin = New-ModeleTest -Alias 'ubuntu'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        Convert-VmEnAutonome -Nom 'poste1' | Out-Null

        # Le modele peut maintenant changer du tout au tout : plus de lien.
        $global:VazyFake.Modeles[$chemin].Empreinte = [ordered]@{}

        { Start-VmParNom -Nom 'poste1' } | Should Not Throw
        (Test-AppelPilote 'Start-Machine') | Should Be $true
    }
}
