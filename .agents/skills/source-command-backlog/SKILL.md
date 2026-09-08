---
name: "source-command-backlog"
description: "Point de situation du backlog — ce qui est prêt, en cours, bloqué, terminé"
---

# source-command-backlog

Use this skill when the user asks to run the migrated source command `backlog`.

## Command Template

Fais le point sur l'état du backlog.

## À lire

- `tasks/backlog.md` — l'index ;
- le contenu de `tasks/active/`, `tasks/pending/`, `tasks/blocked/`,
  `tasks/completed/` ;
- `git status` et la branche courante.

## À vérifier

**Cohérence.** Le `status` inscrit dans chaque fichier doit correspondre au
répertoire qui le contient, et le tableau de `backlog.md` doit refléter les
deux. Signale tout écart : c'est le premier symptôme d'un backlog qui dérive.

**Tâches réellement prêtes.** Une tâche est sélectionnable si son `status` est
`ready`, si toutes ses `depends_on` sont dans `completed/`, et si l'environnement
qu'elle réclame est disponible. Une tâche `ready` dont une dépendance traîne
n'est pas prête : dis-le.

**Tâches débloquées sans le savoir.** Une tâche `pending` dont toutes les
dépendances sont terminées devrait passer `ready`. Signale-les.

## À rendre

Court. Un tableau et trois phrases.

```text
En cours     TASK-xxx — depuis quand, où elle en est
Prêtes       les tâches réellement sélectionnables, par priorité
Bloquées     lesquelles, et ce qui est attendu de Maxime
Terminées    combien, avec les deux dernières
Incohérences les écarts constatés, ou « aucune »
```

Termine par la tâche que tu recommandes de prendre ensuite, et pourquoi.

Ne modifie rien : c'est un état des lieux, pas une remise en ordre. Si tu
constates une incohérence, signale-la et propose de la corriger.
