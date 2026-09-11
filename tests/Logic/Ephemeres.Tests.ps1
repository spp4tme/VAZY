# Regle de securite majeure : le nettoyage automatique ne touche JAMAIS une VM
# qui n'est pas marquee ephemere, quel que soit son etat.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

function New-VmEphemereTest {
    param([string]$Nom)
    # Une VM n'est marquee ephemere qu'une fois demarree (voir New-VmDepuisModele).
    $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom $Nom -Ephemere
    Set-MachineEnMarcheFake -Chemin $vm.Chemin -EnMarche $false   # elle s'est eteinte
    return $vm
}

Describe 'Nettoyage - ce qui doit etre supprime' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'supprime une VM ephemere trouvee eteinte' {
        $vm = New-VmEphemereTest -Nom 'jetable1'
        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 1
        $supprimees[0] | Should Be 'jetable1'
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'jetable1' }).Count | Should Be 0
    }

    It 'laisse tranquille une VM ephemere encore en marche' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'jetable1' -Ephemere
        # Elle tourne toujours : Start-Machine l'a laissee en marche.
        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 0
        (Test-AppelPilote 'Remove-Machine') | Should Be $false
    }

    It 'ne fait aucun appel au pilote quand aucune VM ephemere n''est au catalogue' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'permanente' -SansDemarrage | Out-Null
        $avant = @(Get-AppelsPilote).Count

        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 0
        @(Get-AppelsPilote).Count | Should Be $avant   # pas meme un Get-MachineEnCours
    }
}

Describe 'Nettoyage - ce qui ne doit JAMAIS etre supprime' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'ne supprime pas une VM ordinaire eteinte' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'permanente' -SansDemarrage
        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 0
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'permanente' }).Count | Should Be 1
        (Test-AppelPilote 'Remove-Machine') | Should Be $false
    }

    It 'refuse explicitement de supprimer une VM non marquee ephemere' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'permanente' -SansDemarrage | Out-Null
        { Remove-VmEphemere -Nom 'permanente' } | Should Throw
        (Test-AppelPilote 'Remove-Machine') | Should Be $false
    }

    It 'ne supprime pas les VM ordinaires melangees aux ephemeres' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'permanente' -SansDemarrage | Out-Null
        New-VmEphemereTest -Nom 'jetable1' | Out-Null

        $supprimees = @(Invoke-Nettoyage -Forcer)

        $supprimees.Count | Should Be 1
        $supprimees[0] | Should Be 'jetable1'
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'permanente' }).Count | Should Be 1
    }

    It 'ne supprime rien au-dela du seuil tant que personne ne confirme' {
        1..4 | ForEach-Object { New-VmEphemereTest -Nom ('jetable' + $_) | Out-Null }

        # Pas de -Forcer, et le confirmateur repond non.
        # Le confirmateur note ce qu'on lui soumet : les quatre VM doivent lui
        # avoir ete presentees, pas seulement la question posee.
        $script:Soumises = @()
        $supprimees = @(Invoke-Nettoyage -Confirmer { param($noms) $script:Soumises = @($noms); return $false })
        $script:Soumises.Count | Should Be 4

        $supprimees.Count | Should Be 0
        @(Get-ListeVms).Count | Should Be 4
        # Parentheses obligatoires : le pipe se lie plus fort que -or.
        $averti = ((Test-MessageTest 'beaucoup') -or (Test-MessageTest 'rien n''a'))
        $averti | Should Be $true
    }

    It 'supprime au-dela du seuil si la confirmation est donnee' {
        1..4 | ForEach-Object { New-VmEphemereTest -Nom ('jetable' + $_) | Out-Null }

        # N'accorde que si on lui soumet exactement les quatre VM attendues.
        $supprimees = @(Invoke-Nettoyage -Confirmer { param($noms) return (@($noms).Count -eq 4) })

        $supprimees.Count | Should Be 4
        @(Get-ListeVms).Count | Should Be 0
    }
}
