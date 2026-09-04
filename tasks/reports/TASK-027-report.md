# TASK-027 — Rapport d'exécution

## Statut

COMPLETED — **avec un objet différent de celui de l'énoncé**, amendé en cours de
route sur mesure. Voir `amendement_2026_09_04` dans la tâche.

## Objectif initial, et ce qu'il est devenu

La tâche devait rendre l'agent capable de **démarrer** Docker Desktop, seul
obstacle qui l'arrêtait réellement. Elle produit finalement un outil qui
**attend et diagnostique** — parce que le démarrage ne fonctionne pas depuis la
session de l'agent, et que c'est mesuré.

## Ce que le premier usage réel a mesuré

L'outil a été lancé avec Docker Desktop éteint, ce qui était l'état de départ
voulu. Journal intégral :

```text
15:50:20  Le démon Docker ne répond pas (constaté en 0s)
15:50:32  Démarrage de Docker Desktop (tentative 1/2)
15:50:45  Processus présent après 14s
15:51:15  Le processus a disparu après 46s — arrêté en cours de démarrage
15:51:16  Démarrage de Docker Desktop (tentative 2/2)
15:51:28  Processus présent après 13s
15:54:43  Le processus a disparu après 253s
          → plafond atteint, code 3
```

**L'outil a fait exactement ce qu'on lui demandait** : détecté, démarré, attendu,
constaté la disparition, relancé une fois, puis s'est arrêté au plafond avec un
diagnostic. Sans boucler. Sans jamais tenter d'arrêter quoi que ce soit.

**C'est Docker Desktop qui n'a pas démarré.** Ses propres journaux, version
4.51.0 :

```text
sending event: eventErrorDialog
bind: {"action":"Quit"}
com.docker.backend.exe services: exit status 150
```

Docker Desktop affiche une boîte de dialogue d'erreur, puis se quitte. Deux fois,
une par tentative. Le service `com.docker.service` était `Stopped`, en démarrage
`Manual`. WSL n'était pas en cause : la distribution `docker-desktop` existe.

## Le fait décisif, et il est venu de Maxime

**Lancé à la main, Docker Desktop démarre sans afficher la moindre erreur.**

Le défaut ne tient donc pas à Docker mais au **contexte de lancement** :
`Start-Process` depuis la session de l'agent ne fournit pas ce que Docker Desktop
attend — élévation, ou session interactive. Laquelle des deux n'a pas été
établie.

**Décision du 2026-09-04** : Docker Desktop est lancé au démarrage du système.
L'agent n'a plus à le démarrer.

## Ce que l'outil fait désormais

| État constaté | Traitement |
|---|---|
| le démon répond | rien, code 0, un seul sondage |
| processus présent, moteur pas prêt | attend — **c'est le cas courant** depuis la décision |
| processus jamais vu | attend son apparition, borné, puis code 3 |
| processus vu puis disparu | code 3 **immédiat**, avec la durée écoulée |
| plafond atteint | code 3, diagnostic, jamais de boucle |

Le démarrage subsiste derrière `--demarrer`, **jamais employée par défaut**, avec
la limite mesurée écrite dans le fichier. Si le contexte de lancement change un
jour, le code est là et sa limite est documentée plutôt que réinventée.

## Vérification par le relecteur

Il a exercé les chemins d'échec par **substitution de `docker` et `powershell`
dans le `PATH`**, avec journalisation de tout appel `Start-Process` :

| Scénario | Mesuré |
|---|---|
| moteur muet, processus absent, **sans** `--demarrer` | code 3 en **65 s**, journal d'appels **vide** |
| processus vu puis disparu | plantage détecté en **14 s**, code 3 |
| moteur muet, **avec** `--demarrer` | **exactement 2** `Start-Process`, code 3 en 140 s |
| `run-in-container.sh` réel, démon mort | code 3 en **71 s**, aucun `Start-Process` |
| `run-in-container.sh --dry-run`, démon mort | code 3 en **5 s**, aucune attente |

**Les deux gardes de Maxime tiennent, y compris sous injection.** Aucun ordre
d'arrêt sur aucun chemin ; toutes les sorties sont bornées ; une seule
affectation de `DEMARRAGE_AUTORISE` dans tout le dépôt, dans le `case` de
l'option.

## Fichiers

| Fichier | Nature |
|---|---|
| `tests/env/assurer-docker.sh` | **créé** — l'outil |
| `tests/env/run-in-container.sh` | appel dans la branche d'échec du préflight, aide |
| `AGENTS.md` | commandes de lecture d'état, section « Docker Desktop : constater, jamais agir » |
| `.claude/settings.json` | permissions de lecture |
| `docs/points-en-suspens.md` | §11 — hors `scope`, voir plus bas |
| `tests/README.md` | l'outil, ses délais, ses codes |

## Commandes exécutées

| Commande | Code |
|---|---|
| `tests/run.sh lint` | **0** — 29 fichiers, `shellcheck` absent de l'hôte |
| `bash tests/env/assurer-docker.sh --dry-run` | **0** — rien lancé, processus resté absent |
| `bash tests/env/assurer-docker.sh` | **0** — démon prêt reconnu en 1 s, durée totale 2 s |
| `tests/env/run-in-container.sh -- tests/run.sh lint` | **0** — shellcheck y tourne, l'outil passe propre |
| `tests/env/run-in-container.sh -- tests/run.sh lint unit integration environment` | **0** — 4 niveaux verts |

Non-régression vérifiée : avec un démon sain, `run-in-container.sh` ne produit
**aucune trace** de l'outil et affiche le même message qu'avant.

## Tentatives

2 / 5 — un tour sur l'amendement, un sur deux messages.

## Critères d'acceptation

- [x] démon prêt reconnu sans rien démarrer, code 0 en moins de 5 s — **2 s**
- [x] un démon qui démarre est attendu sans conclure trop tôt
- [x] le démarrage n'est tenté que sur option explicite, avec sa limite écrite
- [x] un plantage en cours est détecté et diagnostiqué avec la durée — **14 s**
- [x] toute attente est plafonnée, code 3 plutôt que boucler
- [x] l'outil n'arrête jamais Docker Desktop, quel que soit le chemin
- [x] chaque démarrage, attente et échec est tracé avec sa durée réelle
- [x] `run-in-container.sh` appelle l'outil au lieu de mourir
- [x] comportement inchangé quand le démon répond au premier contrôle

## Corrections

**Tour 1 — l'amendement.** Le démarrage sort du chemin par défaut, la limite est
écrite avec ses chiffres dans le script, dans `AGENTS.md` et au §11 des points en
suspens, et le message d'échec conseille désormais le lancement manuel en disant
pourquoi.

**Tour 2 — deux messages.** L'aide de `run-in-container.sh` annonce la latence :
un démon mort fait échouer le lanceur en **71 secondes** là où il échouait en
une, et l'appelant doit le savoir avant de se demander pourquoi rien ne se passe.
Et deux messages vrais se contredisaient à la lecture — « plantage en cours de
route » suivi de « Docker Desktop n'est pas lancé » — désormais ordonnés pour que
la chronologie soit évidente.

**Une réserve du relecteur m'était adressée, et elle était juste** : la permission
`Bash(bash tests/env/assurer-docker.sh:*)` que j'avais écrite laissait passer
`--demarrer` sans invite, contredisant la décision. Remplacée par deux entrées
précises — l'appel nu et `--dry-run`.

## Validation finale

PASS

## Écarts de périmètre

`docs/points-en-suspens.md` n'est pas dans le `scope` : c'est le réceptacle que
`CLAUDE.md` désigne pour ce genre de point, et la limite devait y figurer.

Trois `acceptance_criteria` sur quatre ont été réécrits par l'amendement. Le
relecteur le signale sans le compter comme faute : l'amendement porte la décision
de Maxime, mais c'est bien l'agent qui a réécrit les critères qui le jugent. Le
dire vaut mieux que le taire.

## Réserves

**`DELAI_DISPONIBILITE` (300 s) n'a jamais été mesuré** — le moteur n'a jamais
été vu prêt pendant une attente. L'exécution du 2026-09-04 a seulement établi que
le plafond est atteint et que la main est rendue, pas qu'il soit à la bonne
hauteur. Le script et `tests/README.md` le disent tous deux.

**Le vrai chemin d'attente sur un Docker Desktop réellement en cours de
démarrage n'a pas été éprouvé.** Docker tournait pendant la relecture ; les
mesures des chemins d'échec reposent sur des substitutions, pas sur
l'application.

**Le sursis de 60 s quand le processus est absent** est un choix : sans
`--demarrer` et Docker éteint, l'outil attend l'apparition d'un processus que
personne ne lancera. Le relecteur l'a jugé défendable — c'est exactement le cas
que la décision de Maxime rend fréquent, il est borné, et le démon est resondé
toutes les 5 s pendant la fenêtre. Le coût est réel et désormais annoncé dans
l'aide.

**`shellcheck` est absent de l'hôte.** La couverture réelle vient du conteneur,
où le script passe propre.

**La limite que rien ne résout**, et qui est le vrai sujet du §11 : si Docker
Desktop tombe en cours de session, il faut une intervention humaine. Un chantier
qui tourne sans surveillance s'arrête alors jusqu'à ce que quelqu'un le voie.
Trois pistes sont consignées, aucune essayée — la plus probable étant de passer
`com.docker.service` en démarrage automatique.

## Git

Branche : `agent/TASK-027`
Fusionnée dans `master` en `--no-ff` après validation.

## Résumé

La tâche n'a pas produit ce qu'elle annonçait, et c'est son résultat le plus
utile. Elle devait apprendre à l'agent à démarrer Docker ; elle a établi, par la
mesure, qu'il ne le peut pas depuis sa session — et pourquoi.

Ce qui reste est plus modeste et plus juste : un outil qui attend un démon en
train de démarrer, détecte un plantage, et dit clairement ce qui manque au lieu
de mourir sur un `docker info` muet. Le cas qu'il traite est devenu le cas
courant du fait même de la décision qui l'a amputé de son objet initial.

Deux choses valent d'être retenues. **L'outil a été validé par son échec** : la
seule exécution réelle qu'il ait connue s'est terminée en code 3, et c'est ce qui
a prouvé que ses gardes tenaient. Et **le fait décisif n'est venu ni du code ni
d'un sous-agent, mais de Maxime regardant son écran** — « pas d'erreur quand je le
démarre à la main ». Aucune mesure automatique n'aurait produit ce contraste.
