# tests/ — validations du dépôt

Ce répertoire porte la **preuve**. Tant qu'une commande d'ici n'a pas réussi,
rien n'est démontré : ni par la lecture du code, ni par la conviction d'un
modèle, ni par le fait que « ça a marché sur le serveur ».

Point d'entrée unique :

```bash
tests/run.sh              # tous les niveaux implémentés
tests/run.sh lint         # un niveau précis
tests/run.sh --liste      # ce qui existe et ce qui manque
```

Un seul point d'entrée, pour que la commande de validation inscrite dans une
tâche soit exactement celle qu'un humain tape.

Sur la machine de développement, seule l'analyse statique s'exécute directement.
Tout le reste passe par un conteneur Debian jetable (§4) :

```bash
tests/env/run-in-container.sh -- tests/run.sh
```

---

## 1. Niveaux

| Niveau | Contenu | Environnement | État |
|---|---|---|---|
| `lint` | `bash -n` sur tous les `.sh`, `shellcheck` si disponible | hôte | **implémenté** |
| `unit` | fonctions de `lib/common.sh` | conteneur `debian` | **implémenté** |
| `integration` | exécution réelle, `--dry-run`, idempotence | conteneur `debian` | **implémenté** |
| `environment` | services, `systemctl`, état système | conteneur `systemd` | **implémenté** |
| `acceptance` | critères d'acceptation d'une tâche | selon la tâche | **implémenté** |

Un niveau s'ajoute en déposant son script au chemin annoncé par
`tests/run.sh --liste`. Aucune autre modification n'est nécessaire.

### Le niveau `unit`

Un fichier par sujet, nommé `tests/unit/<sujet>.test.sh`. `run-unit.sh` les
découvre — **en `maxdepth 1`**, comme l'acceptance — et agrège leurs verdicts.

```text
tests/unit/
├── run-unit.sh          le dispatcher
└── common.test.sh       les onze critères de TASK-003, plus les trois
                         corrections de TASK-015
```

`lib/common.sh` est le point de défaillance unique du dépôt : chaque script le
charge. Le tester impose trois précautions, toutes visibles en tête de
`common.test.sh` :

- **les fonctions qui appellent `exit`.** `die`, `require_root`, `require_cmd`,
  `require_os` et `load_config` tueraient le shell du harnais. Chaque cas est
  donc écrit dans un fichier jetable et exécuté par un **processus `bash`
  neuf**, dont on capture le code, `stdout`, `stderr` et le journal. Un
  sous-shell `( source … )` ne suffirait pas : il hérite de la variable
  `_COMMON_SH_CHARGE` du harnais, et la garde anti-double-chargement ferait de
  son `source` une opération nulle ;
- **le bac à sable.** `SCRIPTS_ROOT` étant résolu depuis l'emplacement de
  `lib/common.sh`, une **copie** de ce fichier dans un répertoire temporaire s'y
  enracine d'elle-même. Les `config/*.env` jetables y sont créés sans jamais
  écrire dans `config/`, et un éventuel `config/server.env` de la machine — que
  `common.sh` charge de lui-même — ne fausse rien. L'identité de la copie est
  prouvée par `cmp` ;
- **les journaux.** `common.sh` crée `LOG_DIR` et calcule `LOG_FILE` dès le
  `source`. `LOG_DIR` est redirigé vers un répertoire temporaire, remis à zéro
  avant chaque cas et supprimé à la fin.
  Deux situations distinctes sont éprouvées, et ne se confondent pas : un
  `LOG_DIR` **non créable au chargement** — `LOG_FILE` reste vide, rien n'est
  jamais tenté (§10) — et un journal **devenu inécrivable en cours
  d'exécution**, ouvert normalement puis disparu (§11). L'une comme l'autre
  mènent à la seconde branche de `run_logged`, celle qui n'emploie pas `tee`.

`require_root` demande en plus un utilisateur non privilégié, alors que le
conteneur tourne en `root`. Trois lanceurs sont **éprouvés** dans cet ordre —
`setpriv`, `runuser`, `chroot --userspec` — et le premier qui abaisse
réellement l'UID est retenu. Si aucun n'y parvient, les cas concernés sont
déclarés `NON EXÉCUTÉ`, jamais réussis.

Le `set -Eeuo pipefail` du harnais reste en place de bout en bout. Le retirer
pour faire passer un cas vaudrait échec de la tâche — [AGENTS.md](../AGENTS.md)
§12.

#### Trois écarts relevés ici, tranchés et corrigés

Ces trois écarts entre l'énoncé et le socle avaient été **mesurés sans être
corrigés** : `lib/common.sh` est en zone protégée. [ADR-0003](../docs/agent/decisions/ADR-0003-cadrage-execution-autonome.md)
les a tranchés — décisions 7, 8 et 9 — et TASK-015 a corrigé le socle. Les
assertions qui épinglaient l'ancien comportement ont été **retournées dans le
même commit** ; `common.test.sh` décrit désormais le contrat effectif.

| Écart | Décision | Prouvé par |
|---|---|---|
| `load_config` faisait `. "$fichier"` : une affectation nue n'atteignait pas les processus fils | `set -a` / `set +a` autour du `source` (7) | §6 |
| un `LOG_FILE` devenu non inscriptible tuait le script sous `set -e` | un avertissement, **une seule fois**, puis on continue sans journal (8) | §11 |
| le `trap ERR` nommait toujours `$0`, même quand la faute venait du socle | `${BASH_SOURCE[0]}`, évalué dans la chaîne du trap (9) | §12 |

Le §6 ne se contente pas du cas nominal : il vérifie que `set +a` est rétabli
**même lorsque le `source` échoue** — sinon tout ce que le script déclare
ensuite serait exporté à son insu — et que l'appelant qui avait lui-même armé
`allexport` le retrouve armé. Le §11 exige **exactement un** avertissement pour
cinquante-quatre messages, un code de sortie 0, et **aucun message brut de
bash** sur `stderr` : c'est ce dernier point qui prouve que la redirection porte
sur le groupe et non sur le seul `printf`. Le §12 éprouve **les deux sens** —
faute du socle, faute du script appelant : une correction qui se contenterait
d'inverser le défaut passerait un test unilatéral.

Le §6 fige aussi la **contrepartie** de ce `|| code=$?` : le contexte de
condition suspend `errexit` *pendant* l'exécution du fichier sourcé. Une
commande en échec au milieu d'un `.env` n'interrompt donc plus rien — le source
va jusqu'au bout, les affectations qui la suivent sont prises en compte, et
`load_config` annonce un chargement réussi. Le socle de `master` tuait le script
en 127. C'est assumé — voir [docs/architecture-technique.md](../docs/architecture-technique.md) —
et c'est le seul filet : qui « rétablirait » la sévérité en retirant le
`|| code=$?` casserait du même geste la garantie du `set +a`, sans qu'aucune
autre assertion ne s'en aperçoive.

Chaque correction a été éprouvée par mutation de `lib/common.sh` — `set -a`
retiré, `set +a` retiré, drapeau `_JOURNAL_AVERTI` retiré, `$0` rétabli dans le
trap, redirection déplacée sur le `printf`, garde `if` retirée,
`PIPESTATUS[0]` remplacé par `$?`, `|| code=$?` retiré de `load_config`. Les
huit font rougir au moins une assertion — la dernière en fait rougir onze.

#### La régression de couverture de `run_logged`, et comment elle est fermée

Deux cas du §9 sont les **seuls** à prouver que `run_logged` rend
`PIPESTATUS[0]` et non le code du tube : partout ailleurs `tee` réussit et les
deux valeurs coïncident. Ils faisaient échouer `tee` en pointant `LOG_FILE` vers
un répertoire inexistant.

La décision 8 a rendu ce montage **creux** : `run_logged` appelle `info` en
premier, `info` constate le journal mort et vide `LOG_FILE`, et la fonction
bascule sur la branche *sans* `tee`. Les deux assertions restaient vertes sans
plus rien prouver — vérifié : sous une mutation remplaçant `PIPESTATUS[0]` par
`$?`, l'ancienne formulation rend encore `0` et `42`, les valeurs attendues.

Le journal reste donc désormais parfaitement écrivable, et c'est **`tee` seul**
qui échoue : un faux `tee` placé en tête de `PATH` relaie fidèlement son entrée
puis sort en 1. Deux gardes accompagnent chaque cas — journal non vide, aucun
avertissement de journal mort — pour que la branche à `tee` ne puisse plus être
désertée en silence. Sous la même mutation, la nouvelle formulation rougit.

### Le niveau `integration`

Un fichier par sujet, nommé `tests/integration/<sujet>.test.sh`.
`run-integration.sh` les découvre — **en `maxdepth 1`**, comme l'unit et
l'acceptance — et agrège leurs verdicts.

```text
tests/integration/
├── run-integration.sh        le dispatcher
├── check-memory.test.sh      check-memory.sh
├── configure-cron.test.sh    configure-cron.sh
└── linux-system.test.sh      les six scripts de Linux/System, et check-disk.sh
```

`check-memory.sh` a son propre fichier plutôt qu'un groupe dans
`linux-system.test.sh` : ce dernier passe les 4 900 lignes, et l'ordre de ses
groupes est contraint par une garde d'état — l'empreinte relevée au groupe 2 est
comparée à celle du groupe 4. Un script qui n'écrit rien n'a aucune raison
d'entrer dans cette contrainte.

**Ce niveau modifie le système sur lequel il tourne** : il réécrit `/etc/hosts`,
`/etc/localtime` et `/etc/logrotate.d`. Il n'a rien à faire sur une machine de
travail, et ne s'exécute que dans le conteneur jetable :

```bash
tests/env/run-in-container.sh -- tests/run.sh integration
```

Le fichier de cas se protège lui-même : il ne modifie rien tant qu'il n'a pas
reconnu un système jetable — `/.dockerenv`, un cgroup de conteneur, ou
`MGNET_TEST_JETABLE=1`. Ailleurs, les groupes modifiants sont `NON EXÉCUTÉ`.

**Conséquence sur l'hôte Windows :** aucun cas ne peut y tourner, le niveau
rend donc **3** et `tests/run.sh` sans argument rend 3 lui aussi. Ce n'est pas
un échec, c'est le sens exact du code — *rien n'est prouvé pour ce niveau*. La
commande de référence reste celle du §4 :
`tests/env/run-in-container.sh -- tests/run.sh`.

#### Comment l'idempotence est prouvée, et pourquoi « A == B » ne suffit pas

```text
empreinte P0 → exécution 1 → empreinte A → exécution 2 → empreinte B
```

Sur un système déjà conforme, les deux exécutions ne font rien, les trois
empreintes sont égales, et le test passe **sans rien prouver**. C'est
précisément ce que la règle « un conteneur neuf par cas » cherche à empêcher.
Chaque cas exige donc aussi **`P0 != A`** : le premier passage doit avoir
réellement modifié quelque chose. Une idempotence mesurée à vide devient un
échec, et non un succès silencieux.

Les deux assertions se contrôlent l'une l'autre : si l'empreinte était
constante, `P0 != A` tomberait ; si elle était bruitée, `A == B` tomberait. Le
dispositif a été éprouvé à l'envers — système mis d'avance dans l'état
conforme, la garde échoue comme attendu.

L'empreinte relève **tout `/etc`**, contenu compris, plus le nom d'hôte,
`/proc/swaps` et la taille de `/swapfile` — et non une liste de fichiers
arrêtée d'avance : un fichier inattendu se voit. `LOG_DIR` en est exclu,
`lib/common.sh` y écrivant un journal au seul chargement ; les écritures hors
journaux sont surveillées séparément, par `find -newer`.

Ce fichier tourne dans un **unique** conteneur — c'est là que
`tests/run.sh integration` est invoqué, et `docker` n'y est pas disponible pour
en créer d'autres. Trois dispositions remplacent le conteneur neuf par cas, et
sont vérifiées plutôt que supposées : les groupes non modifiants passent en
premier ; l'empreinte relevée juste avant le groupe « idempotence » est
comparée à celle du départ, et une dérive fait déclarer le groupe entier `NON
EXÉCUTÉ` ; les trois cas portent sur des fichiers **disjoints**.

#### Recouvrement avec `tests/acceptance/TASK-011-*`

`TASK-011-analyse-statique.sh` éprouve déjà, dans onze conteneurs neufs, le
préflight, les `--dry-run` et l'idempotence de cinq de ces six scripts. Ses
assertions sont formulées autour des corrections d'analyse statique qu'elle
portait — `SC1087`, `export ASSUME_YES` — et disparaîtront avec elle : le
niveau `integration` est le domicile durable de ces preuves.

Le recouvrement est donc **assumé**, borné à un conteneur au lieu de onze. Les
groupes `preflight`, `dry-run`, `timezone`, `hostname` et `logging` de
TASK-011 pourraient être ramenés à leurs seules assertions propres aux
corrections SC1087 — cela relève d'une tâche distincte, pas d'un effet de bord.

Ce que le niveau `integration` apporte en propre :

- **`system-info.sh`**, que TASK-011 ne couvre que par `--help` : option
  inconnue, exécution sans privilège, lecture seule prouvée, deux exécutions ;
- la garde **`P0 != A`**, absente de TASK-011 ;
- l'empreinte de **tout `/etc`**, là où TASK-011 relève une liste de fichiers ;
- le cas **« le nom demandé est déjà un alias de la ligne `127.0.1.1` »**,
  chemin de `hosts_deja_conforme()` qu'aucun cas existant n'emprunte.

#### Le verrou des codes de retour — groupes « 1 bis » et « 1 ter »

TASK-016 a corrigé quatre écarts à la convention des codes de retour. Les
groupes `1 bis` et `1 ter` de `linux-system.test.sh` les épinglent, faute de
quoi rien n'empêcherait la dérive de revenir — c'est ce qui était arrivé à la
dette `shellcheck`, invisible depuis les premiers commits.

| Ce qui est verrouillé | Par quelle forme d'assertion |
|---|---|
| `--file` sans valeur rend 2, préfixé `[ERROR]` | code, contenu, **une seule ligne** sur `stderr`, et absence du message brut de bash |
| une valeur invalide rend 2 sur les trois scripts | code, sur six chemins de validation distincts |
| le `trap ERR` ne double plus le diagnostic | **absence** de `Échec (code …)`, gardée par le code, la présence du diagnostic métier et le **décompte** des lignes `[ERROR]` |
| un argument obligatoire manquant ne déverse pas l'aide | **borne** sur le nombre de lignes de `stderr`, doublée par l'absence de `Usage :` et `Options :` |
| sans privilège : 1 si la commande est juste, 2 si elle est fautive | les deux moitiés en regard, sur les cinq scripts modifiants |

Deux formes reviennent, et ce n'est pas un hasard. **Le décompte** est la seule
qui voie revenir des lignes en trop : une assertion de contenu reste verte
pendant qu'on en ajoute autour d'elle. **L'assertion d'absence**, elle, est
facile à écrire creuse — sur un `stderr` vide ou mal capturé elle passe sans
rien prouver ; chacune est donc encadrée de gardes qui exigent que le flux
contienne bien ce qu'on y attend par ailleurs.

Les six assertions ont été éprouvées par mutation des scripts — `${1:?…}`
rétabli, `die` sans code dans `valider_fuseau` puis dans `valider_nom`,
`en_megaoctets` remise dans une substitution de commande, `show_help >&2`
rétabli, conversion `G` amputée de son `× 1024`. Chaque mutation fait rougir de
deux à cinq assertions ; les scripts sont restaurés ensuite et l'identité
vérifiée par `git diff`.

#### Ce que `--file` refuse — sections 5 et 6, groupes « 3 bis » et « 3 ter »

TASK-017 puis TASK-019 ont durci `--file`, d'abord sur la **forme** du chemin,
ensuite sur la **nature** de ce qu'il désigne.

| Ce qui est verrouillé | Tâche |
|---|---|
| une valeur commençant par `-` est refusée, et n'est plus consommée comme chemin | 017 |
| un chemin relatif est refusé — sinon un fichier d'échange naîtrait dans le répertoire courant | 017 |
| un fichier régulier qui n'est pas un swap est refusé, jamais supprimé | 019 |
| un répertoire, `/`, un lien symbolique sont refusés proprement, sans message brut de `rm` | 019 |
| une cible illisible faute de privilège rend 1, pas 2 — la commande était juste | 019 |
| les deux cas nominaux passent : chemin inexistant (création), fichier d'échange existant (redimensionnement) | 019 |

Trois enseignements de ces deux tâches méritent d'être retenus, parce qu'ils
reviendront.

**Un décompte de lignes se mesure, il ne se déduit pas.** Le rédacteur de
TASK-017 en avait annoncé trois pour les deux refus ; il y en a quatre pour le
refus du tiret et trois pour celui du chemin relatif. Deux vérifications
indépendantes ont été nécessaires pour l'établir.

**Une assertion peut prouver moins qu'elle n'en a l'air.** Le cas
`--dry-run` placé derrière une valeur de `--file` passait **déjà** sur `master` :
c'est une garde de non-régression, pas la démonstration du correctif. De même,
« aucun fichier créé dans le répertoire courant » ne peut pas rougir — le `trap`
de nettoyage du script efface le fichier avant que le test ne regarde. Ces
limites sont écrites à côté des assertions concernées, pour qu'on ne s'y fie pas.

**La mutation utile n'est pas toujours celle qu'on avait prévue.** Aucune des
trois mutations demandées pour TASK-019 ne touchait les assertions d'intégrité de
fichier. Le testeur en a ajouté une quatrième — neutraliser le contrôle de nature
entièrement — qui a réellement détruit `/etc/passwd` dans le conteneur, et fait
rougir vingt et une assertions. C'est elle qui prouve que ces assertions ne sont
pas creuses.

#### Le non-doublement du `trap ERR` — groupes « 3 quater » à « 4 quinquies », et « 8 bis »

TASK-018 a repris les substitutions de commande de `Linux/System` dont l'échec
faisait parler le `trap ERR` de `lib/common.sh` deux fois : dans le sous-shell de
la substitution, puis dans le shell principal pour l'affectation. Deux lignes
identiques, aucune ne nommant la cause.

**Cinq tours** ont été nécessaires, parce que le recensement a manqué quelque
chose à chaque fois : `configure-cron.sh` et `configure-timezone.sh` au deuxième,
`system-info.sh` en entier au quatrième, et sept sites laissés en forme nue au
cinquième. Le relevé exhaustif existe désormais —
[`Linux/System/recensement-substitutions.md`](../Linux/System/recensement-substitutions.md),
54 sites, un verdict et une raison pour chacun, **y compris ceux qui ne sont pas
traités**. Les cas de `configure-cron.sh` vivent dans son propre fichier, groupe
« 8 bis ».

##### Ce qu'un décompte de lignes vaut vraiment

**Le nombre de lignes que le `trap ERR` produit n'est pas un invariant du
motif.** C'est la mesure qui explique pourquoi trois chiffres annoncés se sont
révélés faux dans ce chantier. Sondes en conteneur :

| Forme | Lignes de trap | Suite |
|---|---|---|
| `f "$(false)"` — position d'argument | **aucune** | le script poursuit, code 0 |
| `v="$(false)"` — affectation directe | deux | code 1 |
| `v="$(g)"` où `g` échoue — affectation appelant une fonction | **trois** : une au numéro du corps de `g`, deux à celui de l'affectation | code 1 |

Et le flux compte autant que la profondeur : avec un `trap` écrivant sur
`stdout`, la même affectation n'en montre qu'**une** — les autres sont produites
dans le sous-shell, donc **capturées par la substitution** et rangées dans la
variable. Celui de `lib/common.sh` écrit sur `stderr`, rien n'est capturé, tout
se voit.

Conséquence de méthode : chaque décompte des fichiers de cas est **mesuré sur son
site**, jamais repris d'un autre, et chacun porte à côté de lui ce qu'il
discrimine et ce qu'il ne discrimine pas. Conséquence de périmètre : seules les
**affectations** doublent, ce qui borne la recherche à `var="$(…)"` — les vingt
substitutions en position d'argument de `system-info.sh` n'en relèvent pas.

Ces groupes **ne verrouillent pas tous les sites**, et c'est le point important.
Le compte a été établi en remettant chaque site en forme nue et en relançant le
niveau — jamais par lecture du code :

| Site corrigé | Cause d'échec atteignable | En forme nue, le fichier de cas… |
|---|---|---|
| `stat` — `lire_taille_actuelle`, swap | oui, faux `stat` en tête de `PATH` | rougit (3 assertions) |
| `mktemp` — hostname | oui, `TMPDIR` sur un chemin absent | rougit (5 assertions) |
| `stat` ×4 — cron, `appliquer_permissions` et `verifier` | oui, deux stubs : l'un total, l'autre refusant le seul `-c %a` | rougit (2 assertions par site) |
| `tr` — timezone, mise en cohérence | oui, faux `tr` | rougit (2 assertions) |
| `fuseau_actuel` — timezone, les deux appels | oui : `/etc/timezone` vide, puis les trois sources en échec | rougit (3 assertions sur la garde de valeur vide, 7 sur la propagation d'échec) |
| `hostname` — configure-hostname, préflight | oui, faux `hostname` | rougit (14 assertions — le script mourait au premier site) |
| `hostname` — configure-hostname, vérification | oui, le même stub | rougit (7 assertions) |
| `nproc` — system-info | oui, faux `nproc` | rougit (11 assertions) |
| `awk` MemTotal — system-info | oui, `free` masqué + faux `awk` sélectif | rougit (9 assertions) |
| `awk` MemAvailable — system-info | oui, le même montage | rougit (9 assertions) |
| `wc \| tr` — update-system | oui, faux `wc` + faux `apt-get` pour atteindre le site | rougit (8 assertions) |
| `dirname` — swap, répertoire d'accueil | oui, faux `dirname` sélectif sur « `--` » | rougit (3 assertions) |
| `sed` — `en_megaoctets`, le nombre | oui, faux `sed` sélectif sur l'expression du site | rougit (2 assertions) |
| `tr` — `en_megaoctets`, l'unité | oui, faux `tr` sélectif sur `[:lower:]` | rougit (2 assertions) |
| `basename` — configure-logging | oui, faux `basename` sélectif sur `LOG_DIR` | rougit (6 assertions) |
| `date` — hostname, nom de la sauvegarde | oui, faux `date` | rougit (4 assertions) |
| `date` — swap, phase fstab | oui, faux `date` + faux `swapon` pour atteindre le site | rougit (5 assertions) |
| boucle de suffixe — swap (substitution **supprimée**) | oui, faux `date` qui numérote ses appels | rougit (3 assertions) |
| `df -T` — répertoire d'accueil, swap | seulement le répertoire absent, que TASK-018 intercepte par un contrôle explicite | reste **vert** ; c'est le contrôle, retiré, qui fait rougir 5 assertions |
| `df -BM` — espace libre, swap | non | reste vert |
| `awk` sur `/proc/swaps` et `/proc/meminfo` — swap | non — exige un swap actif | non muté, hors d'atteinte |
| `tr` — timezone, vérification | non — le stub tue le script à la première lecture | non muté |

`dirname` est allé et venu **trois fois**, et c'est le site le plus instructif du
chantier : corrigé au premier tour, remis en forme nue au second — sa branche
`if !` ayant été jugée du code mort —, remis en condition au cinquième.
L'argument de code mort couvrait l'**absence** de la commande, jamais son
**échec**. Il ne couvrait d'ailleurs pas l'absence de façon sûre : les lignes de
résolution s'exécutent avant que `lib/common.sh` ne charge `config/server.env`,
lequel peut redéfinir `PATH`.

Les sites sans cause atteignable sont déclarés `NON EXÉCUTÉ` au groupe 5, un par
un. Une correction qu'aucune exécution ne touche reste une correction non
vérifiée ; la compter comme prouvée serait le faux vert le plus coûteux de cette
tâche. Le saut y est **neutre** et non `saute_par_nature` pour `df -T` et
`df -BM` : leur raison — « le contrôle de répertoire les précède » — est une
propriété du code que la même tâche vient d'ajouter, pas une limite de
l'environnement. Une correction rendue invérifiable par une autre correction du
même diff ne peut pas s'auto-certifier hors d'atteinte.

**Plus aucune affectation ne reste en forme nue.** Le quatrième tour en laissait
six, plus le `dirname`, chacune avec une raison écrite. Le relecteur a qualifié
cela d'**abandon déguisé** : la raison invoquée était toujours la même — « aucune
cause n'atteint ce site » — et elle avait été démentie quatre fois de suite par
la même mutation d'une ligne. Les sept sont fermés, éprouvés, et chacun rougit
sous mutation. Il ne subsiste au groupe 5 qu'une réserve d'une autre nature :
`update-system.sh:133`, dont le `|| true` empêche le doublement mais laisse une
chaîne vide au test arithmétique qui suit.

Une des sept n'a pas été mise en condition mais **supprimée** : la boucle de
désambiguïsation de `configure-swap.sh` rappelait `date`, si bien qu'une
collision de nom produisait `…-<nouvel horodatage>-1` alors que
`…-<nouvel horodatage>` était libre. L'horodatage est désormais lu une fois et
réutilisé — la meilleure façon de fermer une substitution reste de s'en passer.

##### Les échecs qui ne sont pas fatals

Les six sites du quatrième tour ont une propriété que les précédents n'avaient
pas : **leur échec ne doit pas arrêter le script**, et l'assertion décisive de
chaque cas est donc « code 0 », suivie de la valeur affichée.

`system-info.sh` est un script de diagnostic en lecture seule : sa nature est de
dégrader — « non disponible » — pas de mourir parce qu'un `nproc` manque. Le
décompte de paquets d'`update-system.sh` ne sert qu'à l'affichage : il dégrade en
`?`, jamais en chaîne vide. Et les deux lectures de `hostname` rendent `inconnu`,
le script réécrivant `/etc/hosts` malgré tout.

Trois montages ont été nécessaires, et chacun porte ses gardes :

- un **binaire homonyme en tête de `PATH`** met en échec n'importe quelle
  commande externe. C'est la mutation la moins coûteuse du dépôt, et celle qui a
  démenti trois arbitrages de non-traitement : `require_cmd hostname` prouve que
  la commande existe, **pas qu'elle réussit** ;
- un **stub sélectif** — qui ne refuse que `-c %a`, ou que les lectures de
  `MemTotal` — atteint le second site d'une fonction quand un stub total
  s'arrêterait au premier. Sans lui, quatre corrections resteraient sans preuve ;
- un **bac à sable de liens symboliques** reproduit le `PATH` sans `free`. Le
  mettre en échec ne suffirait pas : `command -v free` réussirait encore et la
  branche `/proc/meminfo` resterait fermée.

Chaque cas est encadré d'une **garde de contraste** : le même appel sans le stub
doit rendre une vraie valeur. Sans elle, un cas serait vert sur une machine où la
valeur vaudrait déjà « non disponible » pour une tout autre raison.

##### Deux défauts que ces groupes ont trouvés, et qui sont corrigés

Ces assertions ont été laissées **rouges le temps d'un tour**, jamais
neutralisées. C'est ce qui a fait corriger les scripts ; leur passage au vert est
la preuve.

**`configure-cron.sh` doublait tout diagnostic postérieur à son `trap EXIT`.**
`nettoyer_temporaire` faisait `return "$code"`, et un `trap EXIT` qui rend un
code non nul **arme le `trap ERR`** : le socle écrivait une ligne
`Échec (code 1) à la ligne 1 de common.sh`, qui ne désignait rien — c'est
l'endroit où le trap est défini. Cela valait pour les quatre lectures de `stat`
comme pour les `die` préexistants de `verifier()`. La fonction rend désormais `0`
en toute circonstance, et son `rm` est en condition pour que son propre échec ne
rejoue pas la scène.

Le **code de sortie n'a pas bougé** : les quatre cas rendent toujours `1`.
Mesuré, y compris sous la mutation qui rétablit `return "$code"`. Bash rend le
code passé à `exit` ; un `trap EXIT` terminé normalement ne le remplace pas, seul
un `exit` exécuté *dans* le trap le ferait. L'ancien `return "$code"` ne
préservait donc rien, il ne faisait qu'armer le trap — aucun `exit "$code"`
n'était nécessaire.

**`configure-timezone.sh` gardait une substitution nue en amont des deux
corrigées.** `FUSEAU_ACTUEL="$(fuseau_actuel)"` appelait une fonction qui lit
`/etc/timezone` par le même `tr`, et dont le `return 0` **effaçait le code** de
la lecture : sous un `tr` en échec, `FUSEAU_ACTUEL` valait la **chaîne vide** et
le script comparait le fuseau demandé à rien avant de l'appliquer. Pas un message
en trop : une décision prise sur rien.

`fuseau_actuel` renseigne désormais la globale, lit chaque source en condition,
annonce l'échec de chacune et **propage** celui de la dernière. Les deux appels
n'en font pas la même chose, et c'est éprouvé : avant l'application l'échec est
**non fatal** — `FUSEAU_ACTUEL` vaut `inconnu`, jamais une chaîne vide — à la
vérification il est **fatal**, une vérification qui ne peut pas lire l'état
courant ne prouve rien.

##### Cinq enseignements

**Un décompte de lignes peut rester vert sous la mutation qu'il vise.** Mesuré
trois fois. Ce qui discrimine, ce sont les assertions de contenu et l'absence de
`Échec (code`. Le décompte borde, il ne prouve pas — mais c'est lui, et lui seul,
qui a vu partir le résidu de `trap EXIT` de `configure-cron.sh`. Chaque cas le dit
à l'endroit où il est écrit.

**Une justification de placement se mesure.** Le premier tour plaçait le contrôle
de répertoire après `require_root`, au motif qu'il aurait exigé des droits.
Faux : l'absence d'un répertoire se constate sans privilège. Le contrôle est
passé au moment `avant-root`, et le cas éprouve désormais **les deux moitiés** —
root et non-root rendent le même 2. Ce que le script a encore raison de différer
est autre chose, et se distingue : un **ancêtre non traversable** rend `[ -d ]`
faux sans que le répertoire soit absent. Trois moitiés le prouvent — refus
différé, témoin qui tranche quand même sans privilège, chemin nominal en root —
et retirer `ancetres_traversables` ne fait rougir que la première.

**Une condition mal formée ne dit rien.** Le vrai risque des affectations mises
en contexte de condition n'est pas un message en trop, c'est une **valeur fausse**
rendue en silence. Le groupe 3 quater confronte donc `espace_libre_mo` et
`repertoire_swap` à une mesure que le harnais fait lui-même, à **64 Mo près** — de
quoi absorber le bruit d'un conteneur qui écrit ses journaux, bien trop peu pour
laisser passer une erreur d'un gigaoctet — et le chemin nominal `512M --dry-run`
exige **zéro** ligne `[ERROR]`.

**Le motif n'était pas « les substitutions », c'était « la valeur perdue ».**
`fuseau_actuel` ne contenait aucun `die` et n'était donc pas dans le périmètre
initial ; elle rendait pourtant sa valeur sur `stdout`, était appelée en
substitution nue, et son `return 0` final effaçait le code de la lecture qui
venait d'échouer. **Toute fonction qui rend sa valeur sur `stdout` en relève**,
qu'elle appelle `die` ou non.

**Un site n'est pas inatteignable, il est « pas encore atteint ».** C'est
l'enseignement le plus cher de ce chantier : cinq tours, quatre arbitrages de
non-traitement démentis, et chaque fois par la même mutation d'une ligne — un
binaire homonyme en tête de `PATH`. « `require_cmd` protège », « `[ -f ]`
protège », « `command -v` protège », « cette branche est du code mort » : aucun
des quatre ne protégeait. Le dernier tour a fermé les sept derniers sites, et les
sept rougissent sous mutation — il n'en restait donc aucun de réellement hors
d'atteinte.

Deux conséquences de méthode. La conclusion tenable n'est jamais « ce site est
inatteignable », c'est « je n'ai pas trouvé comment l'atteindre », et elle
s'écrit alors comme telle — dans le recensement, et en `NON EXÉCUTÉ` dans le
fichier de cas. Et un site laissé nu avec une raison écrite reste un site laissé
nu : la raison ne remplace pas la mutation qui l'aurait éprouvée.

### Le niveau `environment`

Un fichier par sujet, nommé `tests/environment/<sujet>.test.sh`.
`run-environment.sh` les découvre — **en `maxdepth 1`**, comme les trois autres
niveaux — et agrège leurs verdicts, à l'identique de `run-integration.sh`.

```text
tests/environment/
├── run-environment.sh     le dispatcher
└── systemd.test.sh        les scripts de Linux/System face à un init réel
```

C'est le domicile des preuves qui exigent un **init réel** — `systemctl`,
`timedatectl`, `hostnamectl`. Sa commande de référence est le profil `systemd`
du §4 :

```bash
tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment
```

**Ce niveau modifie le système sur lequel il tourne** : fuseau horaire, nom
d'hôte, `/etc/hosts`. Comme pour l'`integration`, les fichiers de cas se
protègent eux-mêmes — rien n'est écrit tant qu'un système jetable n'a pas été
reconnu — et chaque groupe modifiant restitue l'état de départ **et vérifie sa
restitution**.

Ce que `systemd.test.sh` prouve, et que rien ne prouvait avant lui :

| Cas | Où il était déclaré `NON EXÉCUTÉ` |
|---|---|
| `configure-timezone.sh` applique le fuseau **par `timedatectl`** — et n'emprunte alors pas son repli `/etc/localtime` | `tests/integration/linux-system.test.sh` §5 |
| `configure-hostname.sh` change **réellement** le nom de la machine, `/etc/hostname` et `/etc/hosts` suivant | le même §5 |
| systemd répond : PID 1, inventaire des unités, **activation de `systemd-timedated` par le bus** au premier appel de `timedatectl` | nulle part — le profil n'existait pas |

Les deux lignes correspondantes du §5 de `linux-system.test.sh` **ont disparu**,
remplacées par un commentaire qui nomme l'endroit où la preuve vit désormais.

#### Deux règles propres à ce niveau

**La garde éprouve systemd, jamais le nom du profil.** Aucun groupe n'est
conditionné à `--profil systemd` : la condition est mesurée — `/proc/1/comm`
vaut `systemd`, et `systemctl is-system-running` rend un état de marche. Un
profil futur portant un autre init verra ces cas s'exécuter sans qu'on retouche
le fichier. `running` et `degraded` valent tous deux ; `offline` et `unknown`
disent que rien ne répond.

**Le niveau garde des cas exécutables sans systemd, et il le doit.**
`tests/run.sh` sans argument passe par cet étage, **y compris sous le profil
`debian`**. Un fichier qui ne ferait qu'y sauter sortirait en 3 — *rien n'est
prouvé* — et la commande de référence du dépôt cesserait d'être verte (§2). Le
groupe 1 de `systemd.test.sh` ne dépend donc d'aucun init : aide, option
inconnue, `--list`. Il sert aussi de **garde de contraste** — si les scripts ne
démarraient plus du tout, les sauts des groupes suivants ne pourraient plus être
lus comme « seul systemd manque ».

Mesuré, les deux profils donnent :

| Profil | Réussites | `NON EXÉCUTÉ` | Fichier | Niveau | `tests/run.sh` |
|---|---|---|---|---|---|
| `systemd` | 48 | 2, tous par nature | 4 | 4 | **0** |
| `debian` | 13 | 13, tous par nature | 4 | 4 | **0** |

#### Ce qui reste hors de portée, et pourquoi

- **`hostnamectl set-hostname`** échoue dans ce profil sur `Failed to set static
  hostname: Device or resource busy`. La cause est **structurelle** et non une
  lacune de l'image : Docker monte `/etc/hostname` depuis l'hôte — le montage
  est relevé dans `/proc/mounts` par le fichier de cas lui-même — et
  `hostnamectl` procède par remplacement du fichier. Aucune option de lancement
  n'y change rien ; `--transient` est accepté sans effet, le nom statique
  primant. Le chemin `hostname(1)`, lui, fonctionne : c'est celui que
  `configure-hostname.sh` emprunte, et c'est lui qui est éprouvé ;
- **un démon `cron` en service** : `cron` n'est pas dans l'image, qui n'embarque
  aucun service applicatif. Le saut de `tests/integration/configure-cron.test.sh`
  §9 subsiste donc, avec une raison changée de nature — ce n'est plus « le profil
  n'existe pas », c'est « son image n'a pas cron » ;
- **un redémarrage** : `reboot` et `systemctl poweroff` arrêtent le PID 1, donc
  le conteneur, et décapitent la suite en cours.

#### Ne jamais lancer le niveau `integration` sous le profil `systemd`

Plusieurs assertions de `tests/integration/linux-system.test.sh` sont vraies
**parce que** systemd est absent : le repli `/etc/localtime` explicitement
attendu, un décompte exact de lignes sur `stderr`, un saut conditionné à
l'absence de `timedatectl`. Sous un init, elles rougiraient sans qu'aucun défaut
n'existe. Le niveau `integration` reste l'affaire du profil `debian` ; la preuve
qui exige systemd vit ici.

### Le niveau `acceptance`

Un fichier par tâche, nommé `tests/acceptance/TASK-0xx-<sujet>.sh`.
`run-acceptance.sh` les découvre et les exécute — **en `maxdepth 1`**, ce qui a
une conséquence :

```text
tests/acceptance/
├── run-acceptance.sh                    le dispatcher
├── TASK-002-environnement-conteneurise.sh   exécuté sur l'hôte
├── TASK-011-analyse-statique.sh             exécuté sur l'hôte
├── TASK-012-semantique-codes.sh             exécuté sur l'hôte
├── TASK-013-natures-de-saut.sh              exécuté sur l'hôte
└── interne/
    └── TASK-011-cas-conteneur.sh        exécuté DANS le conteneur, jamais sur l'hôte
```

Un fichier de cas destiné à tourner **dans** le conteneur se place dans
`interne/`. Le `maxdepth 1` du dispatcher l'ignore alors, et seul son pilote
— resté au premier niveau — décide quand et comment l'y lancer.

Sans cette séparation, un fichier écrit pour Debian serait exécuté sur l'hôte
Windows, où il échouerait pour de mauvaises raisons.

## 2. Codes de retour

Deux contrats, à ne pas confondre : celui des **niveaux et fichiers de cas**,
qui rendent compte du détail, et celui de **`tests/run.sh`**, qui prononce le
verdict global.

### Ce que rend un niveau ou un fichier de cas

| Code | Sens |
|---|---|
| 0 | tous les cas ont été exécutés et ont réussi |
| 1 | au moins un cas est en défaut |
| 2 | erreur d'usage |
| 3 | **rien n'est prouvé** : aucun cas n'a pu être exécuté, ou l'un d'eux n'a pas pu l'être faute d'environnement |
| 4 | les cas exécutés ont réussi, mais certains ne s'appliquaient pas **par nature** à cet environnement — la preuve est partielle, elle existe |

Le **3** et le **4** sont deux façons très différentes de ne pas tout vérifier,
longtemps confondues sous le même code :

```text
156 cas passés, 7 hors de portée du conteneur   →  4   l'essentiel est prouvé
aucun cas n'a tourné                            →  3   rien n'est prouvé
```

Le 4 n'ouvre pas la porte au faux vert que le 3 avait fermée : il exige **au
moins une réussite**. Une suite intégralement sautée retombe sur le 3, et un
fichier de cas teste donc « aucune réussite » *avant* « des cas sautés ».

#### Les deux natures de saut

« Au moins une réussite » ne suffisait pas. Mesuré, démon Docker rendu
injoignable (`DOCKER_HOST=tcp://127.0.0.1:1`, Docker Desktop jamais arrêté), le
fichier de cas de TASK-011 donnait :

```text
Bilan TASK-011 : 8 réussites, 0 échec, 21 NON EXÉCUTÉ(s)  → code 4
tests/run.sh acceptance                                    → code 0
```

72 % de la preuve avait disparu, le verdict global restait vert. Quelques cas de
préflight, qui n'ont besoin de rien pour tourner, suffisaient à franchir le
seuil.

Ces chiffres sont ceux du 2026-09-01, avant le retrait du §1 de ce fichier de
cas. Ils gardent leur valeur de démonstration : c'est le mécanisme qu'ils
mettent en évidence, pas leur total.

TASK-013 a donc scindé le décompte des sauts en deux natures, que le seul
compteur `non_executes` confondait :

| Nature | Exemple | Verdict |
|---|---|---|
| **non applicable par nature** | le profil `debian` n'a pas `systemd` et ne l'aura jamais ; `swapon` exige `CAP_SYS_ADMIN` ; un fichier de cas ne peut pas lancer le niveau dont il fait partie | **4** — la limite est assumée, ce qui a été prouvé le reste |
| **environnement indisponible** | le démon Docker ne répond pas, `git` est absent, le miroir `apt` est injoignable | **3** — la preuve existe, elle n'a pas pu être produite |

La première est une limite permanente de l'environnement de test ; la seconde un
accident, qui doit interrompre le verdict. **Une seule indisponibilité fait
sortir le fichier en 3**, quel que soit le nombre de cas réussis par ailleurs.

Un saut se déclare donc avec sa nature, et l'ordre des gardes du bilan devient :
échec, puis aucune réussite, puis indisponibilité, puis non applicable.

**Règle de prudence : dans le doute, indisponibilité.** Un rouge à tort se voit
et se corrige ; un vert à tort ne se voit pas. Deux qualifications méritent
d'être connues, parce qu'elles ne vont pas de soi :

- un outil **absent de l'image** — `setpriv`, `zoneinfo`, un paquet obsolète à
  mettre à jour — est *non applicable par nature* : l'image est minimale à
  dessein, elle fonctionne comme prévu, c'est une limite assumée. Un outil
  **installable mais non installé faute de réseau** est une *indisponibilité* :
  là, l'environnement a échoué ;
- les six contrôles de forme du diff de TASK-011 ont été **retirés** le
  2026-09-02 ([ADR-0003](../docs/agent/decisions/ADR-0003-cadrage-execution-autonome.md),
  décision 13). Ils avaient été comptés *non applicables par nature* dès lors que
  les corrections étaient commitées : sur un arbre propre, `git diff HEAD` ne
  produit rien, et l'objet de la comparaison avait disparu. Le saut était
  cependant permanent en pratique, et six `NON EXÉCUTÉ` affichés à chaque
  exécution finissent par être ignorés — c'est le bruit qui masque un vrai
  problème. Le niveau `integration` est le domicile durable de ces preuves.
  L'énoncé du cas et la réserve restent lisibles au §4 de
  [docs/points-en-suspens.md](../docs/points-en-suspens.md).

Un code 4 dit donc désormais **« rien d'atteignable n'a été manqué »** — mais
cette garantie ne vaut que ce que valent les qualifications : elle repose sur la
relecture, un saut à la fois, de celui qui les a écrites. Un saut ajouté sans
qualification réfléchie la ruine en silence. Le décompte des deux natures reste
affiché à chaque bilan — un saut invisible serait pire que le faux vert qu'on
cherche à empêcher.

### Ce que rend `tests/run.sh`

| Code | Sens |
|---|---|
| 0 | tous les niveaux exécutés ont réussi — les cas non applicables, s'il y en a, sont décomptés à l'écran |
| 1 | au moins un niveau a échoué |
| 2 | erreur d'usage — option ou niveau inconnu |
| 3 | rien n'est prouvé : un niveau demandé explicitement n'est pas implémenté, un niveau exécuté n'a rien pu vérifier, ou l'un de ses cas n'a pas pu être produit faute d'environnement |

`tests/run.sh` **ne rend jamais 4** : il lit ce code, l'affiche, et le traduit
en réussite. C'est le point d'entrée du dépôt, son contrat tient en une ligne —
*0, la validation est acquise ; autre chose, elle ne l'est pas*. Il ne réduit
plus pour autant le code d'un niveau à réussi/échoué : le 3 remonte en 3, et
n'est plus maquillé en échec.

Le code **3** reste délibérément distinct de 0 et de 1. Sans lui,
`tests/run.sh unit` sortirait en 0 aujourd'hui et un validator conclurait que
les tests unitaires passent, alors qu'aucun n'existe. « Rien à exécuter » n'est
pas « tout va bien ».

C'est la traduction en code de retour de la règle d'[AGENTS.md](../AGENTS.md)
§10 : une validation non exécutée vaut `NON EXÉCUTÉ`, jamais `PASS`.

Le 3 et le 4 de `tests/env/run-in-container.sh` (§4) relèvent d'un autre
contrat — environnement indisponible, échec de construction — et ne se croisent
pas avec ceux-ci : le lanceur ne juge aucun cas, un niveau ne construit aucune
image. Une seule précaution : dans le conteneur, lancer `tests/run.sh` plutôt
qu'un script de niveau, pour que le code transmis reste celui d'un verdict
global.

## 3. Analyse statique

```bash
tests/lint.sh                       # tout le dépôt
tests/lint.sh Linux/System/*.sh     # une sélection
tests/lint.sh --strict              # les scripts hérités deviennent bloquants
```

Deux contrôles de portées très inégales :

- **`bash -n`** ne vérifie que la syntaxe. Toujours disponible, il ne voit ni
  une variable non quotée, ni un `cd` sans garde, ni un `[ $a = $b ]` fragile.
  Le présenter comme une analyse complète serait trompeur ;
- **`shellcheck`** fait le vrai travail. Il est **absent de la machine de
  développement** : dans ce cas le résultat est annoncé `NON EXÉCUTÉ` et
  l'analyse ne prétend pas à l'exhaustivité.

Pour l'installer :

```bash
winget install koalaman.shellcheck     # Windows
sudo apt install shellcheck            # Debian, Ubuntu
```

Il est de toute façon installé dans l'image de test conteneurisée (§4), qui
reste la référence :

```bash
tests/env/run-in-container.sh -- tests/run.sh lint
```

### Exclusions

`SC1090` et `SC1091` sont désactivés : `shellcheck` ne peut pas suivre
`source "$_dir/lib/common.sh"`, dont le chemin n'est résolu qu'à l'exécution.
C'est le mécanisme de chargement du dépôt, décrit dans
[docs/architecture-technique.md](../docs/architecture-technique.md) — pas un
défaut à corriger.

### Scripts hérités

`Synology/Plex/organize-series.sh` et `Synology/Plex/update-plex.sh` ne chargent
pas `lib/common.sh` et ne respectent pas les conventions. Leur mise au standard
est une tâche identifiée, pas un effet de bord d'un contrôle de routine.

**La tolérance dont ils bénéficient porte sur le style, jamais sur la syntaxe :**

| Problème détecté | Script courant | Script hérité |
|---|---|---|
| erreur de syntaxe (`bash -n`) | `ERROR`, bloquant | **`ERROR`, bloquant** |
| avertissement `shellcheck` | `ERROR`, bloquant | `WARN`, non bloquant |

Un script qui ne s'analyse plus est cassé, hérité ou non. Sans cette
distinction, l'un de ces fichiers pourrait devenir syntaxiquement invalide sans
que « 0 erreur » cesse de s'afficher — le contrôle mentirait.

Tant qu'ils passent `bash -n` et que `shellcheck` est absent de la machine, ces
deux fichiers s'affichent donc en `[SUCCESS]` comme les autres. Le `WARN`
n'apparaît qu'en cas de problème de style réellement détecté.

`--strict` supprime la tolérance et les rend bloquants sur tout, ce qui
permettra de constater le jour où ils seront à niveau.

## 4. Environnement de test conteneurisé

La machine de développement est sous Windows : elle n'a ni `apt`, ni
`systemctl`, ni `/etc/os-release`, et le premier `detect_os` y échoue. **Aucun
script d'administration ne s'exécute sur l'hôte.** Tout ce qui dépasse
l'analyse statique passe par un conteneur jetable.

```bash
tests/env/run-in-container.sh -- bash -c 'cat /etc/os-release'
tests/env/run-in-container.sh -- Linux/System/system-info.sh
tests/env/run-in-container.sh --profil debian -- tests/run.sh unit
tests/env/run-in-container.sh -- Linux/System/configure-swap.sh 512M --dry-run
```

Tout ce qui suit `--` est exécuté **tel quel** dans le conteneur, depuis la
racine du dépôt montée sur `/depot`. Le code de retour de la commande est
transmis fidèlement à l'appelant : `tests/env/run-in-container.sh -- false`
sort en 1.

### Ce que fait le script

1. vérifie que `docker` existe **et que le démon répond**. Un démon qui ne
   répond pas ne fait plus mourir le lanceur d'emblée : `assurer-docker.sh` est
   appelé — il **attend** le moteur, il ne démarre rien —, puis **le même
   contrôle est refait** — s'il échoue encore, message
   explicite et code 3, jamais un faux succès ; en mode `systemd`, vérifie aussi
   `timeout`, qui borne les interrogations du préflight, le lancement du
   conteneur, l'attente du démarrage, le nettoyage et le diagnostic ;
2. construit l'image du profil si elle est absente ;
3. lance un conteneur neuf, dépôt monté en **lecture-écriture** sur `/depot`,
   répertoire de travail `/depot` ;
4. détruit le conteneur — `--rm` en mode direct, le `trap … EXIT` en mode
   systemd. **Aucun état ne survit :** deux exécutions consécutives partent d'un
   état identique, condition sans laquelle un test d'idempotence ne prouve rien.
   Si la destruction n'aboutit pas, elle le dit en `[WARN]` — le conteneur
   survivant est nommé, la commande qui le retire à la main est donnée — et
   **le code de retour n'en est pas changé** : un nettoyage manqué ne
   transforme pas un succès en échec.

### Options

| Option | Effet |
|---|---|
| `--profil <nom>` | profil de conteneur, défaut `debian` |
| `--reconstruire` | reconstruire l'image sans cache et retélécharger l'image de base |
| `--dry-run` | afficher les commandes `docker` sans les exécuter |
| `-h, --help` | aide |

### Codes de retour

| Code | Sens |
|---|---|
| 0 | la commande exécutée dans le conteneur a réussi |
| 2 | erreur d'usage — option inconnue, profil inexistant ou déclarant un mode d'init inconnu, commande absente |
| 3 | environnement indisponible — `docker` absent, démon **toujours arrêté après l'appel à `assurer-docker.sh`** ou **devenu muet au lancement du conteneur ou pendant l'attente**, `timeout` absent, ou **systemd qui ne démarre pas** dans le conteneur ; **rien n'a été exécuté** |
| 4 | échec de la construction de l'image, rien n'a été exécuté |
| autre | code de retour de la commande, transmis tel quel |

Les codes 2, 3 et 4 peuvent aussi venir de la commande elle-même : la
transmission fidèle du code de retour l'impose. Les messages `[ERROR]` lèvent
l'ambiguïté.

### Attendre le démon — `assurer-docker.sh`

Docker Desktop est une **application** Windows, pas un service. Elle est lancée
au démarrage du système depuis le 2026-09-04, mais **être lancée n'est pas être
prête** : l'application initialise WSL2, monte ses systèmes de fichiers, puis
lance son moteur. Une tâche démarrée peu après l'ouverture de session tombe
exactement sur cet intervalle, et tout ce qui passe par le lanceur s'arrêtait
alors sur « le démon Docker ne répond pas ».

```bash
tests/env/assurer-docker.sh             # constate, attend le moteur, diagnostique
tests/env/assurer-docker.sh --dry-run   # constate et annonce, sans attendre
```

Il est appelé **automatiquement** par `run-in-container.sh`, et seulement dans la
branche où le démon ne répond pas. Quand le démon répond dès le premier
`docker info`, rien de tout cela ne s'exécute.

**Il ne démarre pas Docker Desktop.** Le démarrage existe, derrière `--demarrer`,
mais il est hors du chemin par défaut — la section suivante dit pourquoi, avec
les mesures.

#### Ce qu'il traite, un traitement par état

| État constaté | Ce que l'outil fait |
|---|---|
| le démon répond | rien — code 0, en un seul sondage |
| lancé, moteur pas encore prêt | **attend** — c'est le cas courant |
| le processus n'est pas (encore) là | attend son apparition, au plus `DELAI_APPARITION` ; au-delà, code 3 |
| le processus disparaît pendant l'attente | plantage : code 3 tout de suite, avec la durée écoulée |
| plafond ou délai atteint | code 3, avec diagnostic — **jamais de boucle** |

La **présence du processus** est contrôlée à chaque sondage — `Get-Process
'Docker Desktop'` —, et pas seulement la réponse du démon : c'est elle qui
distingue « le moteur n'est pas encore prêt » de « l'application est morte en
route », deux situations que le seul `docker info` confond. Dans le doute —
contrôle de présence sans réponse — l'outil suppose l'application lancée et
attend : conclure dans le doute est le seul vrai risque.

Deux absences du processus, qu'il ne faut pas confondre. **Jamais vu** peut être
une session qui vient de s'ouvrir : Windows n'a pas encore lancé l'application,
elle apparaîtra — d'où l'attente bornée par `DELAI_APPARITION`. **Vu puis
disparu** est un plantage constaté : personne ne le relancera, et attendre cinq
minutes de plus ne ferait que retarder le message.

Le plantage se lit aussi **d'une exécution à l'autre**, par un témoin —
l'horodatage du dernier sondage réussi, écrit à côté du journal, dans
`$LOG_DIR/assurer-docker.temoin` (`logs/` sur la machine de développement,
répertoire ignoré par Git). Ce témoin **ne change aucune décision**, il n'éclaire
que la trace : le comportement de l'outil ne dépend que de ce qu'il constate
lui-même.

#### Pourquoi `--demarrer` n'est pas le chemin par défaut

Le démarrage automatique **ne fonctionne pas depuis la session de l'agent**, et
c'est mesuré. Premier usage réel, le 2026-09-04, Docker Desktop 4.51.0 :

```text
15:50:32  démarrage de Docker Desktop (tentative 1/2)
15:50:45  processus présent après 14 s
15:51:15  le processus a disparu après 46 s — arrêté en cours de démarrage
15:51:16  démarrage de Docker Desktop (tentative 2/2)
15:51:28  processus présent après 13 s
15:54:43  le processus a disparu après 253 s
          plafond atteint, code 3
```

Les journaux de Docker Desktop donnent la suite : `eventErrorDialog`, puis
`bind: {"action":"Quit"}`, puis `com.docker.backend.exe services: exit status
150`. Le service `com.docker.service` était `Stopped`, en démarrage `Manual`.

**Le fait décisif :** lancé **à la main**, Docker Desktop démarre sans afficher
la moindre erreur. Le défaut ne tient donc pas à Docker, ni à la machine, ni au
chemin de l'exécutable — il tient au **contexte de lancement** : `Start-Process`
depuis la session de l'agent ne fournit pas ce que Docker Desktop attend,
élévation ou session interactive. Laquelle des deux n'a pas été établie.

D'où la décision de Maxime, le 2026-09-04 : **Docker Desktop est lancé au
démarrage du système, l'agent n'a plus à le démarrer.** Le code de démarrage
reste dans le script, avec sa limite écrite sur place — si le contexte de
lancement change un jour, il est là plutôt qu'à réinventer.
`run-in-container.sh` **ne passe pas** cette option.

La limite qui subsiste, et qui n'est pas résolue : **si Docker Desktop tombe,
aucun chemin de ce dépôt ne peut le relever.** Le message d'échec le dit et
demande un lancement manuel.

#### Les deux gardes

- **jamais l'arrêt.** Aucun `Stop-Process`, aucun `docker … stop` : aucun chemin
  du code ne peut éteindre Docker Desktop, qui fait peut-être tourner un
  conteneur ne relevant pas de ce dépôt ;
- **un plafond de démarrages**, `PLAFOND_DEMARRAGES`, fixé à **2** par exécution,
  sur le chemin `--demarrer` uniquement. Un plantage au milieu d'une suite doit
  pouvoir être rattrapé — ce qu'une tentative unique interdirait —, mais deux
  morts de suite dans la même attente ne sont plus un accident. Au-delà : code 3.
  Le relevé ci-dessus a exercé ce plafond, et il a tenu.

#### Les délais

Trois valeurs sont adossées à une mesure du 2026-09-04 ; la principale ne l'est
pas, et le dit. Ce sont des **bornes**, pas des durées attendues.

| Constante | Valeur | Mesure | Ce qu'elle borne |
|---|---|---|---|
| `DELAI_SONDAGE` | 5 s | `docker info` sur démon absent : **< 1 s** | un `docker info`, un `Get-Process`, un `Test-Path` |
| `DELAI_ABATTAGE` | 5 s | posé | le sursis avant le SIGKILL de `timeout -k` |
| `DELAI_LANCEMENT` | 30 s | `Start-Process` lui-même : **1 à 2 s** | le lancement, sur `--demarrer` |
| `DELAI_APPARITION` | 60 s | apparition du processus : **13 à 14 s** | l'attente du processus, après un lancement ou au démarrage de session |
| `INTERVALLE_SONDAGE` | 5 s | posé | la pause entre deux sondages |
| `INTERVALLE_TRACE` | 30 s | posé | la périodicité des lignes d'attente |
| `DELAI_DISPONIBILITE` | 300 s | **jamais mesuré** | l'attente entière |

`DELAI_DISPONIBILITE` **reste posé** : il n'a pas pu être mesuré le 2026-09-04,
le moteur n'ayant jamais été prêt. Cette exécution a seulement établi que le
plafond est atteint et rend la main — pas qu'il soit à la bonne hauteur. À
confirmer le jour où un démarrage complet sera observé de bout en bout. Le
message d'échec le dit lui-même : si le moteur devient disponible peu après,
c'est la borne qui est en cause, pas Docker.

Aucune attente n'est laissée libre, et c'est l'enseignement de TASK-020 appliqué
ici : tout appel externe — `docker info`, `Get-Process`, `Test-Path`,
`Start-Process` — passe par `timeout`. L'absence de `timeout` fait sortir l'outil
en 3 : un outil d'attente qui ne peut pas borner ses attentes n'a aucune raison
d'être appelé.

#### La trace

Chaque attente, chaque disparition de processus et chaque échec est écrit **avec
sa durée réelle**, dans `$LOG_DIR/assurer-docker.log` comme à l'écran : durée du
constat initial, délai d'apparition du processus, lignes d'attente périodiques,
et un bilan final donnant la durée totale — plus, sur `--demarrer`, la durée du
`Start-Process` et le nombre de démarrages. Sans ces durées, un plantage
récurrent de Docker sur cette machine passerait pour une lenteur de l'agent.
C'est ce qui a permis d'écrire le relevé ci-dessus.

#### Options

| Option | Effet |
|---|---|
| `--demarrer` | autoriser le démarrage de Docker Desktop si son processus est absent — **hors du chemin par défaut**, voir plus haut |
| `--dry-run` | constater l'état et annoncer ce qui serait fait, sans attendre ni rien lancer |
| `-h, --help` | aide |

#### Codes de retour

| Code | Sens |
|---|---|
| 0 | le démon répond — d'emblée ou après attente ; ou, en `--dry-run`, l'annonce a été faite |
| 2 | erreur d'usage — option inconnue |
| 3 | démon indisponible — `docker`, `timeout` ou `powershell` absent, Docker Desktop non lancé ou arrêté en cours d'attente, plafond de démarrages atteint, ou moteur toujours muet au bout de `DELAI_DISPONIBILITE` |

En `--dry-run`, **le code 0 ne signifie pas que le démon est disponible** : il
signifie que l'état a été constaté et l'action annoncée. `run-in-container.sh`
ne s'y trompe pas — il transmet son propre `--dry-run` à l'outil, puis refait le
contrôle du démon, qui reste seul juge.

Le message d'échec donne le conseil qui fait gagner du temps : **lancer Docker
Desktop à la main**, attendre qu'il soit prêt, relancer — et non pas seulement
« ouvrir Docker Desktop et lire son état », qui laisserait croire qu'une option
du script aurait pu l'éviter.

L'installation de Docker, l'arrêt de Docker Desktop, le redémarrage de la
machine et tout démon distant sont **hors du périmètre** de cet outil.

### Profils

| Profil | Image | Couvre | État |
|---|---|---|---|
| `debian` | `debian:12` | `lint`, `unit`, `--dry-run`, idempotence, `apt` | **implémenté** — `tests/env/Dockerfile.debian` |
| `systemd` | `debian:12`, `/sbin/init`, `--privileged` | `systemctl`, `timedatectl`, `hostnamectl`, niveau `environment` | **implémenté** — `tests/env/Dockerfile.systemd` |

Un profil `<nom>` correspond au fichier `tests/env/Dockerfile.<nom>`. En déposer
un nouveau suffit à le rendre disponible — le script ne tient aucune liste en
dur.

#### Le profil `systemd`

Sa seule raison d'être : sans `systemctl`, `timedatectl` ni `hostnamectl` réels,
tout un pan du dépôt est écrit sans jamais être exécuté. C'est ce profil qui
porte le niveau `environment` (§1).

```bash
tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment
tests/env/run-in-container.sh --profil systemd -- systemctl list-units --type=service
```

**Le mode de lancement est déclaré par le Dockerfile lui-même**, par le label
`mgnet.test.init="systemd"` — le lanceur ne tient aucune liste de profils en
dur, et un `Dockerfile.<nom>` futur portant ce label suivra le même chemin. Ce
chemin diffère de celui du profil `debian` :

| | `debian` | `systemd` |
|---|---|---|
| PID 1 | la commande demandée | `/sbin/init` |
| lancement | `docker run --rm <image> <commande>`, non borné | `docker run -d` **borné à 30 s**, **sans `--rm`**, puis `docker exec -w /depot` |
| options `docker` en plus | — | `--privileged`, `--tmpfs /run` |
| avant la commande | rien | attente de la fin du démarrage |
| destruction | `--rm`, le `trap … EXIT` en filet | le `trap … EXIT`, seul |

Pourquoi ces options : `--privileged` parce que systemd crée un cgroup par unité
et écrit donc dans `/sys/fs/cgroup`, que Docker monte en lecture seule pour un
conteneur ordinaire ; `--tmpfs /run` parce que `/run` porte l'état volatile du
système, que systemd s'attend à trouver vide au démarrage. Deux recettes
courantes sont volontairement **absentes**, et le `Dockerfile` dit pourquoi :
`-v /sys/fs/cgroup:/sys/fs/cgroup:ro` relève de cgroup v1, et `--cgroupns=host`
exposerait à ce conteneur privilégié l'arborescence de l'hôte entier.

**Le conteneur systemd est lancé sans `--rm`, et c'est délibéré.** Sur un
conteneur détaché, Docker efface le conteneur dès l'arrêt de son PID 1 —
c'est-à-dire dans le cas exact où l'on veut savoir *pourquoi* il s'est arrêté.
`docker logs` ne trouvait alors plus rien et ne rendait qu'un
`No such container` : le seul élément de diagnostic prévu pour cette panne était
**systématiquement vide**. Le conteneur est donc conservé le temps que le
lanceur en lise le journal, puis détruit par le `trap … EXIT`, qui efface un
conteneur quel que soit son état.

Rien ne survit davantage qu'avant : en mode détaché, `--rm` ne couvrait que ce
cas-là. Reste la mort brutale du lanceur, où le `trap` ne passe pas — mais
`--rm` n'y aurait rien effacé non plus, le conteneur tournant toujours. C'est le
cas que `docker ps -a --filter 'name=mgnet-test-'` sert à constater.

**L'attente du démarrage est active.** Un `docker exec` lancé aussitôt après le
`run` tombe sur un systemd encore en `initializing` : `systemctl` répond mal, ou
pas du tout. Le lanceur interroge donc `systemctl is-system-running` en boucle.
Si le conteneur s'arrête entre-temps, ou si le démarrage n'aboutit pas, il rend
**3**, affiche le dernier état obtenu puis les vingt dernières lignes du journal
du conteneur, et **détruit le conteneur** : rien n'est exécuté, rien ne survit.
Le journal a quatre issues, toutes annoncées — des lignes, un conteneur qui
n'existe plus, un PID 1 qui n'a rien écrit, un démon qui ne répond plus. Aucune
ne laisse un silence, et aucune ne présente l'erreur de `docker logs` comme s'il
s'agissait d'un journal.

**L'attente est bornée en temps mural, pas seulement en réessais** — et ce qui
l'entoure l'est aussi, en amont comme en aval. Quatre bornes, et il en faut
quatre :

| Borne | Valeur | Ce qu'elle empêche |
|---|---|---|
| plafond de l'attente | 60 s | un systemd qui ne finit jamais de démarrer |
| borne d'un sondage, et des deux interrogations du préflight | 10 s, puis `SIGKILL` 5 s plus tard | un démon Docker figé, qui retiendrait `docker info` ou `docker image inspect` **avant** tout, puis `docker exec` ou `docker ps` **avant** que la boucle n'atteigne le contrôle de son plafond |
| borne du lancement | 30 s, puis `SIGKILL` 5 s plus tard | ce même démon figé retenant le `docker run -d`, **entre** le préflight et la boucle |
| borne du nettoyage et du diagnostic | 5 s, puis `SIGKILL` 5 s plus tard | ce même démon figé retenant `docker ps -a`, `docker logs` ou `docker rm -f`, **après** le diagnostic — dans le `trap … EXIT`, où l'appelant croit le script terminé |

Le plafond seul ne suffisait pas : il compte les réessais, et une boucle dont
chaque tour ne rend pas la main ne réessaie jamais. Les deux appels Docker du
sondage passent donc par `timeout -k 5 10`. Sa présence est vérifiée au
préflight, en mode `systemd` uniquement ; absent, le lanceur rend **3** plutôt
que de promettre une borne qu'il ne tiendrait pas.

Borner la boucle ne suffisait pas davantage : **le blocage s'était déplacé de la
boucle vers le `trap`**. Mesuré, avec un `docker` qui répond au `build` et au
`run` puis ne répond plus : le diagnostic s'affichait bien au bout de 10 s, puis
le script mettait **305 s de plus** à rendre la main, suspendu sur le
`docker ps -a` puis le `docker rm -f` du nettoyage. Les appels du nettoyage et du
diagnostic passent donc par `timeout -k 5 5`. La borne y est **plus courte que
celle des sondages** : aucune de ces commandes n'attend un démarrage, toutes
rendent la main en une fraction de seconde sur un démon sain.

Borner la boucle et le `trap` ne suffisait pas encore : **le blocage s'était
déplacé une troisième fois, en amont cette fois**. Mesuré, avec un `docker` qui
répond à `info` et à `build` puis dort 300 s sur `run` : le lanceur restait
suspendu sur son `docker run -d` — 200 s constatées, et seulement parce qu'un
`timeout` externe coupait la mesure — sans jamais entrer dans la boucle que les
bornes précédentes protégeaient. Ce lancement-là est **détaché** : il n'exécute
aucune commande, il crée le conteneur, démarre son PID 1 et rend la main —
mesuré en moins d'une seconde. Il passe donc par `timeout -k 5 30`. La borne y est **plus
longue que celle des sondages** parce que le démon y fait un vrai travail —
espaces de noms, `tmpfs` sur `/run`, montage du dépôt à travers la frontière
Windows/WSL2 — mais il ne télécharge rien : l'image est présente, construite ou
vérifiée juste avant. Les deux interrogations du préflight, `docker info` et
`docker image inspect`, sont bornées par la même occasion : mêmes questions
instantanées, même trou. Pour `docker image inspect`, une borne expirée **ne
vaut pas « image absente »** — on partirait construire, et `docker build` n'est
pas borné.

**Si le lancement expire, le lanceur nomme le conteneur.** Son nom est choisi
*avant* le lancement, et le démon a pu le créer pendant que le client renonçait.
Le message dit donc quoi vérifier une fois le démon revenu —
`docker ps -a --filter name=<conteneur>` — et laisse le `trap … EXIT` tenter la
destruction ; si elle n'aboutit pas, c'est lui qui donne la commande de retrait à
la main, en `[WARN]`, sans changer le code de retour.

**Ce qui n'est pas borné l'est délibérément** : `docker build`, dont la durée
légitime se compte en minutes, et la commande demandée elle-même — le
`docker run <image> <commande>` du mode direct et le `docker exec` du mode
`systemd`. Le mode direct n'est donc borné nulle part : c'est lui qui exécute
`tests/run.sh` entier, et le borner serait un contresens.

Ce que l'appelant attend au pire : **165 s** avant que la main lui soit rendue —
hors durée de la commande demandée, qui n'est pas bornée et n'a pas à l'être.
Quatre termes, chaque appel se comptant pour sa borne plus le sursis avant
`SIGKILL` :

| Terme | Détail | Durée |
|---|---|---|
| lancement du conteneur | détaché : il crée le conteneur, il n'exécute rien | 30 + 5 s |
| plafond de l'attente | il compte les réessais | 60 s |
| dernier tour de boucle | le sondage a lieu d'abord, le plafond est vérifié ensuite : un tour peut commencer juste avant l'échéance et ajouter ses deux appels bornés | 2 × 15 s |
| chemin de sortie | lecture du journal — existence puis `docker logs` — puis `trap` — existence puis `docker rm -f` | 4 × 10 s |

La somme **majore**, et c'est ce qu'on attend d'un pire cas : les chemins ne
s'additionnent pas tous, un lancement qui expire s'arrête là et n'atteint jamais
la boucle. Le préflight n'y figure pas — ses bornes sont déjà consommées quand la
durée est annoncée, juste avant le `docker run -d`, dernier moment où elle est
encore entièrement devant l'appelant.

Il y a donc toujours au moins un sondage : un plafond de 0 n'interdit pas
d'essayer mais de recommencer. C'est cette durée maximale que le message de
lancement annonce, plutôt qu'un plafond que le lanceur ne tient pas — et elle
mesure le moment où l'appelant **reprend la main**, non celui où le diagnostic
s'affiche.

**L'expiration de la borne a son propre diagnostic**, et c'est tout l'intérêt de
la distinguer. `timeout` rend 124 — ou 137 si la commande n'a cédé qu'au
`SIGKILL`. Le lanceur ne dit alors pas « systemd n'a pas fini de démarrer », qui
enverrait chercher la panne dans le conteneur, mais que le démon Docker n'a pas
répondu, qui la situe sur l'hôte. Il **ne lit pas** le journal du conteneur dans
ce cas : `docker logs` passerait par ce même démon, qui vient de prouver qu'il ne
répond plus. Cette lecture est désormais bornée elle aussi et ne suspendrait donc
plus rien, mais elle coûterait deux attentes de plus pour un échec certain — et
le `trap`, juste après, en paie déjà une pour tenter la destruction.

**Les bornes du nettoyage valent aussi pour le profil `debian`**, dont le `trap`
emprunte le même code. Elles ne le pénalisent pas : en sortie normale, `--rm` a
déjà effacé le conteneur et le `trap` n'a rien à détruire. Les autres — préflight
et lancement — ne s'appliquent qu'au mode `systemd` : le profil `debian`
interroge le démon et lance son conteneur exactement comme avant, appels non
bornés compris. C'est voulu, et c'est la contrepartie de ne rien lui promettre :
il n'annonce aucune durée maximale, et c'est lui qui exécute les suites longues.
`timeout` reste exigé au préflight du seul mode `systemd` — là où une durée
maximale est annoncée. S'il manque sur une machine où le profil `debian` tourne
aujourd'hui, ce profil continue de tourner exactement comme avant.

**Le « dernier état » est trié, jamais recopié.** `docker exec` écrit ses
propres erreurs — un `OCI runtime exec failed: … executable file not found` de
plusieurs lignes — sur `stdout`, à l'endroit même où `systemctl` écrit son état.
N'est donc retenu comme état qu'un mot de la liste que systemd documente
(`initializing`, `starting`, `running`, `degraded`, `maintenance`, `stopping`,
`offline`, `unknown`). Toute autre réponse est affichée sur sa propre ligne,
sous son vrai nom et tronquée à une ligne : elle vaut diagnostic — c'est souvent
elle qui nomme la panne — mais pas sous une étiquette systemd.

Mesuré sur cet hôte, le démarrage prend **1 à 2 secondes** et l'état obtenu est
`running` ou `degraded` selon le moment ; les deux sont acceptés, `degraded`
signifiant seulement qu'une unité a échoué, ce qui est banal en conteneur.

L'image déclare quatre paquets par-dessus `debian:12`, chacun avec sa raison
écrite dans le `Dockerfile` :

| Paquet | Pourquoi |
|---|---|
| `systemd` | `systemctl`, `journald`, `systemd-timedated`, `systemd-hostnamed` — l'objet du profil |
| `systemd-sysv` | fournit `/sbin/init` ; le paquet `systemd` seul ne le pose pas |
| `dbus` | bus par lequel `timedatectl` et `hostnamectl` atteignent leurs services. Simple *Recommends* de `systemd`, donc absent sous `--no-install-recommends` |
| `tzdata` | `/usr/share/zoneinfo`, sans quoi `timedatectl set-timezone` n'aurait aucun fuseau à poser. **Déjà présent** dans l'image de base — mesuré : `Europe/Paris` existe dans le profil `debian`, qui n'installe pas ce paquet. La ligne est gardée pour que la dépendance soit déclarée : sur une base allégée, l'absence se verrait à la construction plutôt qu'à l'exécution. Ce qui manque au profil `debian`, ce ne sont pas les données de fuseau, c'est `timedatectl` |

Les unités qui n'ont aucun sens en conteneur — `systemd-udevd`, les montages de
`/sys/kernel`, `console-getty` — sont **masquées à la construction**, et la
cible par défaut est `multi-user.target`. Chacune rapprocherait sinon le
démarrage de `degraded`, un état accepté mais qui masquerait alors les vraies
défaillances.

**Ne jamais y lancer `reboot` ni `systemctl poweroff`** : le PID 1 s'arrête, le
conteneur meurt, et la suite en cours est décapitée.

Deux limites connues, mesurées, et déclarées `NON EXÉCUTÉ` par le fichier de cas
plutôt que contournées : `hostnamectl set-hostname` échoue — `/etc/hostname` est
un bind-mount Docker — et `cron` n'est pas dans l'image. Voir le niveau
`environment` au §1.

### L'image du profil `debian`

`debian:12` officielle, volontairement minimale. Quatre paquets seulement, et
chacun a sa raison écrite dans le `Dockerfile` :

| Paquet | Pourquoi |
|---|---|
| `ca-certificates` | téléchargements HTTPS |
| `iproute2` | `ip`, lu par `system-info.sh` |
| `procps` | `free` et `uptime`, lus par `system-info.sh` |
| `shellcheck` | niveau `lint` à l'intérieur du conteneur |

La locale est `C.UTF-8`, fournie nativement par la glibc de Debian 12 : sans
elle, les libellés accentués seraient comptés en octets et l'alignement des
colonnes serait décalé.

Les listes `apt` sont supprimées de l'image : un script qui installe un paquet
doit faire son propre `apt-get update`, comme sur un serveur neuf.

Le dépôt **n'est pas copié** dans l'image, il est monté à l'exécution. L'image
ne contient donc jamais le code à tester, et une modification de script est
prise en compte sans reconstruction.

L'image se complète au fil des besoins. Tout paquet ajouté doit avoir sa
justification dans le `Dockerfile`.

### Nommage et nettoyage

Images et conteneurs sont préfixés `mgnet-test-`, sans exception :
[AGENTS.md](../AGENTS.md) §8 n'autorise les commandes Docker de l'agent que sur
ce préfixe. L'image est `mgnet-test-<profil>:latest`, le conteneur
`mgnet-test-<profil>-<pid>-<horodatage>`.

Le profil `systemd` rend cette vérification **moins décorative** : son conteneur
est détaché, et lancé sans `--rm` pour que son journal survive à la mort de son
PID 1. C'est donc le `trap … EXIT` du lanceur, et lui seul, qui le détruit — en
sortie normale comme après interruption ou échec du démarrage.

Pour vérifier qu'il ne reste rien après une exécution :

```bash
docker ps -a --filter 'name=mgnet-test-'
```

### Windows et Git Bash

Deux pièges propres à l'hôte, traités par le script :

- **réécriture des chemins par MSYS.** `-w /depot` deviendrait
  `-w C:/Program Files/Git/depot`. `MSYS_NO_PATHCONV=1` et
  `MSYS2_ARG_CONV_EXCL='*'` désactivent cette conversion ; les chemins de
  l'hôte sont alors passés à Docker sous leur forme Windows via `cygpath -w` ;
- **fins de ligne.** `.gitattributes` impose `eol=lf` : la copie de travail est
  déjà en LF et le montage transmet les octets tels quels. Le script contrôle
  `lib/common.sh` et avertit si des CRLF s'y sont glissés — dans ce cas les
  scripts échoueraient dans le conteneur avec un `bad interpreter` peu parlant.
  Correctif : `git add --renormalize .`.

Le bit exécutable dépend de la façon dont Docker Desktop expose le montage. Si
un `Permission denied` apparaît, lancer la commande via `bash` :

```bash
tests/env/run-in-container.sh -- bash Linux/System/system-info.sh
```

## 5. Écrire un test

Les tests suivent les mêmes conventions que le reste du dépôt : en-tête en trois
lignes, chargement de `lib/common.sh`, messages préfixés, français.

Trois règles propres aux tests :

1. **un test qui ne peut pas s'exécuter le dit.** Il ne se contente jamais de
   passer silencieusement ;
2. **un test d'idempotence part d'un environnement neuf.** Un conteneur
   réutilisé entre deux exécutions invalide le résultat ;
3. **on ne corrige jamais un test pour le faire passer.** Neutraliser une
   assertion, ajouter `|| true` ou retirer `set -e` vaut échec de la tâche —
   voir [AGENTS.md](../AGENTS.md) §12.

### `tests/lib/assert.sh`

Les assertions communes vivent là : `titre`, `ok`, `ko`, `saute`,
`saute_par_nature`, `saute_indisponible`, `assert_code`, `assert_code_non_nul`,
`assert_egal`, `assert_non_vide`, `assert_contient`, `assert_absent`, et `bilan`
— qui applique le modèle ci-dessous et sort avec le code qui convient.

```bash
source "$SCRIPTS_ROOT/tests/lib/assert.sh"

titre "1. Journalisation"
assert_code 1 "$CODE" "die sort en 1 par défaut"
saute "cas non exécuté" "la raison, sans qualification"
saute_par_nature "cas systemd" "le conteneur n'a pas systemd"
saute_indisponible "lint conteneurisé" "le démon Docker ne répond pas"
bilan "lib/common.sh"
```

Trois fonctions de saut, qui ne se remplacent pas l'une l'autre :

| Fonction | Ce qu'elle affiche | Compteur | Verdict |
|---|---|---|---|
| `saute` | `NON EXÉCUTÉ : …` | `non_applicables` | 4 |
| `saute_par_nature` | `NON EXÉCUTÉ (non applicable par nature) : …` | `non_applicables` | 4 |
| `saute_indisponible` | `NON EXÉCUTÉ (environnement indisponible) : …` | `indisponibilites` | 3 |

`saute` et `saute_par_nature` rendent le **même verdict** : seul le message
diffère, et avec lui ce que le harnais affirme. La distinction est là parce que
**la qualification d'un saut se relit, elle ne s'obtient pas par défaut**.

- `saute` est le libellé **neutre** : le cas n'a pas tourné, le harnais n'en dit
  pas plus. C'est ce que servent les quelque soixante-dix sauts de `tests/unit/`
  et `tests/integration/`, qui n'ont pas été examinés un par un — et dont
  plusieurs tiennent à une propriété de la **machine** (`/etc/os-release`
  illisible sur cet hôte, harnais lancé sous `root`) et non à une limite de
  nature ;
- `saute_par_nature` est une **signature** : l'employer, c'est déclarer qu'on a
  examiné ce cas précis et conclu qu'aucune exécution ne le rendra jamais
  atteignable ici.

Le compteur, lui, reste **commun aux deux** : `non_applicables` agrège les sauts
relus et ceux qui ne le sont pas. Il est conservé tel quel pour qu'**aucun
verdict existant ne change** tant que la relecture n'a pas eu lieu — le partage
du compteur est un écart assumé, qui se referme saut par saut, en remplaçant
`saute` par la fonction qui convient.

Ce partage a une conséquence sur l'affichage : la ligne de bilan de
`tests/lib/assert.sh` ne peut pas nommer la nature de ce qu'elle décompte, et ne
la nomme donc pas — elle annonce `N sans indisponibilité déclarée`, ce que le
compteur sait, et rien de plus. Même règle pour les dispatchers de niveau et
pour `tests/run.sh`, qui ne comptent que des fichiers ou des niveaux : ils
parlent de « cas non applicables à cet environnement », sans qualifier une
nature que personne ne leur a transmise. Sous-affirmer ne produit jamais de faux
vert ; sur-affirmer, si. Voir §2 — et la règle de prudence qui l'accompagne.

Bash pur, aucun framework : `bats` est absent de la machine de développement et
ne se justifie pas pour ce volume. La bibliothèque ne pose ni
`set -Eeuo pipefail` ni `trap` — les deux s'appliqueraient au shell appelant —
et ne redéfinit rien de ce que `lib/common.sh` fournit déjà.

> **Ne jamais créer `tests/lib/common.sh`.** La résolution en trois lignes des
> scripts du dépôt cherche `<candidat>/lib/common.sh` en remontant
> l'arborescence : depuis `tests/`, le premier candidat testé est justement
> `tests/lib/common.sh`. Tant qu'il n'existe pas, la remontée se poursuit
> jusqu'à la racine. Le jour où il existerait, tous les scripts de `tests/`
> chargeraient ce fichier-là au lieu du socle du dépôt.

Les trois premiers fichiers de `tests/acceptance/` définissent encore leurs
assertions localement — TASK-013 y a ajouté `saute_indisponible` à l'identique
plutôt que de les réécrire. Leur saut qualifié s'y nomme `saute_par_nature`,
comme ici, et non `saute` : leurs quelques appels ont été relus un par un, et le
nom le dit. Aucun `saute` neutre n'y est défini — un saut ajouté sans
qualification échouera bruyamment au lieu d'hériter d'une nature que personne ne
lui a donnée.
`TASK-002-environnement-conteneurise.sh` n'en déclare aucun, ses onze sauts
étant tous des indisponibilités. `TASK-013-natures-de-saut.sh`, lui, s'appuie
sur cette bibliothèque. Uniformiser les autres est une tâche en soi, pas un
effet de bord.

### Le bilan d'un fichier de cas

Trois compteurs de verdict — réussites, échecs, non exécutés — dont le dernier
se scinde en deux natures — `non_applicables` et `indisponibilites`, dont il
reste le total. Et un bilan qui les traduit en code de retour, **dans cet
ordre** :

```bash
info "Bilan TASK-0xx : $reussites vérification(s) réussie(s), $echecs échec(s), $non_executes NON EXÉCUTÉ(s) — dont $non_applicables non applicable(s) par nature et $indisponibilites indisponibilité(s) d'environnement"

if [ "$echecs" -gt 0 ]; then
    die "TASK-0xx : $echecs critère(s) en défaut." 1
fi

if [ "$reussites" -eq 0 ]; then
    warn "TASK-0xx : aucune vérification n'a pu être exécutée — rien n'est prouvé."
    exit 3
fi

if [ "$indisponibilites" -gt 0 ]; then
    warn "TASK-0xx : $indisponibilites cas n'ont pas pu être produits faute d'environnement — rien n'est prouvé de fiable."
    exit 3
fi

if [ "$non_executes" -gt 0 ]; then
    warn "TASK-0xx : $non_executes vérification(s) NON EXÉCUTÉE(s) — les critères correspondants ne sont pas prouvés."
    exit 4
fi

success "TASK-0xx : tous les critères vérifiés ($reussites vérifications)."
```

L'ordre n'est pas décoratif : un échec prime sur tout, « aucune réussite » se
teste **avant** « des cas non applicables », et une indisponibilité
d'environnement **avant** eux aussi. Sans le premier de ces ordres, une suite
intégralement sautée — démon Docker arrêté, par exemple — sortirait en 4,
c'est-à-dire en réussite partielle, sans avoir rien prouvé. Sans le second, une
suite dont il ne reste que le préflight en sortirait de même : c'est le faux
vert mesuré au §2, fermé par TASK-013.

La ligne `info` du bilan n'est pas facultative : c'est elle qui rend visible le
nombre de cas sautés, et la nature de chacun. Le dispatcher, lui, ne compte que
des fichiers ; le détail vient d'ici.

**Règle de qualification du bilan.** Un fichier de cas dont tous les sauts sont
qualifiés — chaque appel étant `saute_par_nature` ou `saute_indisponible`, aucun
`saute` neutre — peut nommer la nature des sauts dans son propre bilan, et
employer le libellé « non applicable(s) par nature » du modèle ci-dessus. C'est
le cas des trois fichiers de `tests/acceptance/` qui déclarent leurs assertions
localement : leurs appels ont été relus un par un, le fichier sait donc ce qu'il
décompte. Il suffit qu'un seul `saute` neutre y apparaisse pour que ce libellé
redevienne illégitime.

Un fichier qui s'appuie sur `tests/lib/assert.sh` n'a pas ce choix : il hérite
du libellé neutre de sa bibliothèque, `N sans indisponibilité déclarée`. La
bibliothèque ignore, de ses appelants, lesquels ont été relus — elle ne peut
donc pas qualifier ce qu'elle décompte, et ne le fait pas.
