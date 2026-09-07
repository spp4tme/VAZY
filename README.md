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
     lib\interface.ps1        couche 1 : ligne de commande et affichage
     lib\logique.ps1          couche 2 : catalogue, vérifications, enchaînement
     lib\pilote-vmware.ps1    couche 3 : vmrun et fichiers .vmx
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
5. **Éteignez la VM proprement, depuis l'intérieur du système.**

### 3.3 Prendre l'instantané

VM éteinte, dans VMware Workstation : `VM > Snapshot > Take Snapshot...`, nommez-le `base`, validez.

Ou en ligne de commande :

```
"C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe" -T ws snapshot "D:\VMs\ubuntu-server\ubuntu-server.vmx" base
```

### 3.4 Enregistrer le modèle dans vazy

```
vazy template add "D:\VMs\ubuntu-server\ubuntu-server.vmx"
```

- L'alias par défaut est le nom du fichier sans extension (`ubuntu-server`). Pour en choisir un autre : `--name <alias>`.
- Si la VM a plusieurs instantanés, le dernier de la liste est utilisé ; pour en imposer un : `--snapshot <nom>`.
- vazy refuse d'enregistrer une VM sans instantané et explique comment en créer un.

C'est terminé. **Ne redémarrez plus jamais cette VM.** Créez vos machines de TP :

```
vazy ubuntu-server
```

### 3.5 Mettre à jour un modèle (procédure d'exception)

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
| `vazy template add <chemin.vmx> [--name <alias>] [--snapshot <nom>]` | Enregistre un modèle (le dossier de la VM est accepté à la place du `.vmx`) |
| `vazy template list` | Modèles enregistrés, instantané utilisé, nombre de clones |
| `vazy template rm <alias>` | Retire un modèle du catalogue ; **aucun fichier n'est supprimé** |
| `vazy config [<cle> <valeur>]` | Affiche ou modifie la configuration |
| `vazy help`, `vazy version` | |

Codes de retour : `0` succès, `1` erreur, `2` erreur de syntaxe.

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
| `catalogue.json` | Modèles enregistrés et VM créées |

Clés de `config.json`, modifiables avec `vazy config <cle> <valeur>` (valeur `""` pour revenir au défaut) :

| Clé | Rôle | Défaut |
|---|---|---|
| `dossierVms` | Dossier où sont créées les VM (`<dossierVms>\<nom>\<nom>.vmx`) | vide : dossier parent du modèle |
| `outilHyperviseur` | Chemin de l'outil en ligne de commande de l'hyperviseur (`vmrun.exe`) si la détection automatique échoue | vide : détection automatique |
| `espaceDisqueMinGo` | Marge d'espace libre exigée, en plus de la RAM de la VM | `1` |
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
- **Réseaux personnalisés (VMnet2, VMnet3...)** : ils se créent dans le Virtual Network Editor avec les droits administrateur. Une fois créés, `--set ethernet0.connectionType=custom --set ethernet0.vnet=VMnet2` permet quand même de s'y brancher.
- **Autres hyperviseurs** : seul VMware Workstation est pris en charge ; l'architecture est prête pour VirtualBox et Hyper-V (section 9).
- **Interface graphique** : aucune.
- **Nom d'hôte** : tous les clones d'un modèle ont le même nom d'hôte (et, sous Windows, le même SID). Pour un TP réseau où plusieurs clones cohabitent, renommez dans l'invité : `sudo hostnamectl set-hostname tp14` sous Linux, `Rename-Computer tp14 -Restart` sous Windows.

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

Toute erreur est une exception dont `Data['Conseil']` dit quoi faire ; la couche 1 l'affiche en jaune sous le message.

### Ajouter un pilote

1. Créez `lib\pilote-virtualbox.ps1` qui définit ces neuf fonctions avec les mêmes paramètres et les mêmes retours (le chemin de machine devient par exemple celui du `.vbox`, `ExtensionMachine = '.vbox'`).
2. `vazy config hyperviseur virtualbox`.

Rien d'autre à modifier : les couches 1 et 2 ne contiennent aucune ligne propre à un hyperviseur.
