# Chemins critiques a travers les trois couches, via le vrai point d'entree.
#
# L'interface s'execute au chargement et se termine par « exit » : elle ne peut
# pas etre chargee dans le processus de test. On lance donc vazy.cmd comme le
# ferait l'utilisateur, avec le faux pilote branche par variable
# d'environnement. Une commande = un processus, d'ou la persistance du faux
# pilote ($env:VAZY_FAKE_ETAT).
#
# Les assertions portent sur le code de sortie et sur des fragments SANS
# ACCENT : la sortie d'un sous-processus traverse la console, et un accent y
# survit mal selon la page de code active.

. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
$env:VAZY_FAKE_ETAT = Join-Path (Get-RacineTest) 'fake-etat.xml'
. (Get-CheminPiloteFake)      # pour Reset-PiloteFake et Register-ModeleFake

$script:Vazy       = Join-Path (Get-RacineDepot) 'vazy.cmd'
$script:CheminModele = Join-Path (Get-RacineTest) 'modeles\ubuntu\ubuntu.vmx'
$script:DossierVms   = Join-Path (Get-RacineTest) 'vms'

function Invoke-Vazy {
    <# Lance vazy.cmd et renvoie son code de sortie et sa sortie complete. #>
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $sortie = & $script:Vazy @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Sortie = $sortie }
}

function Initialize-BacASable {
    <# Catalogue vide, faux pilote neuf, un modele declare et enregistre. #>
    foreach ($f in @('config.json', 'catalogue.json', 'journal.log')) {
        $c = Join-Path $env:VAZY_HOME $f
        if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Force }
    }
    if (Test-Path -LiteralPath $script:DossierVms) { Remove-Item -LiteralPath $script:DossierVms -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $script:DossierVms -Force | Out-Null
    if (Test-Path -LiteralPath $env:VAZY_FAKE_ETAT) { Remove-Item -LiteralPath $env:VAZY_FAKE_ETAT -Force }

    Reset-PiloteFake -DossierTravail (Get-RacineTest)
    Register-ModeleFake -Chemin $script:CheminModele -Instantane 'base' | Out-Null

    Invoke-Vazy config dossierVms $script:DossierVms | Out-Null
    Invoke-Vazy template add $script:CheminModele --name ubuntu | Out-Null
}

Describe 'Integration - commandes de base' {

    BeforeEach { Initialize-BacASable }

    It 'affiche sa version et sort en 0' {
        $r = Invoke-Vazy version
        $r.Code | Should Be 0
        $r.Sortie | Should Match 'vazy \d+\.\d+\.\d+'
    }

    It 'affiche l''aide et sort en 0' {
        $r = Invoke-Vazy help
        $r.Code | Should Be 0
        $r.Sortie | Should Match 'vazy'
    }

    It 'liste le modele enregistre' {
        $r = Invoke-Vazy template list
        $r.Code | Should Be 0
        $r.Sortie | Should Match 'ubuntu'
    }
}

Describe 'Integration - cycle de vie d''une VM' {

    BeforeEach { Initialize-BacASable }

    It 'cree une VM, la liste, puis la supprime' {
        $creation = Invoke-Vazy ubuntu --name poste1 --nostart
        $creation.Code | Should Be 0

        $liste = Invoke-Vazy list
        $liste.Code | Should Be 0
        $liste.Sortie | Should Match 'poste1'

        $suppression = Invoke-Vazy rm poste1 --yes
        $suppression.Code | Should Be 0

        $apres = Invoke-Vazy list
        $apres.Sortie | Should Not Match 'poste1'
    }

    It 'refuse un nom deja pris avec un code d''erreur' {
        Invoke-Vazy ubuntu --name poste1 --nostart | Out-Null
        $r = Invoke-Vazy ubuntu --name poste1 --nostart
        $r.Code | Should Not Be 0
        $r.Sortie | Should Match 'poste1'
    }

    It 'refuse un modele inconnu avec un code d''erreur' {
        $r = Invoke-Vazy modele-qui-n-existe-pas --name poste1 --nostart
        $r.Code | Should Not Be 0
    }

    It 'ne modifie rien en mode simulation' {
        $r = Invoke-Vazy ubuntu --name poste1 --nostart --dry-run
        $r.Code | Should Be 0

        $liste = Invoke-Vazy list
        $liste.Sortie | Should Not Match 'poste1'
    }
}

Describe 'Integration - lecture d''un fichier de labo' {

    BeforeEach { Initialize-BacASable }

    function New-Labo {
        param([string]$Nom, [string]$Contenu)
        $chemin = Join-Path (Get-RacineTest) ($Nom + '.json')
        [System.IO.File]::WriteAllText($chemin, $Contenu, (New-Object System.Text.UTF8Encoding($false)))
        return $chemin
    }

    It 'refuse un JSON invalide en sortant avec le code 2' {
        $f = New-Labo 'casse' '{ "labo": "casse", '
        $r = Invoke-Vazy lab up $f
        $r.Code | Should Be 2
    }

    It 'refuse une virgule apres le dernier element' {
        $f = New-Labo 'virgule' '{ "labo": "virgule", "machines": { "srv": { "modele": "ubuntu" }, } }'
        $r = Invoke-Vazy lab up $f
        $r.Code | Should Be 2
    }

    It 'nomme la cle inconnue au niveau du labo' {
        $f = New-Labo 'clelabo' '{ "labo": "clelabo", "vitesse": 3, "machines": { "srv": { "modele": "ubuntu" } } }'
        $r = Invoke-Vazy lab up $f
        $r.Code | Should Be 2
        $r.Sortie | Should Match 'vitesse'
    }

    It 'nomme la machine ET la cle inconnue au niveau d''une machine' {
        $f = New-Labo 'clemachine' '{ "labo": "clemachine", "machines": { "srv": { "modele": "ubuntu", "memoire": 4 } } }'
        $r = Invoke-Vazy lab up $f
        $r.Code | Should Not Be 0
        $r.Sortie | Should Match 'srv'
        $r.Sortie | Should Match 'memoire'
    }

    It 'refuse un fichier de labo introuvable' {
        $r = Invoke-Vazy lab up (Join-Path (Get-RacineTest) 'absent.json')
        $r.Code | Should Not Be 0
    }

    It 'monte un labo complet et le demonte' {
        $f = New-Labo 'tp' '{ "labo": "tp", "delai": 0, "machines": { "srv": { "modele": "ubuntu" }, "poste": { "modele": "ubuntu", "apres": "srv" } } }'

        $up = Invoke-Vazy lab up $f
        $up.Code | Should Be 0

        $liste = Invoke-Vazy list
        $liste.Sortie | Should Match 'tp-srv'
        $liste.Sortie | Should Match 'tp-poste'

        $down = Invoke-Vazy lab down $f --yes
        $down.Code | Should Be 0
    }
}

Describe 'Integration - segments reseau' {

    BeforeEach { Initialize-BacASable }

    It 'cree un segment, le liste, y branche une VM, puis refuse de le supprimer' {
        $creation = Invoke-Vazy net add labo-dmz --adresse 192.168.100.0
        $creation.Code | Should Be 0

        $liste = Invoke-Vazy net list
        $liste.Code | Should Be 0
        $liste.Sortie | Should Match 'labo-dmz'

        $vm = Invoke-Vazy ubuntu --name poste1 --reseau-nomme labo-dmz --nostart
        $vm.Code | Should Be 0

        # Une VM y est branchee : le segment ne doit pas partir en silence.
        $suppression = Invoke-Vazy net rm labo-dmz --yes
        $suppression.Code | Should Not Be 0
        $suppression.Sortie | Should Match 'poste1'
    }

    It 'supprime un segment libre' {
        Invoke-Vazy net add labo-dmz | Out-Null
        $r = Invoke-Vazy net rm labo-dmz --yes
        $r.Code | Should Be 0

        # On verifie que la liste est vide, et non l'absence du nom : le
        # message affiche quand il n'y a rien cite « labo-dmz » en exemple.
        $liste = Invoke-Vazy net list
        $liste.Sortie | Should Match 'Aucun segment'
    }

    It 'refuse une VM sur un segment jamais cree' {
        $r = Invoke-Vazy ubuntu --name poste1 --reseau-nomme inexistant --nostart
        $r.Code | Should Not Be 0
        $r.Sortie | Should Match 'inexistant'
    }

    It 'accepte reseau-nomme dans un fichier de labo' {
        Invoke-Vazy net add labo-dmz | Out-Null
        $chemin = Join-Path (Get-RacineTest) 'tpnet.json'
        $contenu = '{ "labo": "tpnet", "delai": 0, "machines": { "srv": { "modele": "ubuntu", "mode": "nat", "reseau-nomme": "labo-dmz" } } }'
        [System.IO.File]::WriteAllText($chemin, $contenu, (New-Object System.Text.UTF8Encoding($false)))

        $up = Invoke-Vazy lab up $chemin
        $up.Code | Should Be 0

        $liste = Invoke-Vazy list
        $liste.Sortie | Should Match 'tpnet-srv'
    }
}

Describe 'Integration - vue temps reel' {

    BeforeEach { Initialize-BacASable }

    It 'affiche un instantane et sort, sans console interactive' {
        # Point critique : sans clavier (sortie redirigee, script, CI), la vue
        # ne doit PAS entrer dans sa boucle, sinon elle bloquerait pour de bon.
        Invoke-Vazy ubuntu --name poste1 --nostart | Out-Null
        $r = Invoke-Vazy top
        $r.Code | Should Be 0
        $r.Sortie | Should Match 'vazy top'
        $r.Sortie | Should Match 'poste1'
    }

    It 'ne se plaint pas quand il n''y a aucune VM' {
        $r = Invoke-Vazy top
        $r.Code | Should Be 0
    }
}

Describe 'Integration - rapport HTML' {

    BeforeEach { Initialize-BacASable }

    It 'ecrit un fichier autonome, sans aucune ressource externe' {
        Invoke-Vazy ubuntu --name poste1 --nostart | Out-Null
        $cible = Join-Path (Get-RacineTest) 'rapport.html'

        $r = Invoke-Vazy report --out $cible
        $r.Code | Should Be 0
        (Test-Path -LiteralPath $cible) | Should Be $true

        $html = [IO.File]::ReadAllText($cible, [Text.Encoding]::UTF8)
        $html | Should Match '<!DOCTYPE html>'
        $html | Should Match 'poste1'
        $html | Should Match 'ubuntu'
        # Un rapport qu'on joint a un compte-rendu doit s'ouvrir hors connexion.
        $html | Should Not Match '<script'
        $html | Should Not Match 'src="http'
        $html | Should Not Match 'href="http'
        $html | Should Not Match '<link'
    }

    It 'produit un rapport meme sans aucune VM' {
        $cible = Join-Path (Get-RacineTest) 'vide.html'
        $r = Invoke-Vazy report --out $cible
        $r.Code | Should Be 0
        ([IO.File]::ReadAllText($cible, [Text.Encoding]::UTF8)) | Should Match 'Aucune VM'
    }

    It 'n''ecrit rien en simulation' {
        $cible = Join-Path (Get-RacineTest) 'jamais.html'
        $r = Invoke-Vazy report --out $cible --dry-run
        $r.Code | Should Be 0
        (Test-Path -LiteralPath $cible) | Should Be $false
    }
}

Describe 'Integration - cout disque' {

    BeforeEach { Initialize-BacASable }

    It 'affiche le cout de chaque VM' {
        Invoke-Vazy ubuntu --name poste1 --nostart | Out-Null
        $r = Invoke-Vazy disk
        $r.Code | Should Be 0
        $r.Sortie | Should Match 'poste1'
    }

    It 'accepte une VM precise et refuse une VM inconnue' {
        Invoke-Vazy ubuntu --name poste1 --nostart | Out-Null
        (Invoke-Vazy disk poste1).Code | Should Be 0
        (Invoke-Vazy disk inconnue).Code | Should Not Be 0
    }

    It 'accepte le reglage du seuil par vazy config' {
        (Invoke-Vazy config seuilDivergencePct 30).Code | Should Be 0
    }

    It 'accepte le reglage de l''attente du pool par vazy config' {
        # Cles ajoutees au lot 1 : elles doivent etre reglables comme les autres.
        (Invoke-Vazy config delaiPoolSec 300).Code | Should Be 0
        (Invoke-Vazy config poolReposSec 30).Code  | Should Be 0
    }
}

Describe 'Integration - synonymes des segments' {

    BeforeEach { Initialize-BacASable }

    It 'accepte « create » et « ls », avec --hostonly' {
        $c = Invoke-Vazy net create dmz --hostonly
        $c.Code | Should Be 0
        $l = Invoke-Vazy net ls
        $l.Code | Should Be 0
        $l.Sortie | Should Match 'dmz'
    }

    It 'refuse toujours une sous-commande inconnue' {
        (Invoke-Vazy net renommer dmz).Code | Should Not Be 0
    }
}

Describe 'Integration - diagnostic' {

    BeforeEach { Initialize-BacASable }

    It 'doctor s''execute sans planter' {
        $r = Invoke-Vazy doctor
        # doctor renvoie un code non nul quand il trouve des anomalies : on
        # verifie seulement qu'il ne s'effondre pas et qu'il rend un rapport.
        $r.Sortie.Length | Should BeGreaterThan 0
    }
}
