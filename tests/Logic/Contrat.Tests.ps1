# Conformite des pilotes au contrat.
#
# Le contrat n'est pas defini par le commentaire en tete de pilote-vmware.ps1
# (un commentaire ne se verifie pas), mais par les faits : les fonctions que
# la couche logique appelle et que le pilote definit. Ce fichier les extrait
# par analyse syntaxique, puis exige que CHAQUE pilote les fournisse toutes,
# avec les memes parametres.
#
# C'est ce test qui rend la portabilite verifiable au lieu d'etre une
# affirmation : un pilote incomplet est refuse ici, pas a l'execution chez
# l'utilisateur.

. "$PSScriptRoot\..\Aide\Environnement.ps1"

$script:Racine = Get-RacineDepot

function Get-FonctionsFichier {
    <# Nom -> liste des noms de parametres, pour chaque fonction d'un fichier. #>
    param([string]$Chemin)
    $jetons = $null
    $erreurs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Chemin, [ref]$jetons, [ref]$erreurs)
    $table = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $params = @()
        if ($f.Body.ParamBlock) {
            $params = @($f.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        $table[$f.Name] = $params
    }
    return $table
}

function Get-CommandesAppelees {
    param([string]$Chemin)
    $jetons = $null
    $erreurs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Chemin, [ref]$jetons, [ref]$erreurs)
    $noms = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
              ForEach-Object { $_.GetCommandName() } |
              Where-Object { $_ })
    return @($noms | Select-Object -Unique)
}

# Le contrat, deduit du pilote de reference et de ce que la logique appelle.
$script:PiloteReference = Join-Path $script:Racine 'lib\pilote-vmware.ps1'
$script:FonctionsRef    = Get-FonctionsFichier -Chemin $script:PiloteReference
$script:AppelsLogique   = Get-CommandesAppelees -Chemin (Join-Path $script:Racine 'lib\logique.ps1')
$script:Contrat         = @($script:FonctionsRef.Keys | Where-Object { $script:AppelsLogique -contains $_ } | Sort-Object)

# Tous les pilotes du depot, y compris celui des tests : le faux pilote doit
# suivre le contrat aussi, sinon les tests valident autre chose que la realite.
$script:Pilotes = @(
    @{ Nom = 'VirtualBox'; Chemin = (Join-Path $script:Racine 'lib\pilote-virtualbox.ps1') },
    @{ Nom = 'faux pilote'; Chemin = (Join-Path $script:Racine 'tests\Fakes\pilote-fake.ps1') }
)

Describe 'Contrat du pilote' {

    It 'est non vide et contient les six operations' {
        $script:Contrat.Count | Should BeGreaterThan 15
        foreach ($f in @('New-MachineDepuisModele', 'Set-MachineParametres', 'Set-MachineReseau',
                         'Start-Machine', 'Stop-Machine', 'Remove-Machine')) {
            $script:Contrat -contains $f | Should Be $true
        }
    }

    It 'ne laisse aucun terme propre a VMware dans les couches 1 et 2' {
        # La regle structurante du projet, verifiee mecaniquement. Les termes
        # peuvent apparaitre dans des chaines de message destinees a
        # l'utilisateur, mais pas dans du code : on analyse donc l'AST.
        foreach ($couche in @('lib\interface.ps1', 'lib\logique.ps1')) {
            $chemin = Join-Path $script:Racine $couche
            $jetons = $null
            $erreurs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($chemin, [ref]$jetons, [ref]$erreurs) | Out-Null
            # Les quatre formes de chaine ont chacune leur Kind, y compris les
            # here-strings : les oublier ferait echouer le test sur le texte
            # d'aide, qui cite legitimement « .vmx » a l'utilisateur.
            $chaines = @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable', 'Comment')
            $suspects = @($jetons | Where-Object {
                $chaines -notcontains [string]$_.Kind -and
                $_.Text -match '(?i)vmrun|vboxmanage|\.vmx\b|vmnet\d|vnetlib'
            })
            if ($suspects.Count -gt 0) {
                throw ("$couche contient des termes propres a un hyperviseur : " + (@($suspects | ForEach-Object { $_.Text }) -join ', '))
            }
        }
    }
}

foreach ($pilote in $script:Pilotes) {

    Describe "Conformite du pilote : $($pilote.Nom)" {

        It 'existe' {
            Test-Path -LiteralPath $pilote.Chemin | Should Be $true
        }

        It 'definit toutes les fonctions du contrat' {
            $fonctions = Get-FonctionsFichier -Chemin $pilote.Chemin
            $manquantes = @($script:Contrat | Where-Object { -not $fonctions.ContainsKey($_) })
            if ($manquantes.Count -gt 0) {
                throw ("fonctions du contrat absentes : " + ($manquantes -join ', '))
            }
        }

        It 'declare les memes parametres que le pilote de reference' {
            $fonctions = Get-FonctionsFichier -Chemin $pilote.Chemin
            $ecarts = @()
            foreach ($nom in $script:Contrat) {
                if (-not $fonctions.ContainsKey($nom)) { continue }
                $attendus = @($script:FonctionsRef[$nom] | Sort-Object)
                $reels    = @($fonctions[$nom] | Sort-Object)
                if (($attendus -join ',') -ne ($reels -join ',')) {
                    $ecarts += ("{0} : attendu ({1}), trouve ({2})" -f $nom, ($attendus -join ', '), ($reels -join ', '))
                }
            }
            if ($ecarts.Count -gt 0) { throw ($ecarts -join ' | ') }
        }

        It 'est syntaxiquement valide' {
            $jetons = $null
            $erreurs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($pilote.Chemin, [ref]$jetons, [ref]$erreurs) | Out-Null
            @($erreurs).Count | Should Be 0
        }

        It 'renseigne toutes les cles de description attendues' {
            # Ce que Initialize-Pilote doit annoncer. La logique s'en sert pour
            # rester ignorante de l'hyperviseur : extension de fichier, conseil
            # affiche a l'utilisateur, protocole de l'ecran distant.
            $jetons = $null
            $erreurs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($pilote.Chemin, [ref]$jetons, [ref]$erreurs)
            $init = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-Pilote'
            }, $true)
            $texte = $init.Extent.Text
            $manquantes = @()
            foreach ($cle in @('Nom', 'Executable', 'ExtensionMachine', 'SensibleHyperV',
                               'ConseilInstantane', 'SchemaAffichageDistant')) {
                if ($texte -notmatch ('(?m)^\s*' + $cle + '\s*=')) { $manquantes += $cle }
            }
            if ($manquantes.Count -gt 0) {
                throw ("cles absentes de la description renvoyee par Initialize-Pilote : " + ($manquantes -join ', '))
            }
        }
    }
}

Describe 'Point de passage unique des commandes' {

    It 'ne lance VBoxManage que depuis Invoke-VBoxManage' {
        # Le pendant d'Invoke-Vmrun : si une commande partait d'ailleurs, elle
        # echapperait au journal, a --dry-run et au masquage des mots de passe.
        $chemin = Join-Path $script:Racine 'lib\pilote-virtualbox.ps1'
        $jetons = $null
        $erreurs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($chemin, [ref]$jetons, [ref]$erreurs)
        $fautifs = @()
        foreach ($appel in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            # C'est le PREMIER element qui dit ce qui est lance. Chercher le nom
            # de la variable dans le texte entier attraperait aussi les messages
            # d'erreur qui citent la commande a taper a la main.
            $premier = $appel.CommandElements[0]
            $lance = ($premier -is [System.Management.Automation.Language.VariableExpressionAst] -and
                      $premier.VariablePath.UserPath -ieq 'script:VBoxExe')
            if (-not $lance) { continue }
            $conteneur = $appel
            while ($conteneur -and $conteneur -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $conteneur = $conteneur.Parent
            }
            $nomConteneur = if ($conteneur) { $conteneur.Name } else { '(niveau du script)' }
            if ($nomConteneur -ne 'Invoke-VBoxManage') {
                $fautifs += ("{0} (ligne {1})" -f $nomConteneur, $appel.Extent.StartLineNumber)
            }
        }
        if ($fautifs.Count -gt 0) { throw ("VBoxManage lance hors d'Invoke-VBoxManage : " + ($fautifs -join ', ')) }
    }
}
