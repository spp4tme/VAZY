# Adressage statique et cle SSH deposes dans l'invite par guestinfo.
#
# Ce que la couche logique doit garantir : une adresse invalide est refusee
# AVANT tout clonage, la charge utile ne contient que ce qui a ete demande
# (sans quoi le comportement DHCP d'origine changerait), et un labo exporte
# reemet l'adressage pour rester rejouable.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)

function New-ModeleGuestinfo {
    param([string]$Alias = 'ubuntu')
    New-ModeleTest -Alias $Alias | Out-Null
    Set-MarqueModele -Alias $Alias -Guestinfo $true
}

# La derniere configuration deposee dans l'invite, decodee.
function Get-DerniereCharge {
    $depots = @(Get-AppelsPilote -Fonction 'Set-MachineVariableInvite' | Where-Object { $_.Parametres.Valeur })
    if ($depots.Count -eq 0) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($depots[-1].Parametres.Valeur))
}

Describe 'Adressage - ce qui part dans l''invite' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfo -Alias 'ubuntu'
    }

    It 'transmet l''adresse, le masque, la passerelle et le DNS' {
        $config = [ordered]@{ ip = '192.168.100.10'; masque = '24'; passerelle = '192.168.100.1'; dns = @('192.168.100.1', '1.1.1.1') }
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -NomHote 'srv' -ConfigInvite $config | Out-Null

        $json = Get-DerniereCharge
        $json | Should Match '192\.168\.100\.10'
        $json | Should Match '"masque":"24"'
        $json | Should Match '192\.168\.100\.1'
        $json | Should Match '1\.1\.1\.1'
    }

    It 'convertit un masque en notation pointee en longueur de prefixe' {
        $config = [ordered]@{ ip = '10.0.0.5'; masque = '255.255.255.0' }
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -NomHote 'srv' -ConfigInvite $config | Out-Null

        # L'invite n'a ainsi qu'une seule forme a traiter.
        (Get-DerniereCharge) | Should Match '"masque":"24"'
    }

    It 'convertit aussi un masque de classe B' {
        (ConvertTo-LongueurPrefixe '255.255.0.0')   | Should Be '16'
        (ConvertTo-LongueurPrefixe '255.255.255.128') | Should Be '25'
        (ConvertTo-LongueurPrefixe '24')            | Should Be '24'
    }

    It 'transmet la cle SSH' {
        $config = [ordered]@{ cle_ssh = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI anthony@poste' }
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -NomHote 'srv' -ConfigInvite $config | Out-Null

        (Get-DerniereCharge) | Should Match 'ssh-ed25519'
    }

    It 'n''ajoute AUCUNE cle quand rien n''est demande' {
        # Retrocompatibilite : sans adressage, la charge utile doit rester
        # exactement ce qu'elle etait, sinon le comportement DHCP change.
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -NomHote 'srv' | Out-Null

        $json = Get-DerniereCharge
        $json | Should Match '"hostname":"srv"'
        $json | Should Not Match 'ip'
        $json | Should Not Match 'masque'
        $json | Should Not Match 'passerelle'
        $json | Should Not Match 'cle_ssh'
    }

    It 'depose l''adressage meme sans nom d''hote demande' {
        $config = [ordered]@{ ip = '10.0.0.5'; masque = '24' }
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite $config | Out-Null

        (Get-DerniereCharge) | Should Match '10\.0\.0\.5'
    }
}

Describe 'Adressage - refus avant tout clonage' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfo -Alias 'ubuntu'
    }

    It 'refuse une adresse qui n''en est pas une' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ ip = '192.168.1'; masque = '24' }) -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse un octet au-dela de 255' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ ip = '192.168.1.300'; masque = '24' }) -SansDemarrage } | Should Throw
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse une adresse sans masque, en disant pourquoi' {
        $message = ''
        try { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ ip = '10.0.0.5' }) -SansDemarrage }
        catch { $message = $_.Exception.Message + ' ' + [string]$_.Exception.Data['Conseil'] }
        $message | Should Match 'masque'
        (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
    }

    It 'refuse une longueur de prefixe hors bornes' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ ip = '10.0.0.5'; masque = '99' }) -SansDemarrage } | Should Throw
    }

    It 'refuse une passerelle invalide' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ ip = '10.0.0.5'; masque = '24'; passerelle = 'la-box' }) -SansDemarrage } | Should Throw
    }

    It 'refuse un serveur DNS invalide' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ dns = @('1.1.1.1', 'pas-une-adresse') }) -SansDemarrage } | Should Throw
    }

    It 'refuse une cle SSH qui n''en est pas une' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ cle_ssh = 'coucou' }) -SansDemarrage } | Should Throw
    }

    It 'accepte une cle SSH bien formee' {
        { New-VmDepuisModele -Modele 'ubuntu' -Nom 'srv' -ConfigInvite ([ordered]@{ cle_ssh = 'ssh-rsa AAAAB3NzaC1yc2E test' }) -SansDemarrage } | Should Not Throw
    }
}

Describe 'Adressage - modele sans guestinfo' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleTest -Alias 'brut' | Out-Null    # ni guestinfo ni identifiants
    }

    It 'previent que l''adressage ne sera pas applique' {
        $config = [ordered]@{ ip = '10.0.0.5'; masque = '24' }
        New-VmDepuisModele -Modele 'brut' -Nom 'srv' -ConfigInvite $config | Out-Null

        (Test-MessageTest 'guestinfo') | Should Be $true
        # Rien n'est depose : le modele ne saurait pas le lire.
        (Test-AppelPilote 'Set-MachineVariableInvite') | Should Be $false
    }
}

Describe 'Adressage - export d''un labo' {

    BeforeEach {
        Reset-EtatVazy
        New-ModeleGuestinfo -Alias 'ubuntu'
    }

    It 'reemet l''adressage pour que le labo reste rejouable' {
        $config = [ordered]@{ ip = '192.168.100.10'; masque = '24'; passerelle = '192.168.100.1'; dns = @('192.168.100.1') }
        New-VmDepuisModele -Modele 'ubuntu' -Nom 'tp-srv' -NomHote 'srv' -ConfigInvite $config -SansDemarrage -Labo 'tp' | Out-Null

        $json = ConvertTo-Json -InputObject (Export-Labo -Labo 'tp') -Depth 8
        $json | Should Match '192\.168\.100\.10'
        $json | Should Match 'passerelle'
        $json | Should Match 'dns'
    }
}
