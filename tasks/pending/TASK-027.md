---
id: TASK-027
title: "Rendre le démon Docker disponible sans intervention humaine"
status: ready
priority: high
depends_on: []
environment: host
human_approval_required: true
objective: |
  Le démon Docker éteint est le seul obstacle qui arrête réellement l'agent, et
  il se représentera à chaque redémarrage de la machine. Docker peut aussi
  planter en cours de tâche, laissant une suite à moitié exécutée. Un outil doit
  savoir démarrer Docker Desktop, attendre qu'il soit prêt, détecter un plantage
  survenu en cours de route et relancer — sans jamais boucler indéfiniment.
scope:
  - tests/env/assurer-docker.sh — l'outil, à créer
  - tests/env/run-in-container.sh — appel de l'outil quand le démon ne répond pas
  - AGENTS.md — le démarrage de Docker Desktop entre dans les commandes autorisées, avec ses gardes
  - .claude/settings.json — permission pour que la commande ne demande pas d'autorisation à chaque appel
  - tests/README.md — ce que fait l'outil, ses délais, ses codes
out_of_scope:
  - l'arrêt de Docker Desktop, en toute circonstance
  - toute autre action sur la machine hôte que le démarrage de cette application
  - l'installation de Docker, s'il est absent
  - le redémarrage de la machine
  - la gestion d'un démon Docker distant, ou d'un contexte docker autre que celui par défaut
  - les scripts de Linux/System, Docker/, Kubernetes/ — cet outil sert le harnais de test, pas l'administration
acceptance_criteria:
  - le démon déjà prêt est reconnu sans rien démarrer, et l'outil rend 0 en moins de cinq secondes
  - Docker Desktop éteint est démarré, et l'outil attend le démarrage à froid sans conclure trop tôt
  - un plantage survenu en cours d'exécution est détecté, et une relance est tentée
  - le nombre de relances est plafonné, et l'outil s'arrête en rendant 3 plutôt que de boucler
  - l'outil n'arrête jamais Docker Desktop, quel que soit le chemin emprunté
  - chaque démarrage, chaque attente et chaque échec est tracé, avec sa durée réelle
  - run-in-container.sh appelle l'outil au lieu de mourir quand le démon ne répond pas
  - le comportement est inchangé quand le démon répond dès le premier contrôle
validation:
  - "tests/run.sh lint"
  - "bash tests/env/assurer-docker.sh --dry-run"
  - "bash tests/env/assurer-docker.sh"
  - "tests/env/run-in-container.sh -- tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh lint unit integration environment"
implementation_notes:
  - autorisé par Maxime le 2026-09-04, avec deux gardes qu'il a lui-même posées - jamais l'arrêt, et un plafond de tentatives
  - le chemin mesuré sur cette machine est C:\Program Files\Docker\Docker\Docker Desktop.exe
  - le lancement se fait par powershell -NoProfile -Command "Start-Process ..." — Docker Desktop est une application Windows, pas un service
  - run-in-container.sh sait déjà détecter le démon par « docker info --format {{.ServerVersion}} » ligne 435 - réutiliser ce contrôle, ne pas en inventer un autre
  - TASK-020 a consacré trois tours à borner les appels Docker - lire son rapport avant d'écrire une seule attente, et n'en écrire aucune qui ne soit bornée
  - un démarrage à froid initialise WSL2 - se compter en minutes, pas en secondes. Mesurer plutôt que supposer
---

# TASK-027 — Le démon Docker, sans intervention

## Origine

Le 2026-09-04, `TASK-022` s'est arrêtée avant de commencer : Docker Desktop
était éteint après un redémarrage de la machine. `AGENTS.md` §7 impose de
s'arrêter dans ce cas, et c'est ce qui a été fait — mais l'obstacle se
représentera à chaque redémarrage, et il reste **quarante-huit scripts** à
écrire.

Maxime a autorisé le démarrage automatique, en posant deux exigences que la
proposition initiale ne couvrait pas.

## Les deux cas qu'il faut traiter

### 1. Le démarrage à froid

Docker Desktop qui démarre n'est pas un démon qui répond tard : il initialise
WSL2, monte ses systèmes de fichiers, lance son moteur. **Cela se compte en
minutes.** Une attente calibrée sur un démon déjà lancé conclurait à l'échec
avant même que le démarrage n'ait commencé.

Cette durée est à **mesurer**, pas à supposer. Elle diffère d'un premier
démarrage après redémarrage de la machine à un simple relancement.

### 2. Le plantage en cours de route

Docker peut mourir **pendant** une tâche, laissant une suite à moitié exécutée.
Le cas est différent du précédent : le démon répondait, il ne répond plus.

Il faut donc :

- **le détecter** — une commande Docker qui échoue sur l'erreur de tube nommé,
  et non sur une erreur métier ;
- **relancer** ;
- **reprendre**, ou dire clairement ce qui n'a pas pu être repris.

C'est ce cas qui interdit la garde « une seule tentative par tâche » de la
proposition initiale : un plantage au milieu d'une suite doit pouvoir être
rattrapé.

## Les cinq états à distinguer

| État | Ce que l'outil fait |
|---|---|
| le démon répond | rien — rendre 0 tout de suite |
| Docker Desktop n'est pas lancé | démarrer, puis attendre le démarrage à froid |
| Docker Desktop est lancé, le démon n'est pas prêt | attendre seulement, ne pas relancer une seconde instance |
| le démon répondait et ne répond plus | relancer, dans la limite du plafond |
| plafond atteint | rendre 3, diagnostiquer, **ne pas boucler** |

Le troisième état mérite attention : lancer une seconde instance de Docker
Desktop alors que la première démarre est le meilleur moyen de tout casser.
Contrôler la présence du processus avant de démarrer, pas seulement la réponse
du démon.

## Les gardes, qui ne se négocient pas

**Jamais l'arrêt.** Fermer Docker Desktop pourrait interrompre un conteneur que
Maxime fait tourner pour son propre compte. L'outil n'a aucune raison légitime
de l'éteindre, et aucun chemin du code ne doit pouvoir le faire.

**Un plafond de tentatives.** Le nombre exact est à décider et à écrire, mais il
existe. Au-delà, l'outil rend 3 et s'arrête — comme le fait déjà
`run-in-container.sh` quand l'environnement manque.

**Aucune attente non bornée.** TASK-020 a consacré trois tours de correction à
ce sujet : le blocage se déplaçait d'un appel Docker à l'autre, et le script
rendait la main après 315 secondes en croyant avoir échoué en dix. Lire
[son rapport](../reports/TASK-020-report.md) avant d'écrire la première boucle.

## La trace

Chaque démarrage, chaque attente et chaque échec doit être **tracé avec sa durée
réelle**, et ces traces doivent se retrouver dans le rapport de la tâche qui a
déclenché le démarrage.

Sans cela, un plantage récurrent de Docker sur cette machine passerait pour une
lenteur de l'agent — et personne ne saurait qu'il faut regarder du côté de Docker
Desktop.

## Pourquoi `human_approval_required: true`

Le champ ne suspend plus l'exécution depuis ADR-0003 décision 2. Il est posé ici
parce que c'est la **première fois que le dépôt agit sur la machine hôte plutôt
que dans le projet**. `AGENTS.md` §5 range aujourd'hui « tout chemin hors du
dépôt » en zone interdite ; cette tâche y ouvre une exception nommée, et
l'exception mérite d'être lue attentivement.

L'autorisation, elle, est donnée : Maxime l'a formulée le 2026-09-04, en même
temps que les deux exigences ci-dessus.
