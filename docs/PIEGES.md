# Pièges rencontrés

Chacun de ces pièges a coûté du temps. Ils sont notés ici avec ce qui les
révèle et ce qui les corrige, pour que la deuxième fois soit plus courte que la
première.

---

## 1. Une commande qui rend la main, mais dont on attend la sortie

**Le plus coûteux de tous.** Découvert le 10 septembre 2026, sur du vrai VMware.

### Le symptôme

`vazy lab up` affichait « Démarrage de dc01 », la VM démarrait et s'affichait à
l'écran, connectée, prête — et vazy restait figé. Indéfiniment. Aucun message,
aucune erreur, aucune consommation de processeur.

### La cause

`vmrun start <vm> gui` lance l'**interface de VMware Workstation**, puis se
termine. Mais cette interface hérite des tuyaux de sortie redirigés par le
processus appelant, et les garde ouverts tant qu'elle vit.

Le code faisait :

```powershell
$sortie = $processus.StandardOutput.ReadToEnd()
$processus.WaitForExit()
```

`ReadToEnd()` ne rend la main que lorsque **tous** les écrivains ont fermé le
tuyau. vazy n'attendait donc pas la fin de `vmrun` — terminé depuis longtemps —
mais la fermeture de VMware Workstation.

Le même piège attend `WaitForExit()` **sans argument** : il attend aussi la fin
de la redirection, donc le petit-fils. `WaitForExit(int)`, lui, attend le
processus seul. Toute la différence est là.

### Comment on l'a vu

La filiation des processus, et rien d'autre :

```powershell
Get-CimInstance Win32_Process -Filter "ParentProcessId=<pid de vazy>"
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'vmware|vmrun' } |
    ForEach-Object { "{0} PID {1} parent {2}" -f $_.Name, $_.ProcessId, $_.ParentProcessId }
```

Trois faits ont suffi : `vmware.exe` lancé à la seconde exacte où vazy avait
demandé le démarrage, son parent (`vmrun.exe`) **disparu**, et vazy toujours
vivant **sans aucun processus enfant**. Le travail était fait, l'outil attendait
dans le vide.

### La correction

```powershell
$lectureSortie  = $processus.StandardOutput.ReadToEndAsync()
$lectureErreurs = $processus.StandardError.ReadToEndAsync()
if (-not $processus.WaitForExit($script:DelaiCommandeSec * 1000)) { ... }
$sortie = if ($lectureSortie.Wait(2000)) { $lectureSortie.Result } else { '' }
```

On attend la fin du **processus**, puis on prend ce qui est arrivé dans les
flux, sans se laisser retenir par un enfant survivant.

Conséquence assumée : quand un petit-fils tient le tuyau, le texte de sortie est
perdu. Pour un démarrage il n'y a rien d'utile dedans, et le code de retour,
lui, reste exact. Un blocage infini valait bien moins.

### Ce qui l'empêche de revenir

`tests/Logic/CommandeExterne.Tests.ps1` reproduit la situation avec
`powershell.exe` — un processus qui en lance un plus durable héritant des
tuyaux — et vérifie que le motif y résiste. Un second test vérifie que la
reproduction reproduit bien quelque chose, sans quoi le premier ne prouverait
rien. Deux gardes syntaxiques interdisent le retour de `ReadToEnd()` et de
`WaitForExit()` sans délai dans les pilotes.

### La leçon générale

Rediriger la sortie d'un programme qui peut lancer une interface graphique, ou
n'importe quel processus plus durable que lui, demande de ne jamais attendre
les flux sans délai. Ça vaut pour `vmrun`, pour `VBoxManage startvm`, et pour
tout outil qui « lance » quelque chose.

---

## 2. Un diagnostic trop vite écrit

Le même incident a d'abord reçu une mauvaise explication, qu'il vaut la peine
de garder ici.

Le journal montrait `vmrun start ... gui -> code 0 en 98,2 s`. Hyper-V étant
actif, la conclusion « VMware tourne en mode dégradé, c'est lent » venait toute
seule. Un message d'attente a même été ajouté, annonçant « comptez une à deux
minutes ».

Après correction du vrai bug, mesure sur le même matériel : **9,2 s** pour la
première VM, **3,0 s** et **3,1 s** pour les suivantes. Les 98 secondes
n'étaient pas Hyper-V : c'était déjà le blocage, qui se dénouait quand
l'interface VMware avait fini de s'initialiser.

Une explication plausible qui colle aux symptômes n'est pas une cause. Le
message annonçant des durées inventées a été retiré.

---

## 3. PowerShell 5.1

C'est la version livrée avec Windows, et la cible du projet. Elle a des angles.

### `@()` sur une liste générique vide

```powershell
$liste = New-Object System.Collections.Generic.List[object]
@($liste).Count      # « Les types des arguments ne correspondent pas »
$liste.ToArray()     # correct
```

Le message d'erreur ne dit rien d'utile. Utiliser `.ToArray()`.

### Une fonction déballe un tableau d'un seul élément

```powershell
function Get-Trucs { return @($unSeulTruc) }
(Get-Trucs).Count    # échoue sous Set-StrictMode : c'est un scalaire
@(Get-Trucs).Count   # correct
```

À l'appel, pas à la définition : c'est l'appelant qui doit envelopper.

### Le pipe se lie plus fort que `-or`

```powershell
(a) -or (b) | Should Be $true      # teste (a) -or ((b) | Should Be $true)
$resultat = ((a) -or (b))
$resultat | Should Be $true        # correct
```

### UTF-8 sans BOM lu comme de l'ANSI

Un `.ps1` en UTF-8 **sans** marque d'ordre des octets est lu en ANSI par
PowerShell 5.1. Les accents deviennent illisibles, et surtout : un motif
accentué dans un `Select-String` ou une comparaison **ne correspond plus à
rien**, sans la moindre erreur. Panne silencieuse.

Tous les `.ps1` du projet portent le BOM, et la CI refuse le contraire.

### Le point-source place les choses dans la portée de l'appelant

```powershell
function Charger { . .\logique.ps1 }   # tout disparaît à la sortie de Charger
. .\logique.ps1                        # au premier niveau : correct
```

C'est pour cette raison que les fichiers de test chargent la logique au premier
niveau, et c'est aussi ce qui permet au harnais d'atteindre ses variables
`$script:`.

### `Measure-Object -Sum` sur une collection vide

```powershell
(@() | Measure-Object -Property Taille -Sum).Sum   # échoue sous Set-StrictMode
Get-Somme -Objets @() -Propriete 'Taille'           # 0, correct
```

Sur une collection vide, `Measure-Object` ne renvoie **rien** — pas un objet
dont la somme vaudrait zéro. `.Sum` sur ce rien lève « La propriété Sum est
introuvable ». Rencontré dans `vazy report` sur un parc sans réserve : le
premier tableau vide faisait tomber tout le rapport. `Get-Somme`, dans la
logique, règle la question une fois pour toutes.

### Un scriptblock retient la portée où il a été écrit

Un scriptblock passé à `Set-Afficheur` ou `Set-PiloteObservateur` continue de
voir les variables du fichier qui l'a défini, pas celles de l'endroit qui
l'exécute. Utile ici, déroutant si on l'ignore.

---

## 4. Clones liés et modèles

### Ne jamais démarrer un modèle

Un clone lié lit **en permanence** dans les disques du modèle. Démarrer le
modèle, ou supprimer son instantané d'ancrage, casse **tous** ses clones d'un
coup, définitivement.

vazy pose une marque (`<machine>.vazy-modele`) que le pilote lui-même vérifie :
il refuse démarrage, suppression et opérations d'instantané sur un modèle, quoi
que dise le catalogue. C'est volontairement redondant avec la logique.

### L'empreinte est ce qui rattrape le reste

À la création d'un clone, vazy relève la taille et la date des disques de base
du modèle. Avant chaque démarrage, il compare :

- **taille changée ou disque disparu** — refus, le clone est cassé ;
- **date seule changée** — avertissement, on laisse passer.

Cause habituelle d'une taille qui change : un instantané du modèle supprimé ou
consolidé dans le Snapshot Manager, ou un disque compacté.

### Modifier un modèle casse ses clones existants

Ça vaut aussi pour une modification légitime, comme installer le script
guestinfo. L'ordre est alors : supprimer les clones, `vazy template rm`,
modifier le modèle, reprendre un instantané, `vazy template add`.

---

## 5. Comportements de VMware à connaître

### La question « moved or copied »

Un clone qui démarre sans `msg.autoAnswer = "TRUE"` peut ouvrir une boîte de
dialogue modale et bloquer indéfiniment. vazy pose cette clé à la création de
chaque machine.

### `checkToolsState` répond avant que l'invité n'accepte des commandes

Les outils invité annoncent `running` un court instant avant d'être réellement
prêts. Les premiers échecs d'exécution dans l'invité sont donc retentés — mais
pas les refus d'identifiants, qui ne s'arrangeront pas d'eux-mêmes.

### Un modèle avec identifiants sérialise tout un labo

Si un modèle a des identifiants enregistrés sans être marqué `guestinfo`, vazy
**entre dans chaque VM** pour appliquer son nom d'hôte : attente des outils
(jusqu'à `delaiOutilsSec`), ouverture de session, script, et seulement ensuite
la machine suivante.

Dans un fichier de labo, une machine sans clé `hostname` prend **son propre nom
comme nom d'hôte** : les trois machines d'un TP passent donc toutes par là.

Trois façons de l'éviter, de la plus légère à la plus propre :

- `"hostname": false` sur les machines, si le renommage n'importe pas ;
- marquer le modèle `guestinfo` : vazy dépose la configuration et passe à la
  suite, sans jamais entrer dans la VM ;
- ne rien changer, et accepter l'attente.

### Hyper-V

Quand Hyper-V possède le processeur (WSL2, Docker Desktop, Windows Sandbox,
intégrité de la mémoire), VMware bascule en mode dégradé : VM plus lentes, pas
de virtualisation imbriquée. `bcdedit /set hypervisorlaunchtype off` puis
redémarrage le désactive, `auto` le remet.

Ce mode dégradé est réel, mais voir le piège n°2 : il n'explique pas tout, et
il a bon dos.

### Les chemins courts 8.3

`C:\Users\ANTHON~1.CER\...` et `C:\Users\anthony.cernon\...` désignent le même
fichier. Sans résolution, une VM du catalogue paraît absente lors d'un balayage
du disque. `Get-CheminLong` s'en charge, via `GetLongPathName`.

---

## 6. Écrire des tests sur ce projet

### Le faux pilote doit rester fidèle

Un faux pilote qui diverge du vrai fait passer des tests qui ne prouvent rien.
Deux cas déjà rencontrés :

- il déclarait `Invoke-MachineScript` **sans** son paramètre `Tentatives` ;
- son garde-fou « modèle » interrogeait l'état mémoire là où le vrai pilote lit
  le fichier témoin — il ne refusait donc pas une machine qu'il n'avait pas
  créée lui-même.

`tests/Logic/Contrat.Tests.ps1` compare mécaniquement les trois pilotes.

### Un test qui se déclenche sur son propre commentaire

Les gardes syntaxiques cherchant `ReadToEnd()` ont d'abord échoué sur les
commentaires qui citent la forme interdite pour expliquer pourquoi on l'évite.
De même, un test cherchant un terme d'hyperviseur dans les couches 1 et 2 a
d'abord trébuché sur le texte d'aide, qui mentionne légitimement `.vmx`.

Analyser l'arbre syntaxique et écarter les jetons `Comment`, `StringLiteral`,
`StringExpandable` et **`HereStringLiteral`** — cette dernière forme a son
propre type, l'oublier suffit à rater le filtre.

### Assertions sur la sortie d'un sous-processus

Préférer des fragments **sans accent** : la sortie traverse la console, où un
accent survit mal selon la page de code active.

### Un exemple dans un message peut faire passer un test pour de mauvaises raisons

Le message affiché quand aucun segment n'existe cite `labo-dmz` en exemple. Un
test qui vérifiait l'absence de `labo-dmz` après suppression passait donc… tant
qu'il n'y avait rien. Vérifier le signal, pas un nom qui traîne ailleurs.

### Un contrôle de la CI qu'on ne peut pas lancer chez soi

Le job PSScriptAnalyzer n'a jamais pu tourner sur la machine de
développement : le fournisseur NuGet demande des droits administrateur, donc
`Install-Module` échouait. Le job est resté rouge sans que personne ne le
voie. La première analyse locale a trouvé **65 avertissements bloquants** :

- 50 `catch { }` volontaires — journal qui ne doit jamais bloquer, sonde qui
  échoue et vaut « inconnu » ;
- 13 paramètres jamais lus, dont 8 dans des scriptblocks : les observateurs
  muets par défaut, `{ param($Type, $Message) }`. La règle
  `PSReviewUnusedParameter` examine **aussi les scriptblocks anonymes**, pas
  seulement les fonctions ;
- un verbe non approuvé (`Ecrire-Journal`) ;
- une fonction qui écrasait une cmdlet intégrée : `ConvertTo-Html`, définie
  dans l'interface pour le rapport, masquait celle de PowerShell.

La leçon : un contrôle de CI qu'on ne sait pas reproduire en local échoue en
silence. Le module s'obtient sans installation — voir CONTRIBUTING,
« Lancer l'analyse de la CI ».

---

## 7. Ce qui reste hors de portée des tests

Les tests tournent sans hyperviseur, en remplaçant la couche pilote. Ce
qu'ils ne peuvent structurellement pas voir :

- le comportement réel de `vmrun` et de `VBoxManage` ;
- tout ce qui touche aux processus et aux handles du système — **le blocage du
  piège n°1 est passé sous les tests pendant tout le développement** ;
- l'invité : outils, renommage, réseau vu de l'intérieur.

D'où la règle : une livraison n'est pas finie tant qu'elle n'a pas tourné une
fois pour de vrai. Les tests attrapent les régressions de logique, pas les
malentendus avec le monde extérieur.
