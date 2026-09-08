# MGNetworking Scripts

Bibliothèque personnelle de scripts d'administration, d'installation, de
configuration et de maintenance d'infrastructure.

> Le dépôt est en cours de refactorisation. Voir
> [le plan](docs/refactorisation-plan.md) pour l'état d'avancement.

## Architecture

```text
Linux/       System (7 scripts) | Security | Docker | K3s
Kubernetes/  Installation | Configuration | Maintenance   (à venir)
Docker/      Installation | Maintenance | Cleanup   (à venir)
Synology/    Plex | Administration
lib/         fonctions communes (common.sh)
config/      server.env (la machine) + un <contexte>.env par application
docs/        socle technique, plan, guides
```

`Linux/` prépare le système, `Docker/` gère le moteur de conteneurs,
`Linux/K3s/` la distribution Kubernetes, `Kubernetes/` tout ce qui s'adresse à un
cluster quelle que soit son origine.

## Scripts disponibles

| Script | Rôle |
|---|---|
| [`Linux/System/system-info.sh`](Linux/System/system-info.sh) | état du système, en lecture seule |
| [`Linux/System/update-system.sh`](Linux/System/update-system.sh) | mise à jour des paquets |
| [`Linux/System/configure-logging.sh`](Linux/System/configure-logging.sh) | répertoire des journaux et rotation logrotate |
| [`Linux/System/configure-hostname.sh`](Linux/System/configure-hostname.sh) | nom d'hôte et cohérence de /etc/hosts |
| [`Linux/System/configure-timezone.sh`](Linux/System/configure-timezone.sh) | fuseau horaire, avec validation |
| [`Linux/System/configure-swap.sh`](Linux/System/configure-swap.sh) | fichier d'échange : état, création, redimensionnement |
| [`Linux/System/configure-cron.sh`](Linux/System/configure-cron.sh) | planification des scripts automatiques dans /etc/cron.d |
| [`Linux/System/check-disk.sh`](Linux/System/check-disk.sh) | diagnostic de stockage : systèmes de fichiers, inodes, périphériques, répertoires consommateurs |
| [`Linux/System/check-memory.sh`](Linux/System/check-memory.sh) | diagnostic mémoire : mémoire vive, fichier d'échange, processus consommateurs |
| [`Linux/System/check-services.sh`](Linux/System/check-services.sh) | diagnostic des services systemd : services actifs, services en échec, vérification d'un service nommé |
| [`Synology/Plex/organize-series.sh`](Synology/Plex/organize-series.sh) | organisation des séries Plex (hérité, pas encore au standard) |
| [`Synology/Plex/update-plex.sh`](Synology/Plex/update-plex.sh) | mise à jour de Plex (hérité, pas encore au standard) |

Détail par domaine : [Linux/System/README.md](Linux/System/README.md).

## Installation sur un serveur

```bash
git clone git@github.com:MGNetworking/script.git /opt/mgnetworking
cd /opt/mgnetworking
cp config/<contexte>.env.example config/<contexte>.env   # selon les scripts utilisés
```

Le dépôt fonctionne quel que soit son emplacement : chaque script résout la
racine du projet à l'exécution.

## Conventions

Tout script commence par :

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
source "$_dir/lib/common.sh"
```

`lib/common.sh` fournit la journalisation (`info`, `warn`, `error`, `success`,
`die`, `run_logged`), les vérifications (`require_root`, `require_cmd`,
`require_os`), la confirmation interactive (`confirm`) et le chargement de
configuration (`load_config`).

Nommage `verb-noun.sh`. Idempotence dès que possible. `--dry-run` sur toute
opération destructive. Aucun secret versionné.

Détail des règles : [CLAUDE.md](CLAUDE.md).
Fonctionnement du socle : [docs/architecture-technique.md](docs/architecture-technique.md).

## Développement assisté par agent

Le dépôt se dote d'une couche permettant à un agent automatique de reprendre le
chantier : lire le backlog, écrire un script, le valider dans un conteneur
jetable, rendre compte.

**Pour s'en servir :** [docs/agent/mode-emploi.md](docs/agent/mode-emploi.md).
Deux commandes suffisent — `/backlog` pour le point de situation, `/tache
TASK-xxx` pour exécuter une tâche de bout en bout.

| Fichier | Rôle |
|---|---|
| [docs/agent/mode-emploi.md](docs/agent/mode-emploi.md) | **comment utiliser tout ceci au quotidien** |
| [docs/agent/comprendre-agent.md](docs/agent/comprendre-agent.md) | comment ça fonctionne, et pourquoi c'est bâti ainsi |
| [AGENTS.md](AGENTS.md) | contrat de travail : périmètre, commandes, Git, validation, arrêt |
| [tasks/](tasks/README.md) | backlog exécutable, une tâche par fichier |
| [tests/](tests/README.md) | validations — analyse statique, tests unitaires et d'intégration |
| [docs/agent/project-audit.md](docs/agent/project-audit.md) | audit du dépôt |
| [docs/agent/decisions/](docs/agent/decisions/ADR-0002-claude-code-comme-moteur.md) | décisions d'architecture et leurs raisons |
| `.claude/agents/` | les trois rôles délégués : rédacteur de script, rédacteur de tests, relecteur |
| `.claude/commands/` | `/tache <ID>` exécute une tâche de bout en bout, `/backlog` fait le point |

Le moteur est Claude Code — aucun programme d'orchestration n'est écrit. Les
règles, le backlog et les preuves appartiennent au dépôt ; `.claude/` ne décrit
que **qui** fait le travail et **comment on le lance**.

## Journalisation

Chaque script écrit à l'écran et dans un fichier nommé d'après lui :
`/var/log/mgnetworking/<script>.log` en root, `logs/<script>.log` sinon.

La rotation est assurée par `logrotate`, configuré une fois par serveur.

## Sécurité

Le dépôt est public. Aucun mot de passe, token, clé privée, kubeconfig ou
certificat ne doit y figurer. Les configurations réelles (`config/*.env`) ne sont
jamais versionnées ; seuls les modèles `*.env.example` le sont.
