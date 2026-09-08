# TASK-022 — Rapport d'exécution

## Statut

COMPLETED — **cycle léger** (ADR-0003, décision 5) : `check-memory.sh` est en
lecture seule, il n'écrit rien sur le système. Rédacteur, testeur, validations,
sans relecteur.

## Objectif

Écrire `Linux/System/check-memory.sh` — plan §1 : « diagnostic RAM, swap et
processus consommateurs ».

Même contrat que `check-disk.sh` : **lecture seule stricte**, aucun privilège, et
**code 0 même quand une information manque**. Un script de diagnostic qui meurt
parce que `free` a échoué ne rend aucun service.

## Ce que le script produit

Quatre blocs, à la mise en page de `system-info.sh` et de `check-disk.sh` :

| Bloc | Source | Repli |
|---|---|---|
| paramètres et **leur origine** | — | — |
| mémoire vive | `free -k` | `/proc/meminfo`, puis « non disponible » |
| fichier d'échange | `free -k`, `/proc/swaps` | « non disponible » |
| processus consommateurs | `ps -eo … --sort=-rss` | « non disponible » |

Aucune des deux commandes externes n'est une dépendance exigée : sans `free`, le
script lit `/proc/meminfo` **et le dit** ; sans `ps`, il abandonne le seul
classement des processus. La lecture de `/proc/meminfo` n'appelle d'ailleurs
aucune commande — la lecture est une redirection Bash, l'analyse un `case` —
contrairement à celle de `system-info.sh`, que deux `awk` exposaient à un
homonyme placé en tête de `PATH`.

## Le seuil, et pourquoi 90 % là où le disque est à 85 %

Le seuil porte sur la part de mémoire **non disponible** — `(totale -
disponible) / totale` —, jamais sur l'occupation apparente, et la comparaison est
« atteint » (`-ge`) comme dans `check-disk.sh` : deux scripts jumeaux ne peuvent
pas comparer différemment.

**« Libre » n'est pas « disponible », et c'est tout l'enjeu du script.** Linux
emploie toute mémoire inemployée en cache et en tampons, qu'il rend dès qu'un
programme en réclame : une machine parfaitement saine affiche couramment 95 %
d'occupation apparente et une mémoire libre proche de zéro. Un seuil posé sur
`MemFree` crierait au loup à chaque exécution. La sortie affiche les deux valeurs
et explique la différence à chaque passage.

Deux raisons à l'écart avec les 85 % du disque :

- **la mémoire ne prévient pas.** Un disque qui se remplit ralentit et laisse le
  temps de voir venir ; une mémoire qui manque déclenche le tueur de mémoire du
  noyau, qui abat un processus sans préavis. Ce qui est mesuré est une **marge**,
  pas une tendance ;
- **10 % de marge reste une marge utile** : 6,4 Go sur un hôte de 64 Go, 200 Mo
  sur une machine de 2 Go. Sur les petites machines elle devient mince, et c'est
  pour cela que le seuil est réglable.

**Le fichier d'échange n'a pas de seuil propre.** Le même seuil s'applique aux
deux grandeurs, mais l'avertissement n'est émis qu'à leur **conjonction** : un
échange occupé au-delà du seuil *alors que* la mémoire l'est aussi. Un échange
occupé seul est le fonctionnement normal du noyau, et un échange absent n'est pas
davantage une anomalie — beaucoup de VPS et tous les conteneurs tournent sans. Un
second seuil configurable aurait donné un réglage de plus pour une décision qui
n'existe pas séparément.

## Choix réversibles, consignés comme la tâche le demande

| Choix | Valeur | Surcharge |
|---|---|---|
| seuil d'alerte | 90 % de mémoire non disponible | `SRV_MEM_SEUIL`, puis `--seuil` |
| processus affichés | 10 | `SRV_MEM_TOP`, puis `--top` |

Contrairement au `--top` de `check-disk.sh`, qui n'est qu'un confort d'affichage,
celui-ci se surcharge **aussi** par `config/server.env` : le classement des
processus est la section qu'on relit le plus souvent, et le nombre d'entrées
utile dépend de la machine.

## La règle d'origine des valeurs fautives

Reprise telle quelle de `check-disk.sh` : le traitement d'une valeur fautive
dépend de son **origine**, jamais de la valeur elle-même.

| Origine | Verdict |
|---|---|
| ligne de commande | refus en **2**, rien n'a été lu |
| `config/server.env` | `[WARN]` nommant la variable, repli, **code 0**, diagnostic produit |

Les deux valeurs de ce script ayant une valeur par défaut utilisable, le repli
est le même pour les deux — contrairement à `check-disk.sh`, dont le répertoire
analysé n'en avait pas.

## Les tests

`tests/integration/check-memory.test.sh`, **fichier de cas séparé** et non un
groupe de `linux-system.test.sh` : ce dernier passe les 4 900 lignes et l'ordre
de ses groupes est contraint par une garde d'état — l'empreinte relevée au
groupe 2 est comparée à celle du groupe 4. Un script qui n'écrit rien n'a aucune
raison d'entrer dans cette contrainte, et `run-integration.sh` découvre
`tests/integration/*.test.sh` : déposer le fichier a suffi.

**265 vérifications, 0 échec, 3 non exécutées et déclarées.**

Onze groupes, du plus décisif au plus accessoire :

| Groupe | Ce qu'il éprouve |
|---|---|
| a | les neuf refus en 2, et **l'absence de toute sortie avant le refus** |
| b | le chemin nominal sur les mesures réelles — décompte des lignes, jamais contenu seul |
| c | la lecture seule : empreinte de tout `/etc` et `find -newer` |
| d | deux exécutions consécutives, système inchangé |
| e | la dégradation : `free` en échec, muet, **absent** ; `ps` en échec, muet, absent |
| f | le seuil **atteint** et non dépassé, encadré à un point près |
| g | l'absence de swap, la conjonction, et **son cas négatif** |
| h | la borne de `--top`, mesurée sur un faux `ps` de cinq lignes |
| i | l'origine des valeurs : configuration contre ligne de commande |
| j | deux sorties identiques à l'octet près, sous sources fixées |
| k | ce qui n'a pas pu être prouvé, et pourquoi |

Trois montages portent l'essentiel de la preuve :

- **le faux `free`**, six variantes. C'est la seule façon de fixer l'occupation à
  une valeur connue : dans un conteneur sans `lxcfs`, `free` décrit l'hôte. La
  variante « nominale » donne exactement 30 % de mémoire non disponible, et les
  cas `--seuil 30` / `--seuil 31` encadrent le `-ge` à un point près. Sans le cas
  d'égalité, un `-gt` écrit à la place passerait inaperçu ;
- **le bac à sable de liens symboliques**, qui reproduit le `PATH` sans `free`
  puis sans `ps`. Le montage de TASK-018 : mettre la commande en échec ne suffit
  pas, `command -v` réussirait encore et la branche « absent » resterait fermée.
  Ce sont deux chemins et deux messages distincts, et les deux sont éprouvés ;
- **le faux `ps` de cinq lignes exactement**, seul montage où « trois lignes
  affichées » se distingue de « la machine n'en avait que trois ».

Le cas le plus important du lot est **négatif** : un échange occupé à 95 % pendant
que la mémoire va bien ne vaut **aucun** avertissement — décompte des `[WARN]` à
zéro, et non simple absence du motif. C'est lui qui prouve que la règle de
conjonction est bien une conjonction.

**Une découverte d'environnement** : `/proc/swaps` n'est **pas** vide dans le
conteneur sur cette machine — l'hôte WSL2 y expose une partition d'échange
`/dev/sdc`. La note d'implémentation de la tâche affirmait le contraire. Le
fichier de cas traite les deux branches, et le tableau des zones actives est donc
réellement éprouvé ici.

## Validations

| Commande | Attendu | Obtenu |
|---|---|---|
| `tests/run.sh lint` | 0 | **0** |
| `run-in-container.sh -- tests/run.sh lint` | 0 | **0** |
| `run-in-container.sh -- tests/run.sh integration` | 0 | **0** |
| `run-in-container.sh -- bash Linux/System/check-memory.sh` | 0 | **0** |
| `run-in-container.sh -- bash Linux/System/check-memory.sh --help` | 0 | **0** |

Le lint de l'hôte n'a pas `shellcheck` et ne vérifie que la syntaxe ; c'est le
lint conteneurisé qui fait foi. Il a relevé **un défaut réel** dans le script,
corrigé : `read -r cle valeur reste` laissait `reste` inutilisé (SC2034). Le
troisième champ de `/proc/meminfo` est l'unité affichée — `kB`, quelle que soit
l'architecture — et elle n'est pas lue : les valeurs sont en kibioctets. Le champ
est désormais absorbé par `_`, avec le commentaire qui dit pourquoi.

Les deux avertissements restants du lint conteneurisé portent sur
`Synology/Plex/*.sh`, scripts hérités déclarés hors standard et non bloquants.

## Fichiers

| Fichier | Nature |
|---|---|
| `Linux/System/check-memory.sh` | le script, 815 lignes |
| `tests/integration/check-memory.test.sh` | le fichier de cas, 1 062 lignes, 265 vérifications |
| `config/server.env.example` | `SRV_MEM_SEUIL` et `SRV_MEM_TOP`, commentés |
| `Linux/System/README.md` | ligne du tableau, utilisation, « Seuils de `check-memory.sh` », codes de retour, risques |
| `README.md` | ligne du tableau des scripts |
| `tests/README.md` | arborescence des cas d'intégration, et pourquoi un fichier séparé |

## Ce que la couverture ne prouve pas

Trois limites, déclarées dans le fichier de cas plutôt que passées sous silence :

- **le chargement de `config/server.env`** n'est pas emprunté : `SRV_MEM_SEUIL` et
  `SRV_MEM_TOP` sont transmises par l'environnement. Même variable et même
  `set -a` de `lib/common.sh`, mais écrire le fichier imposerait de créer
  `config/server.env` dans le dépôt monté, qui n'est pas un système jetable.
  Limite identique à celle de `check-disk.sh` ;
- **les valeurs absolues de mémoire** : sans `lxcfs`, `free` et `/proc/meminfo`
  décrivent la machine hôte. Toutes les assertions qui exigent un chiffre connu
  passent par un faux `free` ;
- **une zone d'échange réellement créée par le test** : `swapon` exige
  `CAP_SYS_ADMIN`, refusé au conteneur. La conjonction mémoire/échange est
  éprouvée par un faux `free`.

## Points versés ailleurs

Aucun. Les sujets écartés par l'énoncé — traces du tueur de mémoire, pression
PSI, comptabilité par cgroup, notification d'un seuil dépassé — restent où ils
étaient : les trois premiers hors du domaine, le dernier dans TASK-024 et
`docs/points-en-suspens.md` § 2.
