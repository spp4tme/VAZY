# Documentation de vazy — par où entrer

## Si vous voulez…

| … | Allez voir |
|---|---|
| **utiliser vazy** | [README](../README.md) — démarrage rapide, puis 20 sections par sujet |
| **la syntaxe exacte d'une commande** | `vazy help`, ou la [référence des commandes](../README.md#15-référence-des-commandes) |
| **régler un problème** | le [dépannage](../README.md#16-dépannage), en huit rubriques |
| **comprendre pourquoi c'est fait comme ça** | l'[architecture](../README.md#18-architecture) |
| **modifier le code** | [CONTRIBUTING](../CONTRIBUTING.md) |
| **lancer ou écrire des tests** | [tests/README](../tests/README.md) |
| **savoir ce qui a changé** | [CHANGELOG](../CHANGELOG.md) |
| **écrire un pilote pour un autre hyperviseur** | l'en-tête de `lib/pilote-vmware.ps1` — c'est la spécification, et un test vérifie qu'elle reste complète |
| **utiliser VirtualBox** | [PILOTE-VIRTUALBOX](PILOTE-VIRTUALBOX.md) |
| **éviter un piège déjà rencontré** | [PIEGES](PIEGES.md) |

## Les documents de ce dossier

### [PILOTE-VIRTUALBOX.md](PILOTE-VIRTUALBOX.md)

Le second pilote : ce qu'il prouve sur l'architecture, et surtout les **écarts
réels** avec VMware — identité des machines, `--set` sans équivalent exact,
réseau host-only absent par défaut, écran distant en RDP, segments plus simples.
Contient l'état de vérification, honnête : ce pilote n'a jamais tourné face à un
vrai VirtualBox, et le document donne l'ordre de test recommandé.

### [PIEGES.md](PIEGES.md)

Ce qu'on a appris en se cognant : le blocage sur les tuyaux hérités qui figeait
l'outil, un diagnostic trop vite écrit et pourquoi il était faux, les angles de
PowerShell 5.1, les règles des clones liés, les comportements de VMware à
connaître, et les façons d'écrire un test qui passe pour de mauvaises raisons.

À lire avant de chercher longtemps.

## Où la documentation vit ailleurs

Une partie de la documentation n'est pas dans des fichiers Markdown, et c'est
volontaire — elle est là où on la cherche :

- **`vazy help`** : la syntaxe, toujours à jour puisqu'elle est dans le code.
- **L'en-tête de `lib/pilote-vmware.ps1`** : la spécification du contrat de
  pilote. Deux tests vérifient qu'aucune fonction ni clé du contrat n'y manque —
  une documentation qui ne peut pas se périmer en silence.
- **Les messages d'erreur** : chacun dit ce qui a raté **et** quoi faire
  ensuite. C'est la règle la plus visible du projet ; un message qui ne propose
  pas de suite est considéré comme incomplet.
- **Les commentaires du code** : ils expliquent le *pourquoi*, jamais le *quoi*.
  Le quoi se lit dans le code.
