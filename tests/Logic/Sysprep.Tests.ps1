# Sysprep des modeles Windows (facultatif).
#
# vazy ne lance jamais sysprep : il retient qu'un modele est generalise, et
# previent quand un labo s'apprete a multiplier les clones d'un modele Windows
# qui ne l'est pas. On teste ces deux regles, plus le fichier de reponses que
# produit le script d'invite -- charge par point-source, sans rien lancer.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)
. (Join-Path (Get-RacineDepot) 'invite\windows\sysprep.ps1')

function New-MachineLabo {
    param([string]$Nom, [string]$Modele)
    return [pscustomobject]@{
        Nom = $Nom; Modele = $Modele; RamGo = 2; Cpu = 2; Modes = @('nat'); Brut = @()
        NomHote = ''; Vnc = $false; SansInterface = $false; SansDemarrage = $true; Apres = @(); ConfigInvite = $null
    }
}

function New-Labo {
    param([object[]]$Machines)
    return [pscustomobject]@{
        Nom = 'ad'; Fichier = (Join-Path (Get-RacineTest) 'ad.json'); Delai = 0; Machines = $Machines; Requis = @()
    }
}

Describe 'Sysprep - la marque' {

    BeforeEach { Reset-EtatVazy }

    It 'un modele neuf n''est pas repute generalise' {
        New-ModeleTest -Alias 'win' | Out-Null
        $script:Catalogue['modeles']['win']['sysprep'] | Should Be $false
    }

    It 'marque un modele Windows' {
        $global:VazyFake.Systeme = 'windows'
        New-ModeleTest -Alias 'win' | Out-Null
        Set-SysprepModele -Alias 'win' -Generalise $true
        $script:Catalogue['modeles']['win']['sysprep'] | Should Be $true
    }

    It 'retire la marque' {
        $global:VazyFake.Systeme = 'windows'
        New-ModeleTest -Alias 'win' | Out-Null
        Set-SysprepModele -Alias 'win' -Generalise $true
        Set-SysprepModele -Alias 'win' -Generalise $false
        $script:Catalogue['modeles']['win']['sysprep'] | Should Be $false
    }

    It 'refuse de marquer un modele Linux' {
        New-ModeleTest -Alias 'ubuntu' | Out-Null     # le faux pilote repond « linux »
        { Set-SysprepModele -Alias 'ubuntu' -Generalise $true } | Should Throw
        $script:Catalogue['modeles']['ubuntu']['sysprep'] | Should Be $false
    }

    It 'accepte sur parole un systeme inconnu, en le disant' {
        $global:VazyFake.Systeme = 'inconnu'
        New-ModeleTest -Alias 'mystere' | Out-Null
        Set-SysprepModele -Alias 'mystere' -Generalise $true
        (Test-MessageTest 'sur votre parole' 'attention') | Should Be $true
    }
}

Describe 'Sysprep - avertissement au montage d''un labo' {

    BeforeEach {
        Reset-EtatVazy
        $global:VazyFake.Systeme = 'windows'
        New-ModeleTest -Alias 'win' | Out-Null
    }

    It 'previent quand plusieurs machines sortent d''un Windows non generalise' {
        $labo = New-Labo -Machines @((New-MachineLabo 'dc01' 'win'), (New-MachineLabo 'srv01' 'win'))
        $alerte = @(Get-ModelesNonGeneralisesDuLabo -Labo $labo)
        $alerte.Count | Should Be 1
        $alerte[0].Machines | Should Be 2

        Invoke-LaboUp -Labo $labo | Out-Null
        (Test-MessageTest 'SID' 'attention') | Should Be $true
    }

    It 'n''empeche pas le montage : c''est un avertissement' {
        $labo = New-Labo -Machines @((New-MachineLabo 'dc01' 'win'), (New-MachineLabo 'srv01' 'win'))
        { Invoke-LaboUp -Labo $labo } | Should Not Throw
        @(Get-AppelsPilote -Fonction 'New-MachineDepuisModele').Count | Should Be 2
    }

    It 'se tait quand le modele est generalise' {
        Set-SysprepModele -Alias 'win' -Generalise $true
        $labo = New-Labo -Machines @((New-MachineLabo 'dc01' 'win'), (New-MachineLabo 'srv01' 'win'))
        @(Get-ModelesNonGeneralisesDuLabo -Labo $labo).Count | Should Be 0
    }

    It 'se tait pour une seule machine : pas de jumelle, pas de collision' {
        $labo = New-Labo -Machines @((New-MachineLabo 'dc01' 'win'))
        @(Get-ModelesNonGeneralisesDuLabo -Labo $labo).Count | Should Be 0
    }

    It 'se tait pour Linux' {
        Reset-EtatVazy
        New-ModeleTest -Alias 'ubuntu' | Out-Null
        $labo = New-Labo -Machines @((New-MachineLabo 'a' 'ubuntu'), (New-MachineLabo 'b' 'ubuntu'))
        @(Get-ModelesNonGeneralisesDuLabo -Labo $labo).Count | Should Be 0
    }
}

Describe 'Sysprep - le fichier de reponses du script d''invite' {

    It 'est un XML valide' {
        { [xml](New-UnattendVazy) } | Should Not Throw
    }

    It 'donne un nom aleatoire, que guestinfo remplacera' {
        $xml = [xml](New-UnattendVazy)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $xml.SelectSingleNode('//u:settings[@pass="specialize"]//u:ComputerName', $ns).InnerText | Should Be '*'
    }

    It 'preserve le compteur de rearmement de l''activation' {
        $xml = [xml](New-UnattendVazy)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $xml.SelectSingleNode('//u:settings[@pass="generalize"]//u:SkipRearm', $ns).InnerText | Should Be '1'
    }

    It 'reprend la langue et le clavier demandes' {
        $texte = New-UnattendVazy -Langue 'en-US' -Clavier '0409:00000409'
        $texte | Should Match '<UILanguage>en-US</UILanguage>'
        $texte | Should Match '<InputLocale>0409:00000409</InputLocale>'
    }

    It 'n''a rien lance en etant charge par point-source' {
        # Le simple fait d'arriver ici prouve que le chargement n'a pas lance
        # la preparation (elle aurait demande les droits administrateur).
        (Get-Command New-UnattendVazy -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }
}
