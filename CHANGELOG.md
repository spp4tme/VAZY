# Journal des modifications

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).
Ce projet suit le [versionnage sémantique](https://semver.org/lang/fr/).

## [Non publié]

### Ajouté

- Suite de tests Pester (66 tests) qui tourne **sans VMware installé** : la
  couche pilote est remplacée par un faux pilote tenant l'état en mémoire et
  journalisant les appels reçus. Voir `tests/README.md`.
- Intégration continue GitHub Actions sur Windows : PSScriptAnalyzer, Pester,
  analyse syntaxique et contrôle d'encodage des fichiers PowerShell.
- `LICENSE` (MIT), `CONTRIBUTING.md`, et ce fichier.
- `$env:VAZY_PILOTE` impose un fichier de pilote précis. Sans effet quand la
  variable est absente ; sert aux tests à injecter le faux pilote.
- **Second pilote : Oracle VirtualBox** (`vazy config hyperviseur virtualbox`).
  Contrat complet via `VBoxManage`. Jamais exécuté face à un vrai VirtualBox :
  écarts, limites et ordre de test dans `docs/PILOTE-VIRTUALBOX.md`.
- Test de conformité des pilotes : le contrat est extrait des faits et exigé de
  chaque pilote, et l'absence de terme propre à un hyperviseur dans les couches
  1 et 2 est vérifiée par analyse syntaxique.
- **Segments réseau isolés.** `vazy net add|list|rm`, option `--reseau-nomme`
  répétable, et clé `reseau-nomme` dans les fichiers de labo. Là où `hostonly`
  met toutes les VM sur le même réseau, un segment ne relie que celles qu'on y
  branche : de quoi monter un TP de routage ou de segmentation.
  Trois fonctions ajoutées au contrat du pilote : `Get-ReseauxNommes`,
  `New-ReseauNomme`, `Remove-ReseauNomme`.

### Corrigé

- `lab export` réécrit les segments sous leur nom parlant et non sous
  l'identifiant du pilote : un labo exporté redevient relisible sur une autre
  machine.
- Un montage de labo interrompu ne laisse plus de VM à moitié créées. Si la
  création d'une machine échoue, celles que **ce montage** venait de créer sont
  supprimées ; les VM du labo antérieures à la commande sont conservées.

### Modifié

- `Set-StrictMode -Version Latest` et `$ErrorActionPreference = 'Stop'` en tête
  des trois couches.
- Le protocole de l'écran distant vient du pilote (`SchemaAffichageDistant`) au
  lieu d'être figé sur `vnc://` dans la logique. Aucun changement visible sous
  VMware ; c'était la seule hypothèse d'hyperviseur restée dans la couche 2.

## [1.8.0] — 2026-09-09

### Ajouté

- Monter un labo sans écrire de JSON : `--vm nom:modele:ram` répétable, et
  `--save` pour enregistrer la description obtenue.
- Assistant interactif `vazy lab new`.
- Les labos sont retrouvés par leur nom court, rangés dans
  `%LOCALAPPDATA%\vazy\labos`.

## [1.7.0] — 2026-09-09

### Ajouté

- Écran d'une VM accessible depuis un autre appareil : `--vnc`, lien `vnc://`
  affiché, et commande `vazy vnc` pour activer ou couper l'accès.
- Port et mot de passe choisis par vazy ; le mot de passe n'apparaît que dans
  le lien affiché, jamais dans le journal.
- Documentation de l'accès à distance par SSH et Tailscale.

## [1.6.0] — 2026-09-08

### Ajouté

- `vazy doctor` : diagnostic de l'installation et du catalogue.
- `--dry-run` sur toutes les commandes, et journal de chaque opération.
- Empreinte des disques de base du modèle, vérifiée avant chaque démarrage.
- `vazy freeze` : convertit un clone lié en VM autonome.
- `vazy lab export` et prérequis de labo, `vazy template alias`.

## [1.5.0] — 2026-09-08

### Ajouté

- Personnalisation de l'invité **sans identifiant**, par `guestinfo` : vazy
  dépose la configuration dans le descripteur de la VM, un script installé dans
  le modèle la lit au démarrage. vazy n'entre jamais dans la VM.
- Scripts d'invité pour Linux et Windows, avec leur installeur.
- `vazy template mark <alias> --guestinfo`.

## [1.4.0] — 2026-09-08

Regroupe les versions 1.1 à 1.4, livrées en une fois.

### Ajouté

- Remise à zéro et instantanés : `reset`, `snap`, `snaps`, `back`, `unsnap`,
  point de retour `vazy-neuf` pris à la création.
- Marque de protection posée sur chaque modèle : le pilote refuse de lui-même
  tout démarrage, suppression ou opération d'instantané sur un modèle.
- VM éphémères `--tmp`, nettoyage paresseux, `vazy gc`.
- Labos : `lab up`, `lab status`, `lab down`, fichier JSON, dépendances entre
  machines et délai entre deux démarrages.
- Personnalisation de l'invité par identifiants, `template creds`,
  `--hostname`.

## [1.0.0] — 2026-09-07

### Ajouté

- Création d'une VM par clone lié, en une commande.
- Options `--name`, `--ram`, `--cpu`, `--mode`, `--nogui`, `--nostart`.
- `--set cle=valeur` : accès direct à n'importe quel paramètre du descripteur.
- Catalogue des VM, gestion des modèles (`template add/list/rm`),
  configuration (`vazy config`).
- Architecture en trois couches : interface, logique, pilote.
