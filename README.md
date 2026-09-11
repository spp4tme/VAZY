# vazy

[![CI](https://github.com/spp4tme/VAZY/actions/workflows/ci.yml/badge.svg)](https://github.com/spp4tme/VAZY/actions/workflows/ci.yml)

**Une commande, une VM.**

```
vazy ubuntu-server --name TP14 --ram 4 --cpu 2
```

En quelques secondes, vazy crée un **clone lié** d'un modèle VMware, règle la mémoire, les processeurs et le réseau, puis démarre la machine. Aucun clic dans VMware Workstation, aucune installation de système : le système a été installé une seule fois, dans le modèle.

|  |  |
|---|---|
| **Système** | Windows 11, VMware Workstation Pro |
| **Langage** | PowerShell 5.1, livré avec Windows |
| **Dépendances** | aucune, rien à installer |
| **Version** | 1.8.0 |
| **Le nom** | « vas-y ». Quatre lettres, faciles à taper des milliers de fois. |

Ce que vazy sait faire, en une phrase chacun : créer une VM en quelques secondes, la remettre à neuf après l'avoir cassée, monter un TP entier de plusieurs machines en une ligne, en garder la recette pour la semaine suivante, donner à chaque clone son propre nom d'hôte sans jamais entrer dedans, montrer l'écran d'une VM sur un téléphone, et dire ce qui ne va pas quand quelque chose casse.

---

## Sommaire

1. [Démarrage rapide](#1-démarrage-rapide)
2. [Le principe : modèles et clones liés](#2-le-principe--modèles-et-clones-liés)
3. [Installation](#3-installation)
4. [Préparer un modèle](#4-préparer-un-modèle)
5. [Créer et gérer des VM](#5-créer-et-gérer-des-vm)
6. [Remise à zéro et instantanés](#6-remise-à-zéro-et-instantanés)
7. [VM éphémères](#7-vm-éphémères)
8. [Les labos : monter un TP entier](#8-les-labos--monter-un-tp-entier)
9. [Partager un labo](#9-partager-un-labo)
10. [Piloter et voir ses VM à distance](#10-piloter-et-voir-ses-vm-à-distance)
11. [Personnalisation de l'invité](#11-personnalisation-de-linvité)
12. [Protéger son travail : doctor, empreinte, freeze](#12-protéger-son-travail--doctor-empreinte-freeze)
13. [Régler n'importe quel paramètre avec `--set`](#13-régler-nimporte-quel-paramètre)
14. [Outillage : simulation, journal, configuration](#14-outillage--simulation-journal-configuration)
15. [Référence des commandes](#15-référence-des-commandes)
16. [Dépannage](#16-dépannage)
17. [Limites connues](#17-limites-connues)
18. [Architecture](#18-architecture)
19. [Historique des versions](#19-historique-des-versions)
20. [Contribuer, tester, réutiliser](#20-contribuer-tester-réutiliser)

---

## 1. Démarrage rapide

Si le modèle est déjà prêt et vazy installé, voici l'essentiel en dix lignes.

```
vazy ubuntu-server                       une VM, créée et démarrée
vazy ubuntu-server --name TP14 --ram 4   avec un nom et 4 Go
vazy list                                ce qui existe et son état
vazy reset TP14                          le TP est cassé : retour à l'état neuf
vazy stop TP14                           arrêt propre
vazy rm TP14                             suppression, fichiers compris

vazy ubuntu-server --tmp                 jetable : disparaît dès qu'elle est éteinte
vazy lab up tp14 --vm dc01:win2022:4 --vm client:win11:4 --save
vazy lab up tp14                         la semaine suivante, une seule commande
vazy doctor                              tout va bien ?
```

Si rien n'est encore en place, l'ordre est : [installer vazy](#3-installation), puis [préparer un modèle](#4-préparer-un-modèle) une fois pour toutes. Comptez une heure pour le premier modèle, quelques secondes pour chaque VM ensuite.

---

## 2. Le principe : modèles et clones liés

Un **modèle** est une VM que vous préparez une seule fois à la main : installation du système, mises à jour, outils d'intégration. Vous l'éteignez, vous prenez un **instantané**, et vous ne la démarrez plus jamais.

Chaque VM créée par vazy est un **clone lié** de cet instantané : elle ne stocke sur le disque que ses différences par rapport au modèle. La création est donc quasi instantanée, et dix VM Ubuntu coûtent à peu près le prix d'une seule.

Deux règles absolues en découlent.

**Un modèle ne se démarre jamais.** vazy refuse de le faire, et pose même un fichier témoin à côté du modèle pour que le refus vienne de la couche la plus basse, quoi qu'il arrive au catalogue.

**L'instantané d'un modèle ne se supprime jamais.** Le supprimer ou le « consolider » réécrit le disque de base, et tous les clones qui en dépendent deviennent inutilisables d'un coup.

Pour être précis sur le pourquoi : ce qui casse réellement les clones, c'est la modification du disque de base, donc la suppression de l'instantané. Démarrer le modèle après l'instantané écrit dans un disque de différences séparé et ne casse rien par soi-même. La règle « jamais démarré » reste la protection la plus simple : elle évite toute fausse manœuvre dans l'interface de VMware. La [procédure d'exception](#47-mettre-à-jour-un-modèle) explique comment mettre un modèle à jour quand c'est vraiment nécessaire.

**Vocabulaire employé dans ce document.**

| Terme | Sens |
|---|---|
| Modèle | La VM de référence, jamais démarrée, enregistrée dans vazy sous un alias court |
| Clone lié | Une VM créée par vazy, qui ne contient que ses différences avec le modèle |
| Instantané d'ancrage | L'instantané du modèle sur lequel les clones s'appuient, souvent nommé `base` |
| `vazy-neuf` | L'instantané pris sur chaque clone à sa création, cible de `vazy reset` |
| Catalogue | Le fichier où vazy note ses modèles et ses VM |
| Labo | Un ensemble de VM décrites ensemble, montées et démontées ensemble |
| Invité | Le système qui tourne dans la VM, par opposition à l'hôte |

---

## 3. Installation

**Prérequis** : VMware Workstation Pro. vazy cherche `vmrun.exe` dans `C:\Program Files (x86)\VMware\VMware Workstation\`, puis dans le registre, puis dans le PATH.

### 3.1 Poser le dossier

Copiez le dossier `vazy` à un emplacement stable, par exemple `C:\Outils\vazy`. Il contient :

```
vazy\
  vazy.cmd                 point d'entrée : c'est lui que vous tapez
  lib\interface.ps1        couche 1 : ligne de commande, fichiers de labo, affichage
  lib\logique.ps1          couche 2 : catalogue, vérifications, enchaînement
  lib\pilote-vmware.ps1    couche 3 : vmrun et fichiers .vmx
  exemples\                exemple de fichier de labo
  invite\linux\            script d'auto-configuration pour un modèle Linux
  invite\windows\          le même pour un modèle Windows
  README.md
```

### 3.2 Ajouter au PATH

Avec PowerShell, une seule fois, en adaptant le chemin :

```powershell
$dossier = 'C:\Outils\vazy'
$actuel = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', ($actuel.TrimEnd(';') + ';' + $dossier), 'User')
```

Ou par l'interface : touche Windows, tapez « variables d'environnement », ouvrez « Modifier les variables d'environnement pour votre compte », sélectionnez `Path` dans la partie « Variables utilisateur », « Modifier », « Nouveau », collez le chemin, validez.

Fermez et rouvrez votre terminal, puis vérifiez :

```
vazy help
```

Le bas de l'aide affiche où vazy a trouvé `vmrun.exe` et où il range ses fichiers.

### 3.3 Points d'installation à connaître

**Politique d'exécution des scripts : rien à changer.** `vazy.cmd` lance PowerShell avec `-ExecutionPolicy Bypass` pour ses propres scripts seulement ; la politique de votre session n'est pas modifiée. C'est aussi pourquoi le point d'entrée est un `.cmd` et non un `.ps1` : avec la politique `Restricted` par défaut de Windows 11, un `.ps1` posé dans le PATH échouerait, et PowerShell le préférerait au `.cmd`.

**Où seront créées les VM.** Par défaut, dans le dossier parent du modèle, donc sur le même disque. Pour choisir :

```
vazy config dossierVms D:\VMs
```

Évitez un dossier synchronisé par OneDrive : les disques virtuels changent en permanence et la synchronisation ne suivra pas.

### 3.4 Auto-complétion, facultative

Une ligne dans votre profil PowerShell, et la touche Tab connaît vos VM :

```powershell
. "C:\chemin\vers\vazy\outils\completion.ps1"
```

Pour l'ajouter une fois pour toutes :

```powershell
Add-Content -Path $PROFILE -Value '. "C:\chemin\vers\vazy\outils\completion.ps1"'
```

Ce que Tab propose, selon l'endroit de la ligne : les commandes et vos modèles en premier mot, vos VM après `start`, `stop`, `rm`, `reset`, `snap`, `back`, `freeze`, `vnc`, vos labos après `lab up`, vos modèles après `pop` et `pool create`, vos segments après `net rm`, et les options dès que vous tapez un tiret.

Le fichier lit le catalogue **directement** : il n'appelle jamais vazy. Une complétion doit répondre instantanément, et surtout n'avoir aucun effet de bord — lancer vazy déclencherait le nettoyage des VM éphémères à chaque appui sur Tab.

Il ne change le comportement d'aucune commande. Sans lui, tout fonctionne pareil, en tapant les noms en entier.

---

## 4. Préparer un modèle

À faire une seule fois par système. Comptez le temps d'une installation classique, c'est la dernière.

Deux variantes, qui ne diffèrent qu'à l'étape 4.3.

**Modèle guestinfo, recommandé.** Un petit script est installé dans le modèle. Au démarrage de chaque clone, il lit la configuration que vazy a déposée de l'extérieur et se configure lui-même. vazy n'entre jamais dans la VM : aucun identifiant nulle part, aucun compte privilégié cloné dans vos machines.

**Modèle classique, repli.** Pour un modèle que vous ne pouvez pas modifier. La personnalisation passe alors par un compte de l'invité que vazy utilise depuis l'hôte. Ce compte privilégié se retrouve dans **toutes** vos VM, y compris celles que vous posez sur un segment réseau pendant un TP de sécurité. Réservez cette variante aux cas sans alternative.

### 4.1 Créer la VM dans VMware Workstation

1. `File > New Virtual Machine`, mode `Typical`.
2. Choisissez l'ISO d'installation.
3. **Nom de la VM** : il deviendra l'alias du modèle. Court, sans espace, par exemple `ubuntu-server`. **Emplacement** : un dossier dédié, par exemple `D:\VMs\ubuntu-server`.
4. **Disque** : donnez une taille maximale large, par exemple 200 Go, et gardez `Store virtual disk as a single file`. Ne cochez **pas** « Allocate all disk space now » : le disque est dynamique, il ne consomme que ce qui est réellement écrit. C'est ce qui permet de ne jamais avoir à le redimensionner ensuite.
5. Matériel : laissez les valeurs par défaut. Mémoire, processeurs et cartes réseau seront redéfinis par vazy sur chaque clone.

### 4.2 Installer et préparer le système

1. Installez le système normalement.
2. Installez les outils d'intégration, indispensables :
   - Ubuntu Server, Debian : `sudo apt install open-vm-tools` (l'installeur Ubuntu le fait souvent tout seul).
   - Windows : menu `VM > Install VMware Tools`, puis lancez l'installation depuis le lecteur CD virtuel.

   Sans eux, `vazy stop` ne peut pas demander d'arrêt propre, et la personnalisation ne fonctionne pas.
3. Faites les mises à jour, installez ce que tous vos TP auront en commun : éditeur, serveur SSH, outils réseau.
4. Nettoyez : `sudo apt clean` sous Linux, et retirez l'ISO du lecteur CD virtuel (`VM > Settings > CD/DVD`, décochez `Connect at power on`).

### 4.3 Installer l'auto-configuration (variante recommandée)

Les fichiers sont dans le dossier `invite` de vazy.

**Linux, avec systemd.** Un seul fichier à transférer, `invite\linux\installer.sh`, qui contient le script et son unité systemd. Depuis Windows, avec l'adresse IP de la VM que vous obtenez par `ip a` dedans :

```
scp "C:\Outils\vazy\invite\linux\installer.sh" etudiant@192.168.x.y:/tmp/
```

Puis dans la VM :

```
sudo sh /tmp/installer.sh
```

Ce que cela installe : `/usr/local/sbin/vazy-guestinfo`, un script POSIX sans dépendance, et `vazy-guestinfo.service`, une unité systemd lancée à chaque démarrage **avant le réseau**. À chaque démarrage, ce script :

- lit la variable `guestinfo.vazy_config` avec `vmtoolsd --cmd "info-get ..."` ;
- applique le nom d'hôte demandé, par `hostnamectl` si D-Bus répond déjà, sinon en écrivant directement `/etc/hostname`, puis met à jour la ligne `127.0.1.1` de `/etc/hosts` ;
- régénère les clés d'identité du serveur SSH et `/etc/machine-id` lorsqu'elles proviennent d'une autre machine. L'identifiant matériel change à chaque clone, et le script mémorise celui pour lequel il a généré les clés dans `/var/lib/vazy/identite.uuid`. Sans cela, tous vos clones auraient la même empreinte SSH, et deux clones Ubuntu demanderaient la même adresse au serveur DHCP ;
- ne fait rien si la variable est absente, vide, ou si tout est déjà en place. Il est idempotent et ne redémarre jamais la machine.

Pas de `scp` sous la main ? Ouvrez `installer.sh` dans un éditeur sur Windows, collez son contenu dans la VM avec `cat > /tmp/installer.sh` puis `Ctrl+D`. Le fichier livré est en fins de ligne LF, gardez-les.

**Windows.** Copiez le dossier `invite\windows` dans la VM par un dossier partagé, `scp` ou une clé USB, puis en administrateur :

```
powershell -ExecutionPolicy Bypass -File installer.ps1
```

Cela installe `C:\ProgramData\vazy\vazy-guestinfo.ps1` et une tâche planifiée `vazy-guestinfo` lancée au démarrage sous le compte SYSTEM. Elle lit la variable avec `vmtoolsd.exe`, applique `Rename-Computer` seulement si le nom diffère, redémarre une seule fois après un renommage effectif, puisque Windows ne prend un nouveau nom qu'au redémarrage, et régénère les clés du serveur OpenSSH s'il est installé. Son journal est dans `C:\ProgramData\vazy\vazy-guestinfo.log`. Le SID de la machine, lui, reste celui du modèle : seul `sysprep` le change, et c'est hors périmètre.

Passez ensuite à l'étape 4.5.

### 4.4 Variante classique : un compte pour vazy

Rien à installer dans le modèle, mais il faut un compte que vazy utilisera depuis l'hôte pour exécuter le renommage après le démarrage :

- Linux : un compte pouvant faire `sudo` **sans mot de passe**, ou `root`. Par exemple `echo "etudiant ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/vazy`.
- Windows : le compte `Administrateur` intégré, activé, avec un mot de passe. Un administrateur ordinaire est bloqué par le contrôle de compte, que VMware ne sait pas contourner.

Ce compte sera présent dans chaque clone. Après l'enregistrement du modèle, déclarez-le avec `vazy template creds <alias>`.

### 4.5 Nettoyer l'identité réseau (Linux, obligatoire)

Un clone reçoit de **nouvelles cartes réseau**, avec de nouvelles adresses matérielles. Si le modèle a mémorisé l'ancienne carte, le clone se retrouve avec une interface qui ne correspond à rien et **n'a plus de réseau du tout**. Avant d'éteindre le modèle, vérifiez ces six points.

1. **netplan, sur Ubuntu** : `cat /etc/netplan/*.yaml`. S'il contient `match: macaddress:` ou `set-name:`, la configuration est liée à la carte du modèle. Remplacez-la par une configuration générique :

   ```yaml
   network:
     version: 2
     ethernets:
       toutes:
         match:
           name: "en*"
         dhcp4: true
   ```

   Si le fichier s'appelle `50-cloud-init.yaml`, cloud-init le régénérera au démarrage : désactivez sa gestion du réseau avec

   ```
   sudo sh -c 'echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
   ```

2. **Règles udev persistantes**, sur les systèmes plus anciens : `sudo rm -f /etc/udev/rules.d/70-persistent-net.rules`.
3. **Fichiers `.link` de systemd** qui lient un nom d'interface à une adresse matérielle : regardez `/etc/systemd/network/*.link` et supprimez ceux qui contiennent `MACAddress=`.
4. **NetworkManager**, sur les systèmes de bureau : dans `/etc/NetworkManager/system-connections/*.nmconnection`, retirez toute ligne `mac-address=`, ou supprimez les profils pour qu'il en recrée.
5. **Baux DHCP mémorisés** : `sudo rm -f /var/lib/dhcp/*.leases /var/lib/NetworkManager/*.lease` et `sudo rm -rf /run/systemd/netif/leases`.
6. **Identifiant machine** : `/etc/machine-id` sert d'identifiant DHCP à systemd-networkd. Le script guestinfo le régénère sur chaque clone. Pour un modèle classique, videz-le : `sudo truncate -s 0 /etc/machine-id`, systemd en génère un neuf au premier démarrage.

Vérification : `ip -br link` doit montrer une interface nommée `ens33` ou `ens160`. Ce nom vient de l'emplacement matériel et reste stable d'un clone à l'autre, contrairement à l'adresse MAC.

Windows n'a pas ce problème de réseau. Le SID dupliqué est un autre sujet, traité par `sysprep`, hors périmètre.

### 4.6 Éteindre, l'instantané, l'enregistrement

**Éteignez la VM proprement, depuis l'intérieur du système.** Puis, VM éteinte, dans VMware Workstation : `VM > Snapshot > Take Snapshot...`, nommez-le `base`.

En ligne de commande, au choix :

```
"C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe" -T ws snapshot "D:\VMs\ubuntu-server\ubuntu-server.vmx" base
```

Enregistrez le modèle dans vazy :

```
vazy template add "D:\VMs\ubuntu-server\ubuntu-server.vmx"
vazy template mark ubuntu-server --guestinfo
```

La seconde ligne ne concerne que la variante recommandée. Quelques précisions :

- L'alias par défaut est le nom du fichier sans extension. Pour en choisir un autre, `--name <alias>`.
- Si la VM a plusieurs instantanés, le dernier de la liste est retenu ; `--snapshot <nom>` en impose un.
- vazy refuse une VM sans instantané, et explique comment en créer un.
- vazy pose un fichier témoin à côté du modèle, `ubuntu-server.vmx.vazy-modele`. Tant qu'il existe, vazy refuse de démarrer, supprimer ou modifier les instantanés de cette VM, même si le catalogue est perdu ou modifié à la main.
- `template mark --guestinfo` indique que le script est installé. Dès lors, `--hostname` passe par le dépôt de configuration, sans identifiant. `vazy template list` affiche la méthode retenue pour chaque modèle.

C'est terminé. **Ne redémarrez plus jamais cette VM.** Créez vos machines :

```
vazy ubuntu-server --hostname web1
```

### 4.7 Mettre à jour un modèle

Si vous devez modifier le modèle, par exemple pour une nouvelle version d'un paquet, voici la seule façon sûre.

1. Démarrez le modèle dans VMware Workstation, faites les modifications, éteignez-le proprement.
2. Prenez un **nouvel** instantané, `base-2`. **Ne supprimez pas l'ancien** tant qu'un clone en dépend.
3. Ré-enregistrez le modèle sur ce nouvel instantané :

   ```
   vazy template rm ubuntu-server
   vazy template add "D:\VMs\ubuntu-server\ubuntu-server.vmx" --snapshot base-2
   ```

Les anciens clones continuent d'utiliser `base`, les nouveaux partent de `base-2`. Le jour où plus aucun clone ne dépend de `base`, vous pouvez le supprimer dans VMware ; `vazy doctor` vous dit combien de clones dépendent de chaque modèle.

---

## 5. Créer et gérer des VM

### 5.1 La commande principale

```
vazy <modele> [options]
```

Crée un clone lié du modèle, applique les options, démarre la VM. Toutes les options sont facultatives.

| Option | Rôle | Défaut |
|---|---|---|
| `--name <nom>` | Nom de la VM. Lettres, chiffres, `.`, `-`, `_` ; il sert aussi de nom de dossier | `<modele>-1`, `<modele>-2`, ... |
| `--ram <Go>` | Mémoire en Go, décimales acceptées (`1.5`, `0.5`) | `2` |
| `--cpu <n>` | Nombre de cœurs | `2` |
| `--reseau <n>` | Nombre de cartes réseau, `0` pour aucune | `1` |
| `--mode <m>` | `nat`, `bridged` ou `hostonly`, un mode par carte en répétant l'option | `nat` |
| `--set <cle>=<valeur>` | Écrit une ligne brute dans la configuration de la VM, répétable | |
| `--nogui` | Démarre sans ouvrir de fenêtre VMware | désactivé |
| `--nostart` | Crée sans démarrer | désactivé |
| `--tmp` | VM éphémère, supprimée dès qu'elle est trouvée éteinte. Incompatible avec `--nostart` | désactivé |
| `--hostname <nom>` | Nom d'hôte appliqué dans l'invité à chaque démarrage | aucun |
| `--vnc` | Écran accessible à distance ; `--vnc off` pour l'état par défaut | désactivé |
| `--dry-run` | N'exécute rien, montre ce qui serait fait | désactivé |

Exemples :

```
vazy ubuntu-server
vazy ubuntu-server --name TP14 --ram 4 --cpu 2
vazy win11 --mode nat --mode hostonly --nogui
vazy ubuntu-server --reseau 3 --mode bridged
vazy ubuntu-server --set svga.autodetect=FALSE --set usb.present=TRUE
```

### 5.2 Le réseau

Trois modes, qui correspondent aux réseaux virtuels standards de VMware.

| Mode | Réseau VMware | Ce que ça donne |
|---|---|---|
| `nat` | VMnet8 | La VM sort vers internet à travers l'hôte, invisible depuis le réseau local |
| `bridged` | VMnet0 | La VM est sur votre réseau local comme une machine physique, avec sa propre adresse |
| `hostonly` | VMnet1 | Réseau fermé entre les VM et l'hôte, sans accès à internet |

Avec `--mode nat --mode hostonly`, la première carte est en NAT et la seconde en host-only : c'est le classique « internet plus réseau de labo ». Si `--reseau` demande plus de cartes que de modes déclarés, les cartes supplémentaires reprennent le dernier mode.

**Piège PowerShell.** La forme `--mode "nat,hostonly"` fonctionne, mais les guillemets sont obligatoires, sinon PowerShell découpe sur la virgule et vazy reçoit deux arguments séparés. Même chose pour la mémoire : écrivez `--ram 1.5` avec un point, ou `--ram "1,5"` avec des guillemets.

Toutes les machines en `hostonly` partagent le même segment : deux labos montés en même temps en host-only se voient mutuellement. Pour un réseau réellement isolé, voir les [segments personnalisés](#53-segments-réseau-isolés).

### 5.3 Segments réseau isolés

`hostonly` met **toutes** vos VM sur le même réseau. Dès qu'un TP demande deux réseaux distincts — un routeur entre une DMZ et un LAN, une machine coupée du reste — il faut un segment personnalisé.

```
vazy net add labo-dmz --adresse 192.168.100.0
vazy net add labo-lan --adresse 192.168.200.0
```

Puis on y branche les VM :

```
vazy debian --name routeur --reseau-nomme labo-dmz --reseau-nomme labo-lan
vazy debian --name web     --reseau-nomme labo-dmz
vazy debian --name poste   --reseau-nomme labo-lan
```

Le routeur a deux cartes, une par segment ; `web` et `poste` ne se voient pas directement. `--reseau-nomme` se combine avec `--mode` — les cartes de `--mode` d'abord, celles des segments ensuite :

```
vazy debian --mode nat --reseau-nomme labo-dmz
```

Dans un fichier de labo, la clé s'appelle `reseau-nomme` et accepte un nom ou une liste :

```json
"routeur": { "modele": "debian", "reseau-nomme": ["labo-dmz", "labo-lan"] },
"web":     { "modele": "debian", "mode": "nat", "reseau-nomme": "labo-dmz" }
```

Les commandes :

| Commande | Effet |
|---|---|
| `vazy net list` | Segments déclarés, leur état réel, et les VM branchées dessus |
| `vazy net add <nom> [--adresse a.b.c.0] [--dhcp] [--hostonly]` | Crée un segment. Synonyme : `create` |
| `vazy net rm <nom> [--yes]` | Le supprime — refusé si des VM y sont encore branchées |

**Droits administrateur.** Sous VMware, créer ou supprimer un segment passe par `vnetlib`, qui exige une invite de commandes administrateur. Tout le reste de vazy fonctionne sans. Sous VirtualBox, aucun droit particulier : voir [docs/PILOTE-VIRTUALBOX.md](docs/PILOTE-VIRTUALBOX.md).

**Adresse et DHCP.** `--adresse` fixe le réseau du segment, `--dhcp` y ajoute un serveur d'adresses. Sans l'un ni l'autre, le segment est un simple câble : à vous d'adresser les machines depuis l'intérieur, ce qui est souvent le but en TP de réseau.

vazy vérifie avant chaque création de VM que le segment demandé existe toujours. Un segment supprimé à la main dans le Virtual Network Editor est signalé au lieu de donner une VM branchée dans le vide.

### 5.4 Ce que vous voyez

```
vazy : création d'une VM depuis le modèle « ubuntu-server »
[1/6] Vérifications
      modèle « ubuntu-server » (instantané « base »), destination D:\VMs\TP14, 214,3 Go libres
[2/6] Clonage lié
      D:\VMs\TP14\TP14.vmx créé en 6,8 s
[3/6] Réglages
      4 Go de RAM (4096 Mo), 2 CPU
[4/6] Réseau
      1 carte : nat
[5/6] Point de retour « vazy-neuf »
      instantané pris en 1,2 s (retour à cet état : vazy reset TP14)
[6/6] Démarrage
      VM « TP14 » démarrée en 4,1 s

VM « TP14 » prête et démarrée en 12,4 s.
  dossier : D:\VMs\TP14
  arrêter : vazy stop TP14     supprimer : vazy rm TP14
```

### 5.5 Le cycle de vie

| Commande | Effet |
|---|---|
| `vazy list` | Les VM créées par vazy, avec leur état, leur modèle, leur labo et leur écran distant |
| `vazy start <nom> [--nogui]` | Démarre |
| `vazy stop <nom> [--hard]` | Arrêt propre par les outils invité ; `--hard` coupe le courant |
| `vazy rm <nom> [--yes]` | Supprime la VM et tous ses fichiers, après confirmation ; arrêt forcé si elle tourne |

Les états affichés par `vazy list` : `en marche`, `arrêtée`, ou `absente` quand les fichiers ont disparu du disque en dehors de vazy.

vazy n'écrase jamais rien. Un nom déjà pris ou un dossier déjà présent produit un refus, pas un remplacement silencieux.

### 5.6 Réserve de VM chaudes

Créer une VM prend une trentaine de secondes, dont l'essentiel est le démarrage du système. L'idée de la réserve : **payer ce démarrage à l'avance**.

```
vazy pool create ubuntu-server --size 3     # une fois, tranquillement
vazy pop ubuntu-server --name TP14          # deux à trois secondes
```

`pool create` crée les clones, les démarre, puis les **suspend** : leur mémoire part sur le disque. `pop` en reprend une — VMware recharge la mémoire, la machine repart exactement où elle en était. Aucun redémarrage, donc aucun boot à attendre.

| Commande | Effet |
|---|---|
| `vazy pool create <modele> --size <n>` | Prépare `n` VM démarrées puis figées. Accepte les options de gabarit : `--ram`, `--cpu`, `--mode`, `--set` |
| `vazy pop <modele> [--name <nom>] [--hostname <h>]` | Réveille une VM, lui donne son identité, la sort de la réserve |
| `vazy pool status [<modele>]` | Stock disponible, état de chaque VM, place occupée |
| `vazy pool refill <modele> [--size <n>]` | Complète la réserve jusqu'à la taille voulue |
| `vazy pool destroy <modele> [--yes]` | Détruit la réserve et libère la place |

#### Le vrai problème : l'identité au réveil

C'est là que tout se joue, et ça mérite d'être compris avant de s'en servir.

Une machine suspendue fige **tout** : son nom d'hôte, son bail DHCP, ses clés SSH en mémoire, son horloge. Réveiller deux VM de la même réserve donnerait deux jumelles sur le réseau. Et comme il n'y a pas de redémarrage, le service `vazy-guestinfo` de l'invité — qui s'exécute au boot — ne se relance pas de lui-même.

La solution est une poignée de main entre vazy et l'invité :

1. Au moment de garnir la réserve, vazy dépose `mode: pool` dans la configuration de l'invité.
2. Le script du modèle reconnaît ce mode. Il fait le strict nécessaire — régénérer les clés SSH et l'identifiant machine, qui ne dépendent pas de l'identité demandée — puis **annonce qu'il est prêt** en posant une variable, et se met à attendre en tâche de fond.
3. vazy voit cette variable et suspend. L'attente est figée avec la machine.
4. Au `pop`, vazy dépose la vraie identité **avant** de reprendre. L'invité, qui attendait, la lit et l'applique : nom d'hôte, puis renouvellement du bail DHCP pour ne pas garder celui d'avant.

Tout cela suppose donc un modèle **marqué guestinfo**, avec le script d'invité à jour (voir [section 11](#11-personnalisation-de-linvité)).

#### Sans script à jour

Si le modèle porte un script d'ancienne génération, la variable n'arrive jamais. vazy ne reste pas bloqué : il retombe sur l'attente des outils invité plus un délai de repos, prévient, et fige quand même. La réserve fonctionne, mais **les VM réveillées gardent l'identité du modèle** — même nom d'hôte, même bail. Utilisable pour une VM isolée, à éviter pour un TP réseau.

#### Windows

Sous Windows, un renommage exige un redémarrage : la réserve perd alors une bonne part de son intérêt, puisqu'on repaye le boot qu'on voulait éviter. `pop` fonctionne et réveille bien la machine, mais si vous demandez un nom d'hôte, le renommage passera par la voie classique avec redémarrage.

**En clair : la réserve est faite pour Linux.** Sous Windows, elle ne vaut le coup que si le nom d'hôte vous est indifférent.

#### Ce que ça coûte

Une VM suspendue écrit sa mémoire sur le disque : une réserve de 3 VM à 4 Go, c'est 12 Go de plus, en plus des disques de différences. vazy vérifie la place avant de garnir, exactement comme pour une création, et `vazy pool status` affiche le coût réel.

#### Péremption

Si le modèle change — un instantané supprimé, un disque consolidé — les VM de la réserve deviennent inutilisables : elles démarreraient sur des disques qui ne sont plus les leurs. `vazy pool status` les marque **périmées** et `vazy pop` refuse de les servir, en indiquant quoi faire :

```
vazy pool destroy ubuntu-server
vazy pool create ubuntu-server --size 3
```

#### Ce qu'une VM de réserve n'est pas

Elle n'apparaît pas dans `vazy list` : c'est un stock, pas une machine de travail. Et elle n'est **jamais** ramassée par le nettoyage des VM éphémères, quel que soit son état.

---

## 6. Remise à zéro et instantanés

Un TP, par définition, on le casse. Plutôt que de recréer la VM :

```
vazy reset TP14
```

Juste après la création d'une VM, avant son premier démarrage, vazy prend automatiquement un instantané nommé `vazy-neuf`. `vazy reset` y revient : la VM est arrêtée si elle tourne, ramenée à l'état neuf, puis redémarrée. L'instantané ayant été pris machine éteinte, il n'y a aucun état mémoire à restaurer et le retour prend quelques secondes.

```
vazy : remise à zéro de « TP14 »
[1/3] Arrêt
      VM en marche : arrêt forcé (son état actuel est abandonné par le retour)
[2/3] Retour à l'instantané « vazy-neuf »
      terminé en 1,8 s
[3/3] Démarrage
      VM « TP14 » démarrée en 3,4 s

VM « TP14 » remise à neuf et redémarrée en 5,6 s.
```

Pourquoi un arrêt forcé plutôt qu'un arrêt propre ? Parce que tout ce qui s'est passé depuis l'instantané est de toute façon abandonné par le retour. Un arrêt propre ne protégerait rien et coûterait dix à trente secondes de plus.

Pour jalonner un TP long :

| Commande | Effet |
|---|---|
| `vazy snap TP14 avant-dhcp` | Instantané manuel. Sans libellé : `snap-<date>-<heure>` |
| `vazy snaps TP14` | Liste les instantanés et leur rôle |
| `vazy back TP14 avant-dhcp` | Revient à cet instantané puis redémarre ; `--nostart` pour ne pas redémarrer |
| `vazy unsnap TP14 avant-dhcp` | Supprime l'instantané, après confirmation |

Quelques règles :

- `vazy-neuf` est protégé. `snap` refuse de l'écraser, `unsnap` refuse de le supprimer.
- Un instantané pris VM en marche inclut la mémoire : plus long à prendre, et `back` ramènera la VM en marche dans cet état. Pour un jalon léger, prenez-le VM éteinte.
- Les instantanés d'un **modèle** ne sont jamais touchés par ces commandes. Le pilote refuse toute opération d'instantané sur une machine marquée modèle.
- Une VM créée avant la version 1.1 n'a pas de `vazy-neuf`. Pour l'ajouter une fois, VM éteinte et dans l'état que vous voulez retrouver : `vazy stop TP14` puis `vazy snap TP14 vazy-neuf`. C'est le seul cas où `snap` accepte ce libellé.

---

## 7. VM éphémères

Je teste une commande, j'éteins, il ne reste rien :

```
vazy ubuntu-server --tmp
```

La VM s'appelle `ubuntu-server-tmp-1`, se crée et démarre comme les autres, puis est marquée **éphémère** dans le catalogue. `vazy list` l'affiche avec `oui` dans la colonne TMP. Dès qu'elle est trouvée éteinte, elle est supprimée, fichiers compris.

Il n'y a aucun service en arrière-plan : le nettoyage est **paresseux**.

1. Au début de chaque commande vazy, quelle qu'elle soit, l'outil regarde s'il existe des VM éphémères au catalogue. S'il n'y en a pas, cela ne coûte rien, aucun appel à VMware. S'il y en a, il interroge leur état et supprime celles qui sont éteintes, une ligne par VM.
2. `vazy stop <nom>` sur une VM éphémère la supprime dans la foulée.
3. `vazy gc` lance le nettoyage à la demande et dit ce qu'il a fait.

```
vazy list
      VM éphémère « ubuntu-server-tmp-1 » éteinte : supprimée (D:\VMs\ubuntu-server-tmp-1)
NOM   ÉTAT   ...
```

Les garde-fous :

- Une VM non marquée éphémère n'est **jamais** supprimée par le nettoyage, quel que soit son état. La fonction de suppression refuse elle-même toute VM non marquée, indépendamment de l'appelant.
- Le marquage n'est posé qu'une fois la VM démarrée avec succès. Si le démarrage échoue, la VM reste une VM ordinaire, à examiner puis à supprimer à la main. Cela évite aussi qu'une commande vazy lancée dans un autre terminal pendant le démarrage ne la prenne pour une VM éteinte.
- Au-delà de trois VM éphémères à supprimer d'un coup, vazy demande confirmation : c'est probablement le signe d'une anomalie. Sans console interactive, rien n'est supprimé et le message renvoie vers `vazy gc --yes`.
- `--tmp` et `--nostart` sont incompatibles : une VM éphémère créée éteinte serait supprimée au lancement suivant.

**À savoir sur VMware Workstation** : fermer la fenêtre d'une VM ne l'éteint pas forcément. Selon la préférence `Edit > Preferences > Workspace`, elle continue de tourner en arrière-plan, et une éphémère qui tourne n'est pas supprimée. Pour en être sûr, éteignez depuis l'intérieur, ou utilisez `vazy stop`.

---

## 8. Les labos : monter un TP entier

Un labo, c'est plusieurs VM créées, réglées et démarrées ensemble, dans le bon ordre. Trois façons de le décrire.

### 8.1 En une ligne

C'est la façon normale :

```
vazy lab up tp14 --vm dc01:win2022:4 --vm srv01:win2022:2 --vm client:win11:4 --save
```

Chaque `--vm` décrit une machine au format `nom:modele:ram`, avec un quatrième champ facultatif pour le nombre de cœurs, `dc01:win2022:4:2`. La mémoire peut être omise, `dc01:win2022`, la valeur par défaut ou celle de `--ram` s'applique alors.

Les options générales valent pour **toutes** les machines du labo : `--mode`, `--vnc`, `--cpu`, `--ram`, `--nogui`, `--set`, `--delai`. Le nom de chaque machine lui sert aussi de nom d'hôte, et les machines démarrent dans l'ordre où vous les avez écrites, avec le délai entre chacune.

### 8.2 `--save` : garder la recette

vazy monte le labo, puis écrit le fichier correspondant aux VM réellement créées. La semaine suivante, une seule commande :

```
vazy lab up tp14
```

vazy retrouve le fichier tout seul, où que vous soyez : il cherche `tp14`, puis `tp14.json` dans le dossier courant, puis dans son dossier de labos, `%LOCALAPPDATA%\vazy\labos`, réglable par `dossierLabos`. C'est ce qui permet de remonter un TP depuis une session SSH sans se soucier du répertoire courant.

Deux choses à savoir. `--save` n'enregistre que les machines de la commande : si d'autres VM sont rattachées au même labo, vazy le signale et les laisse en place, et `lab down` les démontera quand même. Et il ne mémorise pas `--nogui`, qui décrit une façon de démarrer plutôt que la machine ; au remontage, les VM s'ouvriront en fenêtre. Ajoutez `"nogui": true` au fichier si vous les voulez toujours sans fenêtre.

Si le fichier existe déjà, vazy demande confirmation avant de le remplacer.

### 8.3 L'assistant

Pour un labo compliqué, ou quand vous ne connaissez pas encore les options :

```
vazy lab new tp14
```

Les questions viennent une par une, avec une valeur par défaut entre crochets : nombre de machines, délai entre démarrages, puis pour chacune son nom, son modèle choisi dans la liste affichée, sa mémoire, ses cœurs, son réseau, son écran distant, et si elle doit démarrer après la précédente. Le fichier est écrit à la fin, rien n'est monté. L'assistant refuse de s'exécuter hors d'un terminal interactif.

**Le fichier JSON est un résultat, jamais une saisie.** Vous le récoltez avec `--save`, `lab new` ou `lab export`.

### 8.4 Le fichier de labo

Le format est du JSON, que PowerShell lit nativement. Pas de YAML, qui demanderait une dépendance. Vous n'avez normalement pas à l'écrire, mais le relire est utile et le modifier reste possible.

```json
{
  "labo": "tp14-ad",
  "delai": 10,
  "machines": {
    "dc01":   { "modele": "win2022", "ram": 4, "cpu": 2, "mode": "hostonly" },
    "srv01":  { "modele": "win2022", "ram": 2, "mode": "hostonly", "apres": "dc01" },
    "client": { "modele": "win11",   "ram": 4, "mode": ["nat", "hostonly"], "apres": ["dc01", "srv01"],
                "set": { "usb.present": "TRUE" }, "nogui": true }
  }
}
```

Clés au niveau du labo :

| Clé | Rôle | Défaut |
|---|---|---|
| `labo` | Nom du labo, préfixe de toutes ses VM. 32 caractères, sans espace ni accent | nom du fichier |
| `delai` | Secondes d'attente entre deux démarrages | `5` |
| `requis` | Modèles attendus, vérifiés avant toute action. Voir [partager un labo](#9-partager-un-labo) | aucun |
| `machines` | Une entrée par machine, la clé étant son nom court | |

Chaque machine accepte **exactement les mêmes clés que les options de création**, sans les tirets : `modele` qui est obligatoire, `ram`, `cpu`, `reseau`, `mode`, `set`, `nogui`, `nostart`, `hostname`, `vnc`. Plus une clé propre au labo, `apres`, qui déclare les machines à démarrer avant celle-ci.

Détails de forme :

- `mode` : une chaîne (`"hostonly"`, `"nat,hostonly"`) ou une liste (`["nat", "hostonly"]`).
- `set` : un objet `{ "cle": "valeur", ... }` ou une liste `[ "cle=valeur", ... ]`.
- `apres` : une chaîne ou une liste de noms de machines du même fichier.
- `nogui`, `nostart`, `vnc` : `true` ou `false`.
- `hostname` : le nom d'hôte, **par défaut le nom court de la machine**. `false` ou `""` pour ne rien appliquer.
- Une clé inconnue, y compris une faute de frappe ou `tmp`, est refusée avant toute action.

### 8.5 Comportement

- **Nommage préfixé** : la machine `dc01` du labo `tp14-ad` devient la VM `tp14-ad-dc01`. Deux labos ne se marchent jamais dessus, et `vazy list` affiche le labo de chaque VM.
- **Validation avant action** : modèles inconnus, prérequis manquants, dépendances circulaires, `apres` vers une machine inexistante, nom déjà pris par une VM hors labo, espace disque pour l'ensemble. Si une vérification échoue, **aucune VM n'est créée**.
- **Idempotence** : relancer `lab up` ne recrée pas ce qui existe. Les VM manquantes sont créées, les éteintes démarrées, celles qui tournent laissées tranquilles. Une VM dont les fichiers ont disparu est recréée. En revanche, modifier la mémoire ou le réseau dans le fichier ne change pas une VM déjà créée : supprimez-la, ou démontez le labo, puis relancez.
- **Ordre de démarrage** : d'abord toutes les créations, puis les démarrages dans l'ordre des dépendances, avec le délai entre chacun. vazy ne sait pas quand un système a fini de démarrer : `apres` garantit l'ordre et le délai, pas que le contrôleur de domaine réponde déjà.
- `lab status` affiche un tableau par machine, avec l'état `en marche`, `arrêtée`, `à créer`, `absente`, ou `hors labo` quand le nom est pris par une VM qui n'appartient pas à ce labo. Les VM rattachées au labo mais retirées du fichier apparaissent en `(hors fichier)` et sont démontées avec le reste.
- `lab down` arrête toutes les VM dans l'ordre inverse du démarrage, puis les supprime, après confirmation. `--stop-only` arrête sans supprimer, avec repli en arrêt forcé si les outils de l'invité ne répondent pas ; `--hard` force d'emblée.

```
vazy : montage du labo « tp14-ad » (D:\TP\tp14-ad.json)
Vérifications du labo « tp14-ad »
      3 machine(s), modèles win2022, win11, ordre de démarrage : dc01 > srv01 > client
      à créer : dc01, srv01, client
Création 1/3 : dc01 -> VM « tp14-ad-dc01 »
      ...
Démarrage de dc01 -> VM « tp14-ad-dc01 »
      VM « tp14-ad-dc01 » démarrée en 4,2 s
      attente de 10 s avant srv01
Démarrage de srv01 -> VM « tp14-ad-srv01 » (après dc01)
      ...

Labo « tp14-ad » monté en 58,3 s : 3 VM créée(s), 3 démarrée(s).
MACHINE  VM              ÉTAT       MODÈLE   RAM   CPU  RÉSEAU        APRÈS
dc01     tp14-ad-dc01    en marche  win2022  4 Go  2    hostonly
srv01    tp14-ad-srv01   en marche  win2022  2 Go  2    hostonly      dc01
client   tp14-ad-client  en marche  win11    4 Go  2    nat,hostonly  dc01,srv01
```

---

## 9. Partager un labo

### 9.1 Exporter

Vous avez monté un TP à la main, machine par machine, et vous voulez en garder la recette :

```
vazy lab export tp20.json --prefixe tp20 --requis
```

vazy lit les VM existantes et écrit le fichier qui les recréerait : modèle, mémoire, cœurs, réseau, réglages bruts et nom d'hôte de chacune. Trois façons de désigner les VM :

| Option | VM concernées |
|---|---|
| `--labo <nom>` | Celles montées par un `lab up` précédent, colonne LABO de `vazy list` |
| `--prefixe <p>` | Celles dont le nom commence par `p-`, un TP monté à la main en les nommant `tp20-dc01`, `tp20-cli` |
| `--vms a,b,c` | Une liste explicite |

Le nom court de chaque machine est son nom de VM sans le préfixe. `--delai <n>` fixe l'attente entre démarrages, `--yes` remplace un fichier existant sans demander.

L'export **rattache les VM au labo** : elles gardent leur nom, mais `lab up` et `lab down` les reconnaissent désormais comme les siennes. Sans cela, rejouer le fichier buterait sur « cette VM existe déjà mais n'appartient pas à ce labo ».

### 9.2 Les prérequis

`--requis` ajoute un bloc qui décrit les modèles attendus. Il est indispensable si vous partagez le fichier :

```json
{
  "labo": "tp20",
  "delai": 5,
  "requis": [
    { "modele": "win2022", "os": "windows", "version": "2022", "disque_min": 40 }
  ],
  "machines": {
    "dc01": { "modele": "win2022", "ram": 4, "cpu": 2, "mode": "hostonly" }
  }
}
```

À l'autre bout, celui qui reçoit le fichier le pose dans son dossier de labos et lance `vazy lab up tp20`. **Les prérequis sont vérifiés avant toute action** : si un modèle manque, vazy refuse et dit précisément quoi préparer, sans avoir créé la moindre VM. Le système et la taille de disque déclarés produisent un simple avertissement s'ils ne correspondent pas.

### 9.3 Les alias de modèles

Le problème classique du partage : le labo demande `win2022`, mais votre modèle s'appelle `windows-server`. Plutôt que de renommer, déclarez une correspondance locale, une fois pour toutes :

```
vazy template alias windows-server win2022
```

Désormais, tout labo qui demande `win2022` utilise votre modèle. `vazy template list` affiche ces noms dans la colonne « AUSSI CONNU COMME », et `--rm` retire la correspondance. Un alias ne peut ni masquer un modèle existant, ni pointer vers deux modèles. La VM créée mémorise le nom réel du modèle, pas l'alias, pour ne pas devenir orpheline si vous retirez la correspondance plus tard.

Ce qui n'est **pas** fait : `vazy lab up ad-2022` qui irait chercher le labo dans un dépôt public, ainsi que `lab search` et `lab publish`. Le format est prêt, il manque le dépôt et son protocole.

---

## 10. Piloter et voir ses VM à distance

Le but : depuis une appli terminal sur un téléphone, taper une commande et voir l'écran de la VM, sans rien saisir à la main.

```
vazy ubuntu-server --nogui --vnc
```

Deux morceaux : le terminal passe par SSH, l'écran par le serveur VNC intégré à VMware Workstation Pro.

### 10.1 Le terminal : serveur SSH sur le PC

Windows 11 embarque un serveur SSH, il suffit de l'activer. Dans un **PowerShell administrateur** :

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```

L'installation crée la règle de pare-feu du port 22. Vérifiez avec `Get-Service sshd`.

Depuis le téléphone, il faut une appli terminal : Termux, Termius ou JuiceSSH sur Android, Termius ou Blink sur iOS. Puis `ssh votre-compte@adresse-du-pc`. Le shell par défaut d'OpenSSH sur Windows est `cmd.exe`, et vazy y fonctionne tel quel.

**Par clé plutôt que par mot de passe**, pour ne rien retaper : générez une clé sur le téléphone avec `ssh-keygen -t ed25519`, puis collez la clé publique dans `C:\Users\<vous>\.ssh\authorized_keys` sur le PC. Attention, un compte administrateur utilise `C:\ProgramData\ssh\administrators_authorized_keys` à la place, avec des droits restreints sur le fichier.

### 10.2 Depuis l'extérieur : Tailscale

Tailscale est un réseau privé qui relie vos appareils entre eux, où qu'ils soient. Installez-le sur le PC avec `winget install tailscale.tailscale` et sur le téléphone, connectez les deux au même compte. Chaque appareil reçoit une adresse fixe en `100.x.y.z`, joignable de partout, chiffrée de bout en bout, **sans redirection de port sur la box et sans adresse publique**. C'est la solution recommandée : rien n'est exposé à internet.

### 10.3 L'écran : `--vnc`

VMware Workstation Pro embarque un serveur VNC, piloté par trois lignes du fichier de configuration de la VM. Rien à installer : c'est le même mécanisme que tout le reste de vazy, écrire du texte dans un fichier.

vazy choisit un port libre dans la plage réservée, 5901 à 5999 par défaut, vérifie qu'il n'est pris ni par une autre VM ni par un programme de la machine, tire un mot de passe au hasard, et affiche :

```
  Écran de « ubuntu-server-1 » depuis un autre appareil :
  vnc://:Kj7mQp2x@100.94.31.7:5901
  adresse 100.94.31.7 (Tailscale), port 5901, mot de passe Kj7mQp2x
  Appuyez sur le lien depuis votre téléphone : votre client VNC s'ouvre, tout est prérempli.
```

Les applis terminal rendent ce lien tapotable : un appui ouvre le client VNC avec l'adresse, le port et le mot de passe déjà remplis.

| Commande | Effet |
|---|---|
| `vazy <modele> --vnc` | Crée la VM avec l'écran distant activé |
| `vazy vnc <nom>` | Réaffiche le lien, et l'active s'il ne l'était pas |
| `vazy vnc <nom> off` | Retire l'écran distant et libère le port |
| `"vnc": true` | Dans un fichier de labo, machine par machine |

L'adresse affichée est celle de Tailscale si une interface Tailscale existe, sinon celle de la carte qui porte la route par défaut. Les réseaux internes de VMware et les autres interfaces virtuelles sont écartés : ils ne sont jamais joignables depuis un téléphone.

Le mot de passe fait exactement 8 caractères. Ce n'est pas un choix, c'est la limite du protocole VNC. Il est tiré au hasard pour chaque VM, conservé au catalogue, et n'apparaît **que** dans le lien affiché à l'écran : jamais dans le journal, jamais dans un message d'erreur.

**Sur le téléphone, il faut une appli VNC qui gère les liens `vnc://`** : bVNC ou RealVNC Viewer sur Android, RealVNC Viewer sur iOS. Sans elle, le lien n'ouvre rien ; recopiez alors l'adresse, le port et le mot de passe affichés juste en dessous.

### 10.4 La règle de pare-feu, sans laquelle rien ne marchera

Le pare-feu Windows bloque par défaut les ports VNC. Dans un **PowerShell administrateur**, une seule fois :

```powershell
New-NetFirewallRule -DisplayName "vazy VNC (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 5901-5999 -RemoteAddress 100.64.0.0/10 -Action Allow
```

Cette règle n'autorise que les adresses Tailscale. Pour y ajouter votre réseau local, adaptez `-RemoteAddress`, par exemple `@('100.64.0.0/10','192.168.1.0/24')`. N'ouvrez jamais ces ports sans restriction d'adresse.

### 10.5 Sécurité : ce qu'il ne faut pas faire

**N'exposez jamais un port VNC sur internet.** Le VNC de VMware ne chiffre rien : le mot de passe, les frappes clavier et l'écran circulent en clair. Le mot de passe est limité à 8 caractères par le protocole, avec un chiffrement obsolète, cassable en quelques minutes. Concrètement : aucune redirection de port sur la box, jamais.

Deux façons sûres d'y accéder de l'extérieur :

- **Tailscale**, recommandé. Le trafic est chiffré de bout en bout entre vos appareils, rien n'est exposé.
- **Un tunnel dans la connexion SSH**, si vous préférez ne rien installer de plus. Depuis le téléphone, `ssh -L 5901:127.0.0.1:5901 votre-compte@adresse-du-pc`, puis pointez le client VNC sur `127.0.0.1:5901`. Le VNC voyage alors chiffré dans le tunnel. Le lien affiché par vazy ne conviendra pas dans ce cas, l'adresse étant différente.

Le serveur VNC de VMware écoute sur toutes les interfaces de la machine. C'est la règle de pare-feu ci-dessus qui restreint qui peut l'atteindre : ne la retirez pas.

### 10.6 Avant le premier essai

- Les lignes VNC sont **lues au démarrage de la VM**. Activer l'écran distant sur une VM qui tourne déjà n'a d'effet qu'après un redémarrage ; vazy le dit et donne la commande.
- Depuis une session SSH, préférez `--nogui`. Une session SSH n'a pas de bureau : l'ouverture d'une fenêtre VMware peut échouer ou s'afficher sur la session ouverte devant le PC. Avec `--nogui`, la VM tourne sans fenêtre et l'écran distant devient le moyen de la voir, ce qui est exactement le but.
- Le serveur VNC intégré peut refuser de démarrer quand l'accélération 3D est active dans la VM. Si l'écran reste noir, désactivez-la avec `--set mks.enable3d=FALSE`.

---

## 11. Personnalisation de l'invité

Les clones d'un modèle sont identiques : même nom d'hôte, même identifiant machine, mêmes clés SSH. Sur un TP réseau, c'est bloquant. vazy donne à chaque clone son **nom d'hôte**, avec `--hostname` ou, dans un labo, le nom court de chaque machine par défaut.

Deux méthodes, choisies d'après le modèle. `vazy template list` affiche celle qui s'applique.

### 11.1 Méthode guestinfo, recommandée

Le modèle embarque le script `vazy-guestinfo` et a été marqué avec `vazy template mark <alias> --guestinfo`.

Avant **chaque** démarrage fait par vazy, qu'il s'agisse d'une création, d'un `start`, d'un `reset`, d'un `back` ou d'un `lab up`, vazy dépose la configuration dans la machine sous forme d'une variable `guestinfo.vazy_config`. Le script du modèle la lit au démarrage avec les outils invité et l'applique lui-même. **vazy n'entre jamais dans la VM.**

Il n'y a rien à réappliquer après un `reset` ou un `back` : le script relit la variable à chaque démarrage, donc le nom revient tout seul. Aucune attente, aucun compte, aucun mot de passe nulle part.

La charge utile est du JSON encodé en base64, pour éviter tout problème d'échappement :

```json
{ "hostname": "web1" }
```

Le format accueillera plus tard `ip`, `masque`, `passerelle`, `dns` et `cle_ssh`. Seul `hostname` est appliqué aujourd'hui, et le script invité ignore silencieusement toute clé qu'il ne connaît pas, ce qui garde la compatibilité avec les versions futures.

Détail technique, si vous vous demandez pourquoi ce n'est pas `vmrun writeVariable` : cette forme de variable n'existe qu'à l'exécution et disparaît à l'extinction, alors que la clé écrite dans le fichier de configuration est persistante et se pose machine éteinte, avant le démarrage. C'est le mécanisme qu'utilisent cloud-init et Terraform sur VMware.

### 11.2 Méthode classique, par identifiants

Pour un modèle qu'on ne peut pas modifier. `vazy template creds <alias>` enregistre un compte de l'invité. Le mot de passe est saisi masqué au clavier, jamais sur la ligne de commande, et stocké chiffré par DPAPI dans `%LOCALAPPDATA%\vazy\creds\<alias>.xml` : le fichier n'est lisible que par votre compte Windows sur ce PC, et devient inutilisable ailleurs.

Après chaque démarrage, vazy attend que les outils invité répondent, avec des nouvelles tentatives sur le premier script car les outils se déclarent prêts un peu avant de l'être, puis exécute le script de renommage dans la VM. Sous Linux, `hostnamectl` et `/etc/hosts`. Sous Windows, `Rename-Computer` **sans redémarrer** : le script rend la main, et c'est vazy qui arrête proprement la VM puis la redémarre, pour un état déterministe plutôt qu'une connexion coupée en plein vol.

Deux limites à connaître. `vmrun` ne reçoit les identifiants que par des options de sa ligne de commande, visibles pendant les quelques secondes de l'appel pour les processus de votre compte Windows. Et surtout, ce compte privilégié est cloné dans toutes vos VM.

### 11.3 Adressage statique et clé SSH

Un TP de réseau se passe mal avec des adresses attribuées au hasard par le DHCP. Cinq options les fixent, appliquées par le même mécanisme guestinfo :

```
vazy debian --name routeur --ip 192.168.100.1 --masque 24 --dns 1.1.1.1
```

| Option | Effet |
|---|---|
| `--ip <adresse>` | Adressage statique au lieu du DHCP. Exige `--masque` |
| `--masque <m>` | `255.255.255.0` ou la longueur du préfixe : `24` |
| `--passerelle <ip>` | Passerelle par défaut |
| `--dns <a,b>` | Serveurs DNS, séparés par des virgules |
| `--cle-ssh <cle>` | Clé publique ajoutée aux clés autorisées du compte de l'invité |

Dans un fichier de labo, les mêmes clés se déclarent **par machine** — c'est là que ça devient vraiment utile, puisque tout le plan d'adressage du TP tient dans le fichier :

```json
"routeur": { "modele": "debian", "mode": ["nat", "hostonly"],
             "ip": "192.168.100.1", "masque": 24 },
"web":     { "modele": "debian", "mode": "hostonly",
             "ip": "192.168.100.10", "masque": 24, "passerelle": "192.168.100.1",
             "dns": "192.168.100.1" }
```

`vazy lab export` réémet ces clés : un labo exporté reste rejouable tel quel.

**Trois choses à savoir.**

Ces options exigent un modèle **marqué guestinfo** avec le script d'invité à jour. Sur un modèle en repli par identifiants, vazy prévient et n'applique que le nom d'hôte.

Côté invité, l'application passe par **netplan** (Ubuntu récent) ou **systemd-networkd**, sur la première interface réseau réelle. C'est idempotent : une configuration déjà en place n'est pas réécrite et rien n'est redémarré.

Sans aucune de ces options, **rien ne change** : la charge utile ne contient que le nom d'hôte, et l'invité reste en DHCP comme avant.

### 11.4 Règle absolue

Si la personnalisation échoue, pour quelque raison que ce soit, **la VM reste créée et démarrée**. vazy avertit en donnant la cause et la marche à suivre, mais n'annule rien. Une VM utilisable avec un mauvais nom d'hôte vaut mieux qu'une VM supprimée.

Ce qui n'est pas fait dans cette version : le SID Windows. Le format et le script sont prêts à l'accueillir.

---

## 12. Protéger son travail : doctor, empreinte, freeze

### 12.1 Le diagnostic

Sur un outil qui manipule des clones liés, l'écart entre le catalogue et la réalité du disque est certain, pas probable. `vazy doctor` le rend visible.

```
vazy doctor
```

Il vérifie, dans l'ordre : `vmrun` trouvé et qui répond ; Hyper-V ; espace libre de chaque dossier de VM ; chaque modèle, avec son fichier, son instantané d'ancrage, le fait qu'il soit bien éteint, sa marque de protection et le nombre de clones qui en dépendent ; chaque VM du catalogue, avec ses fichiers, son état, l'intégrité de son modèle, son point de retour et son écran distant ; enfin les machines trouvées dans vos dossiers mais absentes du catalogue.

Chaque ligne en échec est suivie de la marche à suivre. Le code de retour est 1 s'il reste au moins un échec, 0 sinon.

```
MODÈLE
  OK     ubuntu-server          instantané « base » présent ; 3 clone(s) lié(s) en dépendent : TP14, TP15, web
  ECHEC  win2022                fichier introuvable : D:\VMs\win2022\win2022.vmx ; 2 clone(s) lié(s) en dépendent : ad-dc01, ad-cli
           -> Remettez le modèle à cet emplacement exact, ou restaurez-le depuis une sauvegarde. Sans lui, ses clones liés ne démarrent plus.
```

### 12.2 L'empreinte du modèle, sans rien faire

À la création de chaque clone, vazy enregistre l'empreinte des disques de base du modèle : nom, taille, date. Avant chaque démarrage, il la compare.

Si le modèle a disparu, a été déplacé, ou si l'un de ses instantanés a été supprimé ou consolidé dans VMware Workstation, vazy refuse de démarrer et dit exactement ce qui manque, au lieu de laisser VMware produire une erreur incompréhensible. Les VM créées avant la version 1.6 n'ont pas d'empreinte, et `vazy doctor` le signale.

### 12.3 Rendre une VM autonome

Un clone lié ne contient que ses différences : c'est ce qui rend la création instantanée, mais il **meurt si le modèle disparaît ou change**. Pour la VM d'un projet que vous voulez garder six mois :

```
vazy stop projet-web
vazy freeze projet-web
```

vazy en fait une copie complète. La VM occupe alors toute sa taille sur le disque, comptez plusieurs minutes de copie, mais ne dépend plus de rien. `vazy list` et `vazy doctor` la signalent comme autonome, et vazy cesse de vérifier son modèle.

Deux points : la VM doit être **arrêtée**, et les instantanés ne survivent pas à une copie complète. vazy reprend donc `vazy-neuf` sur l'état courant, qui devient le nouvel état neuf ; vos jalons manuels, eux, sont perdus.

---

## 13. Régler n'importe quel paramètre

Une VM VMware est entièrement décrite par son fichier `.vmx`, un fichier texte de lignes `cle = "valeur"`. `--set cle=valeur` écrit littéralement cette ligne dans le fichier du clone : la ligne existante est remplacée, sinon elle est ajoutée. Comme il s'applique **après** les options nommées, il peut les écraser. `--ram 4 --set memsize=8192` donne 8 Go.

C'est l'échappatoire du projet : tout ce que ni vous ni vazy n'avez prévu reste accessible, sans attendre une nouvelle version.

| `--set` | Effet |
|---|---|
| `svga.autodetect=FALSE` et `svga.vramSize=16777216` | Fige la mémoire vidéo à 16 Mo |
| `mks.enable3d=FALSE` | Désactive l'accélération 3D, nécessaire si l'écran VNC reste noir |
| `usb.present=TRUE` | Active le contrôleur USB |
| `sound.present=FALSE` | Retire la carte son |
| `mainMem.useNamedFile=FALSE` | Évite le fichier mémoire de la taille de la RAM à côté de la VM |
| `bios.bootDelay=3000` | Trois secondes de délai au démarrage pour attraper le menu du BIOS |
| `bios.forceSetupOnce=TRUE` | Entre dans le BIOS au prochain démarrage |
| `ethernet0.virtualDev=e1000` | Change le type de carte réseau : `e1000`, `e1000e`, `vmxnet3` |
| `ethernet0.connectionType=custom` et `ethernet0.vnet=VMnet2` | Branche la carte sur un réseau personnalisé déjà créé |
| `guestOS=ubuntu-64` | Type de système invité déclaré à VMware |
| `tools.syncTime=TRUE` | Synchronise l'horloge sur celle de l'hôte |
| `displayName=TP 14 - Serveur web` | Nom affiché dans VMware ; les espaces sont acceptés ici, contrairement à `--name` |

Pour découvrir une clé : faites le réglage une fois dans l'interface de VMware sur une VM éteinte, puis ouvrez son `.vmx` dans un éditeur et repérez la ligne ajoutée.

vazy ajoute lui-même `msg.autoAnswer = "TRUE"` à chaque clone, pour que VMware réponde seul à la question « cette VM a-t-elle été déplacée ou copiée ? » au démarrage. `--set msg.autoAnswer=FALSE` l'annule.

---

## 14. Outillage : simulation, journal, configuration

### 14.1 `--dry-run`

N'exécute rien. Affiche en magenta les commandes exactes qui seraient lancées et les lignes qui seraient écrites dans la configuration des VM. Les lectures, elles, ont bien lieu : sans elles il n'y aurait rien à décider. Ni le catalogue ni les fichiers ne sont touchés.

```
vazy ubuntu-server --name TP20 --ram 4 --dry-run
vazy lab down tp14 --yes --dry-run
```

C'est un filet de sécurité avant une opération destructrice, et le moyen le plus simple d'apprendre `vmrun` pour de bon.

### 14.2 Le journal

Chaque opération est enregistrée dans `%LOCALAPPDATA%\vazy\journal.log` : la ligne de commande vazy, chaque commande `vmrun` lancée avec son code de retour et sa durée, et chaque écriture dans un fichier de configuration. Les mots de passe y sont remplacés par `***`, qu'il s'agisse d'identifiants d'invité ou d'un mot de passe VNC. Le fichier tourne tout seul au-delà de 2 Mo.

C'est le premier endroit à regarder quand quelque chose s'est mal passé.

### 14.3 Les fichiers de vazy

Tout est dans `%LOCALAPPDATA%\vazy\`, c'est-à-dire `C:\Users\<vous>\AppData\Local\vazy\`.

| Fichier | Contenu |
|---|---|
| `config.json` | Réglages de l'outil |
| `catalogue.json` | Modèles enregistrés et VM créées. La clé `version` note le schéma ; un catalogue plus ancien est migré automatiquement, sans perte |
| `journal.log` | Trace de chaque opération |
| `creds\<alias>.xml` | Identifiants d'invité d'un modèle, chiffrés pour votre compte Windows |
| `labos\<nom>.json` | Fichiers de labo enregistrés, retrouvés par leur nom |

### 14.4 La configuration

`vazy config` affiche les réglages, `vazy config <cle> <valeur>` en modifie un, et une valeur vide revient au défaut.

| Clé | Rôle | Défaut |
|---|---|---|
| `dossierVms` | Dossier où sont créées les VM | dossier parent du modèle |
| `dossierLabos` | Où sont rangés les fichiers de labo | `%LOCALAPPDATA%\vazy\labos` |
| `outilHyperviseur` | Chemin de `vmrun.exe` si la détection automatique échoue | détection automatique |
| `espaceDisqueMinGo` | Marge d'espace libre exigée, en plus de la mémoire de la VM | `1` |
| `delaiOutilsSec` | Attente maximale des outils invité, de 5 à 1800 secondes | `120` |
| `delaiPoolSec` | Attente maximale qu'un invité s'annonce prêt à être figé | `180` |
| `poolReposSec` | Repli : temps laissé à l'invité avant de le figer, faute de poignée de main | `20` |
| `seuilDivergencePct` | Au-delà de ce pourcentage de la taille du modèle, `vazy disk` signale un clone à revoir | `50` |
| `vncPortMin`, `vncPortMax` | Plage de ports réservée aux écrans distants | `5901`, `5999` |
| `hyperviseur` | Pilote utilisé, c'est-à-dire `lib\pilote-<hyperviseur>.ps1` | `vmware` |

**Espace disque** : avant de cloner, vazy vérifie qu'il reste au moins la mémoire de la VM plus la marge sur le disque de destination, car VMware crée pendant l'exécution un fichier de la taille de la mémoire. Sinon il refuse, sans rien créer.

### 14.5 La vue temps réel

```
vazy top
```

Toutes les VM, leur état, leur mémoire, leur réseau, leur adresse IP, et leur appartenance à un labo ou à une réserve — rafraîchi toutes les deux secondes.

| Touche | Effet |
|---|---|
| Haut / Bas | Choisir une VM |
| `s` | La démarrer |
| `x` | L'arrêter |
| `r` | La remettre à zéro |
| `q` ou Échap | Quitter |

L'adresse IP n'est demandée que pour les VM **en marche** : interroger l'hyperviseur au sujet d'une machine éteinte coûterait un aller-retour à chaque tour de boucle pour rien.

Aucun service en tâche de fond, aucun verrou tenu : à chaque tour, la vue relit le catalogue et interroge l'hyperviseur, exactement comme `vazy list`. Entre deux tours, une autre commande vazy peut travailler dans une autre fenêtre — la règle « une commande à la fois » est intacte, et les changements apparaissent au rafraîchissement suivant.

Sans console interactive — sortie redirigée, script, tâche planifiée — `vazy top` affiche un instantané et rend la main, au lieu de boucler indéfiniment.

### 14.6 Le rapport HTML

```
vazy report --out D:\TP14\parc.html
```

Un **seul fichier**, qu'on envoie par courriel ou qu'on joint à un compte-rendu de TP. Sans `--out`, il s'appelle `vazy-rapport.html` dans le dossier courant.

Ce qu'il contient : des chiffres clés en tête (VM, en marche, modèles, labos, réserve, place occupée), puis un tableau par sujet — les VM avec leur état et leur place **réelle** sur le disque, chaque modèle avec **la liste de ses clones**, les labos, la réserve de VM chaudes, et les segments réseau avec les VM qui y sont branchées.

Il est **autonome** : feuille de style intégrée, aucun script, aucune police ni image chargée d'ailleurs. Il s'ouvre hors connexion, chez le correcteur comme chez vous, et suit le thème clair ou sombre du navigateur. Un test vérifie qu'aucune ressource externe ne s'y glisse.

`--dry-run` le prépare sans l'écrire.

### 14.7 Le coût disque réel

```
vazy disk              # toutes les VM
vazy disk TP14         # une seule
```

Un clone lié **partage** les disques de base de son modèle. Ce qu'il coûte vraiment, c'est son disque de différences : tout ce qui a été écrit depuis sa création. `vazy disk` affiche ce coût réel pour chaque VM, sa nature (clone lié, complète, réserve), la mémoire figée d'une VM suspendue, et sa **divergence** — ses différences rapportées à la taille du modèle.

En bas, le bilan : ce que les VM occupent, les disques de base partagés (comptés une seule fois par modèle), et ce que les mêmes machines auraient pris en copies complètes. C'est le gain concret des clones liés, chiffré sur votre parc.

**Un clone qui a trop divergé** — au-delà de 50 % de la taille de son modèle par défaut, réglable par `vazy config seuilDivergencePct` — est marqué *à revoir* : il coûte presque une copie complète tout en restant dépendant du modèle, donc fragile. Deux issues : le recréer s'il n'a rien de précieux (`vazy rm` puis `vazy <modele>`), ou le rendre autonome s'il en a (`vazy freeze`). Le rapport HTML porte la même marque.

Une VM rendue autonome n'a plus de modèle : on ne lui calcule pas de divergence.

Deux variables d'environnement, utiles pour les essais :

- `VAZY_HOME` : un autre dossier pour la configuration et le catalogue, pratique pour tester sans toucher à son installation.
- `VAZY_DEBUG=1` : affiche la pile d'appel complète en cas d'erreur inattendue.

---

## 15. Référence des commandes

**Créer**

| Commande | Effet |
|---|---|
| `vazy <modele> [options]` | Crée un clone lié du modèle et le démarre. Options à la [section 5.1](#51-la-commande-principale) |

**Cycle de vie**

| Commande | Effet |
|---|---|
| `vazy list` | Les VM créées par vazy, avec leur état |
| `vazy start <nom> [--nogui]` | Démarre |
| `vazy stop <nom> [--hard]` | Arrête proprement ; `--hard` coupe le courant |
| `vazy rm <nom> [--yes]` | Supprime la VM et ses fichiers, après confirmation |
| `vazy gc [--yes]` | Supprime les VM éphémères éteintes |

**Réserve de VM chaudes** — voir [section 5.6](#56-réserve-de-vm-chaudes)

| Commande | Effet |
|---|---|
| `vazy pool create <modele> --size <n> [--ram <Go>] [--cpu <n>] [--mode <m>] [--set <k>=<v>]` | Prépare `n` VM démarrées puis figées |
| `vazy pop <modele> [--name <nom>] [--hostname <h>] [--nogui]` | Réveille une VM de la réserve et lui donne son identité |
| `vazy pool status [<modele>]` | Stock, état de chaque VM, place occupée |
| `vazy pool refill <modele> [--size <n>]` | Complète la réserve |
| `vazy pool destroy <modele> [--yes]` | Détruit la réserve |

**Vue d'ensemble** — voir [section 14.5](#145-la-vue-temps-réel) et [14.6](#146-le-rapport-html)

| Commande | Effet |
|---|---|
| `vazy top` | Vue qui se rafraîchit ; flèches, `s`/`x`/`r` pour agir, `q` pour sortir |
| `vazy report [--out <fichier.html>]` | Rapport HTML autonome du parc |
| `vazy disk [<nom>]` | Coût disque réel de chaque clone, et ceux qui ont trop divergé |

**Instantanés**

| Commande | Effet |
|---|---|
| `vazy reset <nom> [--nostart] [--nogui]` | Retour à `vazy-neuf`, puis redémarrage |
| `vazy snap <nom> [libelle]` | Instantané manuel |
| `vazy snaps <nom>` | Liste les instantanés |
| `vazy back <nom> <libelle> [--nostart] [--nogui]` | Retour à un instantané manuel |
| `vazy unsnap <nom> <libelle> [--yes]` | Supprime un instantané manuel |

**Labos**

| Commande | Effet |
|---|---|
| `vazy lab up <nom> [--vm nom:modele[:ram[:cpu]]] ... [--save]` | Monte un labo décrit en une ligne, ou remonte un labo enregistré |
| `vazy lab new <nom>` | Assistant interactif, puis écriture du fichier |
| `vazy lab status <nom>` | État de chaque machine |
| `vazy lab down <nom> [--yes] [--stop-only] [--hard]` | Arrête et supprime le labo |
| `vazy lab export <fichier> --labo\|--prefixe\|--vms [--requis] [--delai n] [--yes]` | Génère le fichier qui recréerait des VM existantes |

**Modèles**

| Commande | Effet |
|---|---|
| `vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]` | Enregistre un modèle ; le dossier de la VM est accepté |
| `vazy template list` | Modèles, instantané, clones, système, méthode de personnalisation, alias |
| `vazy template rm <alias>` | Retire du catalogue ; **aucun fichier de VM n'est supprimé** |
| `vazy template mark <alias> --guestinfo\|--classique` | Déclare que le modèle embarque le script d'auto-configuration |
| `vazy template alias <alias> <nom standard> [--rm]` | Fait répondre le modèle à un nom standard |
| `vazy template creds <alias> [--user <nom>] [--os linux\|windows] [--rm]` | Identifiants d'invité, méthode de repli |

**Écran distant**

| Commande | Effet |
|---|---|
| `vazy vnc <nom>` | Affiche le lien, l'active si besoin |
| `vazy vnc <nom> off` | Retire l'écran distant et libère le port |

**Divers**

| Commande | Effet |
|---|---|
| `vazy doctor` | Diagnostic complet |
| `vazy freeze <nom> [--yes]` | Convertit un clone lié en VM autonome |
| `vazy config [<cle> <valeur>]` | Affiche ou modifie la configuration |
| `vazy help`, `vazy version` | |

**Codes de retour** : `0` succès, `1` erreur, `2` erreur de syntaxe. `vazy doctor` renvoie 1 s'il a trouvé au moins un problème.

---

## 16. Dépannage

### Installation et démarrage

**« vmrun.exe est introuvable »**
VMware Workstation n'est pas installé, ou se trouve dans un dossier inhabituel. Indiquez le chemin : `vazy config outilHyperviseur "C:\...\vmrun.exe"`.

**« L'exécution de scripts est désactivée sur ce système »**
Vous avez lancé `lib\interface.ps1` directement. Passez par `vazy.cmd`, ce que fait la commande `vazy` quand le dossier est dans le PATH. Ou autorisez les scripts pour votre compte : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

**« Un hyperviseur Windows (Hyper-V) est actif »**
Sur Windows, un seul hyperviseur possède le processeur. Quand Hyper-V est actif, à cause de WSL2, Docker Desktop, Windows Sandbox ou de l'option « Intégrité de la mémoire », VMware bascule sur la couche de virtualisation de Windows : cela fonctionne, mais plus lentement et sans virtualisation imbriquée. vazy prévient une fois en détail, puis d'une ligne, et continue. Pour rendre le processeur à VMware, dans une invite de commandes administrateur puis redémarrage :

```
bcdedit /set hypervisorlaunchtype off
```

WSL2, Docker Desktop et Windows Sandbox cesseront de fonctionner ; `auto` à la place de `off` revient en arrière. Pensez aussi à désactiver « Intégrité de la mémoire » dans Sécurité Windows, section Isolation du noyau.

**Sous PowerShell, `--mode nat,hostonly` ou `--ram 1,5` donnent « Argument inattendu »**
PowerShell découpe sur la virgule avant de transmettre les arguments. Écrivez `--mode nat --mode hostonly` et `--ram 1.5`, ou mettez des guillemets.

### Modèles et clones

**« Le modèle n'a aucun instantané »**
Un clone lié doit s'appuyer sur un instantané. Éteignez la VM, prenez-en un, puis relancez `vazy template add`. Voir la [section 4.6](#46-éteindre-linstantané-lenregistrement).

**« Refus de ... : ... est marquée comme modèle »**
Le pilote a trouvé le fichier témoin posé à côté du modèle. L'opération demandée casserait ses clones. Si vous devez vraiment agir dessus, retirez-le du catalogue avec `vazy template rm <alias>`, ce qui retire aussi la marque.

**« Le modèle ... a changé depuis la création de ... »**
Les disques de base ne sont plus ceux sur lesquels ce clone a été créé. Cause habituelle : un instantané du modèle a été supprimé ou consolidé dans le gestionnaire d'instantanés de VMware, ou le disque a été compacté. Le clone est probablement perdu. `vazy doctor` dit quelles VM sont touchées. Pour l'avenir, `vazy freeze` rend autonome une VM à laquelle vous tenez.

**« Le modèle ... est introuvable »**
Le modèle a été déplacé ou supprimé. Remettez-le à cet emplacement exact, ou restaurez-le. Un clone lié ne peut pas démarrer sans son modèle.

**« Le nom ... est déjà utilisé » ou « Le dossier ... existe déjà »**
vazy n'écrase jamais rien. Choisissez un autre `--name`, ou supprimez l'ancienne VM. Un dossier orphelin, resté d'une VM effacée à la main dans VMware, se supprime avec l'Explorateur.

### Arrêt et instantanés

**« Arrêt propre impossible : les VMware Tools ne répondent pas »**
Le système invité n'a pas les outils d'intégration, ou n'a pas fini de démarrer. Éteignez depuis l'intérieur de la VM, ou `vazy stop <nom> --hard`, qui équivaut à débrancher la prise. Installez les outils dans le modèle pour que cela ne se reproduise plus.

**« La VM ... n'a pas de point de retour vazy-neuf »**
La VM date d'avant la version qui prend cet instantané automatiquement, ou l'instantané a été supprimé dans VMware. Créez-le une fois, VM éteinte : `vazy stop <nom>` puis `vazy snap <nom> vazy-neuf`.

**« Le retour à l'instantané ... a échoué »**
VMware met parfois quelques secondes à libérer une VM après un arrêt forcé : relancez la commande. Vérifiez aussi que l'instantané existe encore avec `vazy snaps <nom>`, il a pu être supprimé depuis l'interface de VMware.

### VM éphémères

**Ma VM éphémère n'a pas été supprimée**
Elle tourne encore : fermer sa fenêtre ne l'éteint pas si VMware est réglé pour garder les VM en arrière-plan. `vazy list` la montre alors « en marche ». Éteignez-la depuis l'intérieur ou avec `vazy stop`. Si elle est éteinte et toujours là, lancez `vazy gc` : le message dira pourquoi.

**« ... VM éphémères éteintes à supprimer : c'est beaucoup pour un nettoyage automatique »**
Plus de trois VM éphémères se sont retrouvées éteintes en même temps, ce qui ressemble à une anomalie comme une coupure ou un arrêt de l'hôte. Vérifiez avec `vazy list`, puis `vazy gc --yes`.

### Labos

**« Fichier ..., machine « x » : clé inconnue ... » ou « n'est pas du JSON valide »**
Le fichier est vérifié en entier avant toute action. Le message nomme la machine et la clé fautive. Erreur classique : une virgule après le dernier élément d'un objet ou d'une liste.

**« dépendances circulaires entre ... »**
Les clés `apres` de ces machines forment une boucle. L'une d'elles doit pouvoir démarrer sans attendre les autres.

**« La VM ... existe déjà mais appartient à ... »**
Le nom préfixé est déjà pris par une VM qui n'a pas été créée par ce labo. Changez le nom du labo ou de la machine, ou supprimez cette VM.

**« ... modèle(s) requis manquant(s) »**
Le fichier vient d'ailleurs et référence un modèle sous un nom que vous n'avez pas. Préparez-le, ou déclarez une correspondance : `vazy template alias <votre modèle> <nom attendu>`.

**« Labo inconnu : ... »**
Aucun fichier de ce nom dans le dossier courant ni dans le dossier des labos. Le message propose les deux façons d'en créer un.

### Nom d'hôte

**Rien ne se passe au démarrage, sur un modèle guestinfo**
Dans la VM, regardez `systemctl status vazy-guestinfo` sous Linux, ou le journal `C:\ProgramData\vazy\vazy-guestinfo.log` sous Windows. Vérifiez ensuite que `vmtoolsd --cmd "info-get guestinfo.vazy_config"` renvoie une valeur : si vous obtenez « No value found », vazy n'a rien déposé, et le modèle n'est probablement pas marqué. Si une valeur en base64 apparaît, c'est le script qui ne s'est pas exécuté, souvent parce qu'il a été installé après l'instantané.

**« outils invité injoignables après 120 s »**
Les outils ne sont pas installés dans le modèle, ou l'invité met plus longtemps à démarrer. Installez-les, ou allongez l'attente avec `vazy config delaiOutilsSec 300`. La VM tourne quand même, et le nom sera réessayé au prochain démarrage.

**« Exécution dans l'invité impossible : ... exit code ... »**
Le script a tourné mais a échoué. Sous Linux, le compte ne peut pas faire `sudo` sans mot de passe. Sous Windows, il n'est pas administrateur élevé : utilisez le compte `Administrateur` intégré.

**« L'invité a refusé le compte ... »**
Utilisateur ou mot de passe faux, ou compte qui ne peut pas ouvrir de session. Ressaisissez avec `vazy template creds <alias>`.

**« Les identifiants d'invité du modèle ... sont illisibles »**
Le fichier a été chiffré par un autre compte Windows ou sur un autre PC. Il est inutilisable ici, et c'est voulu. Ressaisissez-les.

### Écran distant

**Le lien s'ouvre mais l'écran reste noir**
L'accélération 3D bloque le serveur VNC intégré. Désactivez-la : `--set mks.enable3d=FALSE`, puis redémarrez la VM.

**Le lien n'ouvre rien sur le téléphone**
Aucune appli VNC installée, ou elle ne gère pas les liens `vnc://`. Installez bVNC ou RealVNC Viewer, ou recopiez l'adresse, le port et le mot de passe affichés sous le lien.

**Connexion refusée depuis le téléphone**
Trois causes possibles, dans cet ordre : la règle de pare-feu n'a pas été créée, la VM n'a pas été redémarrée depuis l'activation de l'écran distant, ou l'adresse affichée n'est pas joignable depuis le téléphone. Dans ce dernier cas, installez Tailscale.

### Divers

**Une VM supprimée apparaît encore dans la bibliothèque de VMware Workstation**
La bibliothèque est une liste de raccourcis gérée par l'interface graphique. Clic droit sur l'entrée grisée, `Remove from Library`.

**La VM démarrée avec `--nogui` est invisible**
Elle tourne en arrière-plan. Pour la voir, `File > Open` dans VMware Workstation sur son fichier `.vmx`, dont le chemin est affiché par `vazy list`. Ou activez son écran distant.

**Ctrl+C pendant le clonage**
VMware peut laisser un dossier incomplet. Supprimez-le à la main, puis relancez.

---

## 17. Limites connues

Ce qui est volontairement hors périmètre :

- **Redimensionner le disque.** Compliqué sur un clone lié, et inutile si le modèle a été créé avec un disque dynamique très large, comme recommandé à la [section 4.1](#41-créer-la-vm-dans-vmware-workstation).
- **Adressage fin d'un segment.** `vazy net add` pose l'adresse du réseau et, en option, un serveur DHCP. Le reste — plage DHCP, passerelle, routes — se règle dans le Virtual Network Editor. Voir les [segments réseau isolés](#53-segments-réseau-isolés) pour ce qui est couvert.
- **Autres hyperviseurs.** Seul VMware Workstation est pris en charge. L'architecture est prête pour VirtualBox et Hyper-V, voir la [section 18](#18-architecture).
- **Interface graphique.** Aucune, et ce n'est pas prévu.
- **Identité complète de l'invité.** Le nom d'hôte est appliqué, et un modèle guestinfo régénère les clés SSH du serveur et l'identifiant machine. Restent identiques d'un clone à l'autre : le SID Windows, qui demande `sysprep`, et la configuration IP, qui reste en DHCP.
- **Une commande vazy à la fois.** Le catalogue est lu au début de chaque commande et réécrit à la fin. Deux commandes lancées en parallèle dans deux terminaux peuvent s'écraser mutuellement leurs modifications.
- **Bibliothèque de labos distante.** `lab up <nom>` ne va pas chercher un labo dans un dépôt public. Le format est prêt, le protocole n'existe pas.

---

## 18. Architecture

```
vazy.cmd                    lanceur : powershell -File lib\interface.ps1
lib\interface.ps1           couche 1 : arguments, validation, affichage
lib\logique.ps1             couche 2 : catalogue, vérifications, enchaînement
lib\pilote-vmware.ps1       couche 3 : vmrun.exe et fichiers .vmx
```

La **couche 1** analyse les arguments, valide les valeurs, appelle la couche 2, et affiche ce qu'elle publie via l'afficheur qu'elle lui a fourni. Elle lit aussi les fichiers de labo, car leur format est une syntaxe d'entrée comme une autre.

La **couche 2** ne connaît ni la ligne de commande ni l'hyperviseur. Elle charge le pilote désigné par la configuration et ne lui parle qu'à travers le contrat ci-dessous. Un chemin de machine est pour elle une chaîne opaque.

La **couche 3** est la seule à contenir du VMware : localisation de `vmrun.exe`, syntaxe des commandes, lecture et écriture des `.vmx` en conservant leur encodage déclaré.

### 18.1 Contrat du pilote

Les six opérations fondamentales :

| Fonction | Rôle |
|---|---|
| `New-MachineDepuisModele -Modele -Instantane -Dossier -Nom` | Créer depuis un modèle ; renvoie le chemin de la machine |
| `Set-MachineParametres -Machine [-RamMo] [-Cpu] [-Brut]` | Régler les paramètres ; `-Brut` écrit des paires clé-valeur telles quelles |
| `Set-MachineReseau -Machine -Modes` | Brancher le réseau, un mode par carte |
| `Start-Machine -Machine [-SansInterface]` | Démarrer |
| `Stop-Machine -Machine [-Brutal]` | Arrêter |
| `Remove-Machine -Machine` | Supprimer |

La lecture seule, sans laquelle la logique ne peut rien décider :

| Fonction | Rôle |
|---|---|
| `Initialize-Pilote [-CheminForce]` | Localise l'outil ; renvoie `Nom`, `Executable`, `ExtensionMachine`, `SensibleHyperV`, `ConseilInstantane` |
| `Get-MachineEnCours` | Chemins des machines en cours d'exécution |
| `Get-MachineInstantanes -Machine` | Noms des instantanés d'une machine |

Les instantanés :

| Fonction | Rôle |
|---|---|
| `New-MachineInstantane -Machine -Nom` | Prendre un instantané |
| `Restore-MachineInstantane -Machine -Nom` | Revenir à un instantané, machine arrêtée |
| `Remove-MachineInstantane -Machine -Nom` | Supprimer un instantané |

L'invité et l'affichage distant :

| Fonction | Rôle |
|---|---|
| `Set-MachineVariableInvite -Machine -Nom [-Valeur]` | Dépose une variable lisible dans l'invité, machine éteinte |
| `Set-MachineAffichageDistant -Machine -Actif [-Port] [-MotDePasse]` | Active ou retire le serveur d'affichage distant |
| `Get-MachineSystemeInvite -Machine` | `linux`, `windows` ou `inconnu` |
| `Wait-MachineOutils -Machine [-DelaiMaxSec]` | Vrai dès que les outils invité répondent |
| `Invoke-MachineScript -Machine -Identifiants -Systeme -Script` | Exécute un script dans l'invité et renvoie son code de sortie ; retente si l'invité n'est pas prêt ; aucun mot de passe dans les messages |

La protection du modèle et l'autonomie :

| Fonction | Rôle |
|---|---|
| `Get-MachineEmpreinte -Machine` | Disques de base : nom, taille, date |
| `Test-MachineEmpreinte -Machine -Empreinte` | Compare à une empreinte ; renvoie erreurs et avertissements |
| `Convert-MachineEnComplete -Machine -Nom` | Convertit un clone lié en machine complète, au même chemin |
| `Get-MachineDisqueGo -Machine` | Capacité déclarée des disques |
| `Protect-MachineModele`, `Unprotect-MachineModele`, `Test-MachineModele` | Pose, retire et teste la marque de modèle |

Les segments réseau isolés (voir [section 5.4](#53-segments-réseau-isolés)) :

| Fonction | Rôle |
|---|---|
| `Get-ReseauxNommes` | Segments existants : identifiant, adresse, masque, DHCP |
| `New-ReseauNomme [-Identifiant] [-Adresse] [-Masque] [-Dhcp]` | Crée un segment et renvoie son identifiant ; sans `-Identifiant`, le pilote en choisit un de libre |
| `Remove-ReseauNomme -Identifiant` | Le supprime |

L'identifiant rendu est **opaque** pour la couche logique : elle le transporte, elle ne l'interprète jamais. C'est ce qui permet à VMware (VMnet, `vnetlib`, droits administrateur) et à VirtualBox (réseaux internes, aucun droit requis) de répondre au même contrat. Une carte branchée sur un segment est demandée à `Set-MachineReseau` sous la forme `nomme:<identifiant>`.

L'observation, sur laquelle reposent le journal, la simulation et les signes de vie :

| Fonction | Rôle |
|---|---|
| `Set-PiloteObservateur -Observateur -Simulation` | L'observateur reçoit trois types de message |

| Type | Destination | Quand |
|---|---|---|
| `journal` | `journal.log` | chaque commande exécutée |
| `simulation` | écran | chaque commande évitée en `--dry-run` |
| `progression` | écran | signe de vie pendant une opération longue |

Deux points d'accroche uniques rendent tout cela possible : **toute** commande de l'hyperviseur est construite dans `Invoke-Vmrun`, et **toute** écriture de configuration passe par `Write-FichierVmx`.

Toute erreur est une exception dont la donnée `Conseil` dit quoi faire ; la couche 1 l'affiche en jaune sous le message.

### 18.2 Ajouter un pilote

1. Créez `lib\pilote-<nom>.ps1` qui définit ces fonctions avec les mêmes paramètres et les mêmes retours.
2. `vazy config hyperviseur <nom>`.

Rien d'autre à modifier : les couches 1 et 2 ne contiennent aucune ligne propre à un hyperviseur. Ce n'est pas une affirmation en l'air — `tests\Logic\Contrat.Tests.ps1` le vérifie à chaque exécution, en analysant l'arbre syntaxique des deux couches.

### 18.3 Le pilote VirtualBox

`lib\pilote-virtualbox.ps1` existe et implémente le contrat complet via `VBoxManage` :

```
vazy config hyperviseur virtualbox
```

Il a demandé **une seule ligne de changement** dans les couches 1 et 2 : le lien de l'écran distant était figé sur `vnc://`, alors que VirtualBox parle RDP sans son extension VNC. Le protocole vient désormais du pilote (clé `SchemaAffichageDistant`).

Attention : ce pilote **n'a jamais été exécuté face à un vrai VirtualBox**. Les écarts réels avec VMware — identité des machines, `--set`, réseau host-only, écran distant, personnalisation de l'invité — et l'ordre de test recommandé sont dans **[docs/PILOTE-VIRTUALBOX.md](docs/PILOTE-VIRTUALBOX.md)**.

---

## 19. Historique des versions

L'historique détaillé, version par version, est dans
**[CHANGELOG.md](CHANGELOG.md)**.

En un coup d'œil : la 1.0 crée des VM par clone lié ; la 1.4 apporte les
instantanés, les VM éphémères et les labos ; la 1.5 la personnalisation de
l'invité sans identifiant ; la 1.6 le diagnostic, le mode simulation et la
protection du modèle ; la 1.7 l'écran distant ; la 1.8 les labos décrits en
une ligne ; la 1.9 les tests, la CI, le pilote VirtualBox et les segments
réseau isolés.

---

## 20. Contribuer, tester, réutiliser

- **Tests** : `Invoke-Pester -Path .\tests` — toute une suite de tests qui tourne sans VMware
  installé. Comment c'est possible, et ce qu'ils ne peuvent pas voir :
  [tests/README.md](tests/README.md).
- **Contribuer** : [CONTRIBUTING.md](CONTRIBUTING.md) — la règle des trois
  couches, où va quoi, et ce qu'on vérifie avant de proposer un changement.
- **Pièges déjà rencontrés** : [docs/PIEGES.md](docs/PIEGES.md) — à lire avant
  de chercher longtemps. Blocages, angles de PowerShell 5.1, règles des clones
  liés, comportements de VMware.
- **VirtualBox** : [docs/PILOTE-VIRTUALBOX.md](docs/PILOTE-VIRTUALBOX.md) — le
  second pilote et ses écarts réels avec VMware.
- **Où trouver quoi** : [docs/README.md](docs/README.md).
- **Licence** : [MIT](LICENSE). Réutilisez, modifiez, redistribuez ; gardez la
  mention de copyright.
