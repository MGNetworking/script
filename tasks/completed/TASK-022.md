---
id: TASK-022
title: "Écrire Linux/System/check-memory.sh"
status: completed
priority: medium
depends_on: []
environment: container-debian
human_approval_required: false
objective: |
  Livrer le diagnostic mémoire du domaine — RAM, fichier d'échange et processus
  consommateurs — en lecture seule stricte, sans privilège, et sans jamais
  mourir parce qu'une source d'information manque.
scope:
  - Linux/System/check-memory.sh
  - tests/integration/check-memory.test.sh
  - config/server.env.example — le seuil d'occupation mémoire
  - Linux/System/README.md — ligne du tableau, utilisation, risques
  - README.md — ligne du tableau des scripts
out_of_scope:
  - toute action corrective — libération de cache, kill d'un processus, activation d'un swap
  - la création ou le redimensionnement d'un fichier d'échange, qui appartient à configure-swap.sh
  - les traces du tueur de mémoire dans dmesg ou le journal du système
  - la pression mémoire PSI et la comptabilité par cgroup
  - le diagnostic de stockage, qui est l'objet de TASK-021
  - la notification d'un seuil dépassé, qui est l'objet de TASK-024
acceptance_criteria:
  - le script s'exécute sans aucun privilège et rend 0
  - il n'écrit rien en dehors du journal ouvert par lib/common.sh
  - il affiche la mémoire totale, utilisée, libre, disponible et la part occupée par le cache
  - la distinction entre mémoire libre et mémoire disponible est affichée et expliquée, la seconde étant celle qui compte
  - il affiche l'état du fichier d'échange — total, utilisé, libre — et dit qu'aucun swap n'est actif sans traiter ce cas comme une anomalie
  - il affiche les processus les plus consommateurs, triés sur la mémoire résidente, pour un nombre d'entrées borné et configurable
  - il lit /proc/meminfo lorsque « free » est absent du système, et le dit
  - une commande absente ou en échec — free, ps — produit un avertissement nommant la cause et « non disponible » à l'affichage, jamais l'arrêt du script
  - un dépassement du seuil d'occupation est signalé par un WARN, sans que le code de retour en soit changé
  - le seuil et le nombre de processus affichés se surchargent par config/server.env puis par la ligne de commande, la ligne de commande primant
  - une option inconnue rend 2, et une valeur de seuil non numérique ou hors de 1 à 100 rend 2, sans que rien n'ait été lu
  - --help documente les options, les valeurs par défaut, leur origine et les codes de retour
  - une seconde exécution consécutive laisse le système inchangé
validation:
  - "tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh integration"
  - "tests/env/run-in-container.sh -- bash Linux/System/check-memory.sh"
  - "tests/env/run-in-container.sh -- bash Linux/System/check-memory.sh --help"
implementation_notes:
  - system-info.sh lit déjà MemTotal et MemAvailable dans /proc/meminfo — relire ses deux awk et leur commentaire avant d'en écrire d'autres
  - dans le conteneur, free et /proc/meminfo décrivent la machine hôte et non le conteneur — aucune assertion ne peut porter sur une valeur absolue
  - /proc/swaps est vide dans le conteneur de test — c'est le cas nominal « aucun swap actif », pas une indisponibilité
  - toute affectation var="$(…)" se place en contexte de condition, motif tranché par TASK-018
---

# TASK-022 — Diagnostic mémoire

## Ce que le plan demande

[docs/refactorisation-plan.md](../../docs/refactorisation-plan.md) §1,
`check-memory.sh` : *diagnostic RAM, swap et processus consommateurs*. Trois
sections, et rien de plus.

## Le comportement attendu est celui de `system-info.sh`

Même modèle que [TASK-021](TASK-021.md) : aucune écriture, aucun privilège,
aucune dépendance exigée, et une dégradation en « non disponible » plutôt qu'un
arrêt. `system-info.sh` porte déjà une section mémoire réduite ; ce script en est
le développement, il ne la remplace pas et ne modifie pas `system-info.sh`.

Le sujet a une histoire dans ce dépôt, à lire avant d'écrire : les deux `awk` sur
`/proc/meminfo` de `system-info.sh` ont été repris par TASK-018, et leur mise en
condition n'a pu être éprouvée qu'avec un **bac à sable de liens symboliques
reproduisant le `PATH` sans `free`** — le mettre simplement en échec ne suffisait
pas, `command -v free` réussissant encore et la branche `/proc/meminfo` restant
fermée. Le montage est décrit dans `tests/README.md`.

## Décisions déjà prises, à ne pas reposer

| Question | Réponse | Source |
|---|---|---|
| cibles | Debian 12 et 13, Ubuntu 22.04 et 24.04 | ADR-0003 décision 14 |
| code d'une option inconnue | 2 | ADR-0003 décision 10 |
| où vit un seuil | `config/server.env`, surchargeable en ligne de commande | ADR-0003 décision 24 |
| un seuil dépassé ne change pas le code de retour | comme `check-disk.sh` | TASK-021 |

**Le seuil par défaut est 90 %** d'occupation de la mémoire *disponible*,
surchargeable par `SRV_MEM_SEUIL` puis par `--seuil`. Le nombre de processus
affichés vaut 10 par défaut, surchargeable par `--top`. Choix réversibles et
locaux, à consigner dans le rapport.

## Pièges connus

**« Libre » n'est pas « disponible ».** `MemFree` exclut le cache et les tampons,
que le noyau rend à la demande : un serveur sain affiche presque toujours une
mémoire libre proche de zéro. C'est `MemAvailable` qui dit ce qui est réellement
mobilisable, et c'est sur lui que le seuil doit porter. Un script qui alerterait
sur `MemFree` crierait au loup à chaque exécution.

**Le conteneur voit la mémoire de l'hôte.** Sans `lxcfs`, `/proc/meminfo` et
`free` décrivent la machine hôte. Un fichier de cas ne peut donc affirmer ni une
valeur, ni un ordre de grandeur : il éprouve la présence des rubriques, la
cohérence interne des chiffres, la dégradation sous stub, et les codes de retour.

**`/proc/swaps` est vide dans le conteneur.** « Aucun fichier d'échange actif »
est un état parfaitement normal — sur un conteneur comme sur bien des VPS. Le
traiter comme une erreur, ou le déclarer indisponible dans le fichier de cas,
serait faux dans les deux sens.

**`ps` vient de `procps`,** présent dans l'image de test parce que
`system-info.sh` en a besoin. Ne pas ajouter de paquet à l'image pour ce script ;
si un besoin nouveau apparaît, il se discute, il ne se glisse pas.

**Le tri par mémoire résidente compte deux fois la mémoire partagée.** `RSS`
additionne des pages partagées entre processus ; la somme de la colonne dépasse
donc la mémoire réellement occupée. Le dire dans l'affichage plutôt que de
laisser croire à une addition juste.

## Codes de retour attendus des validations

| Commande | Code |
|---|---|
| `tests/run.sh lint` | 0 |
| `run-in-container.sh -- tests/run.sh lint` | 0 |
| `run-in-container.sh -- tests/run.sh integration` | 0 |
| `run-in-container.sh -- bash Linux/System/check-memory.sh` | 0 |
| `run-in-container.sh -- bash Linux/System/check-memory.sh --help` | 0 |
