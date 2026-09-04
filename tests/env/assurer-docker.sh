#!/usr/bin/env bash
# tests/env/assurer-docker.sh — attendre que le démon Docker soit disponible.
#
# L'hôte est une machine Windows, et Docker Desktop y est une application, pas un
# service. Elle est désormais lancée au démarrage du système — décision de Maxime
# du 2026-09-04 —, mais être lancée n'est pas être prête : l'application
# initialise WSL2, monte ses systèmes de fichiers, puis lance son moteur. Une
# tâche lancée peu après l'ouverture de session tombe sur cet intervalle, et tout
# ce qui passe par tests/env/run-in-container.sh s'arrêtait alors sur « le démon
# Docker ne répond pas ». Docker peut aussi mourir *pendant* une tâche, laissant
# une suite à moitié exécutée.
#
# Cet outil constate l'état, attend que le moteur réponde, et rend la main —
# toujours, et toujours borné en temps. Il ne démarre rien de lui-même.
#
# Ce qu'il traite, un traitement par état :
#
#   le démon répond                          rien, code 0
#   lancé, moteur pas encore prêt            ATTENDRE — c'est le cas courant
#   le processus n'est pas (encore) là       attendre son apparition, borné
#   le processus disparaît pendant l'attente plantage : code 3, diagnostiqué
#   plafond ou délai atteint                 code 3, avec diagnostic
#
# Le démarrage de l'application ne fait plus partie de ce chemin. Il subsiste
# derrière « --demarrer », et le bloc suivant dit pourquoi il n'est plus employé.
#
# -------------------------------------------------------------------
# LA LIMITE — pourquoi le démarrage n'est pas le comportement par défaut
# -------------------------------------------------------------------
# Elle est mesurée, et voici la mesure. Premier usage réel, le 2026-09-04, Docker
# Desktop 4.51.0, deux tentatives de démarrage automatique :
#
#   15:50:32  démarrage de Docker Desktop (tentative 1/2)
#   15:50:45  processus présent après 14 s (comptés depuis ce démarrage)
#   15:51:15  le processus a disparu après 46 s — arrêté en cours de démarrage
#   15:51:16  démarrage de Docker Desktop (tentative 2/2)
#   15:51:28  processus présent après 13 s
#   15:54:43  le processus a disparu après 253 s
#             plafond DELAI_DISPONIBILITE atteint dans la foulée, code 3
#
# Les durées de 46 s et 253 s sont comptées depuis le début du script, celles de
# 14 s et 13 s depuis le démarrage qui les précède. Les journaux de Docker Desktop
# donnent la suite : « eventErrorDialog », puis « bind: {"action":"Quit"} », puis
# « com.docker.backend.exe services: exit status 150 ». Le service
# com.docker.service était Stopped, en démarrage Manual.
#
# Le fait décisif est ailleurs : lancé À LA MAIN par Maxime, Docker Desktop
# démarre sans afficher la moindre erreur. Le défaut ne tient donc pas à Docker,
# ni à la machine, ni au chemin de l'exécutable — il tient au CONTEXTE DE
# LANCEMENT. « Start-Process » depuis la session de l'agent ne fournit pas ce que
# Docker Desktop attend : élévation, ou session interactive. Laquelle des deux n'a
# pas été établie, et ce script ne le devine pas.
#
# D'où la décision du 2026-09-04 : Docker Desktop est lancé au démarrage du
# système, l'agent n'a plus à le démarrer. Le code de démarrage reste ici, sous
# « --demarrer », jamais employé par défaut — si le contexte de lancement change
# un jour, il est là avec sa limite écrite, plutôt qu'à réinventer.
# run-in-container.sh ne passe pas cette option.
#
# La limite qui subsiste, et qui n'est pas résolue : si Docker Desktop tombe,
# aucun chemin de ce dépôt ne peut le relever. Elle est consignée, c'est tout.
# -------------------------------------------------------------------
#
# Deux gardes, qui ne se négocient pas :
#
#   1. cet outil n'arrête JAMAIS Docker Desktop. Aucun « Stop-Process », aucun
#      « docker … stop », aucun chemin du code ne l'éteint : l'application fait
#      peut-être tourner un conteneur qui n'appartient pas au dépôt, et rien ici
#      ne justifie de l'interrompre ;
#   2. le nombre de démarrages est plafonné — PLAFOND_DEMARRAGES, écrit et nommé.
#      Au-delà, l'outil rend 3 et s'arrête plutôt que de boucler. Cette garde ne
#      s'applique qu'au chemin « --demarrer », le seul qui démarre quoi que ce
#      soit.
#
# Sur le chemin par défaut, la présence du *processus* est contrôlée à chaque
# sondage, et pas seulement la réponse du démon : c'est elle qui distingue « le
# moteur n'est pas encore prêt » de « l'application est morte en route », deux
# situations que le seul « docker info » confond. Dans le doute — contrôle de
# présence sans réponse —, l'outil suppose l'application lancée et attend.
#
# Le contrôle de disponibilité est exactement celui de run-in-container.sh —
# « docker info --format {{.ServerVersion}} », réponse non vide — et non un
# contrôle d'un autre genre : deux définitions du mot « prêt » finiraient par
# diverger, et c'est l'appelant qui en paierait le prix.
#
# Aucune attente n'est laissée libre. TASK-020 a consacré trois tours de
# correction à ce sujet dans run-in-container.sh : le blocage ne disparaissait
# pas, il se déplaçait d'un appel Docker à l'autre. Tout appel externe passe donc
# ici par « borner », y compris les appels PowerShell — un démon figé retient
# « docker info » aussi sûrement qu'il retenait « docker ps », et un
# « Get-Process » n'a aucune raison d'être la seule attente sans fin du script.
#
# Aucune confirmation n'est demandée, et rien n'est détruit : sur son chemin par
# défaut ce script n'agit pas du tout sur la machine, il l'interroge. Il est
# appelé automatiquement par run-in-container.sh — une invite y attendrait une
# réponse que personne n'est là pour donner. « --dry-run » reste disponible pour
# voir ce qui serait fait sans que rien ne le soit.
#
# Hors périmètre, délibérément : l'arrêt de Docker Desktop, l'installation de
# Docker s'il est absent, le redémarrage de la machine, tout démon distant ou tout
# contexte docker autre que celui par défaut, et toute autre action sur l'hôte que
# le démarrage de cette seule application.

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
source "$_dir/lib/common.sh"

DRY_RUN="false"

# Le démarrage de Docker Desktop est une option, et non le comportement par
# défaut : voir le relevé du 2026-09-04 en tête de fichier. Rien ne met cette
# variable à « true » hors de « --demarrer », explicitement demandé.
DEMARRAGE_AUTORISE="false"

# -------------------------------------------------------------------
# L'application
# -------------------------------------------------------------------
# Chemin mesuré sur cette machine le 2026-09-04. Il n'est pas deviné : il est
# vérifié par « Test-Path » avant le premier démarrage, et un chemin absent
# arrête l'outil avec un diagnostic — installer Docker est hors de son périmètre.
# Il n'est lu que sur le chemin « --demarrer ».
CHEMIN_DOCKER_DESKTOP='C:\Program Files\Docker\Docker\Docker Desktop.exe'

# Nom du processus tel que Get-Process le connaît, mesuré sur cette machine. Il ne
# se déduit pas du nom du fichier : Windows retire le « .exe », et l'espace fait
# partie du nom.
NOM_PROCESSUS='Docker Desktop'

# -------------------------------------------------------------------
# Délais et plafonds
# -------------------------------------------------------------------
# Trois de ces valeurs sont adossées à une mesure, relevée le 2026-09-04 lors du
# premier usage réel ; la principale ne l'est pas, et le dit à sa ligne.
#
# Ce sont des BORNES, pas des durées attendues. La mesure dit ce qui a été
# observé, la borne laisse la marge au-delà : les confondre ferait lire un faux
# positif comme une panne de Docker, alors qu'il ne dirait que « la borne est trop
# courte ».

# Borne d'un sondage pris isolément — « docker info », « Get-Process »,
# « Test-Path ».
#
# MESURÉ le 2026-09-04 : « docker info » sur un démon absent répond en moins
# d'une seconde. Cinq secondes laissent donc plus de cinq fois la marge, et le cas
# nominal — le démon répond déjà, un seul sondage — tient largement sous les cinq
# secondes du critère d'acceptation.
#
# Ce qui n'a pas été mesuré : le même appel sur un démon *figé*, qui est
# précisément le cas pour lequel cette borne existe. Un démon absent répond vite
# parce qu'il refuse la connexion ; un démon figé, lui, ne refuse rien.
DELAI_SONDAGE=5

# Sursis laissé entre le signal d'arrêt de « timeout » et son SIGKILL. Même raison
# que dans run-in-container.sh : sous MSYS, la délivrance d'un signal ordinaire à
# un binaire natif — docker.exe, powershell.exe — n'a pas été mesurée, et un
# signal ignoré ferait attendre « timeout » lui-même. Posé, comme là-bas.
DELAI_ABATTAGE=5

# Borne du « Start-Process » lui-même. Il ne démarre pas Docker, il le lance :
# PowerShell crée le processus et rend la main.
#
# MESURÉ le 2026-09-04, sur les deux tentatives : 1 à 2 secondes. La borne reste à
# trente — elle n'est pas une durée attendue mais le seuil au-delà duquel plus
# rien de légitime ne travaille, et la rabaisser au ras de la mesure ne ferait
# gagner que des échecs sur une machine chargée.
DELAI_LANCEMENT=30

# Délai laissé au processus « Docker Desktop » pour se montrer. Il sert deux fois,
# et pour la même raison — savoir combien de temps l'absence du processus reste
# une absence provisoire :
#
#   après un « Start-Process », le temps que l'application crée son processus ;
#   au démarrage de l'attente, le temps que le lancement automatique de Windows
#     fasse la même chose — c'est le cas d'une tâche lancée dans la minute qui
#     suit l'ouverture de session.
#
# MESURÉ le 2026-09-04 : le processus est apparu après 14 s à la première
# tentative, 13 s à la seconde. La borne de soixante secondes laisse plus de
# quatre fois la marge observée. La poser trop court ferait conclure à l'absence
# une application qui se lance ; la poser trop long ne coûte rien, puisque
# l'apparition met fin à l'attente dès qu'elle est constatée.
DELAI_APPARITION=60

# Pause entre deux sondages. La bonne valeur est celle qui ne noie pas le journal
# sans retarder la reprise : à cette échelle — des minutes —, sonder chaque
# seconde n'apprend rien de plus. Posé.
INTERVALLE_SONDAGE=5

# Périodicité des lignes d'attente dans la trace. Une attente de plusieurs minutes
# qui n'écrit rien est indistinguable d'un script bloqué. Posé.
INTERVALLE_TRACE=30

# Plafond de l'attente entière.
#
# CETTE VALEUR RESTE POSÉE. Elle n'a pas pu être mesurée le 2026-09-04 : le moteur
# n'a jamais été prêt, l'application s'étant quittée d'elle-même les deux fois. La
# seule chose que cette exécution ait établie, c'est que le plafond est atteint et
# qu'il rend la main — pas qu'il soit à la bonne hauteur. Un démarrage à froid
# initialise WSL2, monte ses systèmes de fichiers et lance son moteur ; cinq
# minutes restent une supposition, à confirmer le jour où un démarrage complet
# sera observé de bout en bout.
DELAI_DISPONIBILITE=300

# Le plafond de la seconde garde, sur le chemin « --demarrer » uniquement. Deux,
# et non un : un plantage survenu au milieu d'une suite doit pouvoir être
# rattrapé, ce qu'une tentative unique par exécution interdirait. Deux, et non
# davantage : si Docker Desktop meurt deux fois de suite dans la même attente, il
# ne s'agit plus d'un accident et recommencer ne ferait que retarder le
# diagnostic. Le relevé du 2026-09-04 a exercé ce plafond, et il a tenu.
PLAFOND_DEMARRAGES=2

# Ce que l'appelant doit prévoir au pire, annoncé sous ce nom avant l'attente.
# Trois termes sur le chemin par défaut, chaque appel externe se comptant pour sa
# borne plus le sursis DELAI_ABATTAGE avant SIGKILL :
#
#   le plafond de l'attente, qui compte les sondages ;
#   le dernier sondage, le plafond n'étant contrôlé qu'après lui ;
#   le « docker info » du diagnostic final, sur le chemin d'échec.
#
# Le chemin « --demarrer » y ajoute un dernier démarrage entamé juste avant
# l'échéance, dont l'attente d'apparition n'est pas retranchée du plafond.
#
# La somme majore — les chemins ne s'additionnent pas tous —, et c'est ce qu'on
# attend d'un pire cas.
DELAI_PIRE_CAS=$((DELAI_DISPONIBILITE + 2 * (DELAI_SONDAGE + DELAI_ABATTAGE)))
DELAI_PIRE_CAS_DEMARRAGE=$((DELAI_PIRE_CAS + DELAI_APPARITION))

# Témoin de disponibilité : l'horodatage du dernier sondage réussi. Il ne sert
# qu'à la trace — il distingue « le démon répondait il y a deux minutes » de « le
# démon n'a jamais été vu prêt » — et NE CHANGE AUCUNE DÉCISION. C'est délibéré :
# le comportement de l'outil ne doit dépendre que de ce qu'il constate lui-même,
# jamais d'un fichier qu'un tiers peut effacer.
TEMOIN="$LOG_DIR/assurer-docker.temoin"

# -------------------------------------------------------------------
# Aide
# -------------------------------------------------------------------
show_help() {
    cat <<AIDE
Usage : tests/env/assurer-docker.sh [options]

Attend que le démon Docker soit disponible sur cette machine : constate son
état, attend que le moteur réponde, diagnostique s'il ne répond pas, et rend la
main. Toutes les attentes sont bornées en temps mural. Cet outil ne démarre rien
de lui-même — Docker Desktop est lancé au démarrage du système.

Ce qu'il traite, un traitement par état :

  le démon répond                          rien, code 0
  lancé, moteur pas encore prêt            attente — c'est le cas courant, une
                                           tâche lancée peu après l'ouverture de
                                           session tombe dessus
  le processus n'est pas (encore) là       attente de son apparition, au plus
                                           ${DELAI_APPARITION}s
  le processus disparaît pendant l'attente plantage : code 3, avec la durée
  plafond ou délai atteint                 code 3, avec diagnostic

Deux gardes :

  cet outil n'arrête JAMAIS Docker Desktop, par aucun chemin — l'application
  peut faire tourner un conteneur qui ne relève pas de ce dépôt ;
  avec --demarrer, le nombre de démarrages est plafonné à ${PLAFOND_DEMARRAGES} par exécution.

Options :
      --demarrer  Autoriser le démarrage de Docker Desktop quand son processus
                  est absent. HORS DU CHEMIN PAR DÉFAUT, et pour cause : mesuré
                  le 2026-09-04, ce démarrage échoue depuis la session de
                  l'agent. L'application se lance — processus visible après 13 à
                  14s —, affiche une boîte d'erreur puis se quitte d'elle-même
                  (« com.docker.backend.exe services: exit status 150 »), alors
                  que le même lancement fait à la main réussit sans erreur. Le
                  défaut tient au contexte de lancement, pas à Docker.
                  run-in-container.sh ne passe pas cette option. Relevé complet
                  en tête du script.
      --dry-run   Constater l'état et annoncer ce qui serait fait, sans rien
                  lancer. Le code 0 ne signifie alors pas que le démon est
                  disponible : il signifie que l'annonce a été faite.
  -h, --help      Afficher cette aide

Délais :
  sondage                  ${DELAI_SONDAGE}s par appel, + ${DELAI_ABATTAGE}s de sursis avant SIGKILL
                           (mesuré : « docker info » sur démon absent < 1s)
  apparition du processus  ${DELAI_APPARITION}s (mesuré : 13 à 14s)
  lancement                ${DELAI_LANCEMENT}s pour « Start-Process » (mesuré : 1 à 2s)
  attente du moteur        ${DELAI_DISPONIBILITE}s au total, sondé toutes les ${INTERVALLE_SONDAGE}s — POSÉ,
                           jamais mesuré : le moteur n'a jamais été vu prêt
  pire cas annoncé         ${DELAI_PIRE_CAS}s avant que la main soit rendue,
                           ${DELAI_PIRE_CAS_DEMARRAGE}s avec --demarrer

Codes de retour :
  0   le démon Docker répond — dès le premier contrôle ou après attente ; ou, en
      --dry-run, l'annonce a été faite
  2   erreur d'usage — option inconnue
  3   démon indisponible — docker, timeout ou powershell absent, Docker Desktop
      non lancé ou arrêté en cours d'attente, plafond de démarrages atteint, ou
      moteur toujours muet au bout de ${DELAI_DISPONIBILITE}s
AIDE
}

# -------------------------------------------------------------------
# Arguments
# -------------------------------------------------------------------
while [ "${1:-}" != "" ]; do
    case "$1" in
        --demarrer) DEMARRAGE_AUTORISE="true"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) die "Option inconnue : $1" 2 ;;
    esac
done

# Le pire cas annoncé dépend du chemin emprunté : seul « --demarrer » ajoute une
# attente d'apparition au-delà du plafond.
if [ "$DEMARRAGE_AUTORISE" = "true" ]; then
    PIRE_CAS_ANNONCE="$DELAI_PIRE_CAS_DEMARRAGE"
else
    PIRE_CAS_ANNONCE="$DELAI_PIRE_CAS"
fi

# -------------------------------------------------------------------
# Chemins et Git Bash
# -------------------------------------------------------------------
# Sous MSYS (Git Bash), tout argument qui ressemble à un chemin POSIX est réécrit
# avant d'atteindre un binaire natif. Ces deux variables désactivent la réécriture,
# comme dans run-in-container.sh ; elles sont sans effet sur un hôte Linux.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# -------------------------------------------------------------------
# Préflight
# -------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    error "La commande docker est introuvable sur cette machine."
    die "Démon Docker indisponible — rien n'a été démarré." 3
fi

# « timeout » borne chaque appel de ce script : les sondages du démon, les
# contrôles de présence, le lancement le cas échéant. Sans lui, un démon figé ou
# un PowerShell qui ne rend pas la main suspendrait l'outil exactement là où il
# promet de ne jamais suspendre. Contrairement à run-in-container.sh, qui ne
# l'exige qu'en mode systemd, il est ici une condition d'existence : un outil
# d'attente sans borne n'aurait aucune raison d'être appelé.
if ! command -v timeout >/dev/null 2>&1; then
    error "La commande timeout (GNU coreutils) est introuvable sur cette machine."
    error "Cet outil ne fait qu'attendre, et il promet que chacune de ses attentes"
    error "est bornée. Sans timeout, cette promesse ne tient plus."
    die "Démon Docker indisponible — rien n'a été démarré." 3
fi

# Docker Desktop est une application Windows : c'est PowerShell qui dit si son
# processus tourne. Son absence signe un hôte qui n'est pas celui pour lequel cet
# outil est écrit — un conteneur Linux, par exemple.
if ! command -v powershell >/dev/null 2>&1; then
    error "La commande powershell est introuvable sur cette machine."
    error "Cet outil observe Docker Desktop, application Windows : il n'a de sens que"
    error "sur l'hôte, jamais dans un conteneur."
    die "Démon Docker indisponible — rien n'a été démarré." 3
fi

# -------------------------------------------------------------------
# Bornes de temps
# -------------------------------------------------------------------
# Codes par lesquels GNU timeout signale que le délai a expiré : 124 après le
# signal d'arrêt ordinaire, 137 (128+9) lorsque la commande n'a cédé qu'au SIGKILL
# de « -k ». Même convention que run-in-container.sh, et pour les mêmes raisons.
expiration() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

# Tout appel externe de ce script passe par ici, sans exception : « docker info »,
# « Get-Process », « Test-Path », « Start-Process ». Aucun d'eux n'exécute de
# travail long — ce sont des questions, ou un lancement qui rend la main aussitôt.
borner() {
    local delai="$1"; shift
    timeout -k "$DELAI_ABATTAGE" "$delai" "$@"
}

# -------------------------------------------------------------------
# Constats
# -------------------------------------------------------------------
# Le contrôle de disponibilité, repris de run-in-container.sh à l'identique : le
# client peut répondre alors que le moteur est arrêté, d'où le test sur le contenu
# et non sur le seul code de retour.
#
# Deux globales plutôt qu'une sortie sur stdout : appelée en substitution de
# commande, la fonction s'exécuterait dans un sous-shell et ne pourrait rien
# transmettre d'autre.
#
#   VERSION_SERVEUR  la version du moteur, quand il répond
#   MOTIF_SONDAGE    pourquoi il n'a pas répondu, pour la trace
VERSION_SERVEUR=""
MOTIF_SONDAGE=""
demon_repond() {
    local sortie="" code=0
    VERSION_SERVEUR=""
    MOTIF_SONDAGE=""

    sortie="$(borner "$DELAI_SONDAGE" docker info --format '{{.ServerVersion}}' 2>/dev/null)" \
        || code="$?"
    sortie="${sortie//$'\r'/}"

    if expiration "$code"; then
        MOTIF_SONDAGE="aucune réponse en ${DELAI_SONDAGE}s"
        return 1
    fi
    if [ "$code" -ne 0 ]; then
        MOTIF_SONDAGE="« docker info » a échoué (code $code)"
        return 1
    fi
    if [ -z "$sortie" ]; then
        MOTIF_SONDAGE="version serveur vide — le client répond, le moteur non"
        return 1
    fi

    VERSION_SERVEUR="$sortie"
    return 0
}

# Présence du processus « Docker Desktop », sous borne. Trois issues :
#
#   0  le processus tourne
#   1  il ne tourne pas — constaté, pas supposé
#   2  la présence n'a pas pu être établie : borne expirée, PowerShell en erreur,
#      ou réponse inattendue
#
# Le 2 n'est pas un raffinement. Un contrôle sans réponse ne dit pas que
# l'application est éteinte, il dit qu'on ne sait pas — et conclure dans le doute,
# c'est soit démarrer une seconde instance par-dessus une première qui démarre,
# soit déclarer mort un démarrage en cours. L'appelant traite donc 2 comme
# « présent, on attend ».
processus_present() {
    local sortie="" code=0
    sortie="$(borner "$DELAI_SONDAGE" powershell -NoProfile -Command \
        "if (Get-Process '$NOM_PROCESSUS' -ErrorAction SilentlyContinue) { 'present' } else { 'absent' }" \
        2>/dev/null)" || code="$?"

    if [ "$code" -ne 0 ]; then
        return 2
    fi

    sortie="${sortie//[[:space:]]/}"
    case "$sortie" in
        present) return 0 ;;
        absent)  return 1 ;;
        *)       return 2 ;;
    esac
}

# Existence de l'application au chemin attendu, contrôlée une seule fois, juste
# avant le premier démarrage — donc seulement sur le chemin « --demarrer ». Un
# « Start-Process » sur un chemin absent échoue en annonçant clairement la cause ;
# ce contrôle-ci existe pour que la cause soit nommée AVANT d'avoir consommé une
# tentative du plafond.
#
# Seule une absence *constatée* arrête l'outil. Un contrôle qui ne répond pas ne
# prouve rien et ne doit pas empêcher d'essayer.
chemin_absent() {
    local sortie="" code=0
    sortie="$(borner "$DELAI_SONDAGE" powershell -NoProfile -Command \
        "if (Test-Path -LiteralPath '$CHEMIN_DOCKER_DESKTOP') { 'present' } else { 'absent' }" \
        2>/dev/null)" || code="$?"

    if [ "$code" -ne 0 ]; then
        warn "Le chemin de Docker Desktop n'a pas pu être vérifié (code $code) : démarrage tenté malgré tout."
        return 1
    fi

    sortie="${sortie//[[:space:]]/}"
    [ "$sortie" = "absent" ]
}

# Une réponse qui n'est pas celle attendue reste affichable, mais bornée : sur une
# seule ligne, et tronquée. Un pavé PowerShell noierait sinon le diagnostic.
reponse_lisible() {
    local texte="${1//[[:cntrl:]]/ }"
    if [ "${#texte}" -gt 160 ]; then
        printf '%s […]\n' "${texte:0:160}"
    else
        printf '%s\n' "$texte"
    fi
}

# -------------------------------------------------------------------
# Témoin de disponibilité
# -------------------------------------------------------------------
# Écrit à chaque sondage réussi. Son échec n'interrompt rien : c'est une trace,
# pas un état dont l'outil dépendrait.
ecrire_temoin() {
    if [ -z "$LOG_FILE" ]; then
        return 0
    fi
    if ! date '+%s' > "$TEMOIN" 2>/dev/null; then
        warn "Témoin de disponibilité non écrit : $TEMOIN — sans conséquence sur l'exécution."
    fi
}

# Ce qui distingue le plantage en cours de route d'une machine qui vient de
# démarrer, dans la TRACE et seulement dans la trace : un démon qui répondait il y
# a deux minutes et ne répond plus n'est pas un démon jamais vu prêt. Les deux
# mènent à la même attente, mais pas au même diagnostic, et c'est ce diagnostic
# qui dira plus tard qu'un plantage récurrent de Docker n'était pas une lenteur de
# l'agent.
#
# Le message pose la chronologie avant de rendre la main, et ce n'est pas de
# l'ornement : les constats qui suivent parlent au présent — « Docker Desktop
# n'est pas lancé » —, ce qui, lu juste après « plantage en cours de route »,
# passait pour une contradiction alors que les deux disent la même chute vue à
# deux instants. Dire « a répondu, puis est tombé, donc voici l'état
# maintenant » lève l'ambiguïté sans rien changer à ce qui est constaté.
annoncer_temoin() {
    local valeur="" maintenant="" age=0

    if [ ! -r "$TEMOIN" ]; then
        info "Aucun témoin de disponibilité antérieure : rien n'atteste que le démon ait déjà répondu."
        return 0
    fi

    valeur="$(cat "$TEMOIN" 2>/dev/null || true)"
    valeur="${valeur//[^0-9]/}"
    maintenant="$(date '+%s' 2>/dev/null || true)"
    maintenant="${maintenant//[^0-9]/}"

    if [ -z "$valeur" ] || [ -z "$maintenant" ]; then
        info "Témoin de disponibilité illisible : $TEMOIN — sans conséquence sur l'exécution."
        return 0
    fi

    age=$((maintenant - valeur))
    warn "Le démon a répondu il y a ${age}s (témoin $TEMOIN), puis s'est tu : Docker Desktop"
    warn "a démarré, puis est tombé — plantage en cours de route, et non démon jamais démarré."
    warn "Ce qui suit décrit son état APRÈS cette chute : « pas lancé » s'y lit au présent."
}

# -------------------------------------------------------------------
# Démarrage — chemin « --demarrer » uniquement
# -------------------------------------------------------------------
# Le seul endroit du script qui agit sur la machine hôte, et il est hors du chemin
# par défaut depuis le 2026-09-04 : le relevé en tête de fichier dit ce qu'il a
# produit — l'application se lance, puis se quitte d'elle-même avec « exit status
# 150 », quand le même lancement fait à la main réussit.
#
# Il lance l'application, et rien d'autre : aucune commande d'arrêt n'est écrite
# ici ni ailleurs.
#
# Rend 0 lorsque le processus est présent à la sortie, 1 lorsque le lancement a
# échoué ou que le processus n'est pas apparu. Un échec n'arrête pas l'outil : le
# tour de boucle suivant reconstate l'état, et c'est le plafond qui tranche.
DEMARRAGES=0
demarrer_docker_desktop() {
    local depart="$SECONDS" ecoule=0 code=0 sortie="" etat=0

    if [ "$DEMARRAGES" -eq 0 ] && chemin_absent; then
        error "Docker Desktop est introuvable au chemin attendu :"
        error "  $CHEMIN_DOCKER_DESKTOP"
        error "Installer Docker est hors du périmètre de cet outil. Si l'application est"
        error "installée ailleurs, corriger CHEMIN_DOCKER_DESKTOP en tête de ce script."
        die "Démon Docker indisponible — aucun démarrage n'a été tenté." 3
    fi

    DEMARRAGES=$((DEMARRAGES + 1))
    info "Démarrage de Docker Desktop (tentative $DEMARRAGES/$PLAFOND_DEMARRAGES) : $CHEMIN_DOCKER_DESKTOP"

    sortie="$(borner "$DELAI_LANCEMENT" powershell -NoProfile -Command \
        "Start-Process '$CHEMIN_DOCKER_DESKTOP'" 2>&1)" || code="$?"
    ecoule=$((SECONDS - depart))

    if expiration "$code"; then
        warn "« Start-Process » n'a pas rendu la main en ${DELAI_LANCEMENT}s — abandonné après ${ecoule}s."
        warn "Le processus a pu être créé malgré tout : la présence est reconstatée avant toute autre tentative."
        return 1
    fi
    if [ "$code" -ne 0 ]; then
        error "« Start-Process » a échoué (code $code) après ${ecoule}s."
        if [ -n "$sortie" ]; then
            error "Réponse de PowerShell : $(reponse_lisible "$sortie")"
        fi
        return 1
    fi

    info "Commande de démarrage rendue en ${ecoule}s — attente de l'apparition du processus (au plus ${DELAI_APPARITION}s)."

    # Attendre l'apparition, et non enchaîner : tant que le processus n'est pas
    # constaté présent, aucun second démarrage n'est possible, puisque cette
    # fonction ne rend pas la main. Lancer une seconde instance par-dessus une
    # première qui démarre est le meilleur moyen de tout casser.
    while true; do
        etat=0
        processus_present || etat="$?"
        ecoule=$((SECONDS - depart))

        if [ "$etat" -eq 0 ]; then
            info "Processus « $NOM_PROCESSUS » présent après ${ecoule}s de démarrage."
            return 0
        fi
        # Présence indéterminée : on rend la main comme si elle était acquise. La
        # boucle principale reconstatera, et son plafond tranchera — insister ici
        # ne ferait que reposer la même question au même service muet.
        if [ "$etat" -eq 2 ]; then
            warn "Présence de « $NOM_PROCESSUS » indéterminée après ${ecoule}s : le démarrage est considéré comme lancé."
            return 0
        fi
        if [ "$ecoule" -ge "$DELAI_APPARITION" ]; then
            warn "Le processus « $NOM_PROCESSUS » n'est pas apparu en ${ecoule}s."
            return 1
        fi
        sleep "$INTERVALLE_SONDAGE"
    done
}

# -------------------------------------------------------------------
# Échec
# -------------------------------------------------------------------
# Sortie unique de toutes les fins non nominales — application absente, application
# arrêtée en cours d'attente, plafond atteint, délai dépassé. Toutes disent la même
# chose : le démon n'est pas disponible, et l'outil s'arrête là plutôt que de
# boucler.
#
# Le conseil donné ici est celui qui fait gagner du temps à qui le lit : le
# démarrage automatique ne fonctionne pas depuis cette session, le lancement doit
# être fait à la main. Dire seulement « ouvrir Docker Desktop et lire son état »
# laisserait croire qu'une option du script aurait pu l'éviter.
DEBUT_TOTAL=0
DERNIER_ETAT="-"
PROCESSUS_VU_PRESENT="false"
echouer() {
    local raison="$1" ecoule=$((SECONDS - DEBUT_TOTAL)) libelle=""

    case "$DERNIER_ETAT" in
        0) libelle="Docker Desktop lancé, moteur muet" ;;
        1) libelle="Docker Desktop non lancé" ;;
        2) libelle="présence de Docker Desktop indéterminée" ;;
        *) libelle="aucun constat" ;;
    esac

    error "$raison"
    if [ "$DEMARRAGE_AUTORISE" = "true" ]; then
        error "Durée totale : ${ecoule}s ; ${DEMARRAGES} démarrage(s) tentés sur un plafond de ${PLAFOND_DEMARRAGES}."
    else
        error "Durée totale : ${ecoule}s ; aucun démarrage tenté — l'option --demarrer n'a pas été donnée."
    fi
    error "Dernier état constaté : $libelle. Dernier motif de sondage : ${MOTIF_SONDAGE:-aucun}."
    error "Réponse brute du démon, pour mémoire :"
    borner "$DELAI_SONDAGE" docker info 2>&1 | head -n 5 >&2 || true
    error "Docker Desktop n'a pas été arrêté, et ne le sera pas : un conteneur hors dépôt peut en dépendre."
    error "Ce qu'il faut faire : lancer Docker Desktop À LA MAIN, attendre qu'il soit prêt, puis relancer."
    error "Le démarrage automatique ne fonctionne pas depuis cette session, et c'est mesuré :"
    error "le 2026-09-04, l'application lancée par « Start-Process » s'est quittée d'elle-même"
    error "après une boîte d'erreur (« exit status 150 »), deux fois de suite, alors que le même"
    error "lancement fait à la main réussissait sans erreur. Relevé complet en tête de ce script."
    error "Ensuite : « docker info » pour le message complet."
    error "Si le moteur devient disponible peu après ce message, c'est la borne DELAI_DISPONIBILITE"
    error "(${DELAI_DISPONIBILITE}s) qui est trop courte pour cette machine, pas Docker qui est en panne."
    die "Démon Docker indisponible." 3
}

# -------------------------------------------------------------------
# Le démon répond déjà
# -------------------------------------------------------------------
DEBUT_TOTAL="$SECONDS"

if demon_repond; then
    ecoule=$((SECONDS - DEBUT_TOTAL))
    success "Le démon Docker répond — version serveur $VERSION_SERVEUR (constaté en ${ecoule}s, rien à faire)."
    ecrire_temoin
    exit 0
fi

warn "Le démon Docker ne répond pas : $MOTIF_SONDAGE (constaté en $((SECONDS - DEBUT_TOTAL))s)."
annoncer_temoin

# -------------------------------------------------------------------
# Dry-run
# -------------------------------------------------------------------
# Constater est sans effet ; attendre et agir ne le sont pas. Le dry-run interroge
# donc réellement l'état — démon, puis processus — et n'annonce que ce qu'il
# aurait fait ensuite.
if [ "$DRY_RUN" = "true" ]; then
    etat=0
    processus_present || etat="$?"
    case "$etat" in
        0)
            info "[dry-run] Docker Desktop est lancé, son moteur ne répond pas encore."
            info "[dry-run] attente seule, sondage toutes les ${INTERVALLE_SONDAGE}s, abandon au-delà de ${DELAI_DISPONIBILITE}s"
            ;;
        1)
            info "[dry-run] Docker Desktop n'est pas lancé."
            if [ "$DEMARRAGE_AUTORISE" = "true" ]; then
                info "[dry-run] powershell -NoProfile -Command \"Start-Process '$CHEMIN_DOCKER_DESKTOP'\""
                info "[dry-run] attente de l'apparition du processus, au plus ${DELAI_APPARITION}s"
                info "[dry-run] puis attente du moteur, sondage toutes les ${INTERVALLE_SONDAGE}s, abandon au-delà de ${DELAI_DISPONIBILITE}s"
                info "[dry-run] au plus ${PLAFOND_DEMARRAGES} démarrage(s) ; au-delà, code 3"
            else
                info "[dry-run] aucun démarrage : ce n'est pas le chemin par défaut, et --demarrer n'a pas été donné."
                info "[dry-run] attente de l'apparition du processus, au plus ${DELAI_APPARITION}s, puis code 3"
            fi
            ;;
        *)
            info "[dry-run] la présence de Docker Desktop n'a pas pu être établie."
            info "[dry-run] aucune conclusion dans ce doute : seule l'attente aurait lieu."
            ;;
    esac
    info "[dry-run] durée maximale avant reprise de la main : ${PIRE_CAS_ANNONCE}s"
    success "[dry-run] Aucune exécution — Docker Desktop n'a pas été lancé."
    exit 0
fi

# -------------------------------------------------------------------
# L'attente
# -------------------------------------------------------------------
# Un seul tour de boucle traite tous les états restants, parce qu'ils ne se
# distinguent que par un constat, refait à chaque tour :
#
#   processus présent    -> attendre, sans rien lancer — le cas courant
#   présence inconnue    -> attendre, sans rien lancer — le doute ne conclut pas
#   processus absent     -> attendre son apparition tant que DELAI_APPARITION
#                           n'est pas écoulé ; au-delà, échouer. Avec --demarrer,
#                           démarrer plutôt, si le plafond le permet
#   processus disparu    -> plantage : échouer tout de suite, rien ne le relèvera
#   plafond ou délai     -> échouer, et ne pas recommencer
#
# Deux absences qu'il ne faut pas confondre. Le processus jamais vu peut être
# celui d'une session qui vient de s'ouvrir : le lancement automatique de Windows
# ne l'a pas encore créé, et il apparaîtra — d'où l'attente bornée par
# DELAI_APPARITION, la même borne que pour un « Start-Process », pour la même
# raison. Le processus vu puis disparu, lui, est un plantage constaté : personne
# ne le relancera, et attendre cinq minutes de plus ne ferait que retarder le
# message.
if [ "$DEMARRAGE_AUTORISE" = "true" ]; then
    warn "Option --demarrer : le démarrage de Docker Desktop est autorisé pour cette exécution."
    warn "Il a échoué les deux fois où il a été mesuré, le 2026-09-04 — voir l'en-tête de ce script."
fi

info "Attente du démon Docker : sondage toutes les ${INTERVALLE_SONDAGE}s, abandon au-delà de ${DELAI_DISPONIBILITE}s ; ${PIRE_CAS_ANNONCE}s au pire avant que la main soit rendue."

PROCHAINE_TRACE="$INTERVALLE_TRACE"

while true; do
    etat=0
    processus_present || etat="$?"
    ecoule=$((SECONDS - DEBUT_TOTAL))

    if [ "$etat" -eq 0 ]; then
        PROCESSUS_VU_PRESENT="true"
    fi

    if [ "$etat" != "$DERNIER_ETAT" ]; then
        case "$etat" in
            0) info "Docker Desktop est lancé — attente du moteur, sans rien lancer." ;;
            1)
                if [ "$PROCESSUS_VU_PRESENT" = "true" ]; then
                    warn "Le processus « $NOM_PROCESSUS » a disparu après ${ecoule}s d'attente : Docker Desktop s'est arrêté en cours de démarrage."
                else
                    info "Le processus « $NOM_PROCESSUS » n'est pas là — attente de son apparition, au plus ${DELAI_APPARITION}s."
                    info "Une session qui vient de s'ouvrir n'a parfois pas encore lancé l'application."
                fi
                ;;
            *) warn "La présence de Docker Desktop n'a pas pu être établie : dans le doute, aucune conclusion — attente seule." ;;
        esac
        DERNIER_ETAT="$etat"
    fi

    if [ "$etat" -eq 1 ]; then
        if [ "$DEMARRAGE_AUTORISE" = "true" ]; then
            if [ "$DEMARRAGES" -ge "$PLAFOND_DEMARRAGES" ]; then
                echouer "Plafond de démarrages atteint : Docker Desktop a été lancé ${DEMARRAGES} fois sans que son moteur réponde."
            fi
            demarrer_docker_desktop || true
            DERNIER_ETAT="-"
        elif [ "$PROCESSUS_VU_PRESENT" = "true" ]; then
            echouer "Docker Desktop s'est arrêté après ${ecoule}s : son processus a disparu, et rien ici ne le relancera."
        elif [ "$ecoule" -ge "$DELAI_APPARITION" ]; then
            echouer "Docker Desktop n'est pas lancé : son processus « $NOM_PROCESSUS » ne s'est pas montré en ${ecoule}s."
        fi
    fi

    sleep "$INTERVALLE_SONDAGE"

    if demon_repond; then
        ecoule=$((SECONDS - DEBUT_TOTAL))
        success "Le démon Docker répond après ${ecoule}s — version serveur $VERSION_SERVEUR."
        if [ "$DEMARRAGES" -gt 0 ]; then
            info "Bilan : ${ecoule}s d'attente au total, ${DEMARRAGES} démarrage(s) de Docker Desktop."
        else
            info "Bilan : ${ecoule}s d'attente au total, aucun démarrage — l'application était déjà lancée."
        fi
        ecrire_temoin
        exit 0
    fi

    ecoule=$((SECONDS - DEBUT_TOTAL))
    if [ "$ecoule" -ge "$DELAI_DISPONIBILITE" ]; then
        echouer "Le démon Docker n'a pas répondu au bout de ${ecoule}s (plafond ${DELAI_DISPONIBILITE}s)."
    fi

    if [ "$ecoule" -ge "$PROCHAINE_TRACE" ]; then
        info "Attente du démon : ${ecoule}s écoulées sur ${DELAI_DISPONIBILITE}s — ${MOTIF_SONDAGE}, ${DEMARRAGES} démarrage(s)."
        PROCHAINE_TRACE=$((ecoule + INTERVALLE_TRACE))
    fi
done
