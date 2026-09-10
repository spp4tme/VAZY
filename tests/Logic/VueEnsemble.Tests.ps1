# Donnees de la vue temps reel (vazy top).
#
# Le dessin est affaire d'interface et n'est pas teste ici ; ce qui compte,
# c'est que les donnees soient justes, que le catalogue soit RELU a chaque
# appel (une autre commande vazy peut passer entre deux rafraichissements), et
# qu'aucune adresse IP ne soit demandee pour une VM eteinte -- ce serait une
# interrogation inutile de l'hyperviseur a chaque tour de boucle.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

Describe 'Vue d''ensemble' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'montre toutes les VM, reserve comprise' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'travail' -SansDemarrage | Out-Null
        Set-MarqueModele -Alias 'ubuntu' -Guestinfo $true
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null

        $vue = @(Get-VueEnsemble)
        $vue.Count | Should Be 2
        @($vue | Where-Object { $_.Pool }).Count | Should Be 1
    }

    It 'distingue en marche, arretee et figee' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'allumee' -SansDemarrage
        Start-VmParNom -Nom 'allumee' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'eteinte' -SansDemarrage | Out-Null
        Set-MarqueModele -Alias 'ubuntu' -Guestinfo $true
        New-Pool -Modele 'ubuntu' -Taille 1 | Out-Null

        $vue = @(Get-VueEnsemble)
        (@($vue | Where-Object { $_.Nom -eq 'allumee' })[0]).Etat | Should Be 'en marche'
        (@($vue | Where-Object { $_.Nom -eq 'eteinte' })[0]).Etat | Should Be 'arrêtée'
        (@($vue | Where-Object { $_.Pool })[0]).Etat              | Should Be 'figée'
    }

    It 'signale une VM dont les fichiers ont disparu' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'fantome' -SansDemarrage
        Remove-Item -LiteralPath $vm.Chemin -Force

        (@(Get-VueEnsemble | Where-Object { $_.Nom -eq 'fantome' })[0]).Etat | Should Be 'absente'
    }

    It 'ne demande pas d''adresse IP pour une VM eteinte' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'eteinte' -SansDemarrage | Out-Null
        Get-VueEnsemble -AvecIp | Out-Null

        # Interroger l'hyperviseur pour une machine eteinte serait du temps
        # perdu a chaque tour de boucle.
        (Test-AppelPilote 'Get-MachineAdresseIp') | Should Be $false
    }

    It 'rapporte l''adresse IP d''une VM en marche' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'allumee' -SansDemarrage
        Start-VmParNom -Nom 'allumee' | Out-Null
        Set-AdresseIpFake -Chemin $vm.Chemin -Adresse '192.168.56.42'

        (@(Get-VueEnsemble -AvecIp | Where-Object { $_.Nom -eq 'allumee' })[0]).Ip | Should Be '192.168.56.42'
    }

    It 'ne demande aucune adresse quand on ne les veut pas' {
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'allumee' -SansDemarrage
        Start-VmParNom -Nom 'allumee' | Out-Null
        Get-VueEnsemble | Out-Null

        (Test-AppelPilote 'Get-MachineAdresseIp') | Should Be $false
    }

    It 'relit le catalogue a chaque appel' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'premiere' -SansDemarrage | Out-Null
        @(Get-VueEnsemble).Count | Should Be 1

        # Une autre commande vazy passe pendant que la vue tourne : elle ecrit
        # dans le catalogue sur le disque, pas dans la memoire de la vue.
        $cat = Read-Catalogue
        $fiche = New-Dictionnaire
        foreach ($k in @($cat['vms']['premiere'].Keys)) { $fiche[$k] = $cat['vms']['premiere'][$k] }
        $cat['vms']['ailleurs'] = $fiche
        Write-FichierJson -Chemin $script:CheminCatalogue -Objet $cat

        @(Get-VueEnsemble).Count | Should Be 2
    }

    It 'porte le labo et le caractere ephemere' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'tp-srv' -SansDemarrage -Labo 'tp' | Out-Null
        (@(Get-VueEnsemble | Where-Object { $_.Nom -eq 'tp-srv' })[0]).Labo | Should Be 'tp'
    }
}
