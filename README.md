# vazy

Une commande, une VM.

```
vazy ubuntu-server --name TP14 --ram 4 --cpu 2
```

En quelques secondes, vazy crée un **clone lié** d'un modèle VMware, règle la RAM, les CPU et le réseau, puis démarre la machine. Zéro clic dans VMware Workstation, zéro installation de système : le système a été installé une seule fois, dans le modèle.

- Système : Windows 11, VMware Workstation Pro.
- Langage : PowerShell 5.1 (livré avec Windows), aucune dépendance à installer.
- Le nom : « vas-y ». Quatre lettres, faciles à taper des milliers de fois.

---

## Sommaire

1. [Comment ça marche](#1-comment-ça-marche)
2. [Installation et ajout au PATH](#2-installation-et-ajout-au-path)
3. [Préparer un modèle depuis zéro](#3-préparer-un-modèle-depuis-zéro)
4. [Utilisation](#4-utilisation)
5. [`--set` : régler n'importe quel paramètre](#5---set--régler-nimporte-quel-paramètre)
6. [Configuration et fichiers](#6-configuration-et-fichiers)
7. [Problèmes fréquents](#7-problèmes-fréquents)
8. [Limites de cette version](#8-limites-de-cette-version)
9. [Architecture : trois couches, un pilote](#9-architecture--trois-couches-un-pilote)

---

## 1. Comment ça marche

Un **modèle** est une VM que vous préparez une seule fois à la main (installation du système, mises à jour, outils VMware), que vous éteignez, et dont vous prenez un **instantané**. Ce modèle n'est plus jamais démarré.

Chaque VM créée par vazy est un **clone lié** de cet instantané : elle ne stocke sur le disque que ses différences par rapport au modèle. La création est donc instantanée, et dix VM Ubuntu coûtent à peu près le prix d'une seule.

Deux règles absolues en découlent :

1. **Un modèle ne se démarre jamais.** vazy refuse de le faire (`vazy start <modele>` est rejeté). Si son disque de base change, tous les clones cassent.
2. **L'instantané d'un modèle ne se supprime jamais.** Supprimer (ou « consolider ») l'instantané réécrit le disque de base : tous les clones qui en dépendent deviennent inutilisables.

Point technique, pour être précis : ce qui casse réellement les clones, c'est la modification du disque de base, donc la suppression de l'instantané. Démarrer le modèle après l'instantané écrit dans un disque de différences séparé et ne casse rien par lui-même. La règle « jamais démarré » reste la protection la plus simple et la plus sûre : elle évite toute fausse manœuvre dans VMware (revenir en arrière, supprimer l'instantané par erreur). Voir « Mettre à jour un modèle » plus bas pour la procédure d'exception.

---

## 2. Installation et ajout au PATH

**Prérequis** : VMware Workstation Pro installé (vazy cherche `vmrun.exe` dans `C:\Program Files (x86)\VMware\VMware Workstation\`, dans le registre, puis dans le PATH).

1. Copiez le dossier `vazy` à un emplacement stable, par exemple `C:\Outils\vazy`. Le dossier contient :

   ```
   vazy\
     vazy.cmd                 point d'entrée (c'est lui que vous tapez)
     lib\interface.ps1        couche 1 : ligne de commande, fichiers de labo, affichage
     lib\logique.ps1          couche 2 : catalogue, vérifications, enchaînement
     lib\pilote-vmware.ps1    couche 3 : vmrun et fichiers .vmx
     exemples\tp14-ad.json    exemple de fichier de labo
     invite\linux\            script d'auto-configuration à installer dans un modèle Linux
     invite\windows\          idem pour un modèle Windows
     README.md
   ```

2. Ajoutez ce dossier au PATH utilisateur. Deux méthodes au choix.

   **Avec PowerShell** (une seule fois, à adapter au chemin choisi) :

   ```powershell
   $dossier = 'C:\Outils\vazy'
   $actuel = [Environment]::GetEnvironmentVariable('Path', 'User')
   [Environment]::SetEnvironmentVariable('Path', ($actuel.TrimEnd(';') + ';' + $dossier), 'User')
   ```

   **Avec l'interface Windows** : touche Windows, tapez « variables d'environnement », ouvrez « Modifier les variables d'environnement pour votre compte », sélectionnez `Path` dans la partie « Variables utilisateur », « Modifier », « Nouveau », collez le chemin du dossier, OK partout.

3. Fermez et rouvrez votre terminal (cmd, PowerShell ou Windows Terminal), puis vérifiez :

   ```
   vazy help
   ```

   Le bas de l'aide affiche où vazy a trouvé `vmrun.exe` et où il range sa configuration.

**Politique d'exécution des scripts** : rien à changer. `vazy.cmd` lance PowerShell avec `-ExecutionPolicy Bypass` pour ses propres scripts uniquement ; la politique de votre session n'est pas modifiée. C'est aussi pour cela que le point d'entrée est un `.cmd` et non un `.ps1` : avec la politique `Restricted` par défaut de Windows 11, un `.ps1` dans le PATH échouerait.

**Facultatif** : choisir où seront créées les VM (par défaut, dans le dossier parent du modèle, donc sur le même disque) :

```
vazy config dossierVms D:\VMs
```

Évitez un dossier synchronisé par OneDrive pour les VM.

---

## 3. Préparer un modèle depuis zéro

À faire une seule fois par système (une fois pour Ubuntu Server, une fois pour Windows 11...). Comptez le temps d'une installation classique : c'est la dernière.

Deux variantes, qui ne diffèrent qu'à l'étape 3.3 :

- **Modèle guestinfo (recommandé)** : un petit script est installé dans le modèle. Au démarrage de chaque clone, il lit la configuration que vazy a déposée de l'extérieur (nom d'hôte) et l'applique lui-même. vazy n'entre jamais dans la VM, **aucun identifiant nulle part, aucun compte privilégié**.
- **Modèle classique (repli)** : pour un modèle que vous ne pouvez pas modifier. La personnalisation passe alors par un compte de l'invité que vazy utilise depuis l'hôte (`vazy template creds`). **Ce compte privilégié est cloné dans toutes vos VM**, y compris celles que vous posez sur un segment réseau pendant un TP de sécurité : c'est une mauvaise posture, réservez-la aux cas sans alternative.

### 3.1 Créer la VM dans VMware Workstation

1. `File > New Virtual Machine`, mode `Typical`.
2. Choisissez l'ISO d'installation.
3. **Nom de la VM** : celui-ci deviendra l'alias du modèle, choisissez court et sans espace, par exemple `ubuntu-server`. **Emplacement** : un dossier dédié, par exemple `D:\VMs\ubuntu-server`.
4. **Disque** : indiquez une taille maximale large (par exemple `200 GB`) et gardez `Store virtual disk as a single file`. Ne cochez **pas** « Allocate all disk space now » : le disque est dynamique, il ne consomme que ce qui est réellement écrit. C'est ce qui permet de ne jamais avoir à redimensionner.
5. Matériel : laissez les valeurs par défaut. RAM, CPU et cartes réseau seront de toute façon redéfinis par vazy sur chaque clone.

### 3.2 Installer et préparer le système

1. Installez le système normalement.
2. Installez les outils d'intégration VMware :
   - Ubuntu Server / Debian : `open-vm-tools` (l'installeur Ubuntu le fait souvent automatiquement ; sinon `sudo apt install open-vm-tools`).
   - Windows : menu `VM > Install VMware Tools`, puis lancez l'installation depuis le lecteur CD virtuel.

   Sans ces outils, `vazy stop` ne peut pas demander un arrêt propre (il faudra `--hard`).
3. Faites les mises à jour, installez ce que tous vos TP auront en commun (éditeur, SSH, etc.).
4. Nettoyez : `sudo apt clean` sous Linux ; retirez l'ISO du lecteur CD virtuel (`VM > Settings > CD/DVD`, décochez `Connect at power on`).

### 3.3 Variante guestinfo (recommandée) : installer le script d'auto-configuration

Les fichiers sont dans le dossier `invite` de vazy.

**Linux (Ubuntu Server, Debian, tout système avec systemd)** : un seul fichier à transférer, `invite\linux\installer.sh`, qui contient le script et son unité systemd. Depuis Windows, avec l'adresse IP de la VM (`ip a` dedans) :

```
scp "C:\Outils\vazy\invite\linux\installer.sh" etudiant@192.168.x.y:/tmp/
```

Puis dans la VM :

```
sudo sh /tmp/installer.sh
```

Ce que ça installe : `/usr/local/sbin/vazy-guestinfo` (script POSIX, sans dépendance) et `vazy-guestinfo.service`, une unité systemd lancée à chaque démarrage **avant le réseau**, qui :

- lit `guestinfo.vazy_config` avec `vmtoolsd --cmd "info-get ..."` (open-vm-tools) ;
- applique le nom d'hôte : `hostnamectl set-hostname` si D-Bus est déjà disponible, sinon écriture directe de `/etc/hostname`, ce qui revient au même, puis mise à jour de la ligne `127.0.1.1` de `/etc/hosts` ;
- régénère les clés d'identité du serveur SSH et `/etc/machine-id` quand elles viennent d'une autre machine (l'UUID du BIOS change à chaque clone ; le script mémorise celui pour lequel il a généré les clés dans `/var/lib/vazy/identite.uuid`). Sans cela, tous les clones ont la même empreinte SSH, et deux clones Ubuntu demandent la même adresse au DHCP ;
- ne fait rien si la variable est absente ou vide, ni si tout est déjà en place : idempotent, jamais de redémarrage.

Pas de `scp` possible ? Ouvrez `installer.sh` dans un éditeur sur Windows, collez son contenu dans la VM avec `cat > /tmp/installer.sh` puis `Ctrl+D`. Il doit rester en fins de ligne LF (c'est le cas du fichier livré).

**Windows** : copiez le dossier `invite\windows` dans la VM (lecteur partagé, `scp` si OpenSSH est installé, ou clé USB), puis en administrateur :

```
powershell -ExecutionPolicy Bypass -File installer.ps1
```

Ce que ça installe : `C:\ProgramData\vazy\vazy-guestinfo.ps1` et une tâche planifiée `vazy-guestinfo` lancée au démarrage sous le compte SYSTEM, qui lit la variable avec `vmtoolsd.exe`, applique `Rename-Computer` **sans redémarrer si le nom est déjà le bon**, redémarre une seule fois après un renommage effectif (Windows ne prend un nouveau nom qu'au redémarrage), et régénère les clés du serveur OpenSSH s'il est installé. Journal : `C:\ProgramData\vazy\vazy-guestinfo.log`. Le SID de la machine, lui, reste celui du modèle : seul `sysprep` le change, hors périmètre.

Une fois le script installé, passez à l'étape 3.4.

### 3.3 bis Variante classique (repli) : un compte pour vazy

Rien à installer dans le modèle, mais il faut un compte que vazy utilisera depuis l'hôte, après le démarrage, pour exécuter le renommage :

- Linux : un compte pouvant faire `sudo` **sans mot de passe** (`echo "etudiant ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/vazy`), ou `root`.
- Windows : le compte `Administrateur` intégré, activé, avec mot de passe (un administrateur ordinaire est bloqué par l'UAC, VMware ne l'élève pas).

Ce compte sera présent dans chaque clone. Après l'enregistrement du modèle (3.5) : `vazy template creds <alias>`.

### 3.4 Vider ce qui mémorise la machine (Linux, obligatoire avant l'instantané)

Un clone a de **nouvelles cartes réseau** (adresses MAC régénérées). Si le modèle a mémorisé l'ancienne carte, le clone se retrouve avec une interface qui ne correspond à rien et **n'a plus de réseau du tout**. Avant d'éteindre le modèle, vérifiez et nettoyez :

1. **netplan (Ubuntu)** : `cat /etc/netplan/*.yaml`. S'il contient `match: macaddress:` ou `set-name:`, la configuration est liée à la MAC du modèle. Remplacez le fichier par une configuration générique :

   ```yaml
   network:
     version: 2
     ethernets:
       toutes:
         match:
           name: "en*"
         dhcp4: true
   ```

   Si le fichier s'appelle `50-cloud-init.yaml`, cloud-init le régénérera : désactivez sa gestion du réseau avec `sudo sh -c 'echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'`.
2. **Règles udev persistantes** (Debian ancien, autres) : `sudo rm -f /etc/udev/rules.d/70-persistent-net.rules`.
3. **Fichiers `.link` systemd** liant un nom d'interface à une MAC : `ls /etc/systemd/network/*.link` ; supprimez ceux qui contiennent `MACAddress=`.
4. **NetworkManager** (Debian bureau, Fedora) : dans `/etc/NetworkManager/system-connections/*.nmconnection`, retirez toute ligne `mac-address=`, ou supprimez les profils pour qu'il en recrée.
5. **Baux DHCP** mémorisés : `sudo rm -f /var/lib/dhcp/*.leases /var/lib/NetworkManager/*.lease; sudo rm -rf /run/systemd/netif/leases`.
6. **Identifiant machine** : `/etc/machine-id` sert d'identifiant DHCP à systemd-networkd. Le script guestinfo le régénère sur chaque clone ; pour un modèle classique, videz-le : `sudo truncate -s 0 /etc/machine-id` (systemd en génère un neuf au premier démarrage).

Vérification : `ip -br link` doit montrer une interface nommée `ens33` ou `ens160` ; c'est ce nom, issu de l'emplacement PCI, qui reste stable d'un clone à l'autre, contrairement à la MAC.

Windows n'a pas ce problème pour le réseau ; le SID dupliqué est un autre sujet (sysprep), hors périmètre.

### 3.5 Éteindre, prendre l'instantané, enregistrer le modèle

**Éteignez la VM proprement, depuis l'intérieur du système.** Puis, VM éteinte, dans VMware Workstation : `VM > Snapshot > Take Snapshot...`, nommez-le `base`, validez.

Ou en ligne de commande :

```
"C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe" -T ws snapshot "D:\VMs\ubuntu-server\ubuntu-server.vmx" base
```

Enregistrez le modèle dans vazy :

```
vazy template add "D:\VMs\ubuntu-server\ubuntu-server.vmx"
vazy template mark ubuntu-server --guestinfo        (variante guestinfo uniquement)
```

- L'alias par défaut est le nom du fichier sans extension (`ubuntu-server`). Pour en choisir un autre : `--name <alias>`.
- Si la VM a plusieurs instantanés, le dernier de la liste est utilisé ; pour en imposer un : `--snapshot <nom>`.
- vazy refuse d'enregistrer une VM sans instantané et explique comment en créer un.
- vazy pose un fichier témoin à côté de la VM (`ubuntu-server.vmx.vazy-modele`). Tant qu'il existe, vazy refuse de démarrer, supprimer ou modifier les instantanés de cette VM, même par erreur de manipulation du catalogue.
- `template mark --guestinfo` dit à vazy que le script est dans le modèle : dès lors, `--hostname` et la clé `hostname` des labos passent par le dépôt de configuration, sans identifiant. `vazy template list` affiche la méthode de chaque modèle.

C'est terminé. **Ne redémarrez plus jamais cette VM.** Créez vos machines de TP :

```
vazy ubuntu-server --hostname web1
```

### 3.6 Mettre à jour un modèle (procédure d'exception)

Si un jour vous devez modifier le modèle (nouvelle version d'un paquet, par exemple), voici la seule façon sûre :

1. Démarrez le modèle dans VMware Workstation, faites les modifications, éteignez-le proprement.
2. Prenez un **nouvel** instantané (`base-2`). **Ne supprimez pas l'ancien** tant qu'un clone en dépend.
3. Ré-enregistrez le modèle sur le nouvel instantané :

   ```
   vazy template rm ubuntu-server
   vazy template add "D:\VMs\ubuntu-server\ubuntu-server.vmx" --snapshot base-2
   ```

Les anciens clones continuent d'utiliser `base`, les nouveaux partent de `base-2`.

---

## 4. Utilisation

### La commande principale

```
vazy <modele> [options]
```

Crée un clone lié du modèle, applique les options, démarre la VM. Toutes les options sont facultatives.

| Option | Rôle | Défaut |
|---|---|---|
| `--name <nom>` | Nom de la VM (lettres, chiffres, `.`, `-`, `_` ; il sert aussi de nom de dossier) | `<modele>-1`, `<modele>-2`, ... |
| `--ram <Go>` | Mémoire en Go, décimales acceptées (`1.5`, `0.5`) | `2` |
| `--cpu <n>` | Nombre de cœurs | `2` |
| `--reseau <n>` | Nombre de cartes réseau (`0` = aucune) | `1` |
| `--mode <m>` | Type de réseau : `nat`, `bridged`, `hostonly` ; un mode par carte en répétant l'option | `nat` |
| `--set <cle>=<valeur>` | Écrit une ligne brute dans la configuration de la VM ; répétable ; appliqué après les autres options | |
| `--nogui` | Démarre sans ouvrir de fenêtre VMware | désactivé |
| `--nostart` | Crée sans démarrer | désactivé |
| `--tmp` | VM éphémère : supprimée automatiquement dès qu'elle est trouvée éteinte (voir plus bas) ; incompatible avec `--nostart` | désactivé |
| `--hostname <nom>` | Nom d'hôte appliqué dans l'invité après le démarrage (voir « Personnalisation de l'invité ») | aucun |

Exemples :

```
vazy ubuntu-server
vazy ubuntu-server --name TP14 --ram 4 --cpu 2
vazy win11 --mode nat --mode hostonly --nogui
vazy ubuntu-server --reseau 3 --mode bridged
vazy ubuntu-server --set svga.autodetect=FALSE --set usb.present=TRUE
```

Réseau : avec `--mode nat --mode hostonly`, la première carte est en NAT et la seconde en host-only (le classique « internet + réseau de labo »). Si `--reseau` demande plus de cartes que de modes, les cartes supplémentaires reprennent le dernier mode indiqué. La forme `--mode "nat,hostonly"` fonctionne aussi, mais **sous PowerShell les guillemets sont obligatoires**, sinon la virgule sépare les arguments. Même remarque pour `--ram "1,5"` : préférez `--ram 1.5`.

Ce que vous voyez pendant la création :

```
vazy : création d'une VM depuis le modèle « ubuntu-server »
[1/5] Vérifications
      modèle « ubuntu-server » (instantané « base »), destination D:\VMs\TP14, 214,3 Go libres
[2/5] Clonage lié
      D:\VMs\TP14\TP14.vmx créé en 6,8 s
[3/5] Réglages
      4 Go de RAM (4096 Mo), 2 CPU
[4/5] Réseau
      1 carte : nat
[5/5] Démarrage
      VM démarrée en 4,1 s

VM « TP14 » prête et démarrée en 12,4 s.
  dossier : D:\VMs\TP14
  arrêter : vazy stop TP14     supprimer : vazy rm TP14
```

### Les commandes secondaires

| Commande | Rôle |
|---|---|
| `vazy list` | VM créées par vazy, avec leur état (`en marche`, `arrêtée`, `absente` si les fichiers ont disparu) |
| `vazy start <nom> [--nogui]` | Démarre une VM |
| `vazy stop <nom> [--hard]` | Arrêt propre via les outils VMware ; `--hard` coupe le courant |
| `vazy rm <nom> [--yes]` | Supprime la VM et tous ses fichiers, après confirmation (`--yes` pour la sauter) ; arrêt forcé si elle tourne |
| `vazy reset <nom> [--nostart] [--nogui]` | Remet la VM à neuf : retour à l'instantané `vazy-neuf`, puis redémarrage (voir ci-dessous) |
| `vazy snap <nom> [libelle]` | Instantané manuel |
| `vazy snaps <nom>` | Liste les instantanés |
| `vazy back <nom> <libelle> [--nostart] [--nogui]` | Retour à un instantané manuel, puis redémarrage |
| `vazy unsnap <nom> <libelle> [--yes]` | Supprime un instantané manuel, après confirmation |
| `vazy gc [--yes]` | Supprime les VM éphémères éteintes (le nettoyage se fait aussi tout seul au début de chaque commande) |
| `vazy doctor` | Diagnostic complet : hyperviseur, disque, modèles, VM, cohérence catalogue / disque |
| `vazy freeze <nom> [--yes]` | Convertit un clone lié en VM complète : elle ne dépend plus du modèle |
| `vazy lab up <fichier.json>` | Monte un labo entier décrit par un fichier (voir ci-dessous) |
| `vazy lab status <fichier.json>` | État de chaque machine du labo |
| `vazy lab down <fichier.json> [--yes] [--stop-only] [--hard]` | Arrête et supprime le labo, après confirmation ; `--stop-only` arrête sans supprimer |
| `vazy lab export <fichier.json> --labo <nom>\|--prefixe <p>\|--vms a,b,c [--requis]` | Génère le fichier de labo qui recréerait des VM existantes |
| `vazy template alias <alias> <nom standard> [--rm]` | Fait répondre votre modèle à un nom standard, pour monter un labo partagé |
| `vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]` | Enregistre un modèle (le dossier de la VM est accepté à la place du `.vmx`) |
| `vazy template list` | Modèles enregistrés, instantané utilisé, nombre de clones |
| `vazy template rm <alias>` | Retire un modèle du catalogue ; **aucun fichier n'est supprimé** |
| `vazy template mark <alias> --guestinfo\|--classique` | Déclare que le modèle embarque le script `vazy-guestinfo` : personnalisation sans identifiant |
| `vazy template creds <alias> [--user <nom>] [--os linux\|windows] [--rm]` | Repli pour un modèle non modifiable : identifiants d'un compte de l'invité (mot de passe saisi masqué, stocké chiffré) |
| `vazy config [<cle> <valeur>]` | Affiche ou modifie la configuration |
| `vazy help`, `vazy version` | |

Codes de retour : `0` succès, `1` erreur, `2` erreur de syntaxe.

**Option générale `--dry-run`** : n'exécute rien, affiche en magenta les commandes `vmrun` exactes qui seraient lancées et les lignes qui seraient écrites dans la configuration des VM. Les lectures (état des VM, instantanés, espace disque) ont bien lieu, sinon il n'y aurait rien à décider. Ni le catalogue ni les fichiers ne sont touchés. Utile pour vérifier avant une opération destructrice, et pour apprendre `vmrun` :

```
vazy ubuntu-server --name TP20 --ram 4 --dry-run
vazy lab down tp14-ad.json --yes --dry-run
```

**Journal** : chaque opération est enregistrée dans `%LOCALAPPDATA%\vazy\journal.log`, avec la ligne de commande vazy, chaque commande `vmrun` lancée (mot de passe remplacé par `***`), son code de retour, sa durée, et chaque écriture dans un fichier de configuration de VM. Le fichier tourne tout seul au-delà de 2 Mo. C'est le premier endroit à regarder quand quelque chose s'est mal passé.

### Remise à zéro et instantanés

Un TP, on le casse. Plutôt que de recréer la VM, on revient en arrière :

```
vazy reset TP14
```

Juste après la création d'une VM, avant son premier démarrage, vazy prend automatiquement un instantané nommé `vazy-neuf`. `vazy reset` y revient : la VM est arrêtée si elle tourne, ramenée à l'état neuf, puis redémarrée. L'instantané ayant été pris machine éteinte, il n'y a aucun état mémoire à restaurer : le retour prend quelques secondes.

```
vazy : remise à zéro de « TP14 »
[1/3] Arrêt
      VM en marche : arrêt forcé (son état actuel est abandonné par le retour)
[2/3] Retour à l'instantané « vazy-neuf »
      terminé en 1,8 s
[3/3] Démarrage
      VM démarrée en 3,4 s

VM « TP14 » remise à neuf et redémarrée en 5,6 s.
```

Pourquoi un arrêt forcé plutôt qu'un arrêt propre ? Parce que tout ce qui s'est passé depuis l'instantané est abandonné de toute façon par le retour : un arrêt propre ne protégerait rien et coûterait 10 à 30 secondes de plus.

Pour jalonner un TP long :

| Commande | Rôle |
|---|---|
| `vazy snap TP14 avant-dhcp` | Instantané manuel (sans libellé : `snap-<date>-<heure>`) |
| `vazy snaps TP14` | Liste les instantanés et leur rôle |
| `vazy back TP14 avant-dhcp` | Revient à cet instantané puis redémarre (`--nostart` pour ne pas redémarrer) |
| `vazy unsnap TP14 avant-dhcp` | Supprime l'instantané, après confirmation |

Règles :

- `vazy-neuf` est protégé : `snap` refuse de l'écraser, `unsnap` refuse de le supprimer.
- Un instantané pris VM en marche inclut la mémoire : plus long à prendre, et `back` ramène la VM en marche dans cet état. Pour un jalon léger, prenez-le VM éteinte.
- Les instantanés d'un **modèle** ne sont jamais touchés. `template add` pose un fichier témoin à côté du modèle (`<modele>.vmx.vazy-modele`) ; tant qu'il existe, le pilote refuse lui-même de démarrer, supprimer ou prendre un instantané de cette VM, quel que soit l'état du catalogue. `template rm` le retire.
- VM créées avant cette version : elles n'ont pas de `vazy-neuf`. Pour l'ajouter une fois, VM éteinte et dans l'état que vous voulez retrouver : `vazy stop TP14` puis `vazy snap TP14 vazy-neuf`. C'est le seul cas où `snap` accepte ce libellé.

### VM éphémères

Je teste une commande, j'éteins, il ne reste rien :

```
vazy ubuntu-server --tmp
```

La VM s'appelle `ubuntu-server-tmp-1`, est créée et démarrée comme les autres, puis marquée **éphémère** dans le catalogue (`vazy list` l'affiche avec `oui` dans la colonne TMP). Dès qu'elle est trouvée éteinte, elle est supprimée, fichiers compris. Aucun service en arrière-plan : le nettoyage est paresseux.

1. **Au début de chaque commande vazy**, quelle qu'elle soit, l'outil regarde s'il existe des VM éphémères au catalogue. S'il n'y en a pas, cela ne coûte rien (aucun appel à VMware). S'il y en a, il interroge leur état et supprime celles qui sont éteintes, en l'annonçant sur une ligne par VM.
2. `vazy stop <nom>` sur une VM éphémère la supprime dans la foulée.
3. `vazy gc` lance le nettoyage à la demande et dit ce qu'il a fait.

```
vazy list
      VM éphémère « ubuntu-server-tmp-1 » éteinte : supprimée (D:\VMs\ubuntu-server-tmp-1)
NOM   ÉTAT   ...
```

Garde-fous :

- Une VM qui n'est pas marquée éphémère n'est **jamais** supprimée par le nettoyage, quel que soit son état. La fonction de suppression refuse elle-même toute VM non marquée.
- Le marquage n'est posé qu'une fois la VM démarrée. Si le démarrage échoue, la VM reste une VM normale (à examiner, puis `vazy rm`). Cela évite aussi qu'une commande vazy lancée dans un autre terminal pendant le démarrage ne la prenne pour une VM éteinte.
- Au-delà de 3 VM éphémères à supprimer d'un coup, vazy demande confirmation : c'est probablement le signe d'une anomalie. Sans console interactive, rien n'est supprimé ; relancez `vazy gc --yes` après vérification.
- `--tmp` et `--nostart` sont incompatibles : une VM éphémère créée éteinte serait supprimée au lancement suivant.

Ce qu'il faut savoir sur VMware Workstation : fermer la fenêtre d'une VM en marche ne l'éteint pas forcément. Selon la préférence `Edit > Preferences > Workspace`, la VM continue de tourner en arrière-plan. Une VM éphémère qui tourne encore n'est pas supprimée. Pour être sûr : éteignez-la depuis l'intérieur (`shutdown`, `poweroff`), ou `vazy stop <nom>`, qui l'arrête proprement et la supprime.

### Fichier de labo

Un fichier décrit un TP entier, une commande le monte :

```
vazy lab up tp14-ad.json
vazy lab status tp14-ad.json
vazy lab down tp14-ad.json
```

Le format est du JSON (PowerShell le lit nativement ; pas de YAML, qui demanderait une dépendance). Exemple complet, fourni dans `exemples\tp14-ad.json` :

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

Clés du labo :

| Clé | Rôle | Défaut |
|---|---|---|
| `labo` | Nom du labo, préfixe de toutes ses VM (32 caractères max, sans espace ni accent) | nom du fichier sans `.json` |
| `delai` | Secondes d'attente entre deux démarrages, pour ne pas lancer trois Windows dans la même seconde | `5` |
| `requis` | Modèles attendus, vérifiés avant toute action (labo partagé) | aucun |
| `machines` | Une entrée par machine : la clé est le nom court de la machine | |

Chaque machine accepte **exactement les mêmes clés que les options de création**, sans les tirets : `modele` (obligatoire), `ram`, `cpu`, `reseau`, `mode`, `set`, `nogui`, `nostart`, `hostname`. Plus une clé propre au labo : `apres`, la ou les machines qui doivent être démarrées avant celle-ci. Détails de forme :

- `mode` : une chaîne (`"hostonly"`, `"nat,hostonly"`) ou une liste (`["nat", "hostonly"]`), un mode par carte comme en ligne de commande.
- `set` : un objet `{ "cle": "valeur", ... }` ou une liste `[ "cle=valeur", ... ]`.
- `apres` : une chaîne ou une liste de noms de machines du fichier.
- `nogui`, `nostart` : `true` ou `false`.
- `hostname` : nom d'hôte appliqué dans l'invité (voir « Personnalisation de l'invité »). **Par défaut, le nom court de la machine** (`dc01`). `false` ou `""` pour ne rien appliquer. Sans méthode de personnalisation sur le modèle, la clé est ignorée avec une ligne d'information.
- Une clé inconnue (faute de frappe, `tmp`, `name`) est refusée avant toute action.

Au niveau du labo, la clé `requis` déclare les modèles attendus ; elle est vérifiée avant toute action (voir « Exporter un labo, partager un labo »).

Comportement :

- **Nommage préfixé** : la machine `dc01` du labo `tp14-ad` devient la VM `tp14-ad-dc01`. Deux labos ne se marchent jamais dessus, et `vazy list` affiche le labo de chaque VM.
- **Validation avant action** : modèles inconnus, dépendances circulaires, `apres` vers une machine inexistante, nom déjà pris par une VM hors labo, espace disque pour l'ensemble des VM à créer. Si une vérification échoue, aucune VM n'est créée.
- **Idempotence** : relancer `lab up` ne recrée pas ce qui existe. Les VM manquantes sont créées, les éteintes sont démarrées, celles qui tournent sont laissées tranquilles. Une VM dont les fichiers ont disparu est recréée. Modifier la RAM ou le réseau d'une machine dans le fichier ne change pas une VM déjà créée : supprimez-la (`vazy rm`) ou démontez le labo, puis relancez `lab up`.
- **Ordre de démarrage** : d'abord toutes les créations, puis les démarrages dans l'ordre des dépendances (`apres`), avec `delai` secondes entre deux démarrages. vazy ne sait pas quand un système a fini de démarrer : `apres` garantit l'ordre et le délai, pas que le contrôleur de domaine répond déjà.
- `lab status` : tableau par machine avec l'état `en marche`, `arrêtée`, `à créer`, `absente` (fichiers disparus) ou `hors labo` (le nom est pris par une VM qui n'appartient pas à ce labo). Les VM du catalogue rattachées au labo mais retirées du fichier apparaissent en `(hors fichier)` et sont démontées avec le reste.
- `lab down` : arrêt de toutes les VM dans l'ordre inverse du démarrage, puis suppression, après confirmation (`--yes` pour la sauter). `--stop-only` arrête proprement sans supprimer, avec repli en arrêt forcé si les outils de l'invité ne répondent pas ; `--hard` force d'emblée.

```
vazy : montage du labo « tp14-ad » (D:\TP\tp14-ad.json)
Vérifications du labo « tp14-ad »
      3 machine(s), modèles win2022, win11, ordre de démarrage : dc01 > srv01 > client
      à créer : dc01, srv01, client
Création 1/3 : dc01 -> VM « tp14-ad-dc01 »
[1/5] Vérifications
      ...
Démarrage de dc01 -> VM « tp14-ad-dc01 »
      démarrée en 4,2 s
      attente de 10 s avant srv01
Démarrage de srv01 -> VM « tp14-ad-srv01 » (après dc01)
      ...

Labo « tp14-ad » monté en 58,3 s : 3 VM créée(s), 3 démarrée(s).
MACHINE  VM              ÉTAT       MODÈLE   RAM   CPU  RÉSEAU        APRÈS
dc01     tp14-ad-dc01    en marche  win2022  4 Go  2    hostonly
srv01    tp14-ad-srv01   en marche  win2022  2 Go  2    hostonly      dc01
client   tp14-ad-client  en marche  win11    4 Go  2    nat,hostonly  dc01,srv01
```

### Exporter un labo, partager un labo

Monter un TP à la main puis en garder la recette :

```
vazy lab export tp20.json --prefixe tp20 --requis
```

vazy lit les VM existantes et écrit le fichier qui les recréerait : modèle, RAM, CPU, réseau, réglages `--set` et nom d'hôte de chacune. Trois façons de désigner les VM à exporter :

| Option | VM concernées |
|---|---|
| `--labo <nom>` | Celles montées par un `lab up` précédent (colonne LABO de `vazy list`) |
| `--prefixe <p>` | Celles dont le nom commence par `p-` (un TP monté à la main en les nommant `tp20-dc01`, `tp20-cli`) |
| `--vms a,b,c` | Une liste explicite |

Le nom court de chaque machine est son nom de VM sans le préfixe. `--delai <n>` fixe l'attente entre deux démarrages (5 s par défaut), `--yes` remplace un fichier existant sans demander.

L'export **rattache les VM exportées au labo** : elles gardent leur nom, mais `vazy lab up` et `vazy lab down` avec ce fichier les reconnaissent désormais comme les siennes. Sans cela, rejouer le fichier buterait sur « la VM existe déjà mais n'appartient pas à ce labo ». `vazy list` affiche le rattachement dans la colonne LABO.

**`--requis`** ajoute un bloc de prérequis, indispensable si vous partagez le fichier : il décrit les modèles attendus (système, taille de disque déclarée) sous les noms que vous leur donnez. Relisez-le avant d'envoyer le fichier, et remplacez vos noms locaux par des noms standards si vous voulez qu'il soit rejouable par d'autres.

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

À l'autre bout, celui qui reçoit le fichier lance `vazy lab up tp20.json`. **Les prérequis sont vérifiés avant toute action** : si un modèle manque, vazy refuse et dit quoi préparer, sans avoir créé la moindre VM. Le système et la taille de disque déclarés produisent un avertissement s'ils ne correspondent pas, sans bloquer.

Le problème classique : le labo demande `win2022`, mais votre modèle s'appelle `windows-server`. Plutôt que de renommer, déclarez une correspondance locale, une fois pour toutes :

```
vazy template alias windows-server win2022
```

Désormais, tout labo qui demande `win2022` utilise votre modèle. `vazy template list` affiche ces noms dans la colonne « AUSSI CONNU COMME », et `--rm` retire la correspondance. Un alias ne peut pas masquer un modèle existant, ni pointer vers deux modèles à la fois.

Ce qui n'est **pas** fait dans cette version : `vazy lab up ad-2022` qui irait chercher le labo dans un dépôt public, `vazy lab search`, `vazy lab publish`. Le format est prêt (bloc `requis`, alias locaux) ; il manque le dépôt et son protocole.

### Diagnostic : `vazy doctor`

Sur un outil qui manipule des clones liés, l'écart entre le catalogue et la réalité du disque est certain, pas probable. `vazy doctor` le rend visible :

```
vazy doctor
```

Il vérifie, dans l'ordre : `vmrun` trouvé et qui répond ; Hyper-V ; espace libre de chaque dossier de VM ; chaque modèle (fichier présent, instantané d'ancrage intact, machine bien éteinte, marque de protection, nombre de clones qui en dépendent) ; chaque VM du catalogue (fichiers présents, état, modèle intact, point de retour présent) ; et les machines trouvées dans vos dossiers mais absentes du catalogue. Chaque ligne en échec est suivie de la marche à suivre. Code de retour 1 s'il y a au moins un échec, 0 sinon.

```
MODÈLE
  OK     ubuntu-server          instantané « base » présent ; 3 clone(s) lié(s) en dépendent : TP14, TP15, web
  ECHEC  win2022                fichier introuvable : D:\VMs\win2022\win2022.vmx ; 2 clone(s) lié(s) en dépendent : ad-dc01, ad-cli
           -> Remettez le modèle à cet emplacement exact, ou restaurez-le depuis une sauvegarde. Sans lui, ses clones liés ne démarrent plus.
```

### Rendre une VM autonome : `vazy freeze`

Un clone lié ne contient que ses différences par rapport au modèle : c'est ce qui rend la création instantanée, mais il **meurt si le modèle disparaît ou change**. Pour la VM d'un projet que vous voulez garder six mois :

```
vazy stop projet-web
vazy freeze projet-web
```

vazy en fait une copie complète : la VM occupe alors toute sa taille sur le disque (comptez plusieurs minutes de copie), mais ne dépend plus de rien. `vazy list` et `vazy doctor` la signalent comme autonome, et vazy cesse de vérifier son modèle.

Deux points : la VM doit être **arrêtée**, et les instantanés ne survivent pas à une copie complète. vazy reprend donc le point de retour `vazy-neuf` sur l'état courant, qui devient le nouvel état « neuf » ; vos jalons manuels, eux, sont perdus.

**Protection automatique, sans rien faire** : à la création de chaque clone, vazy enregistre l'empreinte des disques de base du modèle (nom, taille, date). Avant chaque démarrage, il la compare. Si le modèle a disparu, été déplacé, ou si l'un de ses instantanés a été supprimé ou consolidé dans VMware Workstation, vazy refuse de démarrer et dit exactement ce qui manque, au lieu de laisser VMware produire une erreur incompréhensible. Les VM créées avant cette version n'ont pas d'empreinte : `vazy doctor` le signale.

**Limite à connaître avant un TP de routage** : le champ `mode` se limite à `nat`, `bridged` et `hostonly`, c'est-à-dire VMnet8, VMnet0 et VMnet1. Les segments réseau personnalisés (VMnet2, VMnet3, ...) sont **hors périmètre** : ils se créent dans le Virtual Network Editor de VMware avec les droits administrateur, et vazy ne les gère pas. Toutes les machines en `hostonly` partagent le même segment VMnet1 ; deux labos en `hostonly` montés en même temps se voient. Si vous avez déjà créé un VMnet personnalisé à la main, une machine peut s'y brancher via `set` (`"set": { "ethernet0.connectionType": "custom", "ethernet0.vnet": "VMnet2" }`), mais vazy ne vérifie ni son existence ni son adressage.

### Personnalisation de l'invité (nom d'hôte)

Les clones d'un modèle sont identiques : même nom d'hôte, même identifiant machine, mêmes clés SSH. vazy peut donner à chaque clone son **nom d'hôte**, avec `--hostname` ou, dans un labo, le nom court de chaque machine par défaut. Deux méthodes, choisies d'après le modèle (`vazy template list` l'affiche) :

**Méthode guestinfo (recommandée, sans identifiant).** Le modèle embarque le script `vazy-guestinfo` (section 3.3) et est marqué `vazy template mark <alias> --guestinfo`. Avant **chaque** démarrage fait par vazy (création, `start`, `reset`, `back`, `lab up`), vazy dépose la configuration dans la machine, sous forme d'une variable `guestinfo.vazy_config` que le script lit au démarrage avec les outils invité et applique lui-même. vazy n'entre jamais dans la VM. Rien à réappliquer après `reset` ou `back` : le script relit la variable à chaque démarrage, le nom revient tout seul. Aucune attente, aucun compte, aucun mot de passe nulle part.

La charge utile est du JSON encodé en base64, pour éviter tout problème d'échappement :

```json
{ "hostname": "web1" }
```

Le format accueillera plus tard `ip`, `masque`, `passerelle`, `dns`, `cle_ssh` ; seul `hostname` est appliqué aujourd'hui, et le script invité ignore toute clé qu'il ne connaît pas. Détail technique : la variable est écrite dans la configuration de la VM (clé `guestinfo.vazy_config` du `.vmx`), machine éteinte, ce qui la rend persistante ; `vmrun writeVariable ... guestVar` n'aurait pas convenu, cette forme n'existe qu'à l'exécution et disparaît à l'extinction.

**Méthode classique (repli, par identifiants).** Pour un modèle qu'on ne peut pas modifier : `vazy template creds <alias>` enregistre un compte de l'invité (mot de passe saisi masqué, stocké chiffré par DPAPI dans `%LOCALAPPDATA%\vazy\creds\<alias>.xml`, lisible uniquement par votre compte Windows sur ce PC ; jamais affiché, masqué par `***` dans tout message venant de VMware). Après chaque démarrage fait par vazy, celui-ci attend que les outils invité répondent (`delaiOutilsSec`, 120 s par défaut, avec nouvelles tentatives sur le premier script, car les outils se disent prêts un peu avant de l'être), puis exécute le script de renommage dans la VM : `hostnamectl` et `/etc/hosts` sous Linux ; `Rename-Computer` sous Windows, **sans redémarrer** : le script rend la main et c'est vazy qui arrête proprement la VM puis la redémarre, pour un état déterministe. Le script est idempotent. Limite à connaître : `vmrun` ne reçoit ces identifiants que par `-gu` et `-gp` sur sa ligne de commande, visible pendant les quelques secondes de l'appel pour les processus de votre compte Windows ; et surtout, ce compte privilégié est cloné dans toutes vos VM.

Règle absolue, dans les deux méthodes : si la personnalisation échoue (script absent du modèle, outils absents, identifiants refusés, nom invalide), **la VM reste créée et démarrée**. vazy avertit avec la cause et la marche à suivre.

Ce qui n'est pas fait dans cette version : IP fixe, clé SSH de l'utilisateur, SID Windows. Le format et le script sont prêts à les accueillir ; le nom d'hôte doit d'abord tenir la route sur un vrai TP.

---

## 5. `--set` : régler n'importe quel paramètre

Une VM VMware est entièrement décrite par son fichier `.vmx`, un fichier texte de lignes `cle = "valeur"`. `--set cle=valeur` écrit littéralement cette ligne dans le `.vmx` du clone (la ligne existante est remplacée, sinon elle est ajoutée). Comme il s'applique **après** les options nommées, il peut les écraser : `--ram 4 --set memsize=8192` donne 8 Go.

Quelques réglages utiles :

| `--set` | Effet |
|---|---|
| `svga.autodetect=FALSE` + `svga.vramSize=16777216` | Fige la mémoire vidéo (16 Mo) |
| `usb.present=TRUE` | Active le contrôleur USB |
| `sound.present=FALSE` | Retire la carte son |
| `mainMem.useNamedFile=FALSE` | Pas de fichier `.vmem` de la taille de la RAM à côté de la VM |
| `bios.bootDelay=3000` | 3 s de délai au démarrage pour attraper le menu du BIOS |
| `bios.forceSetupOnce=TRUE` | Entre dans le BIOS au prochain démarrage |
| `ethernet0.virtualDev=e1000` | Change le type de carte réseau (`e1000`, `e1000e`, `vmxnet3`) |
| `ethernet0.connectionType=custom` + `ethernet0.vnet=VMnet2` | Branche la carte 0 sur un réseau personnalisé déjà créé dans le Virtual Network Editor |
| `guestOS=ubuntu-64` | Type de système invité déclaré à VMware |
| `tools.syncTime=TRUE` | Synchronise l'horloge sur l'hôte |
| `displayName=TP 14 - Serveur web` | Nom affiché dans VMware (les espaces sont acceptés ici, contrairement à `--name`) |

Pour découvrir une clé : faites le réglage une fois dans l'interface de VMware sur une VM éteinte, puis ouvrez son `.vmx` dans un éditeur de texte et repérez la ligne ajoutée.

Note : vazy ajoute lui-même `msg.autoAnswer = "TRUE"` à chaque clone pour que VMware réponde seul aux questions au démarrage (« cette VM a été déplacée ou copiée ? »). `--set msg.autoAnswer=FALSE` l'annule.

---

## 6. Configuration et fichiers

vazy range ses données dans `%LOCALAPPDATA%\vazy\` (`C:\Users\<vous>\AppData\Local\vazy\`) :

| Fichier | Contenu |
|---|---|
| `config.json` | Réglages de l'outil |
| `catalogue.json` | Modèles enregistrés et VM créées (clé `version` : schéma du fichier ; un catalogue plus ancien est migré automatiquement au premier lancement, sans perte) |
| `creds\<alias>.xml` | Identifiants d'invité d'un modèle, chiffrés pour votre compte Windows (jamais en clair) |
| `journal.log` | Trace de chaque opération : commandes `vmrun`, codes de retour, écritures de configuration |

Clés de `config.json`, modifiables avec `vazy config <cle> <valeur>` (valeur `""` pour revenir au défaut) :

| Clé | Rôle | Défaut |
|---|---|---|
| `dossierVms` | Dossier où sont créées les VM (`<dossierVms>\<nom>\<nom>.vmx`) | vide : dossier parent du modèle |
| `outilHyperviseur` | Chemin de l'outil en ligne de commande de l'hyperviseur (`vmrun.exe`) si la détection automatique échoue | vide : détection automatique |
| `espaceDisqueMinGo` | Marge d'espace libre exigée, en plus de la RAM de la VM | `1` |
| `delaiOutilsSec` | Attente maximale des outils invité avant d'appliquer un nom d'hôte (5 à 1800 s) | `120` |
| `hyperviseur` | Pilote utilisé (`lib\pilote-<hyperviseur>.ps1`) | `vmware` |

Espace disque : avant de cloner, vazy vérifie qu'il reste au moins `RAM de la VM + espaceDisqueMinGo` Go sur le disque de destination (VMware crée pendant l'exécution un fichier de mémoire de la taille de la RAM). Sinon il refuse, sans rien créer.

Variables d'environnement :

- `VAZY_HOME` : autre dossier pour `config.json` et `catalogue.json` (pratique pour tester sans toucher à sa configuration).
- `VAZY_DEBUG=1` : affiche la pile d'appel complète en cas d'erreur inattendue.

---

## 7. Problèmes fréquents

**« vmrun.exe est introuvable »**
VMware Workstation n'est pas installé, ou dans un dossier inhabituel. Indiquez le chemin : `vazy config outilHyperviseur "C:\...\vmrun.exe"`.

**« Un hyperviseur Windows (Hyper-V) est actif »**
Sur Windows, un seul hyperviseur peut posséder le processeur. Quand Hyper-V est actif (à cause de WSL2, Docker Desktop, Windows Sandbox, ou de l'option « Intégrité de la mémoire » dans Sécurité Windows > Sécurité de l'appareil > Isolation du noyau), VMware bascule sur la couche de virtualisation de Windows : ça fonctionne, mais plus lentement et sans virtualisation imbriquée. vazy prévient (message complet une fois, puis un rappel d'une ligne) et continue. Pour rendre le processeur à VMware, dans une invite de commandes administrateur puis redémarrage :

```
bcdedit /set hypervisorlaunchtype off
```

WSL2, Docker Desktop et Windows Sandbox cesseront alors de fonctionner ; `bcdedit /set hypervisorlaunchtype auto` revient en arrière. Pensez aussi à désactiver « Intégrité de la mémoire » si elle est active.

**« Le modèle n'a aucun instantané »**
Voir la section 3.3. Éteignez la VM, prenez un instantané, relancez `vazy template add`.

**« Arrêt propre impossible : les VMware Tools ne répondent pas »**
Le système invité n'a pas les outils VMware (ou n'a pas fini de démarrer). Éteignez depuis l'intérieur de la VM, ou `vazy stop <nom> --hard` (équivaut à débrancher la prise). Installez les outils dans le modèle pour que ça n'arrive plus.

**« La VM ... n'a pas de point de retour vazy-neuf »**
La VM a été créée avant la version qui prend cet instantané automatiquement (ou l'instantané a été supprimé dans VMware). Créez-le une fois, VM éteinte : `vazy stop <nom>` puis `vazy snap <nom> vazy-neuf`.

**« Refus de ... : ... est marquée comme modèle »**
Le pilote a trouvé le fichier témoin `<modele>.vmx.vazy-modele` : la VM visée est un modèle, et l'opération (démarrage, suppression, instantané) casserait ses clones. Si vous devez vraiment agir dessus, retirez-le du catalogue avec `vazy template rm <alias>`, ce qui retire aussi la marque.

**« Le retour à l'instantané ... a échoué »**
VMware met parfois quelques secondes à libérer une VM après un arrêt forcé : relancez la commande. Vérifiez aussi que l'instantané existe encore (`vazy snaps <nom>`), il a pu être supprimé depuis VMware Workstation.

**Ma VM éphémère n'a pas été supprimée**
Elle tourne encore : fermer sa fenêtre ne l'éteint pas si VMware Workstation est réglé pour garder les VM en marche en arrière-plan (`vazy list` la montre « en marche »). Éteignez-la depuis l'intérieur ou avec `vazy stop <nom>`. Si elle est éteinte et toujours là, lancez `vazy gc` : le message dira pourquoi (par exemple plus de 3 VM à supprimer, confirmation attendue).

**« ... VM éphémères éteintes à supprimer : c'est beaucoup pour un nettoyage automatique »**
Plus de 3 VM éphémères se sont retrouvées éteintes en même temps, ce qui ressemble à une anomalie (coupure, arrêt de l'hôte). Vérifiez avec `vazy list`, puis `vazy gc --yes` pour les supprimer toutes.

**« Le modèle ... a changé depuis la création de ... » au démarrage d'une VM**
Les disques de base du modèle ne sont plus ceux sur lesquels ce clone lié a été créé. Cause habituelle : un instantané du modèle a été supprimé ou consolidé dans le Snapshot Manager de VMware, ou le disque a été compacté. Le clone est probablement perdu. `vazy doctor` dit quelles VM sont touchées. Pour l'avenir, `vazy freeze` rend autonome une VM que vous tenez à garder.

**« ... modèle(s) requis manquant(s) »** en montant le labo de quelqu'un d'autre
Le fichier référence un modèle sous un nom que vous n'avez pas. Soit vous le préparez, soit vous avez déjà l'équivalent sous un autre nom : `vazy template alias <votre modèle> <nom attendu>`.

**« Fichier ..., machine « x » : clé inconnue ... » ou « n'est pas du JSON valide »**
Le fichier de labo est vérifié en entier avant toute action. Le message nomme la machine et la clé fautive ; comparez avec `exemples\tp14-ad.json`. Erreur JSON classique : une virgule après le dernier élément d'un objet ou d'une liste.

**« dépendances circulaires entre ... »**
Les clés `apres` de ces machines forment une boucle (a après b, b après a). L'une d'elles doit démarrer sans attendre les autres.

**« La VM ... existe déjà mais appartient à une VM créée à la main / au labo ... »**
Le nom préfixé est déjà pris par une VM qui n'a pas été créée par ce labo. Changez le nom du labo ou de la machine dans le fichier, ou supprimez cette VM.

**Le nom d'hôte n'est pas appliqué sur un modèle guestinfo (rien ne se passe au démarrage)**
Dans la VM : `systemctl status vazy-guestinfo` (Linux) ou le journal `C:\ProgramData\vazy\vazy-guestinfo.log` (Windows). Vérifiez que `vmtoolsd --cmd "info-get guestinfo.vazy_config"` affiche une valeur dans la VM : si « No value found », vazy n'a rien déposé (le modèle n'est peut-être pas marqué : `vazy template list`) ; si une valeur base64 apparaît, le script ne s'est pas exécuté (unité désactivée, script installé après l'instantané).

**« nom d'hôte ... non appliqué : outils invité injoignables après 120 s »**
Les outils invité ne sont pas installés dans le modèle, ou l'invité met plus longtemps à démarrer. Installez `open-vm-tools` / VMware Tools dans le modèle ; pour un invité lent, `vazy config delaiOutilsSec 300`. La VM tourne quand même ; le nom sera réessayé au prochain démarrage par vazy.

**« nom d'hôte ... non appliqué : Exécution dans l'invité impossible : ... exit code ... »**
Le script a tourné mais a échoué : sous Linux, le compte ne peut pas faire `sudo` sans mot de passe ; sous Windows, le compte n'est pas administrateur élevé (utilisez le compte `Administrateur` intégré). Corrigez dans le modèle, ou dans la VM concernée, puis `vazy stop x` et `vazy start x`.

**« L'invité a refusé le compte ... »**
Utilisateur ou mot de passe faux, ou compte qui ne peut pas ouvrir de session. `vazy template creds <alias>` pour les ressaisir.

**« Les identifiants d'invité du modèle ... sont illisibles »**
Le fichier `creds\<alias>.xml` a été chiffré par un autre compte Windows ou sur un autre PC : il est inutilisable ici, c'est voulu. Ressaisissez-les.

**« Le nom ... est déjà utilisé » ou « Le dossier ... existe déjà »**
vazy n'écrase jamais rien. Choisissez un autre `--name`, ou supprimez l'ancienne VM avec `vazy rm`. Un dossier orphelin (VM créée puis effacée à la main dans VMware) se supprime avec l'Explorateur.

**Sous PowerShell, `--mode nat,hostonly` ou `--ram 1,5` donnent « Argument inattendu »**
PowerShell découpe sur la virgule avant de transmettre les arguments. Écrivez `--mode nat --mode hostonly` et `--ram 1.5`, ou mettez des guillemets.

**« L'exécution de scripts est désactivée sur ce système »**
Vous avez lancé `lib\interface.ps1` directement. Passez par `vazy.cmd` (c'est ce que fait la commande `vazy` quand le dossier est dans le PATH), ou autorisez les scripts pour votre compte : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

**Une VM supprimée avec `vazy rm` apparaît encore dans la bibliothèque de VMware Workstation**
La bibliothèque est une liste de raccourcis gérée par l'interface graphique. Clic droit sur l'entrée grisée, `Remove from Library`.

**La VM démarrée avec `--nogui` est invisible**
Elle tourne en arrière-plan. Pour la voir : dans VMware Workstation, `File > Open` sur son `.vmx` (chemin affiché par `vazy list`).

**Ctrl+C pendant le clonage**
VMware peut laisser un dossier incomplet. Supprimez-le à la main, puis relancez.

---

## 8. Limites de cette version

Volontairement hors périmètre :

- **Redimensionner le disque** : compliqué sur un clone lié et inutile si le modèle a été créé avec un disque dynamique très large (section 3.1).
- **Réseaux personnalisés (VMnet2, VMnet3...)** : ils se créent dans le Virtual Network Editor avec les droits administrateur. vazy ne les gère pas, ni en ligne de commande ni dans un fichier de labo : `mode` ne connaît que `nat`, `bridged` et `hostonly`. Une fois un VMnet créé à la main, `--set ethernet0.connectionType=custom --set ethernet0.vnet=VMnet2` permet quand même de s'y brancher, sans aucune vérification.
- **Autres hyperviseurs** : seul VMware Workstation est pris en charge ; l'architecture est prête pour VirtualBox et Hyper-V (section 9).
- **Interface graphique** : aucune.
- **Identité de l'invité** : le nom d'hôte est appliqué par vazy (section « Personnalisation de l'invité ») ; avec un modèle guestinfo, les clés SSH du serveur et `/etc/machine-id` sont régénérés sur chaque clone. Restent identiques : le SID Windows (sysprep) et la configuration IP (DHCP pour l'instant).
- **Une commande vazy à la fois** : le catalogue est lu au début de chaque commande et réécrit à la fin. Deux commandes vazy lancées en parallèle dans deux terminaux peuvent s'écraser mutuellement leurs modifications du catalogue.

---

## 9. Architecture : trois couches, un pilote

```
vazy.cmd                    lanceur (powershell -File lib\interface.ps1)
lib\interface.ps1           couche 1 : arguments, validation, affichage
lib\logique.ps1             couche 2 : catalogue, vérifications, enchaînement
lib\pilote-vmware.ps1       couche 3 : vmrun.exe et fichiers .vmx
```

- La **couche 1** analyse `$args` (options `--x valeur` ou `--x=valeur`), valide les valeurs, appelle la couche 2 et affiche ce qu'elle publie (`Publish-Message`) via l'afficheur qu'elle a enregistré (`Set-Afficheur`).
- La **couche 2** ne connaît ni la ligne de commande ni l'hyperviseur. Elle charge le pilote désigné par la configuration (`lib\pilote-<hyperviseur>.ps1`) et ne lui parle qu'à travers le contrat ci-dessous. Un chemin de machine est pour elle une chaîne opaque.
- La **couche 3** est la seule à contenir du VMware : localisation de `vmrun.exe`, syntaxe des commandes, lecture et écriture des `.vmx` (avec conservation de l'encodage déclaré par la ligne `.encoding`).

### Contrat du pilote

Les six opérations demandées :

| Fonction | Rôle |
|---|---|
| `New-MachineDepuisModele -Modele -Instantane -Dossier -Nom` | Créer depuis un modèle ; renvoie le chemin de la machine |
| `Set-MachineParametres -Machine [-RamMo] [-Cpu] [-Brut]` | Régler les paramètres (`-Brut` : paires Cle/Valeur écrites telles quelles) |
| `Set-MachineReseau -Machine -Modes` | Brancher le réseau (un mode par carte : `nat`, `bridged`, `hostonly`) |
| `Start-Machine -Machine [-SansInterface]` | Démarrer |
| `Stop-Machine -Machine [-Brutal]` | Arrêter |
| `Remove-Machine -Machine` | Supprimer |

Et trois fonctions de lecture seule, sans lesquelles la logique ne peut ni afficher l'état des VM ni vérifier qu'un modèle a un instantané :

| Fonction | Rôle |
|---|---|
| `Initialize-Pilote [-CheminForce]` | Localise l'outil de l'hyperviseur ; renvoie `Nom`, `Executable`, `ExtensionMachine`, `SensibleHyperV`, `ConseilInstantane` |
| `Get-MachineEnCours` | Chemins des machines en cours d'exécution |
| `Get-MachineInstantanes -Machine` | Noms des instantanés d'une machine |

Les instantanés (remise à zéro) :

| Fonction | Rôle |
|---|---|
| `New-MachineInstantane -Machine -Nom` | Prendre un instantané |
| `Restore-MachineInstantane -Machine -Nom` | Revenir à un instantané (machine arrêtée) |
| `Remove-MachineInstantane -Machine -Nom` | Supprimer un instantané |

L'invité (personnalisation) :

| Fonction | Rôle |
|---|---|
| `Set-MachineVariableInvite -Machine -Nom [-Valeur]` | Dépose une variable guestinfo lisible dans l'invité (machine éteinte ; valeur vide = retire) |
| `Get-MachineSystemeInvite -Machine` | `linux`, `windows` ou `inconnu`, d'après la configuration de la machine |
| `Wait-MachineOutils -Machine [-DelaiMaxSec]` | `$true` dès que les outils invité répondent, `$false` passé le délai |
| `Invoke-MachineScript -Machine -Identifiants -Systeme -Script` | Exécute un script dans l'invité avec un `PSCredential` (repli) et renvoie son code de sortie ; retente si l'invité n'est pas encore prêt ; le mot de passe n'apparaît dans aucun message |

La protection du modèle et l'autonomie :

| Fonction | Rôle |
|---|---|
| `Get-MachineEmpreinte -Machine` | Disques de base de la machine : nom, taille, date |
| `Test-MachineEmpreinte -Machine -Empreinte` | Compare à une empreinte : erreurs (disque manquant ou modifié) et avertissements |
| `Convert-MachineEnComplete -Machine -Nom` | Convertit un clone lié en machine complète, au même chemin |
| `Get-MachineDisqueGo -Machine` | Capacité déclarée des disques, en Go |

L'observation, sur laquelle reposent le journal et `--dry-run` :

| Fonction | Rôle |
|---|---|
| `Set-PiloteObservateur -Observateur -Simulation` | L'observateur reçoit `journal` pour chaque commande exécutée, `simulation` pour chaque commande non exécutée |

Toute commande de l'hyperviseur est construite en un seul endroit (`Invoke-Vmrun`) et toute écriture de configuration passe par `Write-FichierVmx` : ce sont les deux seuls points où le journal et la simulation s'accrochent.

La marque « modèle », que le pilote vérifie lui-même avant de démarrer, supprimer ou toucher aux instantanés d'une machine :

| Fonction | Rôle |
|---|---|
| `Protect-MachineModele -Machine` | Poser la marque (fichier témoin à côté de la machine) |
| `Unprotect-MachineModele -Machine` | La retirer |
| `Test-MachineModele -Machine` | `$true` si la machine est marquée |

Toute erreur est une exception dont `Data['Conseil']` dit quoi faire ; la couche 1 l'affiche en jaune sous le message.

### Ajouter un pilote

1. Créez `lib\pilote-virtualbox.ps1` qui définit ces fonctions avec les mêmes paramètres et les mêmes retours (le chemin de machine devient par exemple celui du `.vbox`, `ExtensionMachine = '.vbox'`).
2. `vazy config hyperviseur virtualbox`.

Rien d'autre à modifier : les couches 1 et 2 ne contiennent aucune ligne propre à un hyperviseur.
