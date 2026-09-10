# Règles métier de la création d'une VM : valeurs par défaut et refus.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

Describe 'Creation - valeurs par defaut' {

    BeforeEach { Reset-EtatVazy }
    AfterEach  { }

    It 'donne 2 Go de RAM, 2 CPU et une seule carte NAT quand rien n''est demande' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        $etat.RamMo | Should Be 2048
        $etat.Cpu   | Should Be 2
        @($etat.Modes).Count | Should Be 1
        $etat.Modes[0] | Should Be 'nat'
    }

    It 'transmet au pilote la RAM et les CPU demandes' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -RamGo 4 -Cpu 8 -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        $etat.RamMo | Should Be 4096
        $etat.Cpu   | Should Be 8
    }

    It 'accepte plusieurs cartes reseau dans l''ordre donne' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'routeur' -Modes @('bridged', 'hostonly') -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        @($etat.Modes).Count | Should Be 2
        $etat.Modes[0] | Should Be 'bridged'
        $etat.Modes[1] | Should Be 'hostonly'
    }

    It 'prend le point de retour vazy-neuf avant tout demarrage' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null

        $instantane = @(Get-AppelsPilote -Fonction 'New-MachineInstantane')
        $instantane.Count | Should Be 1
        $instantane[0].Parametres.Nom | Should Be 'vazy-neuf'
        # Aucun demarrage n'a eu lieu : le rang de l'instantane le prouve.
        (Test-AppelPilote 'Start-Machine') | Should Be $false
    }

    It 'ecrit les reglages bruts --set tels quels' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $sets = @(
            [pscustomobject]@{ Cle = 'usb.present';   Valeur = 'FALSE' },
            [pscustomobject]@{ Cle = 'sound.present'; Valeur = 'TRUE'  }
        )
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Brut $sets -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        $etat.Brut['usb.present']   | Should Be 'FALSE'
        $etat.Brut['sound.present'] | Should Be 'TRUE'
    }
}

Describe 'Creation - refus avant tout appel au pilote' {

    BeforeEach { Reset-EtatVazy }

    It 'refuse un nom de VM invalide sans rien creer' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'nom invalide' -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un nom accentue (il sert aussi de nom de dossier)' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { New-VmDepuisModele -Modele 'ubuntu' -Nom ([char]0xE9 + 'lication') -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un mot reserve comme nom de VM' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'doctor' -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un modele inconnu sans rien creer' {
        { New-VmDepuisModele -Modele 'inexistant' -Nom 'poste1' -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un nom deja pris sans rien creer' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        $avant = @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count

        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage } | Should Throw
        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be $avant
    }

    It 'refuse le nom d''un modele existant' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'ubuntu' -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse --tmp avec --nostart, options contradictoires' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Ephemere -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse de cloner un modele dont l''instantane d''ancrage a disparu' {
        $chemin = New-ModeleTest -Alias 'ubuntu' -Instantane 'base'
        # L'instantane disparait cote hyperviseur, comme apres un menage manuel.
        $global:VazyFake.Modeles[$chemin].Instantanes = @()

        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }
}

Describe 'Creation - retours a l''ecran pendant les temps longs' {

    BeforeEach { Reset-EtatVazy }

    It 'annonce le demarrage AVANT de le lancer, pas apres' {
        # Un demarrage peut prendre plus d'une minute sans rien afficher. Sans
        # message prealable, l'utilisateur croit l'outil plante et coupe.
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' | Out-Null

        (Test-MessageTest 'demarrage de' 'info') -or (Test-MessageTest 'marrage de' 'info') | Should Be $true
    }

    It 'place ce message avant l''appel au pilote' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        Start-VmParNom -Nom 'poste1' | Out-Null

        # Le message « en cours » doit exister, et le message « demarree en X »
        # arriver apres : c'est l'ordre qui compte.
        $messages = @(Get-MessagesTest | ForEach-Object { $_.Message })
        $avant = -1
        $apres = -1
        for ($i = 0; $i -lt $messages.Count; $i++) {
            if ($messages[$i] -like '*en cours*' -and $avant -lt 0) { $avant = $i }
            if ($messages[$i] -like '*marr*e en*' -and $apres -lt 0) { $apres = $i }
        }
        $avant | Should Not Be -1
        $apres | Should Not Be -1
        ($avant -lt $apres) | Should Be $true
    }
}

Describe 'Creation - nettoyage quand une etape echoue' {

    BeforeEach { Reset-EtatVazy }

    It 'supprime la VM incomplete si le reglage reseau echoue' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        Set-EchecPilote -Fonction 'Set-MachineReseau' -Message 'reseau indisponible'

        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage } | Should Throw
        # Le clone a bien eu lieu, puis a ete defait.
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $true
        (Test-AppelPilote 'Remove-Machine')          | Should Be $true
        # Et rien n'est reste au catalogue.
        @(Get-ListeVms | Where-Object { $_.Nom -eq 'poste1' }).Count | Should Be 0
    }
}
