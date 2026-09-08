---
id: TASK-023
title: "Écrire Linux/System/check-services.sh"
status: ready
priority: medium
depends_on:
  - TASK-020
environment: container-systemd
human_approval_required: false
objective: |
  Livrer le diagnostic des services systemd — inventaire des services actifs,
  liste de ceux qui sont en échec, et vérification d'un service nommé — en
  lecture seule, avec un code de retour exploitable pour la vérification d'un
  service précis.
scope:
  - Linux/System/check-services.sh
  - tests/environment/check-services.test.sh
  - Linux/System/README.md — ligne du tableau, utilisation, codes de retour
  - README.md — ligne du tableau des scripts
out_of_scope:
  - toute action sur un service — start, stop, restart, enable, disable, reload
  - la lecture des journaux d'un service, qui appartient à un script de diagnostic distinct
  - les unités autres que les services — timers, sockets, mounts, targets
  - les services d'un utilisateur, systemctl --user
  - la création du niveau environment et du profil systemd, livrés par TASK-020
  - un repli sur SysV, OpenRC ou un autre gestionnaire de services — ADR-0003 décision 14 pose systemd partout
acceptance_criteria:
  - le script s'exécute sans privilège et rend 0 lorsqu'il se contente d'inventorier
  - il affiche le nombre et la liste des services actifs, et la liste des services en échec, celle-ci en évidence
  - un service en échec ne change pas le code de retour du mode inventaire
  - avec --service <nom>, il affiche l'état d'activation, l'état d'exécution et la date du dernier démarrage du service nommé
  - avec --service <nom>, il rend 0 si le service est actif et 1 s'il est inactif, en échec ou inconnu, en distinguant les trois cas par le message
  - --service sans valeur rend 2, comme toute option inconnue
  - un nom de service manifestement invalide rend 2 avant toute interrogation du système
  - l'absence de systemctl rend 1 avec un message nommant la dépendance, jamais un message brut du shell
  - le script n'écrit rien en dehors du journal ouvert par lib/common.sh
  - --help documente les options, les trois issues de --service et les codes de retour
  - le fichier de cas conserve sous le profil debian au moins un cas exécutable sans systemd, de sorte que le niveau environment y sorte en 4 et jamais en 3
  - sous le profil systemd, les cas nominaux sont réellement exécutés — un service arrêté volontairement fait rendre 1, le même service relancé fait rendre 0
validation:
  - "tests/run.sh lint"
  - "tests/env/run-in-container.sh -- tests/run.sh lint"
  - "tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment"
  - "tests/env/run-in-container.sh -- tests/run.sh environment"
  - "tests/env/run-in-container.sh --profil systemd -- bash Linux/System/check-services.sh"
  - "tests/env/run-in-container.sh --profil systemd -- bash Linux/System/check-services.sh --help"
implementation_notes:
  - seule tâche du lot qui exige container-systemd — le profil debian n'a pas d'init et systemctl y est absent
  - systemctl is-system-running rend « degraded » dès qu'une unité a échoué, ce qui est banal en conteneur — ce n'est pas une panne
  - systemctl rend 4 pour une unité inconnue et 3 pour une unité inactive — ces codes lui appartiennent, ils ne sont pas ceux du script
  - le fichier de cas modifie l'état de services dans le conteneur — il se protège comme ceux d'integration, en reconnaissant un système jetable avant d'agir
---

# TASK-023 — Diagnostic des services systemd

## Ce que le plan demande

[docs/refactorisation-plan.md](../../docs/refactorisation-plan.md) §1,
`check-services.sh` : *afficher les services systemd actifs/en échec et
permettre de vérifier un service précis*.

## Pourquoi cette tâche attend TASK-020

C'est la seule du lot qui ne peut être prouvée nulle part ailleurs. Le profil
`debian` n'a pas d'init : `systemctl` y est absent, et une exécution ne
franchirait pas le préflight. `AGENTS.md` §7 réserve le profil `systemd` à
exactement ce cas, et ADR-0003 décision 12 a fait construire ce profil d'abord
pour cette raison.

**À passer en `ready` dès que [TASK-020](TASK-020.md) est `completed`.** Tant
qu'elle ne l'est pas, la règle de sélection de `tasks/README.md` §4 l'écarte de
toute façon.

## Deux modes, deux contrats de sortie

C'est la décision structurante de cette tâche, et elle est tranchée ici pour ne
pas l'être à l'exécution.

| Mode | Ce qu'il fait | Code |
|---|---|---|
| inventaire, sans option | liste les services actifs, met en évidence ceux en échec | **toujours 0** |
| `--service <nom>` | répond à une question fermée | **0** actif, **1** inactif, en échec ou inconnu |

Le mode inventaire est un diagnostic : il rend compte, il ne juge pas. Faire
rendre 1 à un serveur qui porte une unité en échec transformerait chaque passage
en tâche planifiée en échec — c'est le rôle de `security-check.sh` (plan §2) de
produire des statuts.

`--service` pose au contraire une question dont la réponse est utile à un
appelant : *ce service tourne-t-il ?* Un non est un **échec d'exécution**, code 1,
conformément à `docs/architecture-technique.md`. Le 2 reste strictement réservé à
ce qu'on reproche à l'appelant — option inconnue, valeur manquante, nom
manifestement invalide. Les trois issues du 1 — inactif, en échec, inconnu — se
distinguent par le message, jamais par le code.

## Décisions déjà prises, à ne pas reposer

| Question | Réponse | Source |
|---|---|---|
| gestionnaire de services | `systemd`, sans repli | ADR-0003 décision 14 |
| cibles | Debian 12 et 13, Ubuntu 22.04 et 24.04 | ADR-0003 décision 14 |
| dépendance absente | code 1, pas 2 | ADR-0003 décision 10 |
| où tourne la preuve | conteneur `systemd`, niveau `environment` | ADR-0003 décision 12, `AGENTS.md` §10 |

## Pièges connus

**Le fichier de cas doit rester utile sous le profil `debian`.** Depuis TASK-020,
le niveau `environment` est exécuté partout, y compris là où systemd n'est pas.
Un fichier qui ne ferait que sauter sortirait en **3** — *rien n'est prouvé* — et
ferait rougir la commande de référence du dépôt. Il doit donc porter au moins un
cas exécutable sans systemd — l'aide, une option inconnue, le refus de
`--service` sans valeur — et qualifier le reste par `saute_par_nature`. La règle
et son ordre de gardes sont dans `tests/README.md` §2.

**Les codes de `systemctl` ne sont pas ceux du script.** `systemctl is-active`
rend 3 pour une unité inactive, `systemctl status` rend 4 pour une unité inconnue.
Les relayer tels quels casserait la convention du dépôt ; les confondre avec le 3
et le 4 du harnais de test serait pire encore.

**`systemctl` sort en 1 sous `set -e` sans rien dire d'utile.** Toute
interrogation se place en contexte de condition — `if ! sortie="$(systemctl …)"` —
comme l'impose le motif tranché par TASK-018 : une affectation nue ferait parler
le `trap ERR` deux fois, sans nommer la cause.

**Un service arrêté n'est pas une panne du conteneur.** Le fichier de cas doit
créer lui-même la situation qu'il éprouve — arrêter un service présent, constater
le 1, le relancer, constater le 0 — plutôt que de compter sur l'état du conteneur.
Le choix du service témoin appartient au rédacteur ; il doit être fourni par
l'image du profil `systemd` et sans effet sur le reste de la suite.

**`systemctl list-units --failed` n'affiche pas les unités masquées ni celles
qui n'ont jamais démarré.** Ne pas présenter la liste comme un état de santé
complet du serveur.

## Codes de retour attendus des validations

| Commande | Code |
|---|---|
| `tests/run.sh lint` | 0 |
| `run-in-container.sh -- tests/run.sh lint` | 0 |
| `run-in-container.sh --profil systemd -- tests/run.sh environment` | 0 |
| `run-in-container.sh -- tests/run.sh environment` | 0, le niveau sortant en 4 sous `debian` |
| `run-in-container.sh --profil systemd -- bash …/check-services.sh` | 0 |
| `run-in-container.sh --profil systemd -- bash …/check-services.sh --help` | 0 |

La quatrième ligne n'est pas une redondance : elle constate que l'ajout de ce
fichier de cas ne fait pas basculer le niveau en 3 sur le profil ordinaire.
