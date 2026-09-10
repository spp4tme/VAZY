# Contribuer à vazy

## Lancer les tests

```powershell
Invoke-Pester -Path .\tests
```

66 tests, qui tournent **sans VMware installé** : la couche pilote est
remplacée par un faux pilote en mémoire. Rien à installer — Pester 3.4.0 est
livré avec Windows, et c'est la version qu'impose la CI.

Le détail est dans [tests/README.md](tests/README.md) : comment le faux pilote
est branché, ce que fournit le harnais, et les pièges de PowerShell 5.1
rencontrés en écrivant ces tests.

## La règle des trois couches

C'est la contrainte structurante du projet. Elle n'est pas négociable, parce
que c'est elle qui rend le code testable sans hyperviseur et portable vers un
autre.

| Fichier | Rôle | N'a pas le droit de |
|---|---|---|
| `lib/interface.ps1` | Lire les arguments, valider leur forme, afficher | prendre une décision métier |
| `lib/logique.ps1` | Décider : quoi créer, dans quel ordre, quoi refuser | connaître `vmrun` ou le format `.vmx` |
| `lib/pilote-<x>.ps1` | Parler à l'hyperviseur | rien savoir du catalogue ni des labos |

**Le pilote est la seule couche qui connaît l'hyperviseur.** Aucun nom de
commande, aucun format de fichier propre à VMware ne doit apparaître ailleurs.
Vérification rapide avant de proposer un changement :

```powershell
Select-String -Path .\lib\interface.ps1, .\lib\logique.ps1 -Pattern 'vmrun|\.vmx|vmnet|vnetlib'
```

Cette commande doit ne rien renvoyer, sauf dans des chaînes de message
destinées à l'utilisateur.

## Où va quoi

- **Une nouvelle option de ligne de commande** : l'analyse et la validation de
  forme dans `interface.ps1`, la décision dans `logique.ps1`.
- **Une nouvelle opération sur une VM** : ajoutez-la au contrat, en tête de
  `lib/pilote-vmware.ps1`, puis implémentez-la dans **chaque** pilote et dans
  `tests/Fakes/pilote-fake.ps1`. Un contrat qu'un seul pilote honore n'est pas
  un contrat.
- **Une règle métier** : dans `logique.ps1`, avec un test dans `tests/Logic/`.
- **Un message d'erreur** : il dit ce qui a raté **et** quoi faire ensuite.
  C'est la règle la plus visible du projet ; voir `New-ErreurOutil`.

## Deux points d'accroche uniques

Ils existent pour que le journal, `--dry-run` et le masquage des mots de passe
soient garantis en un seul endroit. Ne les contournez pas.

- **`Invoke-Vmrun`** : toute commande envoyée à l'hyperviseur y passe.
- **`Write-FichierVmx`** : toute écriture de configuration de VM y passe.

## Style

- Français partout : noms de fonctions, commentaires, messages.
- `Set-StrictMode -Version Latest` et `$ErrorActionPreference = 'Stop'` en tête
  de chaque fichier.
- Fichiers `.ps1` en **UTF-8 avec BOM**. Sans BOM, PowerShell 5.1 les lit en
  ANSI et les accents deviennent illisibles. La CI le vérifie et refuse le
  contraire.
- **Zéro dépendance d'exécution.** vazy doit fonctionner sur un Windows 11 nu
  avec VMware Workstation, sans rien installer d'autre. Pester et
  PSScriptAnalyzer sont des outils de développement, jamais requis à
  l'exécution.
- Rétrocompatibilité : aucune commande, option ou format de fichier existant ne
  change de comportement. Le catalogue est versionné et migré automatiquement
  (voir `Read-Catalogue`).

## Commits

Un commit par changement logique, avec un préfixe : `feat:`, `fix:`, `test:`,
`ci:`, `docs:`, `refactor:`. Le message explique **pourquoi**, pas seulement
quoi : le quoi se lit dans le diff.

## Avant de proposer un changement

1. `Invoke-Pester -Path .\tests` est vert.
2. Le comportement nouveau ou corrigé a son test.
3. La règle des trois couches est respectée.
4. Le README reste juste (l'enrichir plutôt que le refondre), et
   `CHANGELOG.md` mentionne le changement sous « Non publié ».
