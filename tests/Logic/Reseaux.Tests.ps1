# Segments reseau personnalises.
#
# « hostonly » met toutes les VM sur le meme segment : deux labos montes en
# meme temps se voient. Un segment nomme est un reseau isole. Ce que la couche
# logique doit garantir : le nom parlant est traduit en identifiant du pilote,
# un segment disparu est detecte AVANT de creer la VM, et on ne supprime pas un
# segment sous les pieds des VM qui l'utilisent.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

Describe 'Segments - creation' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'cree un segment et le retient sous son nom parlant' {
        $r = New-ReseauLabo -Nom 'labo-dmz'

        $r.Nom | Should Be 'labo-dmz'
        $r.Identifiant | Should Not BeNullOrEmpty
        (Test-AppelPilote 'New-ReseauNomme') | Should Be $true

        $liste = @(Get-ListeReseaux)
        $liste.Count | Should Be 1
        $liste[0].Nom  | Should Be 'labo-dmz'
        $liste[0].Etat | Should Be 'actif'
    }

    It 'transmet l''adresse et le DHCP demandes au pilote' {
        New-ReseauLabo -Nom 'labo-dmz' -Adresse '192.168.100.0' -Dhcp | Out-Null

        $appel = @(Get-AppelsPilote -Fonction 'New-ReseauNomme')[0]
        $appel.Parametres.Adresse | Should Be '192.168.100.0'
        $appel.Parametres.Dhcp    | Should Be $true
    }

    It 'refuse deux segments du meme nom' {
        New-ReseauLabo -Nom 'labo-dmz' | Out-Null
        { New-ReseauLabo -Nom 'labo-dmz' } | Should Throw
        @(Get-AppelsPilote -Fonction 'New-ReseauNomme').Count | Should Be 1
    }

    It 'refuse un nom deja porte par une VM' {
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null
        { New-ReseauLabo -Nom 'poste1' } | Should Throw
        (Test-AppelPilote 'New-ReseauNomme') | Should Be $false
    }

    It 'refuse un nom deja porte par un modele' {
        { New-ReseauLabo -Nom 'ubuntu' } | Should Throw
        (Test-AppelPilote 'New-ReseauNomme') | Should Be $false
    }

    It 'refuse un nom de segment invalide' {
        { New-ReseauLabo -Nom 'segment invalide' } | Should Throw
        (Test-AppelPilote 'New-ReseauNomme') | Should Be $false
    }

    It 'refuse une adresse qui n''en est pas une' {
        { New-ReseauLabo -Nom 'labo-dmz' -Adresse 'pas-une-adresse' } | Should Throw
        (Test-AppelPilote 'New-ReseauNomme') | Should Be $false
    }
}

Describe 'Segments - resolution' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'traduit le nom parlant en identifiant du pilote' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        $mode = Resolve-ReseauNomme -Nom 'labo-dmz'
        $mode | Should Be ('nomme:' + $r.Identifiant)
    }

    It 'accepte le nom sans tenir compte de la casse' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        (Resolve-ReseauNomme -Nom 'LABO-DMZ') | Should Be ('nomme:' + $r.Identifiant)
    }

    It 'refuse un segment inconnu en listant ceux qui existent' {
        New-ReseauLabo -Nom 'labo-dmz' | Out-Null
        $message = ''
        try { Resolve-ReseauNomme -Nom 'labo-lan' } catch { $message = $_.Exception.Message + ' ' + [string]$_.Exception.Data['Conseil'] }
        $message | Should Match 'labo-lan'
        $message | Should Match 'labo-dmz'
    }

    It 'refuse un segment que l''hyperviseur ne connait plus' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        # Supprime cote hyperviseur uniquement, comme un menage manuel dans
        # l'editeur de reseaux virtuels.
        $global:VazyFake.Reseaux.Remove($r.Identifiant)

        { Resolve-ReseauNomme -Nom 'labo-dmz' } | Should Throw
    }
}

Describe 'Segments - branchement d''une VM' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'branche la carte sur le segment demande' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        @($etat.Modes).Count | Should Be 1
        $etat.Modes[0] | Should Be ('nomme:' + $r.Identifiant)
    }

    It 'accepte de melanger un mode classique et un segment' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        $vm = New-VmDepuisModele -Modele 'ubuntu' -Nom 'routeur' -Modes @('nat', ('nomme:' + $r.Identifiant)) -SansDemarrage

        $etat = Get-EtatMachineFake -Chemin $vm.Chemin
        @($etat.Modes).Count | Should Be 2
        $etat.Modes[0] | Should Be 'nat'
        $etat.Modes[1] | Should Be ('nomme:' + $r.Identifiant)
    }

    It 'refuse de creer une VM sur un segment disparu, avant tout clonage' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        $global:VazyFake.Reseaux.Remove($r.Identifiant)

        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'compte les VM branchees sur le segment' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste2' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage | Out-Null
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'ailleurs' -Modes @('nat') -SansDemarrage | Out-Null

        $vms = @(Get-VmsSurReseau -Identifiant $r.Identifiant)
        $vms.Count | Should Be 2
        ($vms -contains 'ailleurs') | Should Be $false
    }
}

Describe 'Segments - suppression' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'supprime un segment inutilise' {
        New-ReseauLabo -Nom 'labo-dmz' | Out-Null
        Remove-ReseauLabo -Nom 'labo-dmz'

        (Test-AppelPilote 'Remove-ReseauNomme') | Should Be $true
        @(Get-ListeReseaux).Count | Should Be 0
    }

    It 'refuse de supprimer un segment sur lequel une VM est branchee' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage | Out-Null

        { Remove-ReseauLabo -Nom 'labo-dmz' } | Should Throw
        (Test-AppelPilote 'Remove-ReseauNomme') | Should Be $false
        @(Get-ListeReseaux).Count | Should Be 1
    }

    It 'nomme les VM concernees dans le refus' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage | Out-Null
        $message = ''
        try { Remove-ReseauLabo -Nom 'labo-dmz' } catch { $message = $_.Exception.Message }
        $message | Should Match 'poste1'
    }

    It 'refuse de supprimer un segment inconnu' {
        { Remove-ReseauLabo -Nom 'jamais-cree' } | Should Throw
    }

    It 'retire la fiche meme si l''hyperviseur refuse, en avertissant' {
        New-ReseauLabo -Nom 'labo-dmz' | Out-Null
        Set-EchecPilote -Fonction 'Remove-ReseauNomme' -Message 'segment verrouille'

        Remove-ReseauLabo -Nom 'labo-dmz'

        # La fiche ne doit pas rester coincee au catalogue pour toujours.
        @(Get-ListeReseaux).Count | Should Be 0
        (Test-MessageTest 'verrouille' 'attention') | Should Be $true
    }
}

Describe 'Segments - export d''un labo' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
    }

    It 'reecrit le segment sous son nom parlant, pas sous son identifiant' {
        $r = New-ReseauLabo -Nom 'labo-dmz'
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'tp-srv' -Modes @('nomme:' + $r.Identifiant) -SansDemarrage -Labo 'tp' | Out-Null

        $description = Export-Labo -Labo 'tp'
        $json = ConvertTo-Json -InputObject $description -Depth 8

        # Un fichier exporte doit etre relisible sur une autre machine, ou
        # l'identifiant du pilote n'aura aucun sens.
        $json | Should Match 'labo-dmz'
        $json | Should Match 'reseau-nomme'
        $json | Should Not Match ('nomme:' + $r.Identifiant)
    }
}
