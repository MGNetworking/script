---
description: Exécute une tâche du backlog de bout en bout — plan, code, tests, relecture, rapport
argument-hint: <TASK-XXX>
---

Exécute la tâche **$1** du backlog, du début à la fin.

C'est l'enchaînement complet. Suis-le dans l'ordre, sans en sauter d'étape.

---

## 1. Charger le contexte

- lis `AGENTS.md` — le contrat de travail ;
- lis la tâche `$1` dans `tasks/pending/`, `tasks/active/` ou `tasks/blocked/` ;
- si le fichier n'existe pas : arrête-toi et dis-le.

## 2. Vérifier qu'elle est exécutable

Refuse et explique pourquoi si :

- son `status` n'est pas `ready` ;
- une de ses `depends_on` n'est pas dans `tasks/completed/` ;
- l'environnement qu'elle réclame est indisponible — pour `container-debian`,
  vérifie que le démon Docker répond, et **arrête-toi s'il ne répond pas**. Ne
  remplace jamais une validation comportementale par une analyse statique en la
  présentant comme équivalente ;
- l'arbre Git n'est pas propre. Ne remise rien, ne supprime rien : signale.

`human_approval_required: true` **ne bloque plus** — ADR-0003, décision 2. Le
champ signale ce qui mérite une lecture attentive ; il ne suspend pas
l'exécution. Un script destructif s'écrit comme un autre : il ne s'exécutera
jamais ailleurs que dans un conteneur jetable.

### Choisir le cycle : complet ou léger

ADR-0003, décision 5.

| La tâche | Cycle |
|---|---|
| produit un script en **lecture seule** — `check-*`, `audit-*`, `*-status` | **léger** |
| ne touche que de la **documentation** | **léger** |
| produit ou modifie un script qui **écrit sur le système** | **complet** |
| touche `lib/common.sh`, `tests/` ou `.claude/` | **complet**, sans exception |

**Cycle léger** : étapes 5 et 6, validations, puis étape 8. Pas de relecteur.
**Cycle complet** : toutes les étapes, relecteur compris.

Dans le doute, prends le cycle complet. Annonce lequel tu as retenu, et
pourquoi, avant de commencer.

## 3. Préparer

- `git status` pour constater l'état de départ ;
- crée la branche `agent/$1` depuis `master`, sauf si elle existe déjà ;
- déplace le fichier de tâche dans `tasks/active/` et passe son `status` à
  `in_progress`.

## 4. Planifier

Établis un plan court : fichiers à créer ou modifier, ordre des opérations,
validations à lancer. Annonce-le avant d'agir.

Si le plan sort du `scope` de la tâche, **arrête-toi**. Le périmètre ne
s'élargit pas en cours de route.

## 5. Rédiger

Délègue au sous-agent **`redacteur-script`** : script et documentation.

Passe-lui la tâche entière, il ne connaît pas la conversation.

## 6. Tester

Délègue au sous-agent **`redacteur-tests`** : tests du travail produit.

Passe-lui la tâche et ce qu'a produit l'étape précédente.

## 7. Valider et relire

**Cycle léger** : lance les commandes du champ `validation`, consigne leurs
codes de retour réels, et passe à l'étape 8. Une validation en échec reste un
échec — le mode léger allège la relecture, jamais la preuve.

**Cycle complet** : délègue au sous-agent **`relecteur`**. Il est en lecture
seule : il constate, il ne répare pas.

**Selon son verdict :**

- **CONFORME** → étape 8 ;
- **NON CONFORME** → boucle de correction ci-dessous ;
- **cinq tentatives atteintes** → la tâche est bloquée, va directement à
  l'étape 8 avec le statut `blocked`.

### Boucle de correction

```text
verdict NON CONFORME
        ↓
diagnostic : QUI a tort, le script ou le test ?
        ↓
   ┌────┴────┐
script      test
   ↓          ↓
redacteur   redacteur       ← on redélègue, on ne bricole pas soi-même
-script     -tests
   └────┬────┘
        ↓
    relecteur     tentative += 1
        ↓
  CONFORME ? → étape 8    sinon, on reboucle
        ↓
  5 tentatives → BLOCKED
```

### Le diagnostic, avant toute correction

Un test qui échoue a deux causes possibles. **La présomption est que le script
est fautif** — c'est lui qu'on teste.

Tu ne modifies un test que si tu peux dire précisément en quoi il est faux :
il vérifie autre chose que le critère d'acceptation, il se trompe de commande,
il attend un comportement que la tâche ne demande pas, ou il dépend de
l'environnement au lieu du script.

**Écris ce diagnostic dans le rapport, à chaque tentative.** « J'ai modifié le
test » sans justification est un aveu, pas une correction.

### Qui corrige

Redélègue au sous-agent concerné plutôt que de corriger toi-même :

- défaut dans le script ou sa documentation → **`redacteur-script`** ;
- défaut dans un test → **`redacteur-tests`**, avec le diagnostic ci-dessus ;
- défaut dans le backlog, un lien, un statut → tu le corriges directement.

Passe-lui le verdict complet du relecteur : il n'a pas suivi la conversation.

### Règles de la boucle

- corrige la cause, jamais le symptôme ;
- **ne neutralise jamais un test ni une validation pour obtenir un verdict
  favorable** — ni `|| true`, ni `set +e`, ni assertion commentée, ni validation
  retirée de la tâche. Cela vaut échec, quel que soit le verdict obtenu ensuite ;
- deux tentatives donnant la même erreur signalent un diagnostic faux : change
  d'hypothèse plutôt que de répéter la correction ;
- si la correction nécessaire sort du périmètre, bloque la tâche au lieu de
  l'élargir ;
- si le relecteur révèle un défaut dans `lib/common.sh`, **ne le corrige pas** :
  c'est une zone protégée. Consigne-le et bloque, ou crée une tâche.

## 8. Rendre compte

Écris `tasks/reports/$1-report.md`.

**Rapport court par défaut** — ADR-0003, décision 6 : ce qui a été produit, les
commandes lancées avec leurs codes de retour, le verdict. Une trentaine de
lignes suffisent pour une tâche sans histoire.

**Format complet** de `tasks/README.md` §6 dès que la tâche a bloqué, a demandé
plus d'un tour de correction, ou a révélé un défaut — c'est là que le détail
sert à quelqu'un.

Le rapport consigne **les faits observés** : les commandes réellement lancées,
leurs vrais codes de retour, les validations réellement exécutées. Une commande
non lancée n'y figure pas. Une validation en échec n'y est pas présentée comme
réussie. Une réserve se dit.

## 8 bis. Verser ce qui survit à la tâche

**Le contexte de la conversation disparaîtra. Ce qui n'est pas écrit est perdu.**

Avant de clore, demande-toi ce que tu as appris qui **n'appartient pas à cette
tâche** — un comportement système mesuré, un piège d'outillage, une limite
d'environnement, une affirmation d'un document rendue fausse par ce travail.
Puis verse-le là où la prochaine session le trouvera :

| Ce que tu as appris | Où l'écrire |
|---|---|
| un fait mesuré sur le comportement du dépôt ou du système | le rapport de la tâche, et le document qu'il concerne |
| un piège qui frappera le prochain script du domaine | le `README.md` du domaine, ou le corps d'une tâche à venir |
| un sujet réel, hors périmètre, qu'on écarte pour ne pas dévier | `docs/points-en-suspens.md` |
| un défaut trouvé et non corrigé | une **nouvelle tâche**, écrite maintenant |
| une décision d'orientation | un ADR — mais seulement si Maxime l'a tranchée |

**Le test à te poser** : une session neuve, qui n'aurait que les fichiers du
dépôt, referait-elle le même travail sans retomber dans le même piège ? Si non,
il manque un écrit.

Ce que tu écris ici doit être **autoportant** : la prochaine session ne verra pas
cette conversation. Nomme les fichiers, cite les mesures avec leurs chiffres,
n'écris pas « comme vu plus haut ».

## 9. Clore

- déplace le fichier de tâche vers `tasks/completed/` ou `tasks/blocked/`, et
  mets son `status` en cohérence ;
- mets à jour le tableau de `tasks/backlog.md`, y compris la section « Terminé »
  et les tâches que celle-ci débloque en `ready` ;
- `git add` et `git commit` sur la branche `agent/$1`, message conventionnel en
  français, avec la ligne `Tâche : $1` ;
- **si la tâche est `completed`** : `git switch master`, puis
  `git merge --no-ff agent/$1`, puis `git branch -d agent/$1`. Sans cette
  fusion, la tâche suivante repartirait d'un `master` qui l'ignore ;
- **si la tâche est `blocked`** : garde la branche, ne fusionne pas ;
- **pas de `git push` ici** : il est groupé en fin de domaine ;
- jamais de `rebase`, de `reset --hard` ni de `push --force` ;
- `git status` final.

## 10. Résumer

En quelques lignes : ce qui a été fait, ce qui a été prouvé, ce qui reste en
suspens, et la prochaine tâche prête.

## 11. Enchaîner

S'il reste une tâche `ready` **du même domaine**, reprends à l'étape 1 sans
demander confirmation — ADR-0003, décision 4.

### Le contexte peut être vidé ici

Une tâche close ne laisse rien derrière elle qui ne soit écrit : c'est l'objet de
l'étape 8 bis. **Après la fusion, la conversation peut donc être vidée sans
perte** — la tâche suivante démarre de son fichier, d'`AGENTS.md`, de
`docs/agent/decisions/` et des rapports.

Le dis-le à Maxime au moment de rendre la main, en une ligne : c'est lui qui tape
`/clear`, pas toi. S'il reste quoi que ce soit dont tu as besoin et qui n'est pas
dans le dépôt, alors **l'étape 8 bis a été mal faite** — écris-le avant de le
proposer.

Quand le domaine est achevé :

- `git push origin master` ;
- rends un point d'étape court : scripts produits, ce qui a été prouvé, ce qui
  reste ouvert, domaine suivant.

---

**En cas de blocage à n'importe quelle étape**, arrête-toi et présente :
pourquoi l'intervention est nécessaire, ce qui a été tenté, ce qui bloque
exactement, quelle décision est attendue, et les conséquences de chaque option.

Une question à laquelle Maxime peut répondre en une phrase — pas un appel à
reprendre les commandes.

**Avant de poser cette question**, vérifie qu'ADR-0003 ne l'a pas déjà tranchée :
ses vingt-quatre décisions valent autorisation permanente, et une question déjà
répondue est une interruption de trop.
