# Points en suspens

Sujets identifiés pendant le développement et écartés pour ne pas interrompre la
production des scripts. À traiter avant la fin du chantier.

---

## 1. Mise en place de `update-system.sh` en tâche planifiée — traité

**Soulevé le** 2026-08-26.
**Converti en tâche le** 2026-08-27 : [TASK-009](../tasks/completed/TASK-009.md).
**Traité le** 2026-08-31 par TASK-009 : `Linux/System/configure-cron.sh`.
Le texte ci-dessous est conservé tel quel — il reste la référence du contenu
déposé. Les décisions prises sont consignées à la fin de la section.

Le script est destiné à tourner par `cron`. Trois éléments conditionnent son
fonctionnement dans ce cadre.

### Cron n'utilise pas `sudo`

Il lance directement sous l'utilisateur indiqué. Deux façons de faire :

```bash
sudo crontab -e     # crontab de root : tout y tourne en root
```

ou, préférable car explicite et versionnable, un fichier dédié :

```
# /etc/cron.d/mgnetworking
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 4 * * 1 root /opt/mgnetworking/Linux/System/update-system.sh --yes >/dev/null 2>&1
```

Le champ `root` placé après l'horaire remplace le `sudo`.

### `--yes` est obligatoire

Cron n'a pas de terminal. Sans cette option, le script attendrait une réponse à
la confirmation, indéfiniment.

### La sortie doit être redirigée

Cron envoie par courriel tout ce qu'un travail écrit. Sans `>/dev/null 2>&1`, la
sortie complète d'`apt` serait expédiée à chaque exécution — ou produirait des
erreurs si aucun serveur de messagerie n'est configuré. La trace est déjà dans
`/var/log/mgnetworking/update-system.log`.

**Reste à faire** : décider de l'emplacement de déploiement et de l'horaire,
puis écrire le fichier `/etc/cron.d/`. Éventuellement un script
`Linux/System/configure-cron.sh` qui l'installe, sur le modèle de
`configure-logging.sh`.

### Ce qui a été fait, et ce qui a été décidé

`Linux/System/configure-cron.sh` dépose `/etc/cron.d/mgnetworking` sur le modèle
de `configure-logging.sh` : lecture de l'état, comparaison, écriture seulement
si nécessaire, `--dry-run`, confirmation avant tout remplacement.

Les deux décisions que le point laissait ouvertes :

| Décision | Valeur retenue | Pourquoi |
|---|---|---|
| emplacement de déploiement | aucun — le chemin est résolu à l'exécution par `SCRIPTS_ROOT` | `/opt/mgnetworking` n'est qu'un exemple du README ; l'écrire en dur casserait tout autre déploiement |
| horaire | `0 4 * * 1`, tous les lundis à 4 h, surchargeable par `SRV_CRON_UPDATE_SYSTEM` puis par `--horaire` | hebdomadaire comme la rotation des journaux, hors des heures d'activité, et en début de semaine : cinq jours ouvrés pour réagir à ce qui a cassé |

Deux pièges de `/etc/cron.d`, vérifiés par le script plutôt que supposés : un nom
de fichier comportant un point est ignoré en silence, et un fichier qui
n'appartient pas à root ou qui porte le bit d'exécution est rejeté.

La redirection retenue est `>/dev/null` **sans** `2>&1` : c'est précisément ce
qui laisse ouverte la première piste du point n° 2 ci-dessous.

---

## 2. Un échec en tâche planifiée passe inaperçu — tranché

**Soulevé le** 2026-08-26, conséquence directe du point 1.
**Indexé au backlog le** 2026-08-27 : [tasks/backlog.md](../tasks/backlog.md) §3.
**Tranché le** 2026-09-02 par
[ADR-0003](agent/decisions/ADR-0003-cadrage-execution-autonome.md), décision 15 :
**un script de notification appelé en cas d'échec**, émettant vers `ntfy` ou un
webhook dont l'URL vit dans un `.env` non versionné.

C'est la seule des trois pistes qui alerte activement, au moment de l'échec, sans
supposer un serveur de messagerie configuré sur la machine — hypothèse rarement
vraie sur un VPS. Le contrôle de fraîcheur, lui, reste passif : il faut que
quelque chose le lise.

Le texte ci-dessous est conservé tel quel : il reste l'énoncé de référence du
problème et des options écartées.

**Le problème.** Avec la sortie jetée vers `/dev/null`, une mise à jour qui
échoue ne prévient personne. Le code de retour est correct et le journal
contient l'erreur, mais rien ne remonte. Un serveur peut rester sans mise à jour
pendant des mois sans que cela se voie.

**État au 2026-08-31.** La ligne déposée par TASK-009 ne redirige que la sortie
standard : la première piste ci-dessous est donc en place à titre conservatoire,
sans avoir été choisie. Elle ne suffit pas — elle suppose un serveur de
messagerie configuré et un courriel effectivement lu. Le choix entre les trois
pistes reste entier.

**Pistes.**

- Ne rediriger que la sortie standard (`>/dev/null`) et laisser cron transmettre
  les erreurs par courriel.
- Un script de notification appelé en cas d'échec — courriel, webhook, ntfy.
- Un script de contrôle exécuté séparément, vérifiant la fraîcheur du dernier
  journal.

**Concerne** tous les scripts destinés à `cron` : `update-system.sh`,
`security-check.sh`, `backup-resources.sh`, `docker-cleanup.sh`.

---

## 3. Le harnais confond « non applicable » et « indisponible » — traité

**Soulevé le** 2026-08-29, pendant [TASK-012](../tasks/completed/TASK-012.md).
**Traité le** 2026-09-01 par TASK-013. Le texte ci-dessous est conservé tel
quel — il reste la mesure de référence du défaut. Ce qui a été fait est consigné
à la fin de la section.

**Le problème.** Depuis TASK-012, un fichier de cas qui réussit tout ce qu'il a
pu exécuter, en déclarant quelques cas non applicables, sort en 4 — preuve
partielle — et `tests/run.sh` traduit ce 4 en 0. Le garde qui empêche le faux
vert est qu'un 4 exige **au moins une réussite**.

Cette garantie est plus faible qu'elle n'en a l'air. Mesuré avec le démon Docker
coupé, Docker Desktop jamais arrêté :

```text
DOCKER_HOST=tcp://127.0.0.1:1 bash tests/acceptance/TASK-011-analyse-statique.sh
Bilan TASK-011 : 8 réussite(s), 0 échec(s), 21 NON EXÉCUTÉ(s)   → 4
tests/run.sh acceptance                                          → 0
```

72 % de la preuve avait disparu, le verdict restait vert. Sur `master` avant
TASK-012, ce même scénario rendait 3, donc 1 : c'est donc une régression sur
l'axe de l'honnêteté, consentie en échange de la levée d'un blocage qui frappait
toutes les tâches.

**La cause.** Les compteurs ne distinguent pas deux natures de saut :

| Nature | Exemple | Ce que ça devrait valoir |
|---|---|---|
| non applicable par nature | le profil `debian` n'a pas `systemd`, il ne l'aura jamais | 4 légitime |
| environnement indisponible | le démon Docker est coupé, la preuve existe mais n'a pas pu être produite | 3 — rien n'est prouvé |

Tout tombe aujourd'hui dans le même compteur, et quelques cas de préflight — qui
n'ont besoin de rien — suffisent à franchir le seuil.

**Le remède connu.** Un compteur `indisponibles` distinct de `non_executes`,
avec la règle `indisponibles > 0 → 3`. Il impose de revoir chaque appel `saute`
de chaque fichier de cas pour qualifier la nature du saut — ce que le périmètre
de TASK-012 excluait nommément.

**Concerne** tout le niveau `acceptance`, et les niveaux `unit`, `integration`
et `environment` le jour où ils existeront.

### Ce que TASK-013 a fait

Le remède connu a été appliqué tel quel : un compteur `indisponibilites`
distinct, alimenté par une seconde fonction de saut, avec la règle
`indisponibilites > 0 → 3`. Les vingt-cinq appels `saute` des trois fichiers de
cas ont été relus un par un et qualifiés ; le fichier de cas conteneurisé de
TASK-011 a reçu un verdict `INDISPO` en plus de son `SKIP`, faute de quoi ses
sauts arrivaient sans leur nature.

Le scénario mesuré ci-dessus donne désormais :

```text
DOCKER_HOST=tcp://127.0.0.1:1 bash tests/acceptance/TASK-011-analyse-statique.sh
Bilan TASK-011 : 8 réussite(s), 0 échec(s), 21 NON EXÉCUTÉ(s)
                 — dont 9 non applicable(s) par nature et 12 indisponibilité(s)  → 3
DOCKER_HOST=tcp://127.0.0.1:1 tests/run.sh acceptance                            → 3
```

Ni `tests/run.sh` ni `run-acceptance.sh` n'ont eu à changer de logique : ils
lisaient déjà le 3 sans le maquiller. Seuls leurs messages ont été précisés.

---

## 4. Les six contrôles de forme de TASK-011 n'ont plus d'objet — tranché

**Soulevé le** 2026-09-01, pendant TASK-013.
**Tranché le** 2026-09-02 par
[ADR-0003](agent/decisions/ADR-0003-cadrage-execution-autonome.md), décision 13 :
**le §1 est retiré**, deuxième des trois voies ci-dessous.

`tests/README.md` §1 annonçait déjà sa disparition, et le niveau `integration`
est le domicile durable de ces preuves. Six `NON EXÉCUTÉ` permanents finissent
par être ignorés — c'est exactement le bruit qui masque un vrai problème.

`tests/acceptance/TASK-011-analyse-statique.sh` §1 compare le diff de six
fichiers avec `REF_AVANT`, qui vaut `HEAD` par défaut. Les corrections de
TASK-011 étant commitées depuis le 2026-08-29, `git diff HEAD` est vide sur un
arbre propre : les six contrôles sortent en `NON EXÉCUTÉ` à chaque exécution, et
ne reviendront jamais d'eux-mêmes.

TASK-013 les a qualifiés **non applicables par nature** — rien n'a manqué, c'est
l'objet de la comparaison qui a disparu, par construction et tant que la
référence reste `HEAD` sur un arbre propre. La justification longue est écrite
sur place, dans le fichier de cas.

**La réserve.** C'est le seul saut du harnais dont la nature ait demandé à être
tranchée, et l'argument contraire s'entend : la preuve reste *rejouable* ici, en
fixant `TASK011_REF` sur le commit antérieur. Ce qui manque n'est pas une pièce
de l'environnement mais un paramètre du test — d'où la qualification retenue,
qui ne dépend pas du verdict qu'elle produit.

**Ce qu'il faudrait décider.** Trois voies, aucune ne relevant de TASK-013 :

- inscrire dans le fichier de cas le commit de référence réel, ce qui rendrait
  les six contrôles exécutables à nouveau — mais gèlerait un identifiant de
  commit dans un test ;
- retirer le §1, dont `tests/README.md` §1 annonce déjà qu'il disparaîtra avec
  TASK-011, le niveau `integration` étant le domicile durable de ces preuves ;
- le laisser tel quel, six `NON EXÉCUTÉ` visibles à chaque exécution.

**Concerne** `tests/acceptance/TASK-011-analyse-statique.sh` §1, et tout futur
fichier de cas qui prétendrait contrôler un diff après son commit.

---

## 5. Le coût du dispositif agentique — tranché

**Soulevé le** 2026-09-02, au terme de la session qui a produit la couche
agentique et les dix premières tâches.
**Tranché le** 2026-09-02 par
[ADR-0003](agent/decisions/ADR-0003-cadrage-execution-autonome.md), décisions 5
et 6 : **mode léger pour les scripts qui ne modifient rien** — lecture seule et
corrections documentaires — et **rapport court par défaut**.

L'arbitrage énoncé plus bas a été suivi à la lettre : le mode léger s'arrête là
où un script commence à écrire sur un système. Le relecteur reste obligatoire
pour tout script qui modifie, et sans exception pour `lib/common.sh`. On rogne où
le contrôle protège le moins.

Les deux autres pistes — prompts de délégation resserrés, pas de relecture sur
les corrections documentaires — sont absorbées par ces deux décisions.

**Le constat.** Les sous-agents ont consommé environ **3,3 millions de jetons**
pour dix tâches — de l'ordre de 300 000 par tâche, davantage pour celles qui ont
demandé plusieurs tours de correction.

### D'où vient le coût

**Un sous-agent démarre à froid.** Il ne connaît pas la conversation : c'est ce
qui le rend fiable, et c'est ce qui coûte. Il relit à chaque invocation
`AGENTS.md`, `CLAUDE.md`, la tâche, les fichiers concernés. Le cycle en fait
travailler trois au minimum, souvent cinq ou six avec les corrections.

### Ce que ce coût achète, et qu'il faut se garder de rogner

**La vérification par mutation** est le poste le plus cher et le plus utile. Sur
TASK-003, le rédacteur des tests a cassé `lib/common.sh` de quinze façons pour
vérifier que ses assertions détectent ; le relecteur a refait l'exercice avec
huit mutations à lui. C'est ce qui sépare « les tests passent » de « les tests
prouvent ».

**Les relectures ont payé à chaque fois.** Elles ont trouvé une garde de
dépendance qui ne gardait rien, une ligne cron qui aurait échoué à chaque
passage en production, une documentation affirmant un arrêt qui n'avait pas
lieu, et une sur-affirmation introduite par la tâche même censée les retirer.
Aucun de ces défauts n'aurait été vu autrement.

### Ce qui était excessif

- **les prompts de délégation** font soixante à cent lignes, et recopient du
  contexte que le sous-agent pourrait lire lui-même ;
- **les rapports** font deux à trois cents lignes. Le format de
  `tasks/README.md` §6 en demande peut-être trop pour une tâche sans histoire ;
- **trois tours de correction sur des commentaires**, lors de TASK-013 : le
  troisième aurait pu attendre le backlog ;
- **des suites relancées sans nécessité**, dont une exécution de six minutes
  lancée deux fois dans un même appel, qui a dépassé le délai.

### Pistes, non décidées

| Piste | Économie estimée |
|---|---|
| un **mode léger** — rédacteur et validations, sans relecteur — pour les tâches sans risque : scripts en lecture seule, corrections documentaires | ~40 % |
| rapport court par défaut, long seulement si la tâche a bloqué ou révélé un défaut | ~15 % |
| ne pas faire relire les corrections purement documentaires | ~10 % |
| prompts de délégation resserrés | ~10 % |

**L'arbitrage à tenir.** Le mode léger est la piste la plus rentable et la plus
dangereuse : c'est le relecteur qui a trouvé tous les défauts sérieux de cette
session. L'ouvrir aux tâches sans risque se défend ; l'ouvrir aux tâches qui
touchent un script d'administration reviendrait à supprimer le seul contrôle
indépendant du dispositif.

**Concerne** `.claude/commands/tache.md`, `tasks/README.md` §6, et la décision
d'ouvrir ou non un second cycle allégé.

---

## 6. `LOG_DIR` n'est validé par personne

**Soulevé le** 2026-09-02, pendant TASK-018, en recensant les substitutions de
commande de `Linux/System`.

Les scripts valident les valeurs qu'ils reçoivent — nom d'hôte, fuseau, taille
de swap, horaire de cron, chemin de `--file`. `LOG_DIR`, lue par `lib/common.sh`
dans `config/server.env`, ne l'est par aucun d'eux.

Une valeur commençant par un tiret traverse le socle sans bruit : `mkdir -p` y
échoue dans un `if … 2>/dev/null`, ce qui vide simplement `LOG_FILE`. Elle
ressort à la ligne 26 de `configure-logging.sh` :

```bash
NOM_REGLE="$(basename "$REPERTOIRE_LOGS")"
```

`basename` prend le tiret pour une option, l'affectation échoue, et le `trap ERR`
parle deux fois — dans le sous-shell puis dans le shell principal.

**Le doublement a été traité le 2026-09-03**, au cinquième tour de TASK-018 :
l'affectation est passée en contexte de condition, avec un diagnostic qui nomme
la valeur fautive et son origine. **Le fond ne l'est pas**, et c'est l'objet de
ce point : personne ne valide `LOG_DIR`. Le remède local (`basename --`) ne
ferait que déplacer le problème — une règle logrotate serait alors déposée pour
un chemin qui n'a pas de sens —, et la valeur fautive n'est toujours atteignable
par aucune ligne de commande : elle suppose un `server.env` écrit à la main.

**Ce qu'il faudrait décider.** Où valider les valeurs de `config/server.env` :
dans `lib/common.sh` au chargement — mais le socle refuserait alors de démarrer,
ce qui est lourd —, dans une fonction de vérification appelée par les scripts
concernés, ou dans un script de contrôle dédié à la configuration.

**Concerne** `LOG_DIR` en premier, et toute variable de `config/server.env`
qu'un script consomme sans la regarder.

---

## 7. `fuseau_actuel` reste appelée dans une substitution de commande — traité

**Soulevé le** 2026-09-02, pendant TASK-018, deuxième tour — le recensement du
premier ne les avait pas nommées.
**Traité le** 2026-09-02 par TASK-018, troisième tour. Le texte ci-dessous est
conservé tel quel, y compris son arbitrage — que la mesure a démenti. Ce qui a
été fait est consigné à la fin de la section.

`Linux/System/configure-timezone.sh` appelle `fuseau_actuel` deux fois dans une
substitution de commande, aux lignes 161 et 210 :

```bash
FUSEAU_ACTUEL="$(fuseau_actuel)"
FUSEAU_VERIFIE="$(fuseau_actuel)"
```

C'est le motif exact que TASK-018 a défait ailleurs : une fonction appelée dans
une substitution, dont l'échec ferait parler le `trap ERR` deux fois — dans le
sous-shell puis dans le shell principal pour l'affectation.

**Ce qui rend l'échec improbable, et ce qui ne le rend pas impossible.** Chaque
branche de la fonction se termine par un `return 0` explicite, et la dernière
rend `inconnu` plutôt que d'échouer. Mais `errexit` n'attend pas ces `return` :
un `tr -d '[:space:]' < /etc/timezone` en erreur d'entrée-sortie, ou un
`readlink -f /etc/localtime | sed …` dont un ancêtre du chemin a disparu, tuent
le sous-shell avant. Le `[ -r /etc/timezone ]` qui précède ne l'interdit pas —
il établit l'état à l'instant du test, comme le `[ -f ]` de `configure-cron.sh`,
qui n'a pas suffi à dispenser du traitement.

**Pourquoi ce n'est pas traité.** Aucune ligne de commande ni aucune variable
d'environnement n'atteint ces causes : elles supposent une erreur matérielle ou
une modification de `/etc` pendant l'exécution. La correction — une fonction qui
renseigne une globale — toucherait deux branches réellement empruntées par le
profil de test `debian`, dont le repli `/etc/localtime`, sans qu'aucun cas ne
puisse en éprouver la régression.

**Ce qu'il faudrait décider.** Appliquer le motif partout où il apparaît, y
compris là où l'échec n'est pas atteignable — au prix de corrections qu'aucun
test ne verra — ou s'arrêter aux sites dont une cause d'échec s'atteint. Le
même arbitrage vaut pour le point n° 6 ci-dessus.

**Concerne** `configure-timezone.sh` lignes 161 et 210.

### Ce que le troisième tour de TASK-018 a fait

L'arbitrage ci-dessus reposait sur une prémisse fausse : « chaque branche se
termine par un `return 0` explicite » était présenté comme ce qui rendait
l'échec inoffensif. C'est au contraire ce qui le rendait invisible. Sous un `tr`
en échec, `fuseau_actuel` rendait **0 malgré son échec** — le `return 0` effaçait
le code du `tr` — et l'appelante recevait une chaîne vide dont elle ne se
défiait pas : le script appliquait le fuseau et le comparait à cette valeur-là.
Le défaut n'était donc pas une ligne de trap en trop, mais une décision prise
sur rien.

La cause était atteignable, contrairement à ce qui est écrit plus haut : un faux
`tr` en tête de `PATH` suffit, et c'est ce que le cas d'intégration fait.

`fuseau_actuel` renseigne désormais `FUSEAU_ACTUEL`, lit chaque source en
contexte de condition, dit celle qui a flanché, passe à la suivante, et propage
son échec quand aucune n'a répondu — avertissement et valeur `inconnu` au
premier appel, arrêt à la vérification.

**Ce que ce point laisse pour la suite.** L'arbitrage général qu'il posait —
appliquer le motif jusque là où l'échec n'est pas atteignable, ou s'arrêter aux
sites dont une cause s'atteint — n'est pas tranché pour autant. Il reste ouvert
au point n° 6, et la leçon de ce tour-ci est qu'un site est présumé atteignable
tant qu'on n'a pas cherché la mutation qui l'atteint.

---

## 8. Six affectations restent en forme nue dans `Linux/System` — traité

**Soulevé le** 2026-09-02, pendant TASK-018, quatrième tour, par le recensement
écrit que les trois tours précédents n'avaient pas produit.
**Traité le** 2026-09-03 par TASK-018, cinquième tour : les six sites sont
fermés et le `dirname` est tranché. Le texte ci-dessous est conservé tel quel ;
ce qui a été fait est consigné à la fin de la section.

Le relevé exhaustif est dans
[Linux/System/recensement-substitutions.md](../Linux/System/recensement-substitutions.md) :
54 affectations `var="$(…)"`, chacune avec son verdict. Six restent en forme
nue avec une cause atteignable — un binaire homonyme en tête de `PATH` —, et
n'ont pas été traitées parce que le périmètre du tour était borné aux cinq sites
mesurés par le relecteur :

`configure-hostname.sh:246`, `configure-swap.sh:435`, `:436`, `:743`, `:746`,
`configure-logging.sh:26` (déjà décrit au point n° 6 ci-dessus).

S'y ajoutent deux réserves d'une autre nature, détaillées dans le recensement :
le `dirname` laissé nu de `configure-swap.sh:536`, dont la raison écrite couvre
l'absence de la commande mais pas son échec, et le `restant=` d'`update-system.sh:133`,
où `|| true` empêche le doublement mais laisse une chaîne vide au test
arithmétique qui suit.

**Ce qu'il faudrait décider**, et c'est l'arbitrage laissé ouvert par les points
n° 6 et n° 7 : traiter la forme partout où elle apparaît, ou seulement là où une
cause s'atteint. Trois tours ont montré qu'une cause jugée inatteignable ne
l'était pas.

**Reste aussi à mesurer** ce que produit exactement une substitution en échec en
**position d'argument**. Qu'elle n'interrompe pas le script est établi, et c'est
ce qui borne le périmètre ; qu'elle n'écrive aucune ligne de trap ne l'est pas —
le sous-shell d'une substitution héritant du `trap ERR` par `set -E`, une ligne
orpheline est plausible. Trois lignes de Bash suffisent à trancher.

**Concerne** `Linux/System/recensement-substitutions.md` et les six sites cités.

### Ce que le cinquième tour de TASK-018 a fait

Les six sites sont fermés — `configure-hostname.sh:246`, `configure-swap.sh:435`,
`:436`, `:743`, `:746`, `configure-logging.sh:26`, numéros du 2026-09-02.
Cinq sont passés en contexte de condition ; le sixième, la seconde substitution
`date` de la boucle de désambiguïsation de `configure-swap.sh`, a été **supprimé**
— l'horodatage est désormais lu une fois et suffixé, comme dans
`configure-hostname.sh`.

La raison qui figurait en face de chacun — « hors des cinq sites bornés pour ce
tour » — était un périmètre auto-décrété, pas une raison technique. C'est ce que
la relecture a nommé un abandon déguisé, et le critère d'acceptation ajouté à la
tâche le formule désormais : aucun site en forme nue avec une cause atteignable
sans que la raison technique du non-traitement soit écrite.

**Le `dirname` nu de `configure-swap.sh` est tranché** : il passe en condition
comme les autres. L'argument qui le dispensait — « l'absence de `dirname` est
exclue par le fait que le script démarre » — couvre l'absence et non l'échec, et
ne vaut même pas pour l'absence, `config/server.env` étant chargé par le socle
*après* les lignes de résolution et pouvant redéfinir `PATH`. L'autre issue —
acter que la forme nue est admise pour les commandes appelées avant le socle —
aurait posé une règle que le code contredit à dix-huit endroits. Le raisonnement
complet est au §11.1 du recensement.

**Ce que ce point laisse pour la suite.** Deux réserves d'une autre nature, qui
ne sont pas des doublements : la validation de `LOG_DIR`, qui reste entière au
point n° 6 ci-dessus, et `update-system.sh:133`, où `|| true` laisse une chaîne
vide au test arithmétique de la ligne suivante.

La mesure attendue sur les substitutions **en position d'argument** avait déjà
été faite au quatrième tour : trois sondes en conteneur, consignées au §1 du
recensement. Une substitution en échec y est sans effet — aucune ligne de trap,
script poursuivi, code 0 — ce qui borne le périmètre à la forme `var="$(…)"`.

---

## 9. `--privileged` sur le profil de conteneur `systemd`

**Soulevé le** 2026-09-03, pendant TASK-020, par le relecteur.

Le profil `systemd` est lancé avec `--privileged`. L'option est justifiée dans le
script et dans `tests/README.md` par un besoin réel — systemd crée un cgroup par
unité, et `/sys/fs/cgroup` est monté en lecture seule pour un conteneur
ordinaire — mais **personne n'a démontré qu'elle soit indispensable**. Le
rédacteur l'écrit lui-même : c'est la seule option dont il doute au sens
« peut-être trop large ».

Mesuré : le profil démarre en 1 à 2 secondes avec `--privileged` et
`--tmpfs /run`. Les deux recettes classiques ont été écartées avec leur raison —
le montage cgroup v1 est un contresens en v2, et `--cgroupns=host` exposerait
toute l'arborescence de cgroups de l'hôte. Ce qui n'a **pas** été essayé est
l'alternative étroite : `--cap-add SYS_ADMIN` assorti des `--security-opt`
nécessaires.

**Pourquoi ce n'est pas urgent.** Le conteneur est jetable, ne porte aucun
secret, et ne monte que le dépôt. Il ne tourne que sur la machine de
développement, jamais sur un serveur.

**Pourquoi ça mérite d'être écrit.** Un choix non prouvé qui n'est consigné nulle
part se re-décide à l'aveugle. Le jour où quelqu'un voudra resserrer les droits
de ce conteneur — ou l'exécuter dans une CI qui refuse `--privileged` — la
question se reposera entière, et la mesure qui la tranche n'aura pas été faite.

**Concerne** `tests/env/run-in-container.sh`, mode `systemd` uniquement. Le
profil `debian` ne demande aucun privilège particulier.

---

## 10. `df` se fige sur un montage réseau injoignable

**Soulevé le** 2026-09-03, pendant TASK-021, qui l'excluait nommément de son
périmètre.

`Linux/System/check-disk.sh` appelle `df` sans précaution contre le montage
réseau tombé. Un partage NFS ou CIFS dont le serveur ne répond plus fige l'appel
à `statfs` : `df` n'échoue pas, il **attend**, et le script attend avec lui — sans
message, sans borne de temps, et sans que la garde en contexte de condition n'y
change quoi que ce soit, puisque rien n'a échoué.

Le script ne modifie rien et n'a pas encore écrit sa première section : la
conséquence est un terminal bloqué, pas un système abîmé. Elle devient sérieuse
le jour où `check-disk.sh` tourne en tâche planifiée.

**Pourquoi ce n'est pas traité dans TASK-021.** Le sujet mérite un traitement
propre, pas une demi-mesure glissée dans un script de diagnostic. Deux remèdes
connus, aux effets très différents :

- **`df -l`** — ne montrer que les systèmes de fichiers locaux. Sûr, mais il
  supprime l'information au lieu de la borner : un partage réseau plein ne serait
  plus jamais vu, alors que c'est un incident réel ;
- **une borne de temps** — `timeout 5 df …`. Elle conserve l'information quand le
  montage répond et rend la main quand il ne répond pas, au prix d'une dépendance
  à `timeout` (coreutils, présent sur les cibles) et d'un choix de valeur qui,
  comme toutes les bornes de ce dépôt, devra être mesuré plutôt que jugé.

**Concerne** `check-disk.sh` en premier, et tout futur script appelant `df`,
`du` ou `stat` sur une arborescence susceptible de contenir un montage réseau —
`check-services.sh`, `backup-resources.sh`.

### Une seconde valeur non mesurée, dans le même fichier

Le même travail a posé des bornes de temps sur les appels Docker du mode
`systemd`. Quatre valeurs y sont écrites : 10 s par sondage, 30 s pour le
lancement détaché, 5 s pour le chemin de sortie, 60 s de plafond — soit 165 s au
pire avant que la main soit rendue.

Trois de ces valeurs bornent des appels dont le nominal a été mesuré et se compte
en fractions de seconde. **Celle de 30 s ne l'est pas** : le `docker run -d`
nominal a été mesuré à moins d'une seconde, mais le cas défavorable *légitime* —
hôte chargé, premier montage du dépôt après un redémarrage de Docker Desktop — ne
l'a pas été. Trente secondes est donc un jugement, pas une mesure.

Le dépôt s'est donné pour règle qu'une propriété se mesure. La valeur est
consignée ici comme jugement, pour qu'un faux positif — une exécution légitime
abandonnée à 30 s sur une machine lente — soit reconnu pour ce qu'il est : la
borne à réviser, et non une panne du démon.

---

## 11. Docker Desktop tombé bloque tout, et rien ne peut le relever

**Soulevé le** 2026-09-04, pendant TASK-027.

Toute validation comportementale de ce dépôt passe par un conteneur. Si Docker
Desktop est arrêté ou en panne, **aucun niveau au-dessus de `lint` ne peut
s'exécuter** — ni `unit`, ni `integration`, ni `environment`, ni la moitié de
l'`acceptance`. L'agent s'arrête et le signale, conformément à `AGENTS.md` §7.

**Ce qui a été tenté, et mesuré.** TASK-027 devait rendre l'agent capable de
démarrer Docker Desktop lui-même. Deux tentatives réelles le 2026-09-04 :

```text
15:50:32  Démarrage (tentative 1/2)
15:50:45  Processus présent après 14s
15:51:15  Le processus a disparu après 46s
15:51:16  Démarrage (tentative 2/2)
15:51:28  Processus présent après 13s
15:54:43  Le processus a disparu après 253s        -> plafond, code 3
```

Journaux de Docker Desktop 4.51.0 : `eventErrorDialog`, puis
`bind: {"action":"Quit"}`, puis `com.docker.backend.exe services: exit status
150`. Le service `com.docker.service` était `Stopped`, en démarrage `Manual`.

**Le fait décisif** : lancé à la main, Docker Desktop démarre sans afficher la
moindre erreur. Le défaut ne tient donc pas à Docker mais au **contexte de
lancement** — `Start-Process` depuis la session de l'agent ne fournit pas ce que
Docker Desktop attend, élévation ou session interactive. Laquelle des deux n'a
pas été établie.

**Décision du 2026-09-04** : Docker Desktop est lancé au démarrage du système.
L'agent se borne à attendre qu'il soit prêt et à diagnostiquer son absence.

**Ce qui reste ouvert, et que cette décision ne résout pas.** Si Docker Desktop
tombe **en cours de session**, il faut une intervention humaine. Un chantier qui
tourne sans surveillance s'arrête alors jusqu'à ce que quelqu'un le voie.

Trois pistes, aucune essayée :

- passer `com.docker.service` en démarrage **automatique**, ce qui pourrait
  suffire à rendre `Start-Process` viable — c'est l'hypothèse la plus probable et
  la moins coûteuse à vérifier ;
- lancer Docker Desktop par une tâche planifiée Windows, qui s'exécute dans un
  contexte différent de celui de l'agent ;
- une notification vers Maxime quand le démon manque — mais le point n° 2
  ci-dessus n'est pas encore traité, et il n'existe donc aucun canal.

**Concerne** `tests/env/assurer-docker.sh`, `tests/env/run-in-container.sh`, et
toute tâche dont l'`environment` n'est pas `host`.
