# Tests de vazy

66 tests, qui tournent **sans VMware installé** et sans toucher à vos vraies VM.

```powershell
Invoke-Pester -Path .\tests
```

## Pourquoi ça marche sans hyperviseur

vazy est découpé en trois couches, et la couche 3 (le pilote) a le monopole de
tout ce qui parle à l'hyperviseur. Les tests remplacent cette couche par un
**faux pilote** qui tient l'état des machines en mémoire et note chaque appel
reçu. On peut alors vérifier non seulement ce que la logique a demandé, mais
surtout **ce qu'elle n'a pas demandé** — qu'aucun clonage n'a eu lieu avant la
validation du nom, par exemple.

C'est tout l'intérêt de la séparation en couches, rendu concret.

## Organisation

| Dossier | Contenu |
|---|---|
| `Fakes\pilote-fake.ps1` | Le faux pilote : contrat complet, journal des appels, échecs programmables |
| `Aide\Environnement.ps1` | Le harnais : `%VAZY_HOME%` jetable, messages capturés, raccourcis de mise en place |
| `Logic\` | Tests unitaires de la couche 2, pilote mocké |
| `Integration\` | Chemins critiques à travers les trois couches, via `vazy.cmd` |

## Comment le faux pilote est branché

`lib\logique.ps1` choisit son pilote d'après la configuration
(`lib\pilote-<hyperviseur>.ps1`). Une seule ligne y a été ajoutée pour les
tests : `$env:VAZY_PILOTE` impose un fichier précis. Hors tests, la variable
n'existe pas et rien ne change.

Un fichier de test commence donc toujours ainsi :

```powershell
. "$PSScriptRoot\..\Aide\Environnement.ps1"
Initialize-VazyTest | Out-Null
. (Get-CheminLogique)
```

Le point-source **au premier niveau du fichier** est obligatoire. Chargée
depuis l'intérieur d'une fonction, la logique disparaîtrait avec la portée de
celle-ci ; c'est aussi ce qui permet à `Reset-EtatVazy` d'atteindre les
variables `$script:` de la logique, qui vivent alors dans la même portée.

Puis, dans chaque `Describe` :

```powershell
BeforeEach { Reset-EtatVazy }
```

## Écrire un test

```powershell
It 'refuse un nom deja pris sans rien creer' {
    New-ModeleTest -Alias 'ubuntu' | Out-Null
    New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage | Out-Null

    { New-VmDepuisModele -Modele 'ubuntu' -Nom 'poste1' -SansDemarrage } | Should Throw
    (Test-AppelPilote 'New-MachineDepuisModele') | Should Be $false
}
```

### Ce que fournit le harnais

| Fonction | Rôle |
|---|---|
| `Reset-EtatVazy` | Catalogue vide, configuration par défaut, journal des appels vidé |
| `New-ModeleTest -Alias` | Déclare un modèle utilisable (passe par le vrai `Add-Modele`) |
| `Get-MessagesTest [-Type]` | Les messages émis (`ok`, `info`, `attention`…) |
| `Test-MessageTest -Fragment` | Un message contenant ce fragment a-t-il été émis ? |
| `Get-RacineTest` | Le dossier jetable de l'exécution en cours |

### Ce que fournit le faux pilote

| Fonction | Rôle |
|---|---|
| `Get-AppelsPilote [-Fonction]` | Les appels reçus, avec leurs paramètres et leur ordre |
| `Test-AppelPilote -Fonction` | La fonction a-t-elle été appelée ? |
| `Set-EchecPilote -Fonction [-Saut] [-Fois]` | Programme un échec, éventuellement après N appels |
| `Get-EtatMachineFake -Chemin` | L'état d'une machine : RAM, CPU, réseau, instantanés… |
| `Set-MachineEnMarcheFake -Chemin` | Simule un arrêt ou un démarrage extérieur à vazy |
| `Register-ModeleFake -Chemin` | Déclare un modèle côté hyperviseur, avec son empreinte |

## Ce qui est couvert

- **Valeurs par défaut** : 2 Go, 2 CPU, une carte NAT ; le point de retour
  `vazy-neuf` pris avant tout démarrage ; les réglages `--set` transmis tels quels.
- **Refus avant tout appel au pilote** : nom invalide ou accentué, mot réservé,
  modèle inconnu, nom déjà pris, `--tmp` avec `--nostart`, instantané d'ancrage
  disparu. Chaque cas vérifie qu'aucun clonage n'a été demandé.
- **VM éphémères** : le nettoyage ne supprime **jamais** une VM non marquée,
  ne coûte aucun appel quand il n'y a rien à faire, et ne supprime rien au-delà
  du seuil sans confirmation.
- **Protection du modèle** : refus au niveau du pilote (sur la seule marque,
  sans consulter le catalogue) **et** au niveau de la logique.
- **Empreinte** : taille changée ou disque disparu bloquent le démarrage, date
  seule changée avertit sans bloquer, une VM `freeze` n'est plus vérifiée.
- **Labos** : ordre topologique, refus des cycles et dépendances inconnues,
  idempotence de `lab up`, et retour arrière borné aux VM créées par le montage.
- **Intégration** : cycle de vie complet, `--dry-run` qui ne modifie rien,
  et lecture d'un fichier de labo (JSON invalide, virgule finale, clé inconnue
  au niveau du labo ou d'une machine — le message doit nommer les deux).

La couche 1 (interface) n'est couverte que par les tests d'intégration, et la
couche 3 pas du tout : la vérifier demanderait un vrai hyperviseur.

## Pièges de PowerShell 5.1 rencontrés ici

Ils sont notés parce qu'ils coûtent chacun une demi-heure quand on les
redécouvre.

- **`@()` sur une `List[object]` vide** lève « Les types des arguments ne
  correspondent pas ». Utiliser `.ToArray()`.
- **Une fonction qui renvoie un tableau d'un seul élément le déballe** en
  scalaire ; `.Count` échoue ensuite sous `Set-StrictMode`. Envelopper l'appel
  dans `@(...)`.
- **Le pipe se lie plus fort que `-or`** : `(a) -or (b) | Should Be $true` ne
  teste pas ce qu'on croit. Calculer d'abord dans une variable.
- **Les accents dans les motifs de recherche** : préférer un fragment sans
  accent, surtout pour la sortie d'un sous-processus qui traverse la console.
- **Les fichiers `.ps1` sont en UTF-8 avec BOM.** Sans BOM, PowerShell 5.1 les
  lit en ANSI et les accents deviennent illisibles.

## Version de Pester

Pester **3.4.0**, celui livré avec Windows — donc rien à installer. La CI
l'impose explicitement, pour que le résultat local et le résultat en CI soient
identiques.

La syntaxe diffère de Pester 5 : `Should Be` et non `Should -Be`, et aucune
phase de découverte séparée (les variables d'un `Describe` sont visibles dans
les `It`).
