---
id: TASK-028
title: "Justifier la directive shellcheck nue de linux-system.test.sh"
status: ready
priority: high
depends_on: []
environment: container-debian
human_approval_required: false
objective: |
  Rendre la commande de référence du dépôt verte de nouveau. Une directive
  « shellcheck disable » a été déposée sans justification au-dessus d'elle, ce
  que le critère d'acceptation de TASK-011 interdit : le niveau « acceptance »
  échoue donc sur master, et avec lui « tests/run.sh » sans argument.
scope:
  - tests/integration/linux-system.test.sh — ligne 2016, la directive et son commentaire
out_of_scope:
  - toute autre modification de linux-system.test.sh — le fichier passe les 4 900 lignes et son ordre de groupes est contraint
  - le retrait de la directive elle-même : elle est légitime, c'est sa justification qui manque
  - la règle de TASK-011 et le fichier qui la vérifie, tests/acceptance/TASK-011-analyse-statique.sh
  - les trois fichiers d'acceptance qui sortent en 3 faute de démon Docker dans le conteneur — c'est le sujet distinct des points en suspens
acceptance_criteria:
  - la ligne qui précède la directive est un commentaire disant POURQUOI SC2016 est désactivé à cet endroit
  - "tests/env/run-in-container.sh -- tests/run.sh acceptance rend 0"
  - "tests/env/run-in-container.sh -- tests/run.sh rend 0, ou 3 pour la seule raison des trois fichiers privés de démon Docker — jamais 1"
  - aucune assertion de linux-system.test.sh ne change de verdict — le fichier rend le même bilan qu'avant
validation:
  - "tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh acceptance"
  - "tests/env/run-in-container.sh -- tests/run.sh integration"
implementation_notes:
  - une seule ligne de commentaire suffit ; le critère ne demande pas davantage
  - ne pas écrire une justification de complaisance — SC2016 a une vraie raison d'être ici, il faut la dire
---

# TASK-028 — Une directive shellcheck sans justification bloque la commande de référence

## Le fait

Mesuré le 2026-09-08, sur `master`, pendant TASK-023 :

```text
tests/env/run-in-container.sh -- tests/run.sh acceptance
  → /depot/tests/integration/linux-system.test.sh ligne 2016 : rien au-dessus de la directive
  → [ERROR] ÉCHEC : toute directive shellcheck locale porte une justification au-dessus — 1 directive(s) nue(s)
  → [ERROR] tests/acceptance/TASK-011-analyse-statique.sh : ÉCHEC (code 1)
  → code 1
```

`tests/integration/linux-system.test.sh:2015-2016` :

```bash
# shellcheck disable=SC2016
if [ -n "$("$REP_STUB_AWK_MUET/awk" '{ print $1 }' /proc/uptime)" ]; then
```

La ligne au-dessus de la directive est une accolade fermante `fi`, pas un
commentaire. `tests/acceptance/TASK-011-analyse-statique.sh:189-200` lit la ligne
précédant chaque `shellcheck disable` et exige qu'elle soit un commentaire.

## Pourquoi ce n'est pas un faux positif du critère

La directive **est légitime** : `'{ print $1 }'` est un programme `awk` en
guillemets simples, et `$1` n'y est pas une variable de shell. SC2016 avertit
justement des `$` non interpolés dans une chaîne simple ; c'est exactement le cas
où on veut le taire.

Ce qui manque n'est donc pas la directive, c'est **la phrase qui dit tout cela**.
Le critère de TASK-011 ne demande rien d'autre, et sa raison d'être est là : une
directive muette se recopie sans qu'on sache si elle protège encore quelque
chose.

## Antériorité

La directive est entrée par le commit `aeaf4fb`, *feat(linux/system): ajouter
check-disk.sh* — TASK-021. Elle est donc antérieure à TASK-022 et à TASK-023, et
étrangère à l'une comme à l'autre : `git diff --name-only master...agent/TASK-023`
ne touchait pas ce fichier.

Le défaut n'a pas été vu plus tôt parce que ni TASK-021, ni TASK-022, ni TASK-023
n'inscrivaient `tests/run.sh acceptance` dans leur champ `validation` — chacune
listait les niveaux qui la concernaient, et aucune ne concernait l'acceptance.
C'est en éprouvant la **commande de référence du dépôt**, `tests/run.sh` sans
argument, que le rouge est apparu.

## Ce que cette tâche ne traite pas

Le même passage montre trois fichiers d'acceptance sortant en **3** — *rien n'est
prouvé* — parce qu'ils ont besoin du démon Docker depuis l'intérieur du
conteneur, ce que le montage ne fournit pas (pas de Docker-in-Docker). C'est un
sujet distinct, qui appelle une décision et non une correction d'une ligne. Il ne
fait pas passer le niveau en échec : il le prive de preuve.

**Ne pas mélanger les deux.** Cette tâche-ci ferme le 1. Le 3 reste ouvert.

## Codes de retour attendus des validations

| Commande | Code |
|---|---|
| `tests/run.sh lint` | 0 |
| `run-in-container.sh -- tests/run.sh lint` | 0 |
| `run-in-container.sh -- tests/run.sh acceptance` | **0** — c'est l'objet de la tâche |
| `run-in-container.sh -- tests/run.sh integration` | 0, inchangé — la garde qu'entoure la directive doit continuer de passer |

La dernière ligne n'est pas une redondance : elle constate qu'on a justifié la
directive sans toucher au cas qu'elle protège.
