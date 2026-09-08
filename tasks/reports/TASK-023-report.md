# TASK-023 — Rapport d'exécution

## Statut

COMPLETED — **cycle complet** (relecteur compris).

ADR-0003 décision 5 rangerait `check-services.sh` au cycle léger : c'est un
script en lecture seule, comme `check-disk.sh` (TASK-021) et `check-memory.sh`
(TASK-022), tous deux menés en léger. Le cycle complet a été retenu pour une
raison qui n'appartient pas au script mais à son fichier de cas : **celui-ci
arrête et relance un service**, et il s'exécute au niveau `environment`, juste
avant `systemd.test.sh` dans l'ordre `find | sort` de `run-environment.sh`. Un
service témoin laissé à terre aurait empoisonné le fichier suivant, et le défaut
serait apparu à l'autre bout de la suite. C'est exactement ce qu'un relecteur
indépendant existe pour attraper.

Le choix s'est révélé juste : la relecture a trouvé six écarts, dont deux
sérieux — voir « Erreurs rencontrées ».

## Objectif

Livrer le diagnostic des services systemd — inventaire des services actifs,
liste de ceux qui sont en échec, et vérification d'un service nommé — en lecture
seule, avec un code de retour exploitable pour la vérification d'un service
précis.

## Travail réalisé

- `Linux/System/check-services.sh`, 635 lignes, deux modes :
  - **inventaire**, sans option : état global, nombre et liste des services
    actifs, liste des services en échec mise en évidence par `[WARN]`. Rend
    **toujours 0** ;
  - **`--service <nom>`**, question fermée : état d'activation, état d'exécution,
    date du dernier démarrage, et un code qui porte la réponse — 0 si actif,
    1 sinon ;
- `tests/environment/check-services.test.sh`, 1 635 lignes, neuf groupes ;
- les deux README mis à jour dans le même geste.

### Les deux contrats de sortie, et pourquoi ils diffèrent

C'est la décision structurante, et elle était déjà tranchée par l'énoncé de la
tâche.

| Mode | Nature | Code |
|---|---|---|
| inventaire | un diagnostic : il rend compte, il ne juge pas | **toujours 0** |
| `--service` | une question fermée dont la réponse est utile à l'appelant | **0** actif, **1** sinon |

Faire rendre 1 à l'inventaire d'un serveur qui porte une unité en échec — état
banal — transformerait chaque passage en tâche planifiée en échec. La production
de statuts est le rôle du futur `security-check.sh` (plan §2).

### Les sept issues de `--service`

Le `2` reste strictement réservé à ce qu'on reproche à l'appelant. Les six
manières de ne pas être actif se distinguent **par le message, jamais par le
code**.

| Issue | `LoadState` / `ActiveState` | Code |
|---|---|---|
| service actif | `loaded` / `active` | **0** |
| service inconnu | `not-found` | 1 |
| service masqué | `masked` | 1 |
| unité non chargée | ni `loaded`, ni `masked`, ni `not-found` | 1 |
| service en échec | `loaded` / `failed` | 1 |
| service inactif | `loaded` / autre | 1 |
| état inétablissable | `systemctl show` ne rend rien d'exploitable | 1 |

## Fichiers modifiés

| Fichier | Nature |
|---|---|
| `Linux/System/check-services.sh` | **créé** — 635 lignes |
| `tests/environment/check-services.test.sh` | **créé** — 1 635 lignes |
| `Linux/System/README.md` | ligne du tableau, bloc d'utilisation, section « Codes de retour », sous-section « Les deux modes de `check-services.sh` », comptes corrigés |
| `README.md` | une ligne dans le tableau des scripts |
| `tasks/active/TASK-023.md` | déplacé depuis `pending/`, `status` en `in_progress` puis `completed` |
| `tasks/backlog.md` | statut, liens, section « Terminé » |

`run-environment.sh` n'a **pas** été touché : le dispatcher découvre les
`*.test.sh` en `maxdepth 1`, déposer le fichier suffit à ouvrir le niveau.

## Faits mesurés sur le comportement de systemd

Ces relevés viennent d'exécutions réelles dans `mgnet-test-systemd` (Debian 12,
systemd 252, systemd en PID 1). Ils ont dicté la conception, et ils valent
au-delà de cette tâche : **le prochain script du domaine qui interroge systemd
les retrouvera.**

### `systemctl show` est le seul appel qui distingue les issues

```text
systemctl show -p LoadState -p ActiveState -p SubState -p UnitFileState \
               -p ActiveEnterTimestamp <unité>

  unité inconnue   → CODE 0, LoadState=not-found, ActiveState=inactive,
                     SubState=dead, UnitFileState et ActiveEnterTimestamp VIDES
  unité active     → CODE 0, loaded / active / running / static
  unité inactive   → CODE 0, loaded / inactive / dead / static
  unité masquée    → CODE 0, masked / inactive / dead / masked
  unité en échec   → CODE 0, loaded / failed / failed / enabled
```

`systemctl show` **rend toujours 0**, y compris sur une unité qui n'existe pas.

À l'inverse, `systemctl is-active` rend **3** pour `inactive`, pour `failed`
**et** pour une unité inconnue : il confond les trois issues que la tâche
demande précisément de distinguer. `systemctl is-enabled` sur une unité inconnue
rend 1 avec un message brut sur `stderr`.

**Conséquence de conception :** `--service` est bâti sur `show`, et lit
`LoadState` avant `ActiveState`.

### `ActiveEnterTimestamp` peut être vide

Un service jamais démarré depuis l'amorçage n'a pas de date de dernier
démarrage : la propriété rend une ligne vide, pas une erreur. Le script affiche
alors « non disponible ».

### Une unité au fichier invalide donne `LoadState=bad-setting`

```bash
printf '%%%% ceci n est pas une unite\n' > /etc/systemd/system/sonde.service
systemctl daemon-reload
systemctl show -p LoadState --value sonde.service     # → bad-setting

bash Linux/System/check-services.sh --service sonde
  → code 1
  → [ERROR] Unité non chargée : « sonde.service » — LoadState vaut « bad-setting ».
```

C'est la mesure qui établit la septième issue. Elle est **documentée** dans
l'aide et dans le README ; son message d'exécution n'est **pas** éprouvé par un
cas — voir « Ce qui n'est pas prouvé ».

## Faits mesurés sur l'environnement de test

### Le profil `systemd` n'est pas déterministe

`getty@tty1.service` part en boucle de redémarrage et bascule seul en `failed`
au bout de deux à trois secondes — **ou pas**. Trois lancements de la même image
ont donné successivement `running`, `degraded`, puis `running` avec zéro unité en
échec.

**Aucune assertion ne peut donc porter sur `systemctl is-system-running`, ni sur
le nombre d'unités en échec de l'image.** Le cas déterministe est une unité
fabriquée par le fichier de cas lui-même.

C'est le piège principal du niveau `environment`, et il n'était écrit nulle part
avant ce rapport.

### Le service témoin : `systemd-logind.service`

Trois candidats ont été éprouvés avant d'en retenir un :

| Candidat | Verdict |
|---|---|
| `getty@tty1.service` | **écarté** — instable, bascule seul en `failed` |
| `dbus.service`, `systemd-journald.service` | **écartés** — activés par socket, reviennent seuls ; couper `dbus` casserait en outre `systemd.test.sh`, qui atteint `systemd-hostnamed` et `systemd-timedated` par le bus |
| `systemd-logind.service` | **retenu** — `stop` rend 0 et laisse `inactive/dead`, `start` rend 0 et rétablit `active/running`, et rien d'autre dans la suite n'en dépend |

Deux autres unités de l'image servent de témoins **immobiles**, ce qui permet de
prouver deux issues sans rien modifier : `systemd-timedated.service`
(`loaded/inactive/dead`) pour le cas inactif, `console-getty.service`
(`masked`) pour le cas masqué.

### Ce qui bouge réellement sous `/var` pendant une exécution

Mesuré par `find /var /tmp /home -newer <témoin>`, sur trois passes :

- passe 1 : `/var/log/mgnetworking` et `check-services.log` ;
- passes 2 et 3 : `check-services.log` seul ;
- sur une fenêtre de 15 s englobant trois exécutions : **rien d'autre** — ni
  `/var/lib/systemd`, ni `/var/cache`, ni `/var/spool`, ni `/var/log/journal` ;
- pendant un `systemctl stop`/`start` en revanche : `/var/log/journal/…`, et une
  paire `systemd-private-*` sous `/tmp` et `/var/tmp`.

`/var` est donc **surveillable** sous un init réel, contrairement à ce qu'un
raisonnement de principe laissait croire. Voir « Corrections », défaut 3.

### Le profil `debian` n'a pas `systemctl`

Mesuré : `command -v systemctl` ne rend rien, `/run/systemd/system` n'existe pas.
C'est ce qui rend le profil ordinaire capable de prouver, à lui seul, que les
refus d'usage tombent **avant** le préflight de dépendance — il n'y a là aucun
`systemctl` pour rendre 1 à la place du 2.

## Commandes exécutées

Les six validations du champ `validation`, relancées après le dernier
changement. Durées arrondies, mesurées sur l'hôte.

| Commande | Code | Durée |
|---|---|---|
| `tests/run.sh lint` | **0** | ~5 s |
| `tests/env/run-in-container.sh -- tests/run.sh lint` | **0** | ~50 s |
| `tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment` | **0** | ~2 min |
| `tests/env/run-in-container.sh -- tests/run.sh environment` | **0** | ~1 min |
| `tests/env/run-in-container.sh --profil systemd -- bash Linux/System/check-services.sh` | **0** | ~40 s |
| `tests/env/run-in-container.sh --profil systemd -- bash Linux/System/check-services.sh --help` | **0** | ~40 s |

Commandes de mesure et de contrôle, hors champ `validation`, toutes dans un
conteneur jetable :

| Commande | Ce qu'elle a établi |
|---|---|
| `--profil systemd -- systemctl list-units --state=running/--state=failed` | l'inventaire des services de l'image, et son instabilité |
| `--profil systemd -- systemctl show` sur cinq unités | les codes et propriétés du tableau ci-dessus |
| `--profil systemd -- systemctl stop/start systemd-logind.service` | le témoin est stable et restituable |
| `-- command -v systemctl` | `systemctl` est absent du profil `debian` |
| `--profil systemd -- check-services.sh --service` × 8 noms | les sept issues, la normalisation, les refus |
| `--profil systemd -- <unité invalide> + daemon-reload` | `LoadState=bad-setting`, septième issue |

## Validations

| Validation | Résultat |
|---|---|
| `bash -n`, 33 fichiers, hôte | **PASS** — 0 erreur |
| `shellcheck`, 33 fichiers, conteneur | **PASS** — 0 erreur sur les fichiers de cette tâche |
| niveau `environment`, profil `systemd` | **PASS** — `check-services.sh` : 286 / 0 / 3 |
| niveau `environment`, profil `debian` | **PASS** — `check-services.sh` : 133 / 0 / 27, fichier en **4** |
| non-régression de `systemd.test.sh` derrière lui | **PASS** — 48 / 0 / 2, inchangé |
| inventaire réel, profil `systemd` | **PASS** — code 0 |
| `--help`, profil `systemd` | **PASS** — code 0 |

Lecture des bilans : *réussites / échecs / non exécutés*. Les 3 et 27 non
exécutés sont tous **sans indisponibilité déclarée** — aucun n'est un
environnement qui a manqué —, ce qui fait sortir le fichier en 4 et non en 3.

Les deux avertissements `shellcheck` du lint conteneurisé portent sur
`Synology/Plex/organize-series.sh` et `update-plex.sh`, scripts hérités déclarés
hors standard, antérieurs à cette tâche.

## Erreurs rencontrées

Le relecteur a rendu **six écarts** au premier passage, dont deux sérieux, et le
rédacteur de tests en a trouvé **trois de plus** dans le script pendant la
correction. Aucun n'aurait été vu par le seul examen des codes de retour : les
six validations étaient déjà vertes.

| # | Écart | Où |
|---|---|---|
| 1 | `--service` répondait « **Service actif** » sur `.timer`, `.socket`, `.target` — unités que l'`out_of_scope` exclut | script |
| 2 | un cas déclaré « non applicable par nature » l'était **à tort** : `--service @` atteint la branche avec le vrai `systemctl` | test |
| 3 | `/var` écarté **en bloc** de la preuve de lecture seule, ce qui retirait `/var/log/mgnetworking` — le seul endroit où le script a le droit d'écrire | test |
| 4 | `--service <unité inconnue>` affichait `État d'exécution : inactive (dead)` | script |
| 5 | `show_help` omettait la septième issue, et le README en listait quatre là où l'aide en documentait six | script + doc |
| 6 | le refus d'un nom à points conseillait `systemctl status ..` pour une valeur qui ne désigne aucune unité | script |
| 7 | `README.md` du domaine : « neuf scripts » pour dix lignes de tableau | doc |
| 8 | la phrase sur `recensement-substitutions.md` ne nommait qu'un des trois scripts non couverts | doc |
| 9 | la septième issue n'apparaissait qu'en commentaire, pas au bilan | test |

### Les deux plus sérieux

**Écart 1 — le script mentait sur ce qu'il diagnostiquait.** Mesuré :

```text
--service systemd-tmpfiles-clean.timer  → code 0  [SUCCESS] Service actif : « …timer »
--service dbus.socket                   → code 0  [SUCCESS] Service actif : « dbus.socket »
--service local-fs.target               → code 0  [SUCCESS] Service actif : « local-fs.target »
```

Un `check-services.sh` qui répond « Service actif » à propos d'un `.target` ment
à son appelant. Ce n'était pas une fonctionnalité offerte — c'était un angle mort
du parsing.

**Écart 2 — une affirmation gratuite dans le harnais.** `saute_par_nature` est
défini dans `tests/lib/assert.sh` comme une **signature** : « l'employer, c'est
déclarer qu'on a examiné ce cas précis et conclu qu'aucune exécution ne le rendra
jamais atteignable ici ». Le fichier de cas l'employait pour une branche que
`--service @` atteint en une commande, avec le vrai `systemctl`, sans aucun faux
binaire. Sur un harnais dont l'objet déclaré est l'honnêteté des verdicts, un cas
prouvable rangé comme improuvable coûte plus cher qu'un cas manquant.

## Corrections automatiques

### Tentative 1 — écarts 1, 2, 3, 7, 8

*Diagnostic.* Trois fautifs distincts, établis avant toute correction :

- **écart 1 : le script.** L'`out_of_scope` de la tâche exclut « les unités
  autres que les services ». Le script y répondait, et répondait faux.
  Correction : un suffixe autre que `.service` est **refusé en 2**, au même
  endroit que la validation de caractères, donc **avant** l'interrogation du
  système. Le 2 découle de l'énoncé, qui le réserve à « ce qu'on reproche à
  l'appelant » : demander à `check-services.sh` l'état d'un timer est une erreur
  d'appel, pas un constat du système ;
- **écart 2 : le test.** Le script n'y est pour rien — c'est la déclaration qui
  était fausse. Remplacée par un cas réel, `--service @` → code 1, message croisé
  par `assert_absent` avec les quatre autres messages du 1 ;
- **écart 3 : le test.** La justification de principe — journald écrit en
  permanence sous un init réel — n'avait pas été **mesurée**. Elle l'a été :
  l'exclusion étroite fonctionne, seuls `$LOG_DIR`, `/var/log/journal`, les nœuds
  de `/tmp` et `/var/tmp` et les `systemd-private-*` bougent. `assert_aucune_ecriture`
  surveille désormais neuf racines, `/var` `/tmp` `/home` comprises, chaque
  exclusion portant sa mesure en commentaire. **Sensibilité vérifiée** par quatre
  écritures délibérées, toutes remontées.

*Effet de bord de la correction 1, non anticipé et bénéfique* : le refus des
unités non-service tombant avant `require_cmd systemctl`, il est **exécutable
sous le profil `debian`**. Le groupe des cas inconditionnels est passé de 6 à 10.

### Tentative 2 — écarts 4, 5, 6

Tous trois de la même famille : **le script affirmait des choses qui n'étaient
pas vraies.** Aucun test n'était en cause.

- afficher `inactive (dead)` pour `cron.service` absent de l'image, c'est dire
  « le service existe, il est arrêté ». Un administrateur qui lit ces cinq lignes
  avant d'arriver au `[ERROR]` conclut de travers. La ligne affiche désormais
  « non disponible » quand `LoadState` vaut `not-found` — et **conserve**
  `inactive (dead)` pour une unité masquée, qui, elle, existe ;
- la septième issue a été ajoutée à l'aide et au README, et le décompte de la
  phrase qui les introduit corrigé ;
- le refus d'un nom à points est départagé : suffixe d'un type connu d'un côté,
  conseil `systemctl status` conservé ; chaîne qui n'est une unité d'aucun type
  de l'autre, message neuf sans conseil inapplicable.

### Tentative 3 — réalignement des assertions

*Diagnostic : le test a tort.* Deux assertions rouges après la tentative 2, toutes
deux épinglant une formulation que la correction venait de changer
délibérément — la section « Codes de retour » de l'aide, réenroulée, et le
message de refus d'un nom à points.

Le réalignement a été l'occasion de **resserrer** : l'aide est désormais assertée
sur des fragments stables plutôt que sur des lignes soumises à l'enroulement, les
sept issues sont vérifiées une par une avec leur code, et la phrase qui les
compte est assertée elle aussi — une huitième ligne ne pourra pas entrer dans le
tableau sans que le compte suive.

Le rédacteur a éprouvé ses propres assertions **par mutation du script**, en le
restaurant à l'identique à chaque fois : quatre mutations, de 2 à 4 assertions
rouges chacune. Une assertion qui reste verte sous la mutation qu'elle prétend
attraper est une assertion creuse.

### Écart 9 — corrigé sans délégation

La branche « unité non chargée » n'était signalée que par un commentaire. Le
groupe 8 du fichier pose pourtant lui-même que taire un cas non prouvé « ferait
croire à une couverture complète » : les sept lignes vertes de l'aide se lisaient
comme sept comportements prouvés, alors que six seulement le sont.

Déclarée au groupe 8 par un **`saute` neutre**, mesure à l'appui — et non par
`saute_par_nature`, qui aurait été une seconde signature mensongère : ce qui
écarte ce cas est une décision de périmètre, pas une limite de nature.

Correction faite directement plutôt que déléguée : elle n'aide aucune assertion à
passer, elle ajoute un non-exécuté au bilan. Les compteurs sont passés de 2 à 3
sous `systemd`, de 26 à 27 sous `debian` ; les deux fichiers restent en 4.

### Ce qui n'a été neutralisé nulle part

Aucun `|| true`, `set +e`, assertion commentée ni validation retirée sur un
chemin d'assertion — vérifié par le relecteur, deux fois. Les dix `|| true` du
fichier de cas sont dans le filet `EXIT`, le nettoyage du groupe 7, la création
de liens du bac à sable et le sondage d'environnement. Le champ `validation` de
la tâche porte ses six commandes d'origine, inchangées.

## Tentatives

**3 / 5.**

## Critères d'acceptation

- [x] le script s'exécute sans privilège et rend 0 lorsqu'il se contente d'inventorier
- [x] il affiche le nombre et la liste des services actifs, et la liste des services en échec, celle-ci en évidence
- [x] un service en échec ne change pas le code de retour du mode inventaire
- [x] avec `--service <nom>`, il affiche l'état d'activation, l'état d'exécution et la date du dernier démarrage
- [x] avec `--service <nom>`, il rend 0 si le service est actif et 1 sinon, en distinguant les cas par le message
- [x] `--service` sans valeur rend 2, comme toute option inconnue
- [x] un nom de service manifestement invalide rend 2 avant toute interrogation du système
- [x] l'absence de `systemctl` rend 1 avec un message nommant la dépendance
- [x] le script n'écrit rien en dehors du journal ouvert par `lib/common.sh`
- [x] `--help` documente les options, les issues de `--service` et les codes de retour
- [x] le fichier de cas conserve sous le profil `debian` au moins un cas exécutable sans systemd — 133, et le niveau y sort en 4
- [x] sous le profil `systemd`, les cas nominaux sont réellement exécutés — témoin arrêté → 1, relancé → 0

Deux précisions sur la façon dont deux d'entre eux sont établis :

- **« sans privilège »** n'est pas exécuté sous un compte ordinaire : la preuve
  est l'absence de `require_root`, avec exécution réelle du « rend 0 ». C'est le
  standard posé par TASK-021 pour `check-disk.sh` ;
- **« nom manifestement invalide »** est lu comme un filtre de **caractères**,
  auquel s'ajoute depuis la tentative 1 le refus des suffixes non-`.service`. Un
  nom bien formé mais absurde — `foo.bar` — sort en 1 et non en 2 :
  l'inexistence est un constat du système, pas une faute d'appel. La règle est
  écrite à l'identique dans `--help` et dans le README du domaine.

## Ce qui n'est pas prouvé, et pourquoi

Trois cas, tous **déclarés au bilan** du groupe 8 et non tus.

| Cas | Nature du saut | Raison |
|---|---|---|
| les branches dégradées des deux `list-units` de l'inventaire | **par nature** | mesuré : une adresse de bus inexistante ne suffit pas, `systemctl` passe par `/run/systemd/private` et rend 0. Seul un faux `systemctl` y mènerait, et il couperait toutes les mesures de contrôle indépendantes du fichier |
| l'état `degraded` et le nombre d'unités en échec de l'image | **neutre** | propriété de l'image, pas limite de nature — `getty@tty1` est instable |
| la septième issue, « unité non chargée » | **neutre** | atteignable, mesurée à `bad-setting` ; l'éprouver demanderait une seconde unité fabriquée et un second chemin de restitution. Aucun critère ne l'exige |

## Validation finale

**PASS** — verdict `CONFORME` du relecteur au second passage, sur l'état courant,
validations relancées par lui.

## Git

Branche : `agent/TASK-023`
Commit : voir l'historique de la fusion `--no-ff` dans `master`.

**Réserve consignée sur l'état de l'arbre.** L'arbre n'était pas propre au
démarrage : `.agents/` et `.codex/` étaient présents en non suivis, antérieurs à
la session, hors du périmètre de cette tâche. `AGENTS.md` §9 et §13.6 imposaient
l'arrêt ; Maxime a arbitré la poursuite avec des **commits par chemin**. Aucun
`git add -A` n'a été employé : les deux répertoires sont restés non suivis et
intouchés.

## Résumé

`check-services.sh` est le dixième script de `Linux/System`, et le troisième
diagnostic en lecture seule après `check-disk.sh` et `check-memory.sh`. C'est
aussi **le premier script du dépôt dont la preuve n'existait nulle part avant
TASK-020** : le profil `debian` n'a pas d'init, et une exécution n'y franchissait
pas le préflight.

Ce que la tâche a établi au-delà d'elle-même : `systemctl show` est le seul appel
qui distingue les issues d'une interrogation d'unité — `is-active` les confond
toutes en un code 3 —, le profil `systemd` n'est pas déterministe et aucune
assertion ne peut porter sur son état global, et `/var` reste surveillable sous
un init réel à condition d'exclure nommément ce qui bouge.

Le cycle complet a payé : les six validations étaient vertes avant la première
relecture, et le relecteur a trouvé un script qui répondait « Service actif » à
propos d'un `.target`, et un fichier de cas qui déclarait improuvable un cas
qu'une seule commande atteint.
