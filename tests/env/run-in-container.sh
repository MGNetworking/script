#!/usr/bin/env bash
# tests/env/run-in-container.sh — exécute une commande dans un conteneur neuf.
#
# L'hôte est une machine Windows : ni apt, ni systemctl, ni /etc/os-release. Un
# script d'administration ne s'y exécute pas, et une lecture de code ne vaut pas
# une exécution. Toute validation comportementale passe donc par ici.
#
#   tests/env/run-in-container.sh -- bash -c 'cat /etc/os-release'
#   tests/env/run-in-container.sh -- Linux/System/system-info.sh
#   tests/env/run-in-container.sh --profil debian -- tests/run.sh unit
#   tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment
#
# Tout ce qui suit « -- » est exécuté tel quel dans le conteneur, depuis la
# racine du dépôt montée sur /depot. Le code de retour de la commande est
# transmis fidèlement à l'appelant.
#
# Deux modes de lancement, que le profil choisit lui-même :
#
#   direct   le conteneur démarre sur la commande, qui en est le PID 1. C'est
#            le cas du profil « debian ».
#   systemd  le conteneur démarre sur /sbin/init ; on attend que le démon ait
#            fini de démarrer, puis la commande passe par « docker exec ».
#            C'est le cas de tout profil dont le Dockerfile porte le label
#            mgnet.test.init="systemd".
#
# Le conteneur est détruit à la fin de chaque exécution : deux appels
# consécutifs partent d'un état strictement identique, ce sans quoi un test
# d'idempotence ne prouverait rien.
#
# Aucune confirmation n'est demandée : rien n'est détruit sur l'hôte. Le
# conteneur est jetable par construction et l'image est reconstruite en place.
# Si le démon Docker ne répond pas, tests/env/assurer-docker.sh est appelé : il
# attend le moteur sous plafond de temps, diagnostique, et ne démarre ni n'arrête
# jamais Docker Desktop — son option de démarrage n'est pas passée, parce qu'elle
# ne fonctionne pas depuis la session de l'agent (relevé en tête de cet outil).
# Le contrôle est ensuite refait, et lui seul tranche. S'il échoue encore, le
# script s'arrête avec un code non nul —
# jamais un faux succès, et jamais une attente sans fin : en mode systemd, les
# interrogations du préflight, le lancement du conteneur détaché, l'attente du
# démarrage, le diagnostic et la destruction sont tous bornés en temps mural.
# Deux durées restent libres, parce qu'elles appartiennent à ce qu'elles
# mesurent : la construction de l'image et la commande demandée.

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
source "$_dir/lib/common.sh"

PROFIL="debian"
DRY_RUN="false"
RECONSTRUIRE="false"
COMMANDE=()

REPERTOIRE_ENV="$SCRIPTS_ROOT/tests/env"

# Point de montage du dépôt dans le conteneur, et répertoire de travail des
# commandes exécutées : les chemins relatifs des exemples ci-dessus en dépendent.
MONTAGE="/depot"

# Préfixe imposé par AGENTS.md §8 : les commandes Docker de l'agent ne portent
# que sur les images et conteneurs préfixés « mgnet-test- ». Tout ce que ce
# script crée doit donc l'être, sans exception.
PREFIXE="mgnet-test-"

# Attente du démarrage de systemd, pour les profils qui en ont un. Le plafond
# est large à dessein : un démarrage en conteneur tient d'ordinaire en quelques
# secondes, et ce qui n'est pas venu au bout d'une minute ne viendra pas. Cette
# borne n'est pas là pour temporiser, elle est là pour qu'un systemd absent
# rende la main avec un diagnostic plutôt que de suspendre la suite.
#
# Elle borne les réessais, pas la durée d'un sondage — d'où la seconde borne
# ci-dessous, sans laquelle « borné » ne voudrait rien dire : un démon Docker
# figé retient indéfiniment un « docker exec » ou un « docker ps », et la boucle
# n'atteindrait jamais le contrôle de son plafond. Une troisième borne suit,
# pour le nettoyage et le diagnostic : le même démon figé les retenait tout
# autant, une fois la boucle quittée. Une quatrième encore, pour le lancement du
# conteneur : c'est en amont de la boucle que le blocage s'était déplacé ensuite,
# et un plafond ne protège pas ce qui se passe avant qu'on l'atteigne.
DELAI_DEMARRAGE=60
INTERVALLE_SONDAGE=1

# Borne d'un sondage pris isolément. Ce n'est pas une marge de confort : sur cet
# hôte, le démarrage complet tient en 1 à 2 s et une interrogation du démon en
# bien moins d'une seconde. Dix secondes sans réponse ne signalent donc pas une
# lenteur, elles signalent un démon qui ne répond plus — et c'est ainsi que le
# script le dit.
#
# Elle borne aussi les deux interrogations du préflight — « docker info » et
# « docker image inspect » —, de même nature : une question posée au démon, sans
# rien à faire pour y répondre. Elles étaient jusqu'ici les dernières à ne
# dépendre d'aucune borne en amont de la boucle.
DELAI_SONDAGE=10

# Délai laissé au client Docker entre le signal d'arrêt et le SIGKILL de
# « timeout -k ». Le signal ordinaire suffit sur un hôte Linux ; sous MSYS
# (Git Bash), sa délivrance à un binaire natif — docker.exe — n'a pas été
# mesurée, et un signal ignoré ferait attendre « timeout » lui-même. Le SIGKILL
# de repli ferme ce trou sans rien coûter quand le premier signal porte.
DELAI_ABATTAGE=5

# Borne des appels Docker du nettoyage et du diagnostic — « docker ps -a »,
# « docker logs », « docker rm -f ». Elle est plus courte que celle des sondages,
# et pour une raison mesurable : aucune de ces trois commandes n'attend un
# démarrage, elles rendent la main en une fraction de seconde sur un démon sain.
# Dix secondes n'y diraient rien de plus que cinq, cinq secondes plus tard.
#
# Ces appels-là étaient les derniers à n'être bornés par rien, et c'était le trou
# qui restait : le diagnostic d'un démon figé arrivait bien au bout de
# DELAI_SONDAGE, puis le « trap … EXIT » suspendait le script sur son
# « docker ps -a » et son « docker rm -f ». Le blocage n'avait pas disparu, il
# s'était déplacé — au pire endroit, l'appelant venant de lire le diagnostic et
# croyant le script terminé. Mesuré : 10 s de diagnostic, puis 305 s de silence.
DELAI_NETTOYAGE=5

# Borne du « docker run -d » du mode systemd. Ce lancement-là est détaché : il
# n'exécute aucune commande, il crée le conteneur, démarre son PID 1 et rend la
# main — mesuré en moins d'une seconde sur cet hôte. Rien n'y justifie une durée
# libre, et il était pourtant le dernier appel non borné de l'amont : mesuré avec
# un démon devenu muet, le script y restait suspendu 200 s — et seulement parce
# qu'une borne externe coupait la mesure, le faux démon dormant 300 s —, avant
# même d'entrer dans la boucle d'attente que ces bornes protègent.
#
# La valeur est plus large que celle des sondages, et pour une raison : c'est un
# démarrage, pas une question. Le démon y fait un vrai travail — espaces de noms,
# tmpfs sur /run, montage du dépôt à travers la frontière Windows/WSL2. Il ne
# télécharge rien en revanche : l'image est présente, construite ou vérifiée
# quelques lignes plus haut. Trente secondes ne sont donc pas une marge de
# confort, elles sont le seuil au-delà duquel plus rien de légitime ne travaille.
#
# Elle ne s'applique qu'au mode systemd. Le « docker run » du mode direct porte
# la commande demandée : sa durée est celle de tests/run.sh entier, et la borner
# serait un contresens.
DELAI_LANCEMENT=30

# Ce que l'appelant doit réellement attendre au pire, et qui est annoncé à
# l'écran sous ce nom, juste avant le lancement du conteneur — le dernier moment
# où cette durée est encore entièrement devant lui. Quatre termes, chaque appel
# Docker se comptant pour sa borne plus le sursis DELAI_ABATTAGE avant SIGKILL :
#
#   le lancement du conteneur détaché ;
#   le plafond de l'attente, qui compte les réessais ;
#   le dernier tour de boucle — le plafond est contrôlé *après* les sondages, un
#     tour peut donc commencer juste avant l'échéance et ajouter ses deux appels ;
#   le chemin de sortie le plus long — journal_du_conteneur, qui interroge
#     l'existence du conteneur puis lit son journal, puis le trap, qui interroge
#     l'existence à son tour puis détruit. Soit quatre appels bornés.
#
# La somme majore, et c'est voulu : les chemins ne s'additionnent pas tous — un
# lancement qui expire s'arrête là et n'atteint jamais la boucle. Majorer est ce
# qu'on attend d'un pire cas.
#
# Deux durées n'y figurent pas, pour des raisons opposées. Le préflight, parce
# que ses bornes sont déjà consommées quand la durée est annoncée. La
# construction de l'image, parce qu'elle n'est pas bornée du tout : télécharger
# et construire prend légitimement des minutes.
DELAI_LANCEMENT_TOTAL=$((DELAI_LANCEMENT + DELAI_ABATTAGE))
DELAI_DERNIER_TOUR=$((2 * (DELAI_SONDAGE + DELAI_ABATTAGE)))
DELAI_CHEMIN_SORTIE=$((4 * (DELAI_NETTOYAGE + DELAI_ABATTAGE)))
DELAI_PIRE_CAS=$((DELAI_LANCEMENT_TOTAL + DELAI_DEMARRAGE + DELAI_DERNIER_TOUR + DELAI_CHEMIN_SORTIE))

# -------------------------------------------------------------------
# Aide
# -------------------------------------------------------------------
show_help() {
    cat <<'AIDE'
Usage : tests/env/run-in-container.sh [options] -- <commande> [arguments...]

Exécute une commande dans un conteneur Debian neuf, avec la racine du dépôt
montée en lecture-écriture sur /depot. Le conteneur est détruit ensuite : rien
ne survit d'une exécution à l'autre.

Tout ce qui suit « -- » est passé tel quel au conteneur. Son code de retour est
transmis fidèlement à l'appelant.

Un profil dont le Dockerfile porte le label mgnet.test.init="systemd" démarre
autrement : le conteneur est lancé sur /sbin/init, le script attend que systemd
ait fini de démarrer, puis la commande passe par « docker exec ». C'est le seul
moyen d'obtenir un systemctl, un timedatectl et un hostnamectl qui répondent.

Tout ce que ce mode demande au démon Docker est borné en temps mural : les
interrogations du préflight, le lancement du conteneur détaché, chaque sondage
de l'attente — en plus du plafond posé sur l'attente entière —, puis la lecture
du journal et la destruction du conteneur. Un démon figé ne retient donc le
script à aucune de ces étapes. Deux durées restent libres, parce qu'elles
appartiennent à ce qu'elles mesurent : la construction de l'image et la commande
demandée. Le message affiché au lancement annonce la durée maximale que
l'appelant doit prévoir. Un démon qui cesse de répondre et un systemd qui ne
démarre pas rendent tous deux 3, avec deux diagnostics distincts : la panne
n'est pas au même endroit.

Une destruction qui échoue ne change en revanche aucun code de retour : elle
nomme le conteneur survivant et la commande qui le retire à la main, en [WARN].

Un démon Docker qui ne répond pas n'arrête plus le lanceur d'emblée :
tests/env/assurer-docker.sh est appelé, il attend le moteur sous plafond de
temps — cas d'un Docker Desktop lancé au démarrage du système et pas encore
prêt — puis diagnostique. Il ne démarre pas l'application : son option
--demarrer ne lui est pas passée, le démarrage automatique ne fonctionnant pas
depuis cette session. Le contrôle est refait ensuite, à l'identique, et c'est lui
qui tranche — un démon toujours muet rend 3, comme avant. Avec --dry-run, l'outil
constate et annonce sans attendre.

Cette attente se paie, et le prix est mesuré : là où un démon mort faisait
échouer le lanceur en une seconde, il le fait échouer en 71 secondes — le temps
laissé au processus de Docker Desktop pour se montrer avant qu'on conclue qu'il
ne viendra pas. Si ce processus est bien là mais que son moteur reste muet,
l'attente va jusqu'au plafond de l'outil, soit plusieurs minutes. Rien n'est
bloqué pendant ce temps : assurer-docker.sh trace son attente en chemin, et
« tests/env/assurer-docker.sh --help » en donne les délais exacts.

Options :
      --profil <nom>  Profil de conteneur (défaut : debian). Un profil <nom>
                      correspond au fichier tests/env/Dockerfile.<nom>.
      --reconstruire  Reconstruire l'image sans cache, en retéléchargeant
                      l'image de base. Sinon, l'image n'est construite que si
                      elle est absente.
      --dry-run       Afficher les commandes docker sans les exécuter.
  -h, --help          Afficher cette aide

Exemples :
  tests/env/run-in-container.sh -- bash -c 'cat /etc/os-release'
  tests/env/run-in-container.sh -- Linux/System/system-info.sh
  tests/env/run-in-container.sh --profil debian -- tests/run.sh unit
  tests/env/run-in-container.sh -- Linux/System/configure-swap.sh 512M --dry-run
  tests/env/run-in-container.sh --profil systemd -- systemctl list-units

Codes de retour :
  0       la commande exécutée dans le conteneur a réussi
  2       erreur d'usage — option inconnue, profil inexistant ou déclarant un
          mode d'init inconnu, commande absente
  3       environnement indisponible — docker absent, démon toujours arrêté
          après l'appel à assurer-docker.sh, ou devenu muet au lancement du
          conteneur ou pendant l'attente, timeout absent, ou systemd qui ne
          démarre pas dans le conteneur ; rien n'a été exécuté
  4       échec de la construction de l'image ; rien n'a été exécuté
  autre   code de retour de la commande, transmis tel quel

Les codes 2, 3 et 4 peuvent aussi provenir de la commande elle-même : la
transmission fidèle du code de retour l'impose. Les messages [ERROR] du script
lèvent l'ambiguïté.
AIDE
}

# -------------------------------------------------------------------
# Arguments
# -------------------------------------------------------------------
while [ "${1:-}" != "" ]; do
    case "$1" in
        --profil)
            shift
            [ -n "${1:-}" ] || die "--profil attend un nom de profil." 2
            PROFIL="$1"; shift
            ;;
        --reconstruire) RECONSTRUIRE="true"; shift ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        -h|--help)      show_help; exit 0 ;;
        --)
            shift
            COMMANDE=("$@")
            break
            ;;
        *) die "Option inconnue : $1 (la commande doit suivre « -- »)" 2 ;;
    esac
done

if [ "${#COMMANDE[@]}" -eq 0 ]; then
    error "Aucune commande à exécuter."
    error "Usage : tests/env/run-in-container.sh [options] -- <commande> [arguments...]"
    die "Rien n'a été exécuté." 2
fi

IMAGE="${PREFIXE}${PROFIL}:latest"
DOCKERFILE="$REPERTOIRE_ENV/Dockerfile.$PROFIL"

# Un nom unique par exécution : deux appels simultanés ne se marchent pas dessus,
# et un conteneur résiduel se rattache sans ambiguïté à l'appel qui l'a créé.
CONTENEUR="${PREFIXE}${PROFIL}-$$-$(date '+%Y%m%d%H%M%S')"

# -------------------------------------------------------------------
# Chemins et Git Bash
# -------------------------------------------------------------------
# Sous MSYS (Git Bash), tout argument qui ressemble à un chemin POSIX est
# réécrit avant d'atteindre docker.exe : « /depot » deviendrait
# « C:/Program Files/Git/depot ». Ces deux variables désactivent la réécriture ;
# elles sont sans effet sur un hôte Linux.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# La réécriture étant désactivée, les chemins de l'hôte doivent être donnés à
# docker dans leur forme native : D:\Projet\script et non /d/Projet/script.
chemin_pour_docker() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

profils_disponibles() {
    local fichier liste=""
    for fichier in "$REPERTOIRE_ENV"/Dockerfile.*; do
        [ -f "$fichier" ] || continue
        liste="$liste ${fichier##*/Dockerfile.}"
    done
    printf '%s\n' "${liste# }"
}

# Mode de lancement du profil, déclaré par son propre Dockerfile via le label
# mgnet.test.init. Aucune liste de profils n'est tenue ici : le script se
# contente de lire ce que le profil dit de lui-même, et un Dockerfile.<nom>
# déposé demain avec le même label suit le même chemin sans modification.
#
# Le label est lu dans le fichier, pas dans l'image : --dry-run doit répondre
# juste avant même qu'aucune image n'ait été construite.
#
# Le « || true » final garde le trap ERR de lib/common.sh silencieux si sed
# échoue : armé par set -E, il parle jusque dans les substitutions de commande.
mode_init_du_profil() {
    sed -n 's/^[[:space:]]*LABEL[[:space:]]\{1,\}mgnet\.test\.init="\([^"]*\)".*/\1/p' \
        "$DOCKERFILE" | tail -n 1 || true
}

# -------------------------------------------------------------------
# Bornes de temps
# -------------------------------------------------------------------
# Ces fonctions sont définies ici, et non dans la section d'exécution où elles
# vivaient : le préflight interroge lui aussi le démon, et ce qui borne un appel
# doit être lisible avant le premier appel qu'on prétend borner.

# Codes par lesquels GNU timeout signale que le délai a expiré : 124 après le
# signal d'arrêt ordinaire, 137 (128+9) lorsque la commande n'a cédé qu'au
# SIGKILL de « -k ». Mesuré sur cet hôte, « timeout 2 sleep 5 » rend bien 124
# (coreutils 8.32) ; le 137 n'y a pas été reproduit, il est admis parce que la
# documentation de coreutils le prévoit et qu'il dit ici la même chose. Aucune
# des commandes bornées ne rend légitimement 137 : « docker info »,
# « docker image inspect », « docker run -d », « docker ps », « docker logs » et
# « docker rm » n'exécutent rien dans le conteneur, et
# « systemctl is-system-running » rend un code compris entre 0 et 4.
expiration() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

# Un appel Docker sous borne de temps. En mode systemd, tout appel au démon passe
# par ici, sauf trois, et pour une seule et même raison : leur durée appartient à
# ce qu'ils font, pas à ce script.
#
#   « docker build », qui télécharge et construit — des minutes, légitimement ;
#   « docker run <image> <commande> » du mode direct, dont la durée est celle de
#     la commande : c'est ce lancement-là qui exécute les suites longues ;
#   « docker exec <commande> » du mode systemd, pour la même raison.
#
# « docker run -d » n'en fait pas partie, contrairement à ce qui était écrit ici
# auparavant : détaché, il n'exécute aucune commande, il crée le conteneur et
# rend la main. Il est borné comme le reste.
#
# Sans « timeout », l'appel est lancé tel quel, non borné — c'est le comportement
# d'avant, et il ne subsiste que là où aucune borne n'a été promise : le
# préflight refuse le mode systemd si timeout manque, et le mode direct
# n'annonce aucune durée maximale.
borner() {
    local delai="$1"; shift
    if [ "$TIMEOUT_PRESENT" = "true" ]; then
        timeout -k "$DELAI_ABATTAGE" "$delai" "$@"
    else
        "$@"
    fi
}

# Les appels que les deux modes partagent — les interrogations du préflight —
# ne sont bornés qu'en mode systemd. C'est le seul mode qui annonce une durée
# maximale, donc le seul qui la doive ; et le profil debian, qui exécute les
# suites longues, doit continuer de lancer exactement les mêmes commandes
# qu'avant, à l'octet près.
borner_si_systemd() {
    local delai="$1"; shift
    if [ "$MODE_INIT" = "systemd" ]; then
        borner "$delai" "$@"
    else
        "$@"
    fi
}

# La borne des sondages de la boucle d'attente. Le nettoyage et le diagnostic
# emploient DELAI_NETTOYAGE, plus courte, en appelant « borner » directement.
sonder() {
    borner "$DELAI_SONDAGE" "$@"
}

# -------------------------------------------------------------------
# Préflight
# -------------------------------------------------------------------
if [ ! -f "$DOCKERFILE" ]; then
    error "Profil inconnu : $PROFIL (fichier attendu : tests/env/Dockerfile.$PROFIL)"
    die "Profils disponibles : $(profils_disponibles)" 2
fi

MODE_INIT="$(mode_init_du_profil)"

# Un label absent vaut « mode direct », c'est le cas de Dockerfile.debian. Un
# label présent mais inconnu est en revanche une faute de frappe dans le profil,
# pas une invitation à retomber en silence sur le mode direct : le symptôme
# n'apparaîtrait alors que bien plus loin, sous la forme d'un systemctl muet.
case "$MODE_INIT" in
    ""|systemd) ;;
    *) die "Profil $PROFIL : mode d'init inconnu « $MODE_INIT » (attendu : systemd)." 2 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    error "La commande docker est introuvable sur cette machine."
    die "Environnement de test indisponible — rien n'a été exécuté." 3
fi

# « timeout » borne les appels Docker : ceux du préflight, le lancement du
# conteneur, ceux de l'attente du démarrage, ceux du nettoyage et du diagnostic
# — trap compris. Sans lui, ces appels redeviendraient indéfinis dès que le démon
# cesse de répondre.
#
# Ce contrôle est local et ne coûte rien. Il vient après la présence de docker,
# qui reste le manque le plus fondamental à nommer, mais avant la première
# interrogation du démon : savoir si l'on peut poser une borne doit venir avant
# le premier appel qu'on prétend borner.
#
# Sa présence n'est exigée qu'en mode systemd, comme avant : ce mode-là ne peut
# pas tenir sa promesse de borne sans lui. Le mode direct n'attend rien ; son
# trap emprunte les mêmes fonctions, qui se passent de timeout quand il est
# absent — exactement comme aujourd'hui. En faire une exigence commune
# empêcherait le profil debian de tourner là où il tourne, pour une borne dont
# il n'a jamais eu besoin.
TIMEOUT_PRESENT="false"
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_PRESENT="true"
fi

# L'outil qui attend le démon — attente bornée du moteur, détection d'un Docker
# Desktop arrêté, diagnostic. Il n'est appelé que dans la branche d'échec du
# contrôle ci-dessous : quand le démon répond dès le premier « docker info », rien
# de tout cela ne s'exécute et le lanceur se comporte exactement comme avant.
ASSURER_DOCKER="$REPERTOIRE_ENV/assurer-docker.sh"

# Il est invoqué par « bash », et non exécuté directement : sur un montage
# Windows, le bit exécutable de la copie de travail n'est pas garanti — le §4 de
# tests/README.md le documente déjà pour les scripts lancés dans le conteneur.
#
# Son absence n'est pas fatale ici, et c'est délibéré : le lanceur retombe alors
# sur le message d'avant, celui qui demande de démarrer Docker Desktop à la main.
# Un fichier manquant ne doit pas transformer un diagnostic clair en erreur de
# chemin.
#
# « --dry-run » est transmis tel quel : un lanceur qui promet de n'exécuter aucune
# commande docker n'a pas à immobiliser l'appelant plusieurs minutes dans son dos.
#
# « --demarrer », en revanche, n'est JAMAIS passé, et ce n'est pas un oubli : le
# démarrage automatique de Docker Desktop depuis la session de l'agent a été
# mesuré le 2026-09-04, il échoue — l'application se lance puis se quitte
# d'elle-même. Docker Desktop est lancé au démarrage du système, et le lanceur
# n'attend de cet outil que l'attente et le diagnostic.
#
# Le code de retour de l'outil est tracé mais ne décide de rien : c'est le second
# « docker info » qui tranche. Une seule source de vérité sur la disponibilité du
# démon, la même que la première fois.
#
# Cette fonction rend donc toujours 0, y compris quand elle n'a rien pu faire.
# C'est délibéré, et pas seulement esthétique : appelée nue sous « set -e », un
# retour non nul tuerait le lanceur ici même, en armant au passage le trap ERR du
# socle — pour une étape dont l'échec a précisément son propre diagnostic deux
# lignes plus bas.
assurer_docker_desktop() {
    local code=0
    local options=()

    if [ ! -f "$ASSURER_DOCKER" ]; then
        warn "Outil de mise à disposition introuvable : $ASSURER_DOCKER"
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        options+=(--dry-run)
    fi

    bash "$ASSURER_DOCKER" "${options[@]}" || code="$?"
    if [ "$code" -ne 0 ]; then
        warn "tests/env/assurer-docker.sh a rendu le code $code."
    fi
    return 0
}

if [ "$MODE_INIT" = "systemd" ] && [ "$TIMEOUT_PRESENT" != "true" ]; then
    error "La commande timeout (GNU coreutils) est introuvable sur cette machine."
    error "Le profil $PROFIL interroge le démon, lance un conteneur détaché, attend le"
    error "démarrage de systemd, puis lit le journal du conteneur et le détruit. Aucun"
    error "de ces appels n'est borné sans timeout."
    error "Sans lui, un démon figé suspendrait la suite — avant, pendant ou après l'attente."
    die "Environnement de test indisponible — rien n'a été exécuté." 3
fi

# « docker info » est le seul contrôle qui atteste que le démon répond : la
# présence du client ne prouve rien. Sans lui, un démon arrêté produirait une
# erreur tardive et confuse au moment du run.
# Le test porte aussi sur le contenu : selon les versions, le client sort en 0
# avec une version serveur vide quand le démon est arrêté.
#
# L'appel est borné en mode systemd : un démon figé y retiendrait « docker info »
# aussi longtemps qu'il retenait le reste, et le préflight n'a pas de raison
# d'être le seul endroit où l'on attend sans fin. La borne expirée laisse
# version_serveur vide, ce qui emprunte la branche ci-dessous — celle qui dit
# précisément qu'il faut vérifier Docker Desktop.
#
# Un démon muet n'arrête plus la course pour autant : c'est ici que
# tests/env/assurer-docker.sh s'insère. Il attend le moteur sous plafond, et ne
# démarre ni n'arrête l'application. Le contrôle est ensuite refait — le même, à
# l'identique —, et c'est lui seul qui décide : si le démon reste muet, le lanceur
# meurt en 3 comme avant.
version_serveur=""
if ! version_serveur="$(borner_si_systemd "$DELAI_SONDAGE" \
        docker info --format '{{.ServerVersion}}' 2>/dev/null)" \
   || [ -z "$version_serveur" ]; then
    warn "Le démon Docker ne répond pas — attente par tests/env/assurer-docker.sh."

    assurer_docker_desktop

    version_serveur=""
    if ! version_serveur="$(borner_si_systemd "$DELAI_SONDAGE" \
            docker info --format '{{.ServerVersion}}' 2>/dev/null)" \
       || [ -z "$version_serveur" ]; then
        error "Le démon Docker ne répond toujours pas."
        borner_si_systemd "$DELAI_SONDAGE" docker info 2>&1 | head -n 5 >&2 || true
        if [ "$DRY_RUN" = "true" ]; then
            error "--dry-run : l'état a été constaté et annoncé, sans attendre le moteur."
            error "Lancer Docker Desktop à la main, attendre qu'il soit prêt, puis relancer."
        else
            error "Le diagnostic de assurer-docker.sh est au-dessus de cette ligne."
            error "Lancer Docker Desktop À LA MAIN, attendre qu'il soit prêt, puis relancer."
            error "Le lanceur ne le démarre pas : mesuré le 2026-09-04, un démarrage automatique"
            error "depuis cette session échoue là où le lancement manuel réussit."
        fi
        die "Environnement de test indisponible — rien n'a été exécuté." 3
    fi
fi
info "Démon Docker : version serveur $version_serveur"

# Les fins de ligne CRLF rendraient tout script inexécutable dans le conteneur
# (« bad interpreter »). Le dépôt impose LF par .gitattributes ; on vérifie que
# la copie de travail le respecte réellement, plutôt que de le supposer.
if LC_ALL=C grep -q $'\r' "$SCRIPTS_ROOT/lib/common.sh" 2>/dev/null; then
    warn "lib/common.sh contient des retours chariot (CRLF) dans la copie de travail."
    warn "Les scripts échoueront dans le conteneur. Correctif : git add --renormalize ."
fi

# -------------------------------------------------------------------
# Image
# -------------------------------------------------------------------
CHEMIN_DOCKERFILE="$(chemin_pour_docker "$DOCKERFILE")"
CHEMIN_CONTEXTE="$(chemin_pour_docker "$REPERTOIRE_ENV")"
CHEMIN_DEPOT="$(chemin_pour_docker "$SCRIPTS_ROOT")"

# Interrogation locale du démon, bornée en mode systemd comme celles du
# préflight. Son expiration ne peut pas être lue comme « image absente » : on
# partirait construire, et « docker build » — délibérément non borné — ne rendrait
# jamais la main sur un démon figé. Une borne qui expire ici dit que le démon ne
# répond plus, rien d'autre, et le script s'arrête là.
image_presente() {
    local code=0
    borner_si_systemd "$DELAI_SONDAGE" \
        docker image inspect "$IMAGE" >/dev/null 2>&1 || code="$?"
    if expiration "$code"; then
        error "Le démon Docker n'a pas répondu en ${DELAI_SONDAGE}s à « docker image inspect »."
        error "La présence de l'image $IMAGE n'a pas pu être établie ; construire sans le"
        error "savoir exposerait à un « docker build » que rien ne borne."
        error "Piste : Docker Desktop figé, arrêté ou en cours de redémarrage. Le vérifier"
        error "par « docker info », attendre qu'il soit prêt, puis relancer."
        die "Environnement de test indisponible — rien n'a été exécuté." 3
    fi
    [ "$code" -eq 0 ]
}

construire_image() {
    local options=()
    if [ "$RECONSTRUIRE" = "true" ]; then
        # --pull : repartir de la dernière debian:12 publiée.
        # --no-cache : ignorer les couches déjà construites.
        options+=(--pull --no-cache)
    fi

    if [ "$DRY_RUN" = "true" ]; then
        info "[dry-run] docker build ${options[*]:-} -f $CHEMIN_DOCKERFILE -t $IMAGE $CHEMIN_CONTEXTE"
        return 0
    fi

    info "Construction de l'image $IMAGE (première construction : téléchargement de debian:12)…"
    if ! run_logged docker build "${options[@]}" \
            -f "$CHEMIN_DOCKERFILE" -t "$IMAGE" "$CHEMIN_CONTEXTE"; then
        die "Échec de la construction de l'image $IMAGE — rien n'a été exécuté." 4
    fi
    success "Image prête : $IMAGE"
}

if [ "$RECONSTRUIRE" = "true" ]; then
    construire_image
elif image_presente; then
    info "Image déjà présente : $IMAGE (--reconstruire pour la refaire)"
else
    construire_image
fi

# -------------------------------------------------------------------
# Options de lancement
# -------------------------------------------------------------------
# Communes aux deux modes : un nom qui rattache le conteneur à cet appel, et le
# dépôt monté en lecture-écriture.
#
# Les chemins « /run » et « /depot » traversent MSYS sans être réécrits grâce
# aux deux variables exportées plus haut ; sans elles, « --tmpfs /run »
# deviendrait « --tmpfs C:/Program Files/Git/run ».
OPTIONS_RUN=(
    --name "$CONTENEUR"
    -v "$CHEMIN_DEPOT:$MONTAGE"
)

if [ "$MODE_INIT" = "systemd" ]; then
    # -d : le conteneur démarre en arrière-plan sur son CMD, /sbin/init. La
    #   commande demandée ne peut pas être passée ici — elle remplacerait le CMD
    #   et systemd ne démarrerait jamais. Elle passe par « docker exec ».
    # --rm est délibérément ABSENT de ce mode, et c'est la seule différence qui
    #   demande une justification. Sur un conteneur détaché, Docker efface le
    #   conteneur dès l'arrêt de son PID 1 — c'est-à-dire précisément dans le cas
    #   où l'on veut savoir pourquoi il s'est arrêté. « docker logs » ne trouvait
    #   alors plus rien et ne rendait que « No such container », si bien que le
    #   seul élément de diagnostic prévu pour cette panne était systématiquement
    #   vide. Le conteneur est donc conservé le temps que le script en lise le
    #   journal, puis détruit par le « trap … EXIT » plus bas, qui efface un
    #   conteneur quel que soit son état. Rien ne survit davantage qu'avant : en
    #   mode détaché, « --rm » ne couvrait que ce cas-là. Reste la mort brutale
    #   du lanceur, où le trap ne passe pas — mais « --rm » n'y aurait rien
    #   effacé non plus, le conteneur tournant toujours.
    # --privileged : systemd crée un cgroup par unité, donc écrit dans
    #   /sys/fs/cgroup, que Docker monte en lecture seule pour un conteneur
    #   ordinaire. C'est le levier que Docker offre pour lever cette contrainte.
    #   Il n'est pas anodin — le conteneur obtient toutes les capacités et voit
    #   les périphériques de l'hôte — et il n'est employé que parce que ce profil
    #   n'a pas d'autre raison d'être que de faire tourner un init. Le conteneur
    #   est jetable, ne porte aucun secret, et ne monte que le dépôt.
    # --tmpfs /run : /run porte l'état d'exécution volatile du système. Le faire
    #   reposer sur la couche d'image laisserait des résidus de construction à un
    #   endroit que systemd s'attend à trouver vide au démarrage. /run/lock n'est
    #   pas monté séparément : systemd-tmpfiles le recrée dans ce tmpfs.
    #
    # Deux options classiques de la littérature sont volontairement absentes :
    #   -v /sys/fs/cgroup:/sys/fs/cgroup:ro — recette de cgroup v1. L'hôte est
    #     Docker Desktop sur WSL2, donc cgroup v2 unifié, où un montage en
    #     lecture seule empêcherait précisément ce que systemd doit faire ;
    #   --cgroupns=host — exposerait à ce conteneur privilégié l'arborescence de
    #     cgroups de l'hôte entier. En cgroup v2, Docker place par défaut le
    #     conteneur dans son propre espace de noms, ce qui est la configuration
    #     que systemd sait gérer. À n'ajouter que si le démarrage échoue et que
    #     le journal du conteneur le réclame.
    OPTIONS_RUN+=(-d --privileged --tmpfs /run)
else
    # « --rm » n'a pas le même effet ici : la commande est le PID 1, elle
    # s'arrête forcément, et Docker efface le conteneur sans qu'il reste rien à
    # en lire — sa sortie est déjà celle de l'appelant.
    #
    # Le répertoire de travail n'est posé ici que pour le mode direct : dans le
    # mode systemd, le PID 1 est init — c'est le « docker exec » qui a besoin de
    # se placer sur le montage, et il le fait lui-même.
    OPTIONS_RUN+=(--rm -w "$MONTAGE")
fi

# -------------------------------------------------------------------
# Résumé
# -------------------------------------------------------------------
info "Profil     : $PROFIL"
info "Image      : $IMAGE"
info "Conteneur  : $CONTENEUR (détruit en fin d'exécution)"
info "Dépôt      : $CHEMIN_DEPOT -> $MONTAGE (lecture-écriture)"
info "Commande   : ${COMMANDE[*]}"
if [ "$MODE_INIT" = "systemd" ]; then
    info "Lancement  : systemd en PID 1, puis docker exec (label mgnet.test.init)"
else
    info "Lancement  : direct — la commande est le PID 1 du conteneur"
fi

if [ "$DRY_RUN" = "true" ]; then
    if [ "$MODE_INIT" = "systemd" ]; then
        info "[dry-run] docker run ${OPTIONS_RUN[*]} $IMAGE (lancement détaché, borné à ${DELAI_LANCEMENT}s)"
        info "[dry-run] attente de « systemctl is-system-running » (running ou degraded) : un sondage au moins, chacun borné à ${DELAI_SONDAGE}s, puis abandon au-delà de ${DELAI_DEMARRAGE}s"
        info "[dry-run] docker exec -w $MONTAGE $CONTENEUR ${COMMANDE[*]}"
        info "[dry-run] docker rm -f $CONTENEUR (par le trap, avec le diagnostic : appels bornés à ${DELAI_NETTOYAGE}s chacun)"
        info "[dry-run] durée maximale avant reprise de la main, lancement, attente et sortie compris : ${DELAI_PIRE_CAS}s"
    else
        info "[dry-run] docker run ${OPTIONS_RUN[*]} $IMAGE ${COMMANDE[*]}"
    fi
    success "[dry-run] Aucune exécution — rien n'a été lancé."
    exit 0
fi

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
# Existence et marche du conteneur. Ces fonctions sont définies avant le filet
# de nettoyage qui les emploie : le trap est armé quelques lignes plus bas, et
# une interruption entre les deux ne doit pas le faire tomber sur une fonction
# pas encore lue. Les bornes qu'elles emploient sont définies plus haut, avant
# le préflight, qui en a besoin lui aussi.

# Existence du conteneur, quel que soit son état, sous borne. Trois issues, comme
# conteneur_en_marche et pour la même raison : un « docker ps -a » qui ne rend
# pas la main ne dit pas que le conteneur a disparu, il dit que le démon ne
# répond plus. Les confondre ferait annoncer un conteneur effacé alors que
# personne n'a pu le vérifier.
#
#   0  le conteneur existe
#   1  il n'existe pas, ou le démon a répondu en erreur
#   2  le démon n'a pas répondu dans la borne
#
# La distinction entre exister et tourner porte tout le diagnostic du mode
# systemd. « docker ps » ne montre que ce qui tourne ; « docker ps -a » montre
# aussi ce qui s'est arrêté. Un conteneur absent de la première liste mais
# présent dans la seconde est un PID 1 mort — dont le journal, lui, est encore
# lisible.
conteneur_existe() {
    local sortie="" code=0
    sortie="$(borner "$DELAI_NETTOYAGE" \
        docker ps -a --filter "name=^${CONTENEUR}$" --format '{{.Names}}' 2>/dev/null)" \
        || code="$?"
    if expiration "$code"; then
        return 2
    fi
    [ -n "$sortie" ]
}

# Marche du conteneur, sondée sous borne. Trois issues, et la troisième n'est pas
# un raffinement : un « docker ps » qui ne rend pas la main dans la borne ne dit
# pas que le conteneur s'est arrêté, il dit que le démon ne répond plus. Les
# confondre ferait accuser le conteneur — et afficher son journal — pour une
# panne qui est celle de l'hôte.
#
#   0  le conteneur tourne
#   1  il ne tourne pas : arrêté, absent, ou démon en erreur
#   2  le démon n'a pas répondu dans la borne
conteneur_en_marche() {
    local sortie="" code=0
    sortie="$(sonder docker ps --filter "name=^${CONTENEUR}$" --format '{{.Names}}' 2>/dev/null)" \
        || code="$?"
    if expiration "$code"; then
        return 2
    fi
    [ -n "$sortie" ]
}

# Ce que le trap dit lorsqu'il n'a pas pu détruire le conteneur : pourquoi il a
# renoncé, quel conteneur a pu survivre, et la commande exacte qui le retire à la
# main. Un nettoyage manqué laisse un état sur l'hôte ; le taire serait pire que
# de l'annoncer.
#
# Le niveau est WARN, jamais ERROR, et le code de retour du script n'en est pas
# changé : un nettoyage qui échoue ne transforme pas un succès en échec. C'est la
# règle qui gouverne toute cette section — le trap ne devient jamais lui-même la
# cause d'un échec.
# shellcheck disable=SC2317
avertir_conteneur_survivant() {
    warn "Nettoyage incomplet : $1."
    warn "Le conteneur $CONTENEUR a pu survivre à cette exécution."
    warn "Le retirer à la main : docker rm -f $CONTENEUR"
    warn "Le code de retour du script n'en est pas changé."
}

# En mode direct, « --rm » détruit le conteneur en sortie normale et ce filet ne
# couvre que le reste : interruption au clavier, échec du démon en cours de
# route. En mode systemd, il n'a pas de suppléant — le conteneur y est lancé sans
# « --rm » pour que son journal survive à la mort de son PID 1, et c'est ce trap
# seul qui l'efface. Dans les deux cas, aucun état ne survit à l'exécution.
#
# Ses deux appels Docker sont bornés, et c'est le sens de cette borne-ci : sans
# elle, un démon figé suspendait le script ici, après l'affichage du diagnostic
# et alors que l'appelant croyait l'exécution terminée. Mesuré sur un démon
# devenu muet : 10 s pour le diagnostic, puis 305 s de silence dans le trap.
#
# Le code de retour est relu en première instruction et rendu en dernière ; rien
# de ce qui se passe entre les deux ne le change.
#
# La fonction n'est pas morte : elle est appelée par le « trap … EXIT » posé
# juste en dessous. shellcheck ne suit pas les trap et la croit inatteignable.
# D'où SC2317 désactivé.
# shellcheck disable=SC2317
nettoyer_conteneur() {
    local code="$?"
    local etat=0 abandon=0

    conteneur_existe || etat="$?"

    # Démon muet : nul ne sait si le conteneur existe encore, et insister
    # coûterait une seconde attente pour rien. Le dire vaut mieux que de le
    # supposer effacé.
    if [ "$etat" -eq 2 ]; then
        avertir_conteneur_survivant \
            "le démon Docker n'a pas répondu en ${DELAI_NETTOYAGE}s à « docker ps -a »"
        return "$code"
    fi

    if [ "$etat" -ne 0 ]; then
        return "$code"
    fi

    if [ "$MODE_INIT" = "systemd" ]; then
        # Attendu, et non résiduel : ce mode ne confie sa destruction à
        # personne d'autre. C'est ici, et seulement ici, qu'elle a lieu —
        # que le PID 1 tourne encore ou qu'il se soit arrêté entre-temps.
        info "Destruction du conteneur $CONTENEUR."
    else
        warn "Conteneur résiduel $CONTENEUR : suppression."
    fi

    borner "$DELAI_NETTOYAGE" docker rm -f "$CONTENEUR" >/dev/null 2>&1 || abandon="$?"
    if [ "$abandon" -eq 0 ]; then
        return "$code"
    fi

    if expiration "$abandon"; then
        avertir_conteneur_survivant \
            "« docker rm -f » n'a pas rendu la main en ${DELAI_NETTOYAGE}s"
    else
        avertir_conteneur_survivant "« docker rm -f » a échoué (code $abandon)"
    fi
    return "$code"
}
trap nettoyer_conteneur EXIT

# Dernières lignes de ce que le PID 1 a écrit. C'est le seul élément de
# diagnostic disponible quand le démarrage n'aboutit pas : sans lui, un échec
# d'attente ne dirait que « systemd n'est pas venu », sans dire pourquoi.
#
# Quatre issues, toutes annoncées : un journal, un conteneur qui n'existe plus,
# un PID 1 qui n'a rien écrit, un démon qui ne répond plus. Aucune ne laisse
# l'appelant devant un silence, et aucune ne recopie le message d'erreur de
# « docker logs » sous le titre d'un journal — un « No such container » affiché
# en guise de diagnostic ne dit rien de la panne, il dit seulement qu'on a
# regardé trop tard.
#
# Ses deux appels Docker sont bornés par DELAI_NETTOYAGE. Un diagnostic qui
# suspend indéfiniment le script qu'il devait éclairer ne serait pas un
# diagnostic ; et un démon qui ne répond plus est lui-même une information, qui
# vaut d'être dite à la place du journal qu'on n'a pas pu lire.
journal_du_conteneur() {
    local lignes="" etat=0 code=0

    conteneur_existe || etat="$?"

    if [ "$etat" -eq 2 ]; then
        error "Le démon Docker n'a pas répondu en ${DELAI_NETTOYAGE}s à « docker ps -a » :"
        error "l'existence de $CONTENEUR n'a pas pu être établie, son journal n'est pas lu."
        return 0
    fi

    if [ "$etat" -ne 0 ]; then
        error "Le conteneur $CONTENEUR n'existe plus : aucun journal à lire."
        return 0
    fi

    # Le « || code » garde le trap ERR de lib/common.sh silencieux — armé par
    # set -E, il parle jusque dans les substitutions de commande — et retient le
    # code, seul moyen de distinguer l'expiration de la borne d'un échec
    # ordinaire de « docker logs ».
    lignes="$(borner "$DELAI_NETTOYAGE" docker logs --tail 20 "$CONTENEUR" 2>&1)" || code="$?"
    if expiration "$code"; then
        error "Le démon Docker n'a pas répondu en ${DELAI_NETTOYAGE}s : « docker logs » abandonné."
        error "Le journal de $CONTENEUR n'a pas pu être lu."
        return 0
    fi

    if [ -z "$lignes" ]; then
        error "Le PID 1 de $CONTENEUR n'a rien écrit — journal vide."
        return 0
    fi

    error "Dernières lignes du journal du conteneur :"
    printf '%s\n' "$lignes" | sed 's/^/    /' >&2 || true
}

# État du système d'init, tel que systemd lui-même le rapporte.
#
# La fonction renseigne deux globales au lieu d'écrire sur stdout : appelée en
# substitution de commande, elle s'exécuterait dans un sous-shell et ne pourrait
# rien transmettre d'autre que sa sortie.
#
#   ETAT_SYSTEMD   l'un des états que systemd documente, ou une chaîne vide
#   REPONSE_ETAT   la dernière ligne non vide obtenue, quelle qu'elle soit
#   CODE_SONDAGE   le code de retour du sondage, dont l'expiration de la borne
#
# Le tri entre les deux n'est pas cosmétique. « docker exec » écrit ses propres
# erreurs — un « OCI runtime exec failed: … executable file not found » de
# plusieurs lignes — sur stdout, à l'endroit exact où systemctl écrit son état.
# Reprendre cette sortie telle quelle derrière « Dernier état rendu par
# systemctl is-system-running » afficherait un pavé Docker sous une étiquette
# systemd. N'est donc retenu comme état qu'un mot figurant dans la liste
# ci-dessous ; le reste est affiché ailleurs, sous son vrai nom, plutôt que jeté.
#
# La sortie d'erreur est fusionnée à dessein : un « Failed to connect to bus »
# vaut diagnostic. Chercher l'état ligne par ligne, et non sur la dernière ligne,
# rend le tri insensible à l'ordre d'arrivée des deux flux.
#
# Le « || CODE_SONDAGE » n'est pas une commodité : « is-system-running » rend un
# code non nul pour tout état autre que « running », et le trap ERR de
# lib/common.sh — armé jusque dans les substitutions de commande par set -E —
# écrirait sinon une ligne d'échec à chaque tour de boucle. Il remplace le
# « || true » d'avant, qui jetait le code : l'expiration de la borne ne se
# distingue d'un échec ordinaire de « docker exec » que par ce code-là.
ETAT_SYSTEMD=""
REPONSE_ETAT=""
CODE_SONDAGE=0
lire_etat_du_systeme() {
    local sortie="" ligne=""
    ETAT_SYSTEMD=""
    REPONSE_ETAT=""
    CODE_SONDAGE=0

    sortie="$(sonder docker exec "$CONTENEUR" systemctl is-system-running 2>&1)" \
        || CODE_SONDAGE="$?"

    while IFS= read -r ligne; do
        ligne="${ligne%$'\r'}"
        case "$ligne" in
            initializing|starting|running|degraded|maintenance|stopping|offline|unknown)
                ETAT_SYSTEMD="$ligne"
                ;;
        esac
        if [ -n "$ligne" ]; then
            REPONSE_ETAT="$ligne"
        fi
    done <<<"$sortie"
}

# Une réponse qui n'est pas un état reste affichable, mais bornée : sur une seule
# ligne, et tronquée. Un pavé Docker de plusieurs centaines de caractères
# noierait sinon le reste du diagnostic.
reponse_lisible() {
    local texte="${1//[[:cntrl:]]/ }"
    if [ "${#texte}" -gt 160 ]; then
        printf '%s […]\n' "${texte:0:160}"
    else
        printf '%s\n' "$texte"
    fi
}

# Sortie commune aux deux sondages quand la borne a expiré. Le diagnostic est
# délibérément distinct de celui d'un systemd lent : là, le démon répondait et
# c'est le démarrage qui traînait ; ici, le client Docker lui-même n'a pas rendu
# la main. Dire « systemd n'a pas fini de démarrer » enverrait chercher la panne
# dans le conteneur, alors qu'elle est sur l'hôte.
#
# Le journal du conteneur n'est volontairement pas lu : « docker logs » passerait
# par ce même démon, qui vient de prouver qu'il ne répond plus. La lecture est
# désormais bornée elle aussi et ne suspendrait donc plus rien, mais elle
# coûterait deux attentes de plus pour un échec certain — et le trap, juste
# après, en paiera déjà une pour tenter la destruction.
demon_fige() {
    error "Le démon Docker n'a pas répondu en ${DELAI_SONDAGE}s : « $1 » a été abandonné."
    error "Ce n'est pas un systemd lent — le client Docker lui-même est resté sans réponse."
    error "Piste : Docker Desktop figé, arrêté ou en cours de redémarrage. Le vérifier"
    error "par « docker info », attendre qu'il soit prêt, puis relancer."
    error "Le journal du conteneur n'est pas lu : il passerait par ce même démon."
    die "Environnement de test indisponible — la commande n'a pas été exécutée." 3
}

# Attente active et bornée de la fin du démarrage.
#
# Un « docker exec » lancé aussitôt après le « run » tombe sur un systemd encore
# en « initializing » : systemctl répond mal, ou pas du tout. On interroge donc
# le démon plutôt que de dormir un temps de confort — mais avec un plafond : au
# delà de DELAI_DEMARRAGE secondes, le script rend la main avec un diagnostic et
# un code non nul. Une attente sans borne suspendrait la suite entière.
#
# Le plafond ne suffit pas à lui seul : il compte les réessais, et un démon figé
# retiendrait le sondage lui-même — la boucle n'atteindrait jamais le contrôle du
# plafond. Chaque appel Docker porte donc sa propre borne, et son expiration a
# son propre diagnostic : voir demon_fige juste au-dessus.
#
# « degraded » est un état de marche, pas un échec : il suffit qu'une unité ait
# échoué, ce qui est banal en conteneur. Le refuser rendrait le profil
# inutilisable.
#
# « offline » et « unknown » disent que rien ne répond — mais ils apparaissent
# aussi pendant les toutes premières secondes, avant que le bus ne soit là. On
# ne s'y arrête donc pas : c'est le plafond qui tranche, et la mort du conteneur
# qui abrège.
#
# « systemctl is-system-running --wait » ne remplacerait pas cette boucle : il ne
# bloque que si le manager répond déjà, et rend « offline » immédiatement s'il
# est interrogé trop tôt — la course resterait entière.
#
# Ce que « borné » veut dire ici, exactement : le sondage a lieu d'abord, le
# plafond est vérifié ensuite. Il y a donc toujours **au moins un sondage** — un
# plafond de 0 n'interdit pas d'essayer, il interdit de recommencer — et
# l'attente réelle peut dépasser le plafond de la durée du dernier tour, un
# « docker exec » n'étant pas instantané. C'est assumé : rendre la main sans
# avoir interrogé le démon une seule fois ne dirait rien de plus que « je n'ai
# pas regardé ». Ce dépassement est lui-même borné — chaque sondage l'est.
#
# La durée annoncée, DELAI_PIRE_CAS, ne s'arrête pas à cette boucle : elle part
# du lancement du conteneur et comprend aussi le chemin de sortie — lecture du
# journal puis destruction —, dont les quatre appels Docker sont bornés eux
# aussi. Elle est donc annoncée juste avant le « docker run -d », dernier moment
# où elle est encore entièrement devant l'appelant, et non ici. C'est la seule
# durée qu'il ait à connaître : celle au bout de laquelle il a repris la main, et
# non celle au bout de laquelle le diagnostic s'affiche.
attendre_systemd() {
    local depart="$SECONDS" ecoule=0 marche=0

    info "Attente du démarrage de systemd : un sondage au moins, chacun borné à ${DELAI_SONDAGE}s ; abandon au-delà de ${DELAI_DEMARRAGE}s."
    info "Diagnostic et destruction du conteneur sont bornés à ${DELAI_NETTOYAGE}s par appel."
    while true; do
        marche=0
        conteneur_en_marche || marche="$?"
        case "$marche" in
            0) ;;
            2) demon_fige "docker ps" ;;
            *)
                error "Le conteneur $CONTENEUR s'est arrêté avant la fin du démarrage."
                journal_du_conteneur
                die "Environnement de test indisponible — la commande n'a pas été exécutée." 3
                ;;
        esac

        lire_etat_du_systeme
        if expiration "$CODE_SONDAGE"; then
            demon_fige "docker exec $CONTENEUR systemctl is-system-running"
        fi
        ecoule=$((SECONDS - depart))

        case "$ETAT_SYSTEMD" in
            running|degraded)
                info "systemd est prêt après ${ecoule}s — état « $ETAT_SYSTEMD »."
                return 0
                ;;
        esac

        if [ "$ecoule" -ge "$DELAI_DEMARRAGE" ]; then
            error "systemd n'a pas fini de démarrer dans $CONTENEUR au bout de ${ecoule}s."
            error "Dernier état rendu par « systemctl is-system-running » : ${ETAT_SYSTEMD:-aucun état reconnu}"
            if [ -z "$ETAT_SYSTEMD" ] && [ -n "$REPONSE_ETAT" ]; then
                error "Dernière réponse obtenue, qui n'est pas un état : $(reponse_lisible "$REPONSE_ETAT")"
            fi
            error "Piste : relancer avec --reconstruire, ou vérifier que le démon Docker"
            error "autorise les conteneurs privilégiés."
            journal_du_conteneur
            die "Environnement de test indisponible — la commande n'a pas été exécutée." 3
        fi

        sleep "$INTERVALLE_SONDAGE"
    done
}

# La sortie de la commande n'est délibérément ni capturée ni redirigée : stdout
# et stderr du conteneur sont ceux de l'appelant. « run_logged » enverrait tout
# sur stderr et fausserait un « cat » ou un « tests/run.sh » lu par un tiers.
#
# Le démarrage détaché, lui, passe par run_logged : « docker run -d » écrit
# l'identifiant du conteneur sur stdout, qui n'a rien à y faire. Il passe aussi
# par « borner », ce qui n'est visible que dans la ligne « Exécution : » du
# journal — c'est le prix d'une seule et même façon de poser une borne dans ce
# script, et le délai y est lisible.
code_retour=0
if [ "$MODE_INIT" = "systemd" ]; then
    info "Lancement du conteneur détaché, borné à ${DELAI_LANCEMENT}s : ${DELAI_PIRE_CAS}s au pire avant que la main soit rendue, hors durée de la commande elle-même."

    lancement=0
    run_logged borner "$DELAI_LANCEMENT" \
        docker run "${OPTIONS_RUN[@]}" "$IMAGE" || lancement="$?"

    # L'expiration a son propre diagnostic, distinct d'un lancement refusé : le
    # démon n'a pas dit non, il n'a rien dit. Et elle laisse une incertitude
    # qu'il faut nommer — le nom du conteneur est choisi avant le lancement, le
    # démon a donc pu le créer pendant que le client renonçait. Le trap qui suit
    # tente la destruction ; s'il n'y parvient pas, il nomme le survivant et la
    # commande qui le retire. Ce qui est dit ici est ce que l'appelant peut
    # vérifier lui-même, une fois le démon revenu.
    #
    # Le journal du conteneur n'est pas lu, pour la raison qui vaut ailleurs :
    # « docker logs » passerait par ce même démon, qui vient de prouver qu'il ne
    # répond plus.
    if expiration "$lancement"; then
        error "Le démon Docker n'a pas rendu la main en ${DELAI_LANCEMENT}s : « docker run -d » a été abandonné."
        error "Ce n'est pas un démarrage lent : ce lancement est détaché, il n'exécute aucune"
        error "commande et rend la main en moins d'une seconde sur un démon sain."
        error "Le nom du conteneur étant choisi avant le lancement, $CONTENEUR peut malgré"
        error "tout exister : le client a renoncé, pas forcément le démon."
        error "Sa destruction est tentée à la sortie ; si elle n'aboutit pas, elle le dit et"
        error "donne la commande de retrait. Le constater une fois le démon revenu :"
        error "  docker ps -a --filter name=$CONTENEUR"
        error "Piste : Docker Desktop figé, arrêté ou en cours de redémarrage. Le vérifier"
        error "par « docker info », attendre qu'il soit prêt, puis relancer."
        die "Environnement de test indisponible — la commande n'a pas été exécutée." 3
    fi

    if [ "$lancement" -ne 0 ]; then
        die "Le conteneur $CONTENEUR n'a pas pu démarrer — rien n'a été exécuté." 3
    fi

    attendre_systemd
    docker exec -w "$MONTAGE" "$CONTENEUR" "${COMMANDE[@]}" || code_retour="$?"
else
    docker run "${OPTIONS_RUN[@]}" "$IMAGE" "${COMMANDE[@]}" || code_retour="$?"
fi

# -------------------------------------------------------------------
# Vérification
# -------------------------------------------------------------------
if [ "$code_retour" -eq 0 ]; then
    success "Commande terminée dans $PROFIL — code de retour 0."
else
    error "Commande terminée dans $PROFIL — code de retour $code_retour."
fi

exit "$code_retour"
