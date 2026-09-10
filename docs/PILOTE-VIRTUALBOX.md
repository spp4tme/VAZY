# Pilote VirtualBox

`lib/pilote-virtualbox.ps1` implémente le contrat de pilote de vazy via
`VBoxManage`. Il sert deux buts : permettre d'utiliser vazy sur une machine
sans VMware, et **mettre l'architecture à l'épreuve**.

```powershell
vazy config hyperviseur virtualbox
```

## Ce que ce pilote prouve

Écrire un second pilote n'a demandé **aucune modification des couches 1 et 2**,
à une exception près, décrite plus bas. Le point d'entrée, l'analyse des
arguments, le catalogue, les labos, les VM éphémères, les instantanés, la
protection du modèle : rien n'a bougé.

C'est vérifié mécaniquement, pas affirmé. `tests/Logic/Contrat.Tests.ps1` :

- extrait le contrat des faits (les fonctions du pilote que la logique appelle),
  et non du commentaire qui le décrit ;
- exige que **chaque** pilote — VMware, VirtualBox, et le faux pilote des tests —
  définisse ces fonctions avec les mêmes paramètres ;
- refuse tout terme propre à un hyperviseur (`vmrun`, `VBoxManage`, `.vmx`,
  `vmnet`, `vnetlib`) dans le code des couches 1 et 2, en analysant l'arbre
  syntaxique pour ne pas confondre code et message affiché à l'utilisateur ;
- vérifie qu'aucune commande `VBoxManage` ne part d'ailleurs que du point de
  passage unique `Invoke-VBoxManage`.

## L'exception : le protocole de l'écran distant

La couche logique construisait un lien `vnc://` en dur. C'était le seul endroit
où elle présupposait un hyperviseur : VMware Workstation Pro embarque un
serveur VNC, VirtualBox non.

Corrigé par le point d'extension déjà prévu — la description que renvoie
`Initialize-Pilote` — qui porte désormais une clé `SchemaAffichageDistant`. La
logique lit le protocole au lieu de le supposer. Une ligne de la couche 2 a
donc bougé, et c'est le seul cas.

## Écarts réels avec VMware

### Identité des machines

Le contrat désigne une machine par le chemin de son descripteur. VMware ouvre
un `.vmx` au vol ; VirtualBox ne connaît que des machines **inscrites à son
registre**, désignées par nom ou UUID.

Le pilote fait la traduction (`Get-NomMachine`) : il tente d'abord le nom du
fichier, vérifie via `showvminfo --machinereadable` que le `CfgFile` correspond,
et balaie `list vms` sinon. Le résultat est mis en cache pour la durée du
processus.

**Conséquence** : une machine VirtualBox non enregistrée est invisible pour
vazy. Le message d'erreur donne la commande `registervm` à taper.

**Conséquence** : VirtualBox impose des **noms uniques sur toute
l'installation**, pas seulement dans un dossier. Deux labos qui voudraient une
VM du même nom entrent en conflit — le préfixe `<labo>-<machine>` de vazy évite
le problème en pratique.

### Réglages bruts (`--set`)

C'est l'écart le plus important, et il est irréductible.

Sous VMware, `--set cle=valeur` écrit une ligne dans le `.vmx`, un fichier de
configuration en texte libre. **VirtualBox n'a pas d'équivalent** : sa
configuration est un XML structuré que `VBoxManage` refuse de laisser modifier
arbitrairement.

Le pilote envoie donc les réglages bruts vers `setextradata`, qui attache des
données supplémentaires à la machine. Ce n'est **pas** la même chose : une clé
`.vmx` change le comportement de la VM, une donnée `extradata` n'est lue que par
ce qui sait la chercher.

Autrement dit : `--set` reste utile sous VirtualBox pour les réglages que
VirtualBox expose par `extradata` (`GUI/...`, `VBoxInternal/...`), mais un
`--set` écrit pour VMware n'a aucune raison de fonctionner tel quel.

### Réseau

| | VMware | VirtualBox |
|---|---|---|
| `nat` | VMnet8, fourni | `--nic<n> nat`, fourni |
| `bridged` | VMnet0, automatique | `--bridgeadapter<n>` : il faut **nommer** l'interface hôte |
| `hostonly` | VMnet1, fourni d'office | **aucun réseau host-only par défaut** |

Le pilote choisit la première interface disponible (`list bridgedifs`,
`list hostonlyifs`). S'il n'y a aucun réseau host-only, il refuse avec la
commande à taper : `VBoxManage hostonlyif create`.

Les cartes au-delà de celles demandées sont explicitement débranchées
(`--nic<n> none`), pour que la machine reflète exactement ce qui a été demandé.

### Segments réseau isolés

C'est le seul domaine où VirtualBox est **plus simple** que VMware.

| | VMware | VirtualBox |
|---|---|---|
| Mécanisme | VMnet2 à VMnet19, via `vnetlib` | réseaux internes (`intnet`) |
| Création | commande explicite, **droits administrateur** | aucune : le réseau existe dès qu'une machine s'y rattache |
| Suppression | commande explicite | aucune : il disparaît quand plus personne ne l'utilise |
| Nombre | 18 au maximum | illimité |
| Adresse, DHCP | réglables | **aucun** : un réseau interne est un segment de niveau 2 |

`New-ReseauNomme` et `Remove-ReseauNomme` n'ont donc presque rien à faire côté
VirtualBox. Ce n'est pas un oubli : c'est la nature du mécanisme.

Conséquence pratique : `--adresse` et `--dhcp` sont **ignorés** sous VirtualBox,
et le pilote l'écrit au journal. Adressez les machines depuis l'intérieur, ou
placez un serveur DHCP dans le segment — ce qui est souvent l'exercice.

### Écran distant

VirtualBox n'expose pas de serveur VNC natif. Son mécanisme, VRDE, parle :

- **RDP** avec le pack d'extension Oracle — sans mot de passe simple ;
- **VNC** seulement si l'extension VNC est installée.

Le pilote détecte l'extension (`list extpacks`) et annonce le protocole obtenu.
Avec l'extension VNC, le mot de passe tiré par vazy s'applique et le lien
affiché est `vnc://`. Sans elle, le lien est `rdp://` et **le mot de passe de
vazy ne protège rien** : le pilote l'écrit au journal plutôt que de laisser
croire à une sécurité inexistante.

L'avertissement du README reste entier, et vaut davantage encore ici : ne jamais
exposer ce port à internet. Passez par Tailscale ou un tunnel SSH.

### Personnalisation de l'invité

`guestinfo.vazy_config` (VMware) devient la propriété d'invité `/vazy/vazy_config`
(VirtualBox). Le mécanisme est équivalent : la valeur est déposée sur une
machine éteinte et lue au démarrage depuis l'intérieur.

**Les scripts d'invité fournis dans `invite/` ne conviennent pas tels quels** :
ils lisent `vmtoolsd --cmd "info-get guestinfo.vazy_config"`. Sous VirtualBox il
faudrait `VBoxControl guestproperty get /vazy/vazy_config`. Ce portage n'est pas
fait.

### Exécution d'un script dans l'invité

Le repli par identifiants utilise `guestcontrol run`. Amélioration involontaire
au passage : `VBoxManage` accepte `--password-file`, ce qui évite de faire
passer le mot de passe par une ligne de commande visible de toute la machine
dans le gestionnaire des tâches. Le fichier temporaire est effacé dans un bloc
`finally`.

### Lancement des commandes

`VBoxManage startvm` lance `VirtualBoxVM.exe`, qui hérite des tuyaux de sortie
redirigés et les garde ouverts tant que la VM tourne — exactement le piège qui
figeait vazy côté VMware. Le pilote emploie donc le même motif : lecture
asynchrone, attente du **processus** avec un délai, puis on prend ce qui est
arrivé. Voir [PIEGES.md, piège n°1](PIEGES.md#1-une-commande-qui-rend-la-main-mais-dont-on-attend-la-sortie).

Ce point-là, au moins, est vérifié par des tests : ils reproduisent la situation
avec `powershell.exe`, sans hyperviseur.

### Conversion en machine autonome (`freeze`)

L'opération la plus délicate à porter. VMware clone en complet, supprime
l'ancienne VM, renomme le dossier : le chemin de la machine ne change pas.

VirtualBox impose des noms uniques et garde le chemin du descripteur dans son
registre. Le pilote enchaîne donc : clone complet sous un nom temporaire,
suppression de l'ancienne machine, désenregistrement du clone, déplacement du
dossier, ré-enregistrement, puis renommage. Chaque étape a son message d'erreur
indiquant où en est l'opération si elle s'interrompt.

**C'est le point le plus fragile de ce pilote.** À tester en premier.

## État de vérification

Soyons précis sur ce qui est vérifié et ce qui ne l'est pas.

| | État |
|---|---|
| Conformité au contrat (fonctions, paramètres) | vérifiée automatiquement |
| Validité syntaxique | vérifiée automatiquement |
| Point de passage unique des commandes | vérifié automatiquement |
| Lancement des commandes sans blocage sur les tuyaux | vérifié automatiquement |
| Non-régression des couches 1 et 2 | vérifiée par toute la suite |
| **Comportement face à un vrai VirtualBox** | **jamais exécuté** |

Ce pilote a été écrit d'après la documentation de `VBoxManage`, sans VirtualBox
installé sur la machine de développement. Les enchaînements de commandes sont
plausibles et les erreurs sont traitées, mais **aucune n'a été lancée pour de
vrai**. Attendez-vous à des ajustements sur le format exact de certaines
sorties.

Ordre de test recommandé, du plus sûr au plus fragile :

1. `vazy doctor`, `vazy template list` — lectures seules.
2. `vazy template add <chemin.vbox>` — enregistrement d'un modèle.
3. `vazy <modele> --nostart` — le clone lié.
4. `vazy start` / `vazy stop` / `vazy rm`.
5. `vazy snap` / `vazy back` / `vazy reset`.
6. `vazy lab up` / `vazy lab down`.
7. `vazy --vnc` — dépend du pack d'extension installé.
8. `vazy freeze` — en dernier, sur une VM dont vous vous moquez.

Utilisez `--dry-run` d'abord : il affiche chaque commande `VBoxManage` sans en
exécuter aucune.

## Ce qui reste à faire

- Porter les scripts d'invité de `invite/` vers `VBoxControl`.
- Choisir l'interface réseau autrement que « la première trouvée » : une option
  serait utile sur une machine à plusieurs cartes.
- Éprouver `freeze` sur du vrai VirtualBox.
