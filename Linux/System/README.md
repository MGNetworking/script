# Linux/System

Administration du système Linux lui-même, indépendamment de Docker et Kubernetes.

## Prérequis

Debian ou Ubuntu. Les scripts modifiant le système demandent root ; les scripts
de diagnostic s'exécutent sans privilège.

Les valeurs propres au serveur (nom d'hôte, fuseau horaire, taille du fichier
d'échange, horaire des tâches planifiées) se déclarent dans `config/server.env` — voir
[config/README.md](../../config/README.md). Un argument de ligne de commande
prime toujours sur la valeur du fichier.

## Scripts

| Script | Rôle | Privilèges | Modifie le système |
|---|---|---|---|
| `system-info.sh` | état du système : distribution, noyau, CPU, mémoire, stockage, réseau, heure | aucun | non |
| `update-system.sh` | mise à jour des paquets (Debian, Ubuntu) | root | oui |
| `configure-logging.sh` | crée le répertoire des journaux et installe la règle logrotate | root | oui |
| `configure-hostname.sh` | définit le nom d'hôte et met /etc/hosts en cohérence | root | oui |
| `configure-timezone.sh` | définit le fuseau horaire, en validant son existence | root | oui |
| `configure-swap.sh` | affiche le swap, crée ou redimensionne un fichier d'échange | root | oui |
| `configure-cron.sh` | dépose `/etc/cron.d/mgnetworking` : planification des scripts automatiques | root | oui |
| `check-disk.sh` | diagnostic de stockage : systèmes de fichiers, inodes, périphériques, répertoires consommateurs | aucun | non |
| `check-memory.sh` | diagnostic mémoire : mémoire vive, fichier d'échange, processus consommateurs | aucun | non |
| `check-services.sh` | diagnostic des services systemd : inventaire des actifs, services en échec, vérification d'un service nommé | aucun | non |

Les autres scripts prévus (`manage-users.sh`, `reboot-system.sh`) restent à
écrire — voir [le plan](../../docs/refactorisation-plan.md).

Relevé technique du domaine :
[recensement-substitutions.md](recensement-substitutions.md) — toutes les
affectations `var="$(…)"` des sept scripts qu'il couvre, une par une, avec leur
verdict et sa raison. À lire avant toute affirmation sur le doublement du
`trap ERR`, décrit plus bas sous « Codes de retour ». Le relevé s'arrête à ces
sept scripts : **aucun des trois diagnostics écrits depuis n'y est versé** —
`check-disk.sh`, `check-memory.sh` et `check-services.sh` —, toutes leurs
affectations étant en contexte de condition, aucune en forme nue.

## Utilisation

```bash
./Linux/System/system-info.sh

sudo ./Linux/System/update-system.sh --dry-run   # lister sans installer
sudo ./Linux/System/update-system.sh             # avec confirmation
sudo ./Linux/System/update-system.sh --yes       # sans confirmation (cron)

sudo ./Linux/System/configure-logging.sh          # une fois par serveur

sudo ./Linux/System/configure-hostname.sh                 # prend SRV_HOSTNAME
sudo ./Linux/System/configure-hostname.sh mon-serveur     # l'argument l'emporte
sudo ./Linux/System/configure-hostname.sh mon-serveur --dry-run

sudo ./Linux/System/configure-timezone.sh --list      # lister les fuseaux
sudo ./Linux/System/configure-timezone.sh            # prend SRV_TIMEZONE
sudo ./Linux/System/configure-timezone.sh Europe/Paris

./Linux/System/configure-swap.sh                     # état du swap, sans root
sudo ./Linux/System/configure-swap.sh 2G             # créer ou redimensionner
sudo ./Linux/System/configure-swap.sh 2G --dry-run
sudo ./Linux/System/configure-swap.sh 2G --file /var/swapfile   # chemin absolu

sudo ./Linux/System/configure-cron.sh --dry-run          # afficher le fichier
sudo ./Linux/System/configure-cron.sh                    # une fois par serveur
sudo ./Linux/System/configure-cron.sh --horaire "30 5 * * 7"

./Linux/System/check-disk.sh                          # diagnostic complet
./Linux/System/check-disk.sh --seuil 90               # alerter à partir de 90 %
./Linux/System/check-disk.sh --repertoire /var --top 5
./Linux/System/check-disk.sh --sans-repertoires       # sauter l'analyse « du »
./Linux/System/check-disk.sh --tous                   # sans filtrer les pseudo-FS

./Linux/System/check-memory.sh                        # diagnostic complet
./Linux/System/check-memory.sh --seuil 80             # alerter à partir de 80 %
./Linux/System/check-memory.sh --top 3                # trois processus au lieu de dix

./Linux/System/check-services.sh                      # inventaire, rend toujours 0
./Linux/System/check-services.sh --service cron       # 0 si actif, 1 sinon
./Linux/System/check-services.sh --service ssh.service
./Linux/System/check-services.sh --service getty@tty1 # unité à instance
./Linux/System/check-services.sh --service dbus.socket # refusé en 2
```

`check-services.sh --service <nom>` complète le nom d'un suffixe `.service`
lorsqu'il n'en porte pas : `cron` et `cron.service` désignent la même unité.
**Seules les unités `.service` sont acceptées** — un timer, un socket, un target
ou un mount est refusé en 2, avant toute interrogation du système. Le code de
retour est exploitable dans un script — `0` si le service est actif, `1`
sinon :

```bash
if ./Linux/System/check-services.sh --service cron >/dev/null; then
    echo "cron tourne"
fi
```

### Seuils de `check-disk.sh`

**Le seuil par défaut est 85 %**, appliqué à l'occupation des blocs comme à
celle des inodes. Un système de fichiers qui l'**atteint** — comparaison en
« supérieur ou égal », pas en « strictement supérieur » — est signalé par un
`[WARN]` nommant le point de montage, le périphérique et le pourcentage.

Trois raisons à cette valeur :

- **elle laisse de quoi travailler.** 15 % d'une racine de 40 Go font 6 Go : de
  quoi absorber une mise à jour de paquets, une image de conteneur ou une rafale
  de journaux avant que le disque soit réellement plein ;
- **la dégradation commence avant le 100 % de `df`.** ext4 réserve 5 % des blocs
  à root — que `df` ne compte pas comme disponibles pour les autres — et son
  allocateur se fragmente nettement au-delà de ~85 % d'occupation ;
- **plus bas, le signal devient du bruit.** Un serveur sain vit couramment entre
  70 et 80 % — un disque vide est un disque payé pour rien —, et une alerte qui
  se déclenche à chaque passage n'est plus lue au bout de trois fois.

**Le même seuil vaut pour les inodes**, faute d'une raison de les traiter
autrement : un système de fichiers dont 85 % des inodes sont consommés est aussi
près de la panne que celui dont 85 % des blocs le sont — et la panne y est plus
déroutante, `No space left on device` s'affichant alors qu'il reste 60 %
d'espace libre. Il n'existe donc **qu'un seuil**, global, et non un par système
de fichiers ni un par métrique.

Il se surcharge par `SRV_DISK_SEUIL` dans `config/server.env`, puis par
`--seuil`, qui l'emporte. Le répertoire analysé suit la même règle :
`SRV_DISK_REPERTOIRE` puis `--repertoire`, défaut `/`. L'origine effective de
chaque valeur est rappelée en tête de la sortie, pour qu'un seuil surprenant se
retrouve sans chercher.

Un `SRV_DISK_SEUIL` mal saisi n'interrompt pas le diagnostic : il vaut un `[WARN]`
et le repli sur 85 %, la ligne de commande restant seule à pouvoir rendre 2 —
voir « Codes de retour » plus bas.

### Seuils de `check-memory.sh`

**Le seuil par défaut est 90 %**, et il porte sur la part de mémoire **non
disponible** — `(totale - disponible) / totale` — jamais sur l'occupation
apparente. Comme pour `check-disk.sh`, le seuil est **atteint** et non dépassé :
la comparaison est en « supérieur ou égal ».

**« Libre » n'est pas « disponible », et c'est tout l'enjeu.** Linux emploie
toute mémoire inemployée en cache et en tampons, qu'il rend dès qu'un programme
en réclame : une machine parfaitement saine affiche couramment 95 % d'occupation
apparente et une mémoire libre proche de zéro. Un seuil posé sur `MemFree`
crierait au loup à chaque exécution. La sortie affiche les deux valeurs et
explique la différence à chaque passage, précisément pour que personne ne
conclue d'une mémoire libre nulle que la machine manque de mémoire.

**Pourquoi 90 % ici et 85 % pour le disque** — le seuil ne porte pas sur la même
grandeur, et la mémoire ne se dégrade pas comme un disque :

- **un disque qui se remplit prévient.** Il ralentit, il laisse le temps de voir
  venir. Une mémoire qui manque déclenche le tueur de mémoire du noyau, qui abat
  un processus sans préavis. Ce que mesure ce seuil est donc une **marge** — de
  quoi absorber le prochain pic —, pas une tendance ;
- **10 % de marge reste une marge utile** : 6,4 Go sur un hôte de 64 Go, 200 Mo
  sur une machine de 2 Go. Sur les petites machines cette marge devient mince,
  et c'est pour cela que le seuil est réglable : 80 % y donne plus de temps de
  réaction ;
- **plus bas, le signal devient du bruit**, pour la même raison que sur le
  disque : un serveur qui travaille garde peu de mémoire disponible.

**Le fichier d'échange n'a pas de seuil propre**, et son absence n'est jamais
une anomalie — beaucoup de VPS et tous les conteneurs tournent sans. Le même
seuil s'applique aux deux grandeurs, mais l'avertissement n'est émis qu'à leur
**conjonction** : un échange occupé au-delà du seuil **alors que** la mémoire
l'est aussi. Un échange occupé seul ne dit rien de mauvais — le noyau y déplace
des pages inactives même quand la mémoire est ample, et ne les rapatrie pas tant
que personne ne les lit. Les deux ensemble, si : il ne reste plus de réserve
nulle part, et la machine part en pagination continue puis en OOM. Un second
seuil configurable donnerait un réglage de plus pour une décision qui n'existe
pas séparément.

Le seuil se surcharge par `SRV_MEM_SEUIL` dans `config/server.env`, puis par
`--seuil`, qui l'emporte. Le nombre de processus affichés suit la même règle :
`SRV_MEM_TOP` puis `--top`, défaut 10. L'origine effective de chaque valeur est
rappelée en tête de la sortie.

Une valeur fautive venue de `config/server.env` n'interrompt pas le diagnostic :
elle vaut un `[WARN]` nommant la variable et le repli sur la valeur par défaut,
la ligne de commande restant seule à pouvoir rendre 2.

### Planification par cron

`configure-cron.sh` dépose `/etc/cron.d/mgnetworking`, qui contient `SHELL`,
`PATH` et une ligne par tâche planifiée. Une seule tâche existe à ce jour :

```text
0 4 * * 1 root /bin/bash /opt/mgnetworking/Linux/System/update-system.sh --yes >/dev/null
```

Quatre traits de cette ligne ne sont pas négociables :

- **`root` suit l'horaire, il n'y a pas de `sudo`.** Cron lance directement sous
  l'utilisateur nommé dans le fichier ;
- **le script est lancé par `/bin/bash`, pas par son chemin seul.** Ce choix
  répondait à un défaut du dépôt, corrigé depuis : les scripts étaient
  enregistrés dans Git en `100644`, si bien qu'après un `git clone` un appel
  direct rendait `126` à chaque passage, sans que rien ne le signale. Ils sont
  en `100755` depuis le 2026-09-02
  ([ADR-0003](../../docs/agent/decisions/ADR-0003-cadrage-execution-autonome.md),
  décision 11) — `git ls-files -s Linux/System/` le montre. La ligne reste
  passée par `bash` : elle demeure ainsi correcte sur un dépôt déployé autrement
  qu'en clonant, par copie ou par archive, où le bit peut se perdre ;
- **`--yes` est obligatoire.** Cron n'a pas de terminal : sans lui, le script
  attendrait indéfiniment une réponse à sa confirmation ;
- **seule la sortie standard est jetée.** Cron expédie par courriel tout ce
  qu'un travail écrit ; la sortie complète d'`apt` à chaque exécution serait
  inacceptable, et la trace est de toute façon dans
  `/var/log/mgnetworking/update-system.log`. La sortie d'erreur, elle, est
  conservée : c'est la seule alerte disponible tant que la remontée des échecs
  n'est pas traitée — [points-en-suspens.md](../../docs/points-en-suspens.md) §2.

L'horaire par défaut est `0 4 * * 1` — tous les lundis à 4 h. Il se change par
`SRV_CRON_UPDATE_SYSTEM` dans `config/server.env`, ou par `--horaire`, qui
l'emporte. Les cinq champs de cron sont attendus ; les raccourcis `@weekly` et
consorts sont refusés. L'horaire suit le fuseau horaire du système.

Le chemin du dépôt n'est pas écrit en dur : il est résolu à l'exécution, ce qui
rend le fichier correct quel que soit l'endroit où le dépôt est déployé.

#### Prérequis de la planification

**Cron doit être installé ; le script ne l'installe pas.** Il cherche le démon
(`cron` ou `crond`, y compris dans `/usr/sbin`, absent du `PATH` de root sur
certains systèmes) et s'arrête en indiquant `apt-get install cron` s'il ne le
trouve pas. Il ne se fie pas à la présence de `/etc/cron.d` : sur Debian 12, ce
répertoire est fourni par `e2fsprogs` — `dpkg -S /etc/cron.d` le confirme — et
existe donc même sans cron. Seul `--dry-run` fait exception : il n'écrit rien,
se contente d'un avertissement et affiche l'aperçu, ce qui permet de lire le
fichier avant d'installer cron.

**Le bit d'exécution n'est pas un prérequis de la planification**, la ligne
déposée passant par `bash`. Depuis le 2026-09-02, il n'en est plus un non plus
pour un lancement à la main : les scripts sont enregistrés en `100755`, et
`./Linux/System/update-system.sh` fonctionne directement après un `git clone`.
`configure-cron.sh` continue de signaler un bit manquant sans y toucher — le cas
subsiste sur un dépôt déployé par copie ou par archive.

Aucun rechargement n'est nécessaire après le dépôt : cron relit `/etc/cron.d`
dès que son contenu change.

## Codes de retour

Les dix scripts suivent la même convention, détaillée dans
[docs/architecture-technique.md §6](../../docs/architecture-technique.md) :

```text
0  succès
2  erreur d'usage      option inconnue, argument manquant, valeur invalide
1  échec d'exécution   privilège insuffisant, dépendance absente, opération échouée
```

Le 2 reproche quelque chose à l'appelant, qui n'a qu'à corriger sa ligne de
commande. Une valeur refusée en fait partie : `configure-swap.sh 12X`,
`configure-swap.sh --file 2G`, `configure-swap.sh 64M --file /etc/passwd`,
`configure-timezone.sh Zone/Inexistante`,
`configure-hostname.sh mon_serveur` et `configure-cron.sh --horaire "@weekly"`
sortent tous en 2, sans avoir rien tenté.

Le 1 constate que le travail n'a pas pu être fait alors que la demande était
recevable. **Un manque de privilège en relève** : lancer sans `sudo` l'un des
scripts qui modifient le système rend 1, la commande tapée étant juste.
`system-info.sh`, `check-disk.sh`, `check-memory.sh` et `check-services.sh` font
exception — ils ne font que lire, ils n'ont jamais eu besoin de privilège, et
aucun manque de privilège ne peut donc les faire sortir en 1.

Les trois premiers rendent **0 même lorsqu'une information manque**, et les deux
`check-*` à seuil rendent 0 même lorsqu'un seuil est dépassé : un diagnostic est une
lecture, pas un verdict. Faire rendre 1 à un disque plein ou à une mémoire
saturée transformerait chaque passage en tâche planifiée en échec, et la
production de statuts `PASS` / `WARNING` / `FAIL` est le rôle du futur
`security-check.sh`.

`check-disk.sh` rend 2 sur une option inconnue et sur une valeur invalide **tapée
sur la ligne de commande** : `--seuil` ou `--top` qui n'est pas un entier de 1 à
100, `--repertoire` qui commence par un tiret ou qui ne désigne pas un répertoire
accessible. `check-memory.sh` suit la même règle, avec ses deux seules valeurs :
`--seuil` et `--top`, entiers de 1 à 100, sans zéro initial.

**Une valeur fautive venue de `config/server.env` ne rend jamais 2.** La règle ne
dépend que de l'origine de la valeur, et elle vaut pour toutes : la ligne de
commande vaut un refus — l'appelant s'est trompé en tapant, le reproche lui est
utile —, la configuration vaut un `[WARN]` nommant la variable, la valeur refusée
et ce qui est retenu à la place. Un diagnostic en lecture seule doit
diagnostiquer : priver l'appelant de tout son tableau de disques parce qu'une
variable qu'il n'a peut-être pas écrite lui-même est mal saisie serait
disproportionné.

| Valeur fautive de `config/server.env` | Ce que fait le script |
|---|---|
| `SRV_DISK_SEUIL=abc` | `[WARN]`, repli sur le seuil par défaut de 85 %, code 0 |
| `SRV_DISK_REPERTOIRE=/pas/la` | `[WARN]`, section des répertoires sautée, code 0 |
| `SRV_MEM_SEUIL=abc` | `[WARN]`, repli sur le seuil par défaut de 90 %, code 0 |
| `SRV_MEM_TOP=zero` | `[WARN]`, repli sur les 10 processus par défaut, code 0 |

Le repli diffère parce que la valeur de repli diffère, et c'est le seul écart
entre ces lignes : 85 % reste une comparaison utile, tandis que retomber sur
`/` ferait parcourir pendant des minutes une arborescence que personne n'a
demandée et afficherait le classement d'un autre répertoire que celui configuré.
Un `SRV_DISK_REPERTOIRE` pointant sur `/var/lib/docker`, non traversable par un
compte ordinaire, ne doit pas non plus priver ce compte de tout le reste du
diagnostic. L'origine rappelée en tête de sortie porte la trace du repli —
`85 % (valeur par défaut, SRV_DISK_SEUIL refusé)`.

Les deux valeurs de `check-memory.sh` ont, elles, une valeur par défaut
utilisable : leur repli est donc le même, et le diagnostic est produit en entier
dans les deux cas.

### Les deux modes de `check-services.sh`

`check-services.sh` est le seul diagnostic du domaine dont le code de retour
dépende du mode, et c'est la seule chose surprenante de ce script :

| Mode | Ce qu'il fait | Code |
|---|---|---|
| sans option | inventorie les services actifs, met en évidence ceux en échec | **toujours 0** |
| `--service <nom>` | répond à une question fermée | **0** actif, **1** dans les six autres cas |

**L'inventaire rend compte, il ne juge pas.** Un service en échec ne change pas
son code de retour, pour la raison qui fait déjà rendre 0 à un seuil dépassé de
`check-disk.sh` : sortir en 1 transformerait chaque passage en tâche planifiée
en échec sur un serveur qui porte une unité en échec — état banal — et la
production de statuts `PASS` / `WARNING` / `FAIL` est le rôle du futur
`security-check.sh`.

**`--service` pose au contraire une question dont la réponse est utile à un
appelant** : *ce service tourne-t-il ?* Un non est un échec d'exécution, code 1.
Les six façons de ne pas être actif se distinguent **par le message, jamais
par le code** — un appelant qui teste le code veut savoir si le service tourne,
pas pourquoi il ne tourne pas. Ce tableau et celui de `--help` disent la même
chose, et doivent continuer de le dire :

| Ce que dit le message | Ce que systemd répond |
|---|---|
| service inconnu de systemd | `LoadState=not-found` |
| service masqué — il ne peut démarrer ni à la main, ni par dépendance | `LoadState=masked` |
| unité non chargée — systemd n'a pas pu charger son fichier d'unité | `LoadState` autre que `not-found`, `masked` ou `loaded` |
| service en échec | `LoadState=loaded`, `ActiveState=failed` |
| service inactif | `LoadState=loaded`, `ActiveState` autre qu'`active` |
| état impossible à établir | `systemctl show` n'a rien rendu d'exploitable, ou pas même un `LoadState` |

La dernière ligne n'est pas théorique, elle est mesurée : `--service @` rend
`[ERROR] L'état de « @.service » n'a pas pu être établi : …`. Le nom ne
contient que des caractères admis, il franchit donc le contrôle de forme ;
c'est systemd qui n'en dit ensuite rien d'exploitable. Le script l'annonce au
lieu de conclure, et rend 1 comme pour les cinq autres.

La troisième non plus : un fichier d'unité au contenu invalide déposé dans
`/etc/systemd/system` donne `LoadState=bad-setting`. L'unité existe, systemd
refuse de la charger, et ni « inconnu » ni « masqué » ne décriraient
l'état — d'où un message qui renvoie vers `systemctl status`.

**Une unité inconnue n'a pas d'état d'exécution.** `systemctl show` rapporte
`inactive (dead)` pour un nom qu'il ne connaît pas ; la ligne « État
d'exécution » affiche donc `non disponible` lorsque `LoadState=not-found`,
comme le font déjà « État d'activation » et « Dernier démarrage ». Afficher la
valeur brute se lisait *le service existe, il est arrêté* — l'inverse du
`[ERROR]` qui suit. **Une unité masquée n'est pas traitée de même** : systemd y
rapporte aussi `inactive (dead)`, mais l'unité existe et n'est effectivement pas
en cours d'exécution — la valeur est vraie, elle est conservée, et « État
d'activation » affiche `masked`.

L'ordre de lecture n'est pas indifférent : une unité inconnue et une unité
masquée annoncent toutes deux `ActiveState=inactive`, état qu'elles partagent
avec un service simplement arrêté. `LoadState` est donc lu en premier — sans
quoi le script conseillerait `systemctl start` pour une unité qui n'existe pas.
C'est aussi la raison pour laquelle l'état vient de `systemctl show`, seul appel
qui distingue les trois cas en une fois : `systemctl is-active` les confond
toutes en un même code 3.

Le 2 reste réservé à ce qu'on reproche à l'appelant. Quatre cas, tous refusés
**avant toute interrogation du système** :

| Ce que l'appelant a écrit | Pourquoi c'est un 2 |
|---|---|
| une option inconnue | rien à interpréter |
| `--service` sans valeur | la question n'est pas posée |
| un nom qui ne peut pas être une unité | un nom d'unité systemd n'admet que lettres, chiffres, `-`, `_`, `.`, `@`, `\` et `:` ; une valeur commençant par un tiret est une option, pas un nom ; et un point qui ne précède aucun type d'unité connu ne compose pas davantage un nom — `..`, `foo.bar` |
| une unité qui n'est pas un service | `--service dbus.socket`, `--service local-fs.target`, `--service systemd-tmpfiles-clean.timer` |

**Seules les unités `.service` sont acceptées.** Un nom porteur d'un autre
suffixe est refusé en 2 : ce script diagnostique des services, et répondre
`Service actif` à propos de `local-fs.target` serait faux — un target n'est pas
un service. Les autres types d'unités sont hors du périmètre de ce script, et
leur état se lit avec `systemctl status`. Un nom **sans** point n'est pas
concerné : il reçoit `.service`. Un service dont le nom contient un point
s'écrit donc avec son suffixe — `com.exemple.app.service`.

**Deux fautes se cachent sous ce refus, et le message les distingue.**
`dbus.socket` nomme une unité réelle d'un autre type : le message renvoie vers
`systemctl status dbus.socket`, qui répondra. `..` n'est une unité d'aucun
type : le même conseil enverrait l'appelant sur une commande qui ne peut rien
lui apprendre, et il reçoit à la place `Nom de service invalide`. Le départage
se fait sur le suffixe, comparé à la liste close des types d'unités de systemd —
`socket`, `target`, `timer`, `mount`, `automount`, `swap`, `path`, `device`,
`slice`, `scope` — et sur la présence d'un nom devant lui : `.socket` n'est pas
plus une unité que `..`. Le refus, lui, ne change pas : **2** dans les deux cas,
avant toute interrogation du système.

Ces refus portent sur ce qui ne peut pas être un service, jamais sur ce qui
n'existe pas : l'inexistence est un constat du système, elle vaut 1.

L'absence de `systemctl` rend **1**, avec un message qui nomme la dépendance :
la ligne de commande était juste, c'est la machine qui n'a pas ce qu'il faut.
Aucune distribution n'est exigée — ce qui compte est la présence de systemd, que
[ADR-0003](../../docs/agent/decisions/ADR-0003-cadrage-execution-autonome.md)
décision 14 pose partout, sans repli sur SysV ni OpenRC.

**La liste des services en échec n'est pas un état de santé complet du serveur.**
`systemctl list-units --state=failed` ne montre que les unités **chargées** dont
l'exécution a échoué : une unité masquée, désactivée ou qui n'a jamais démarré
n'y figure pas. La sortie du script le dit à chaque passage plutôt que de laisser
croire à un inventaire exhaustif. L'« état global » affiché en tête vient de
`systemctl is-system-running` : sa valeur `degraded` signifie qu'au moins une
unité a échoué — c'est banal, en conteneur notamment, et ce n'est pas une panne
du gestionnaire de services.

Le script n'agit sur aucun service — ni `start`, ni `stop`, ni `restart`, ni
`enable`, ni `disable` — et n'écrit rien hors du journal ouvert par
`lib/common.sh`. Il ne lit pas non plus les journaux d'un service : le message
renvoie vers `systemctl status` et `journalctl -u`, il ne les exécute pas.

Les arguments sont vérifiés avant les privilèges, si bien qu'une commande à la
fois mal formée et sans `sudo` rend 2 — le reproche le plus utile en premier.

Encore faut-il que le défaut soit constatable sans privilège. `configure-swap.sh
64M --file <un fichier d'échange en mode 600>` lancé sans `sudo` rend donc **1**,
et non 2 : la ligne de commande est juste, et si le script ne peut pas établir
la nature de la cible, c'est faute de droits de lecture — pas parce que la cible
serait mauvaise. Deux verdicts seulement sont reportés après `require_root`, et
pour cette raison-là : celui d'une cible existante et illisible, et celui d'un
répertoire d'accueil dont un ancêtre n'est pas traversable — `[ -d ]` y répond
« non » sans que le répertoire soit absent. Tous les autres refus de `--file`
sont rendus à l'analyse des arguments, en 2, avec ou sans `sudo` : l'absence
d'un répertoire, elle, se constate sans le moindre droit.

Tout message d'erreur porte le préfixe `[ERROR]` et part sur `stderr`. Un
argument obligatoire manquant produit un diagnostic de quelques lignes qui
renvoie vers `--help`, jamais l'aide entière.

**Un échec ne s'annonce qu'une fois.** Le `trap ERR` de `lib/common.sh` se
déclenche dans le sous-shell d'une substitution de commande *puis* dans le shell
principal pour l'affectation en échec : la même ligne `Échec (code 1) à la
ligne …` apparaissait deux fois, sans jamais dire ce qui avait échoué. Le remède
prend trois formes selon le site : l'affectation est placée en contexte de
condition — `if ! var="$(…)"`, où ni `errexit` ni le trap n'ont prise —, la
lecture est confiée à une fonction qui renseigne une variable globale au lieu
d'écrire sur `stdout`, ou la substitution est purement et simplement supprimée
quand elle faisait double emploi : la boucle de désambiguïsation des sauvegardes
de `configure-swap.sh` rappelait `date` à chaque tour, elle suffixe désormais un
horodatage lu une seule fois.

**Le périmètre tient dans une mesure : seules les affectations doublent.** En
position d'argument — `ligne "Noyau" "$(uname -r)"` — la substitution en échec
n'interrompt pas le script sous `errexit` : le code retenu est celui de la
commande appelante, jamais celui de la substitution. C'est l'affectation, et elle
seule, qui remonte l'échec au shell principal. Le motif se cherche donc sur la
forme `var="$(…)"` — y compris quand la substitution est noyée dans une chaîne,
comme l'était `sauvegarde="/etc/fstab.bak-$(date …)"` — et nulle part ailleurs.
Ces sites-là ne se trouvent pas en cherchant `="$(`, et deux d'entre eux ont
tenu jusqu'au dernier tour. Chercher plus
large, c'est ratisser trois fois trop de sites et manquer les vrais : trois
fichiers y ont échappé, l'un après l'autre.

Ni un test préalable ni `require_cmd` ne dispensent de la garde. `[ -f
<fichier> ]` établit que le fichier existait à l'instant du test, pas que le
`stat` qui suit aboutira ; `require_cmd hostname` prouve que la commande existe,
pas qu'elle réussit — un faux `hostname` en tête de `PATH` la met en échec, et
c'est une cause atteignable, mesurée. C'est à ce titre qu'ont été traitées les
quatre lectures de `stat` de `configure-cron.sh` — propriétaire et mode, avant
application puis à la vérification —, les deux lectures de `/etc/timezone` de
`configure-timezone.sh`, les deux appels à `hostname` de `configure-hostname.sh`,
le `nproc` et les deux `awk` sur `/proc/meminfo` de `system-info.sh`, et le
décompte de paquets d'`update-system.sh`, comme l'avait été la lecture de `stat`
de `configure-swap.sh`, qu'un faux `stat` en tête de `PATH` a mise en défaut sous
la même garde.

Sur un script en lecture seule, la garde ne tue pas le script : `system-info.sh`
avertit et affiche « non disponible », ce qu'il fait déjà partout ailleurs.

**Le motif ne s'arrête pas aux substitutions qui contiennent une commande
externe** : toute fonction qui rend sa valeur sur `stdout` et qu'on appelle en
substitution nue en relève, qu'elle appelle `die` ou non. `fuseau_actuel`, dans
`configure-timezone.sh`, en donnait la forme la plus coûteuse : sous un `tr` en
échec, elle rendait 0 malgré tout — le `return 0` qui suivait la lecture effaçait
le code — et l'appelante recevait une **chaîne vide** qu'elle comparait ensuite
au fuseau demandé. Un message en trop est une gêne ; une décision prise sur une
valeur fausse est un défaut. La fonction renseigne désormais `FUSEAU_ACTUEL`,
lit chaque source en contexte de condition, dit celle qui a flanché, passe à la
suivante, et **propage l'échec** quand aucune n'a répondu : au premier appel il
vaut un avertissement et la valeur `inconnu`, à la vérification il est fatal.

**Un `trap EXIT` ne doit jamais rendre un code non nul.** Bash y voit une
commande en échec de plus : `errexit` s'en saisit et le `trap ERR` du socle
écrit une ligne `Échec (code 1) à la ligne 1 de common.sh` — qui désigne
l'endroit où le trap est défini, jamais celui où quelque chose a échoué. Le
`nettoyer_temporaire` de `configure-cron.sh` faisait `return "$code"` et doublait
ainsi **tout** diagnostic postérieur à sa pose, les quatre lectures de `stat`
comme les `die` préexistants de `verifier()`. Il rend maintenant 0. Le code de
sortie du script n'en dépendait pas : bash rend celui passé à `exit`, et seul un
`exit` exécuté *dans* le trap le remplacerait.

**Ce README ne certifie plus la complétude ; le recensement le fait.** Les
affectations de la forme `var="$(…)"` du domaine sont relevées une par une, avec
leur verdict et sa raison — traitées, éteintes par `|| true`, sans objet, ou
laissées en l'état et pourquoi — dans
[recensement-substitutions.md](recensement-substitutions.md). C'est la pièce à
lire et à tenir à jour avant d'affirmer quoi que ce soit sur ce motif : les trois
énoncés de complétude qui figuraient ici étaient faux, et chacun a coûté un tour
de relecture.

**Plus aucun site du domaine n'est en forme nue avec une cause atteignable.** Le
dernier — `repertoire_swap="$(dirname -- "$FICHIER_SWAP")"` dans
`configure-swap.sh` — est passé en condition : sa raison écrite excluait
l'*absence* de `dirname`, jamais son *échec*, et elle ne valait pas même pour
l'absence, `config/server.env` pouvant redéfinir `PATH` après les lignes de
résolution de l'en-tête. Les six derniers sites ouverts — deux horodatages de
sauvegarde, les deux lectures d'`en_megaoctets`, le `basename` de
`configure-logging.sh` et ce `dirname` — ont été fermés le 2026-09-03 ; le
détail, verdict par verdict, est dans le recensement.

`DEMON_CRON="$(chemin_demon_cron)"`, dans `configure-cron.sh`, est une
affectation elle aussi, mais écrite **dans la condition d'un `if`** : elle relève
déjà de la garde, et son `return 1` est justement le cas que l'appelante traite.

### Interroger une unité systemd : `show`, jamais `is-active`

Relevé par TASK-023, dans le conteneur du profil `systemd` (Debian 12,
systemd 252). Le prochain script du domaine qui interroge systemd s'y heurtera.

**`systemctl is-active` ne distingue rien.** Il rend le même code **3** pour une
unité inactive, pour une unité en échec **et** pour une unité qui n'existe pas.
Un script qui s'appuie dessus ne peut pas dire à son appelant laquelle des trois
situations il a rencontrée. `systemctl is-enabled` sur une unité inconnue rend 1
en déversant un message brut sur `stderr`.

**`systemctl show` les distingue toutes, en un seul appel, et rend toujours 0** —
y compris sur une unité qui n'existe pas. C'est `LoadState` qui porte la
réponse, et il se lit **avant** `ActiveState` :

| `LoadState` | `ActiveState` | Situation |
|---|---|---|
| `not-found` | `inactive` | l'unité n'existe pas — `UnitFileState` est une **ligne vide** |
| `masked` | `inactive` | l'unité existe, elle est liée à `/dev/null` |
| `bad-setting`, autre | — | le fichier d'unité existe mais n'a pas pu être chargé |
| `loaded` | `active` / `failed` / autre | l'unité est chargée : l'état d'exécution est alors lisible |

Deux pièges de lecture qui accompagnent ce choix :

- **`ActiveEnterTimestamp` peut être vide.** Un service jamais démarré depuis
  l'amorçage n'a pas de date de dernier démarrage. Afficher la ligne telle quelle
  produirait un blanc ; `check-services.sh` affiche « non disponible » ;
- **`show` rapporte `inactive (dead)` pour une unité inconnue.** Relayer cette
  valeur ferait dire au diagnostic « le service existe, il est arrêté ».
  `check-services.sh` l'efface lorsque `LoadState` vaut `not-found`, et la
  conserve pour une unité masquée — celle-là existe.

**`systemctl list-units --failed` n'est pas un état de santé complet.** Il ne
montre que les unités **chargées** dont l'exécution a échoué : une unité masquée,
désactivée ou qui n'a jamais démarré n'y figure pas.

Enfin, `systemctl is-system-running` rend **`degraded`**, et un code 1, dès
qu'une seule unité a échoué. C'est banal — en conteneur notamment — et ce n'est
pas une panne du gestionnaire de services.

## Risques

`system-info.sh` est en lecture seule : il n'écrit rien et ne modifie rien.

`check-disk.sh` est en lecture seule lui aussi : hors du journal ouvert par
`lib/common.sh`, il ne crée, ne modifie ni ne supprime aucun fichier. Deux
réserves d'usage tout de même :

- **son analyse des répertoires coûte du temps.** `du` parcourt l'arborescence ;
  sur un répertoire de plusieurs téraoctets, la section prend des minutes.
  Trois bornes la contiennent — le répertoire de départ, l'absence de
  franchissement des points de montage (`-x`) et la profondeur 1 — et
  `--sans-repertoires` la supprime entièrement ;
- **`df` peut se figer sur un montage réseau injoignable.** Le script ne prend
  aujourd'hui aucune précaution contre ce cas : ni `df -l`, ni borne de temps.
  Sur une machine montant du NFS ou du CIFS, un partage tombé suspend la
  première section, sans que rien n'ait été écrit ni modifié — voir
  [points-en-suspens.md](../../docs/points-en-suspens.md) § 10.

**Ce que `check-disk.sh` ne fait pas** — et ce n'est pas un oubli :

| Il ne fait pas | Où cela se traite |
|---|---|
| aucune action corrective : suppression de fichier, purge de journaux, `apt-get clean`, nettoyage Docker | `Docker/Cleanup/`, et à la main |
| aucun contrôle de santé matérielle : `smartctl`, `badblocks`, températures | hors du domaine |
| aucun diagnostic mémoire | `check-memory.sh` |
| aucune notification d'un seuil dépassé | la remontée des échecs, [points-en-suspens.md](../../docs/points-en-suspens.md) § 2 |
| aucun seuil distinct par système de fichiers ni par métrique | un seuil global, surchargeable |

Il ne masque pas non plus ce qu'il n'a pas pu lire : une commande absente ou en
échec produit un avertissement qui la nomme, et « non disponible » à
l'affichage. **« non disponible » dit une ignorance, « aucun » un constat**, et
les deux ne se confondent pas : dans la section des périphériques, un `awk` en
échec sur `/proc/partitions` donne « non disponible » — la table n'a pas pu être
lue —, tandis qu'une table lue et vide donne « aucun périphérique bloc visible ».
Les faire aboutir au même message revenait à affirmer une absence qui n'avait pas
été établie. `df` et `du` rendent un code non nul dès qu'un seul point de
montage ou sous-répertoire leur résiste — le cas ordinaire d'une exécution sans
privilège sur `/` — après avoir écrit tout ce qu'ils ont pu : cette sortie
partielle est affichée, assortie d'un avertissement qui dit qu'elle l'est. Les
pseudo-systèmes de fichiers sont écartés du tableau, `overlay` excepté : c'est
le seul système de fichiers de la racine d'un conteneur, et l'écarter rendrait
le script muet là où il sert le plus.

`check-memory.sh` est en lecture seule lui aussi : hors du journal ouvert par
`lib/common.sh`, il ne crée, ne modifie ni ne supprime aucun fichier, et n'exige
aucun privilège. Il n'appelle que deux commandes externes — `free` et `ps`, du
paquet `procps` — et se passe des deux : sans `free`, il lit `/proc/meminfo` et
le dit ; sans `ps`, il abandonne le seul classement des processus. Aucune des
deux n'est une dépendance exigée, et son analyse ne parcourt aucune
arborescence : contrairement à `check-disk.sh`, il n'a aucun coût en temps.

**Ce que `check-memory.sh` ne fait pas** — et ce n'est pas un oubli :

| Il ne fait pas | Où cela se traite |
|---|---|
| aucune action corrective : libération de cache, `kill` d'un processus, activation d'un swap | à la main, en connaissance de cause |
| aucune création ni redimensionnement de fichier d'échange | `configure-swap.sh` |
| aucune lecture des traces du tueur de mémoire dans `dmesg` ou le journal | hors du domaine |
| aucune pression mémoire PSI, aucune comptabilité par cgroup | hors du domaine — ces grandeurs relèvent du diagnostic d'un conteneur, pas de la machine |
| aucun diagnostic de stockage | `check-disk.sh` |
| aucune notification d'un seuil dépassé | la remontée des échecs, [points-en-suspens.md](../../docs/points-en-suspens.md) § 2 |

Comme `check-disk.sh`, il ne masque pas ce qu'il n'a pas pu lire, et **« non
disponible » y dit une ignorance quand « aucune » dit un constat** : un
`/proc/swaps` lu et vide donne « aucune zone d'échange active », tandis qu'un
`/proc/swaps` illisible donne « non disponible ». La colonne de mémoire
résidente, enfin, compte les pages partagées dans chaque processus qui les
emploie : la somme de cette colonne dépasse la mémoire réellement occupée, et la
sortie le dit plutôt que de laisser croire à une addition juste.

Deux réserves de lecture, sans conséquence sur le système :

- **dans un conteneur sans `lxcfs`, `free` et `/proc/meminfo` décrivent la
  machine hôte** et non le conteneur. Les chiffres restent justes, ils ne
  portent simplement pas sur ce que l'on croit ;
- **la colonne `available` de `free` n'existe que depuis procps-ng 3.3.10**, et
  `MemAvailable` que depuis Linux 3.14. Sur un système antérieur, le seuil n'a
  rien à comparer : le script l'annonce au lieu d'inventer une valeur.

`update-system.sh` installe des paquets. Il ne redémarre jamais le serveur : un
redémarrage nécessaire est signalé en fin d'exécution, jamais déclenché.
Utiliser `--dry-run` pour vérifier ce qui serait installé.

`configure-logging.sh` écrit dans `/etc/logrotate.d/`. Il ne remplace jamais une
règle existante différente sans afficher les écarts et demander confirmation.

`configure-hostname.sh` modifie `/etc/hosts`, sauvegardé au préalable. La
réécriture passe par un fichier temporaire, la ligne `127.0.1.1` devant rester
unique ; si ce temporaire ne peut pas être créé — `/tmp` plein ou monté en
lecture seule — le script s'arrête en le disant, `/etc/hosts` inchangé. Sur un
nœud K3s ou Kubernetes, le nom d'hôte identifie le nœud : le changer après
installation rend le nœud existant inutilisable.

`configure-timezone.sh` modifie l'heure locale du système. Les tâches planifiées
suivent ce fuseau : un cron réglé sur 4 h s'exécutera à 4 h dans le nouveau
fuseau, donc à une autre heure réelle qu'auparavant.

`configure-cron.sh` écrit dans `/etc/cron.d/`. Il ne remplace jamais un fichier
existant différent sans afficher les écarts et demander confirmation, et il
n'installe pas cron : sur un serveur dont le démon est introuvable, il s'arrête
en indiquant `apt-get install cron`, sauf en `--dry-run` où il se contente d'un
avertissement puisqu'il n'écrit rien. Le fichier déposé fait tourner `update-system.sh` en
root, sans confirmation : à partir de son installation, des paquets sont mis à
jour sans intervention humaine. Le script signale — sans y toucher — une
planification concurrente d'`update-system.sh` trouvée dans `/etc/crontab` ou
dans un autre fichier de `/etc/cron.d/`. Il refuse un horaire mal formé plutôt
que de déposer une ligne que cron ignorerait en silence.

`configure-swap.sh` sans argument n'affiche que l'état. Avec une taille, il
désactive puis recrée le fichier d'échange et complète `/etc/fstab`, sauvegardé
au préalable. Il refuse de désactiver un swap dont le contenu ne tiendrait pas
en mémoire disponible. Les partitions de swap et les systèmes de fichiers btrfs
et ZFS ne sont pas pris en charge.

**`--file` n'accepte qu'un chemin absolu.** Deux valeurs sont refusées avant
toute action, avec le code 2 :

- **une valeur commençant par un tiret**, parce que c'est une option du script et
  non un chemin. `configure-swap.sh 512M --file --dry-run` faisait autrement de
  `--dry-run` le nom du fichier d'échange, et l'essai à blanc était perdu en
  silence — l'utilisateur croyait le demander sans l'obtenir ;
- **un chemin relatif**, parce que le fichier d'échange naîtrait dans le
  répertoire courant, quel qu'il soit. `configure-swap.sh --file 2G` — l'ordre
  inversé — prend `2G` pour un chemin, et si `SRV_SWAP_SIZE` est défini dans
  `config/server.env`, la taille ne manque même pas : plus rien n'arrêtait le
  script.

Un fichier d'échange n'a de sens qu'à un emplacement choisi ; il n'existe aucun
usage légitime d'un chemin relatif ici.

**Un chemin bien formé ne dit pas ce qu'il désigne.** Le script supprime sa cible
avant de la recréer : il ne le fera que d'un fichier qu'il reconnaît. Trois
natures, trois traitements :

| La cible | Traitement |
|---|---|
| n'existe pas | création — cas nominal |
| est un fichier d'échange existant | redimensionnement — cas nominal |
| est autre chose | refus en code 2, avant toute confirmation |

`configure-swap.sh 64M --file /etc/passwd` annonçait `créer /etc/passwd`,
demandait confirmation, et le fichier disparaissait sur un simple oui.
`--file /tmp/un-répertoire` ou `--file /` mouraient plus loin sur le message brut
`rm: cannot remove … : Is a directory`. Les deux sont désormais refusés à
l'analyse des arguments, avec le code 2 et un diagnostic qui nomme la cible et
dit ce qui aurait été détruit. Un lien symbolique l'est aussi : le fichier
d'échange remplacerait le lien et laisserait sa cible en place.

**Le répertoire d'accueil doit exister.** `--file /pas/de/dossier/swapfile`
franchit les contrôles ci-dessus — une cible absente est le cas nominal d'une
création — mais un fichier d'échange ne peut pas naître dans un répertoire qui
n'existe pas. Le script mourait alors sur l'échec muet de `df` ; il refuse
désormais en code 2, en nommant le répertoire manquant, **dès l'analyse des
arguments** : un répertoire absent se constate sans privilège, et le script ne
crée aucun répertoire. Seul le cas ambigu attend `require_root` — lorsqu'un
ancêtre du chemin n'est pas traversable par l'appelant, `[ -d ]` répond « non »
sans que le répertoire soit absent, et rien ne serait alors reproché à la ligne
de commande.

Un fichier d'échange est reconnu de deux façons, dans cet ordre : `/proc/swaps`
le liste s'il est **actif** ; s'il est **inactif**, la signature `SWAPSPACE2` que
`mkswap` écrit sur les dix derniers octets de la première page l'identifie —
c'est celle-là même que lit la commande `file`, qui n'est pas pour autant exigée
comme dépendance. Un fichier d'échange est en mode 600 : sans `sudo`, sa
signature est hors d'atteinte, et le script ne peut rien conclure. Il ne conclut
donc rien à ce moment-là — le jugement est reporté après `require_root`, qui
reproche le privilège manquant en rendant 1. Une fois root, la lecture aboutit :
la cible est reconnue et redimensionnée, ou refusée en 2 comme n'importe quelle
autre.

Le contrôle porte sur la cible effective. La valeur de `--file` est vérifiée dès
sa lecture ; le chemin par défaut `/swapfile` l'est juste après `require_root`,
avant le résumé et la confirmation — le même `rm -f` l'attend. C'est aussi lui
qui tranche le cas des cibles restées illisibles au premier.

**Un fichier d'échange incomplet n'est plus recréé automatiquement.** Le script
supprime ce qu'il ne reconnaît pas comme un swap : un fichier laissé par une
exécution interrompue avant `mkswap` — `kill -9`, plantage, coupure de courant —
ne porte pas encore la signature `SWAPSPACE2` et sera donc refusé au lancement
suivant, à supprimer soi-même. Le cas est étroit : toutes les sorties ordinaires,
`die` compris, passent par un `trap` qui retire déjà le fichier incomplet ; seul
un arrêt brutal y échappe.
