# Configuration PSScriptAnalyzer de vazy.
#
# La CI échoue sur Error et Warning. Les règles écartées ci-dessous le sont
# pour une raison d'architecture, pas pour faire passer la CI : chacune est
# justifiée. Toutes les règles de sécurité (mots de passe en clair,
# Invoke-Expression, identifiants) restent actives — ce sont précisément
# celles qu'on veut voir remonter sur ce projet.

@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # vazy EST une interface en ligne de commande : sa sortie est destinée
        # à un humain devant un terminal, en couleurs. Write-Output enverrait
        # ce texte dans le pipeline, où il polluerait les valeurs de retour des
        # fonctions. 151 occurrences, toutes volontaires.
        'PSAvoidUsingWriteHost',

        # vazy a son propre modèle de confirmation (--yes, et une question en
        # console sinon), homogène sur toutes les commandes destructrices.
        # Ajouter -WhatIf/-Confirm donnerait deux mécanismes concurrents pour
        # la même chose, et --dry-run couvre déjà le besoin de simulation.
        'PSUseShouldProcessForStateChangingFunctions',

        # Les noms sont en français : « Get-MachineInstantanes » rend bien une
        # liste d'instantanés, « Get-ListeVms » une liste de VM. Le pluriel est
        # correct ici ; la règle raisonne sur l'anglais.
        'PSUseSingularNouns',

        # Uniquement dans tests\Fakes\pilote-fake.ps1, et documenté sur place :
        # le faux pilote est chargé par point-source à travers deux niveaux, où
        # $script: désignerait des portées différentes selon le niveau.
        'PSAvoidGlobalVars',

        # Faux positifs systématiques avec le point-source : logique.ps1 pose
        # des variables que interface.ps1 consomme, et l'analyseur examine
        # chaque fichier isolément.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Une cinquantaine de « catch { } » volontaires, tous du même genre :
        # un journal illisible ne doit jamais empêcher de travailler, une
        # complétion ne doit jamais écrire d'erreur dans la console, une sonde
        # (espace disque, IP, état d'une VM) qui échoue vaut « inconnu », pas
        # un arrêt. Les remplir d'un « $null = $_ » pour faire taire la règle
        # serait du bruit sans information.
        'PSAvoidUsingEmptyCatchBlock'
    )

    Rules = @{
        # Le projet vise PowerShell 5.1 sur Windows 11, rien d'autre.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
