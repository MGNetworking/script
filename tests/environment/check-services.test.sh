#!/usr/bin/env bash
# tests/environment/check-services.test.sh — Linux/System/check-services.sh, exécuté.
#
# TASK-023. Le script est un diagnostic EN LECTURE SEULE — il n'agit sur aucun
# service —, mais son mode « --service » répond à une question fermée dont le
# code de retour porte la réponse. Éprouver ce contrat impose de créer les
# situations qu'il décrit : un service arrêté, un service masqué, un service
# inconnu, une unité en échec. C'est le fichier de cas qui les fabrique, jamais
# le script.
#
# ---------------------------------------------------------------------------
# Ce fichier MODIFIE le système sur lequel il tourne
# ---------------------------------------------------------------------------
#
#   - il ARRÊTE un service témoin, puis le relance ;
#   - il DÉPOSE une unité vouée à l'échec dans /etc/systemd/system, la démarre,
#     puis la retire.
#
# Il ne touche à rien tant qu'il n'a pas reconnu un SYSTÈME JETABLE — /.dockerenv,
# un cgroup de conteneur, ou MGNET_TEST_JETABLE=1 —, exactement comme les
# fichiers de tests/integration/. Ailleurs, les groupes modifiants se déclarent
# NON EXÉCUTÉS.
#
#   tests/env/run-in-container.sh --profil systemd -- tests/run.sh environment
#
# ---------------------------------------------------------------------------
# Le témoin, et pourquoi celui-là
# ---------------------------------------------------------------------------
#
# systemd-logind.service. Mesuré dans l'image du profil « systemd » : chargé,
# actif, « static » ; « systemctl stop » rend 0 et le laisse « inactive/dead » ;
# « systemctl start » le ramène « active/running ».
#
# Surtout, RIEN DANS LA SUITE N'EN DÉPEND : hostnamectl et timedatectl —
# éprouvés par systemd.test.sh — passent par systemd-hostnamed et
# systemd-timedated, pas par logind. Ni dbus.service ni systemd-journald.service
# ne conviendraient : tous deux sont activés par socket et reviennent seuls, et
# couper dbus casserait en outre systemd.test.sh.
#
# getty@tty1.service est ÉCARTÉ COMME TÉMOIN, et l'écarter est délibéré : mesuré
# instable — il part en boucle de redémarrage et bascule seul en « failed » au
# bout de deux à trois secondes, ou pas. Aucune assertion de ce fichier ne porte
# sur son état, ni sur son code de retour, ni sur le nombre de services en échec,
# ni sur la valeur de « systemctl is-system-running ».
#
# Il sert à UNE SEULE CHOSE, au groupe 3.2 : prouver qu'un nom d'instance reçoit
# « .service » et que c'est l'unité normalisée qui est affichée. L'assertion y
# porte sur le NOM AFFICHÉ, jamais sur l'état ni sur le code — elle reste donc
# vraie quel que soit le tour que prend ce service.
#
# ---------------------------------------------------------------------------
# La restauration du témoin n'est pas négociable
# ---------------------------------------------------------------------------
#
# run-environment.sh découvre ses fichiers par « find … | sort » :
# check-services.test.sh s'exécute donc AVANT systemd.test.sh. Un témoin laissé
# à terre, ou une unité fabriquée laissée en place, empoisonnerait le fichier
# suivant — et le défaut apparaîtrait à l'autre bout de la suite, loin de sa
# cause.
#
# Trois protections, qui ne se remplacent pas :
#
#   1. un « trap » sur EXIT relance le témoin et retire l'unité fabriquée, y
#      compris si une assertion échoue au milieu ou si le fichier est
#      interrompu. Ce filet ne rend compte de rien : il rattrape ;
#   2. chaque groupe modifiant restaure lui-même, en fin de groupe ;
#   3. le groupe 9 VÉRIFIE la restauration par une lecture indépendante du
#      script. Une restauration silencieusement ratée est pire que pas de
#      restauration du tout : elle se verrait alors dans systemd.test.sh, et
#      non ici.
#
# ---------------------------------------------------------------------------
# Ce fichier reste utile SANS systemd, et c'est structurant
# ---------------------------------------------------------------------------
#
# « tests/run.sh » sans argument passe par le niveau environment, y compris sous
# le profil « debian » où systemctl est absent. Un fichier qui n'y ferait que
# sauter sortirait en 3 — rien n'est prouvé — et ferait rougir la commande de
# référence du dépôt (tests/README.md §2).
#
# L'ordre des gardes de check-services.sh le permet : parsing, puis validation
# du nom, puis « require_cmd systemctl ». Onze cas du groupe 1 s'exécutent donc
# partout, sans init :
#
#   --help                     code 0, et l'aide nomme les SEPT issues
#   --inconnue                 code 2
#   --service sans valeur      code 2
#   --service « a b »          code 2 AVANT toute interrogation du système
#   --service --help           code 2 — la valeur en tiret n'est pas avalée
#   --service dbus.socket      code 2 — une socket n'est pas un service
#   --service local-fs.target  code 2 — un target non plus
#   --service …-clean.timer    code 2 — un timer non plus
#   --service com.exemple.app  code 2 — un point, mais aucun type connu derrière
#   --service ..               code 2 — le même refus, sur sa forme la plus nue
#   systemctl introuvable      code 1, message NOMMANT la dépendance
#
# Les cinq refus de point tombent eux aussi AVANT « require_cmd systemctl » :
# une assertion d'absence du message de require_cmd l'établit, sous debian, plutôt
# qu'un commentaire.
#
# LES CINQ NE PORTENT PAS LE MÊME MESSAGE, et le 1.2 bis éprouve les deux
# moitiés : un suffixe de type connu renvoie vers « systemctl status », un point
# qui n'ouvre sur aucun type ne le fait pas — il ne désigne aucune unité, la
# commande ne pourrait rien répondre.
#
# Le dernier est joué partout : sous debian par une exécution nue, sous systemd
# par un bac à sable de PATH qui masque systemctl. Le mettre en échec ne
# suffirait pas — « command -v » réussirait encore et require_cmd ne verrait
# rien. Le montage est celui de tests/integration/check-memory.test.sh.
#
# ---------------------------------------------------------------------------
# La garde MESURE systemd, elle ne lit pas le nom du profil
# ---------------------------------------------------------------------------
#
# Comme systemd.test.sh : le nom d'un profil ne prouve rien. Deux sources
# indépendantes — ce que le noyau dit du PID 1, et ce que le manager dit de
# lui-même. « running » et « degraded » valent tous deux : degraded signifie
# qu'une unité a échoué, ce qui est banal en conteneur. « offline » et
# « unknown » disent que rien ne répond.
#
# ---------------------------------------------------------------------------
# Deux pièges de systemctl, dont ce fichier tient compte
# ---------------------------------------------------------------------------
#
#   - « systemctl show » rend TOUJOURS 0, même pour une unité inconnue, qu'il
#     décrit alors par « LoadState=not-found ». Un code de retour ne dit donc
#     rien ici : c'est la valeur lue qui tranche ;
#   - « systemctl is-active » rend 3 pour une unité inactive, en échec ET
#     inconnue. Il ne distingue rien, et ne peut servir ni au script ni aux
#     mesures de contrôle de ce fichier.

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
# shellcheck source=/dev/null
source "$_dir/lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPTS_ROOT/tests/lib/assert.sh"

CHECK_SERVICES_SH="$SCRIPTS_ROOT/Linux/System/check-services.sh"

# Le témoin qu'on arrête et qu'on relance — voir l'en-tête pour le choix.
TEMOIN="systemd-logind.service"

# Unité fabriquée pour le cas « en échec ». Le PID du fichier de cas la rend
# unique d'une exécution à l'autre.
UNITE_ECHEC="mgnet-test-echec-$$.service"
FICHIER_UNITE_ECHEC="/etc/systemd/system/$UNITE_ECHEC"

# Nom d'unité qui ne désigne rien, et qui ne risque pas de se mettre à exister.
UNITE_INCONNUE="mgnet-test-inexistant-$$.service"

REP_TMP="$(mktemp -d)"
F_OUT="$REP_TMP/stdout"
F_ERR="$REP_TMP/stderr"
CODE=0

# Renseignées par les groupes modifiants, relues par le filet posé sur EXIT.
TEMOIN_ARRETE=""
UNITE_ECHEC_POSEE=""

# Filet de sécurité — il RATTRAPE, il ne prouve rien.
#
# Les « || true » qui suivent sont ceux d'un nettoyage, jamais ceux d'une
# assertion : ce filet s'exécute aussi après un échec, sur un système dont on ne
# sait plus rien, et il ne doit ni s'interrompre ni masquer le code de sortie
# réel. La restauration est ASSERTÉE ailleurs — en fin de groupe modifiant, puis
# de nouveau au groupe 9, par une lecture indépendante du script.
filet_de_securite() {
    local code="$?"
    if command -v systemctl >/dev/null 2>&1; then
        if [ -n "$TEMOIN_ARRETE" ]; then
            systemctl start "$TEMOIN_ARRETE" >/dev/null 2>&1 || true
        fi
        if [ -n "$UNITE_ECHEC_POSEE" ]; then
            systemctl stop "$UNITE_ECHEC_POSEE" >/dev/null 2>&1 || true
            systemctl reset-failed "$UNITE_ECHEC_POSEE" >/dev/null 2>&1 || true
            rm -f "$FICHIER_UNITE_ECHEC" 2>/dev/null || true
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$REP_TMP"
    return "$code"
}
trap filet_de_securite EXIT

# ===================================================================
# Outillage
# ===================================================================

# lancer <commande...> — exécute dans un SOUS-SHELL et capture le code.
#
# Le sous-shell est indispensable : le script pose « set -Eeuo pipefail » et
# lib/common.sh un « trap ERR ». Un « die … 2 » tuerait le harnais s'il n'était
# pas isolé. L'entrée standard est fermée, comme partout ailleurs dans tests/.
lancer() {
    CODE=0
    ( "$@" ) >"$F_OUT" 2>"$F_ERR" </dev/null || CODE=$?
}

sortie() { cat "$F_OUT"; }
erreur() { cat "$F_ERR"; }

# --- Mesure du volume de stderr --------------------------------------------
# Ce que ces deux fonctions permettent d'exiger n'est pas dans le contenu d'un
# message mais dans sa QUANTITÉ : c'est la seule forme d'assertion qui empêche
# une aide entière, un second diagnostic ou une ligne du trap ERR de revenir
# sur stderr sans qu'on le voie.
#
# Le « || [ -n "$ligne_lue" ] » compte la dernière ligne même sans saut de ligne
# final : sans lui, un diagnostic non terminé serait décompté à zéro.

nb_lignes_erreur() {
    local ligne_lue n=0
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        n=$(( n + 1 ))
    done < "$F_ERR"
    printf '%s' "$n"
}

nb_lignes_contenant() {
    local motif="$1" ligne_lue n=0
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        if contient "$ligne_lue" "$motif"; then
            n=$(( n + 1 ))
        fi
    done < "$F_ERR"
    printf '%s' "$n"
}

# --- Lecture de la sortie du script ----------------------------------------
# La mise en page vient de « titre() » et de « ligne() » : un titre collé à la
# marge, une ligne de tirets, des lignes « libellé <remplissage> valeur » et des
# paragraphes, tous indentés de deux espaces.
#
# Une section commence donc à son titre et s'arrête au titre suivant, reconnu à
# ce qu'il est le SEUL contenu non vide à commencer à la marge. Les lignes vides
# n'interrompent pas la section — contrairement à ce que fait le lecteur de
# tests/integration/check-memory.test.sh —, parce qu'ici le tableau des unités
# est séparé de son décompte par une ligne vide et qu'il appartient pourtant
# bien à la section.

region_section() {
    local titre_section="$1" ligne_lue dans="non"
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        if [ "$ligne_lue" = "$titre_section" ]; then
            dans="oui"
            continue
        fi
        [ "$dans" = "oui" ] || continue
        case "$ligne_lue" in
            '')       continue ;;
            ' '*|-*)  printf '%s\n' "$ligne_lue" ;;
            *)        dans="non" ;;
        esac
    done < "$F_OUT"
}

# valeur_ligne <titre de section> <libellé> — la valeur affichée en face de ce
# libellé, DANS CETTE SECTION.
#
# Le contrôle du caractère qui suit le libellé n'est pas un ornement : sans lui,
# « Unité » capturerait l'en-tête de tableau « Unité … Sous-état … ». Le
# remplissage de « ligne() » vaut au moins un espace, ce caractère est donc
# toujours un espace pour un libellé complet.
valeur_ligne() {
    local titre_section="$1" libelle="$2" ligne_lue
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        case "$ligne_lue" in
            "  $libelle"*)
                ligne_lue="${ligne_lue#"  $libelle"}"
                case "$ligne_lue" in ' '*) ;; *) continue ;; esac
                while [ "${ligne_lue# }" != "$ligne_lue" ]; do
                    ligne_lue="${ligne_lue# }"
                done
                printf '%s' "$ligne_lue"
                return 0
                ;;
        esac
    done < <(region_section "$titre_section")
    return 0
}

# nb_unites_section <titre de section> — le nombre de lignes de la section qui
# nomment une unité de service.
#
# C'EST LE DÉCOMPTE QUI VOIT UN TABLEAU VIDE : une assertion de contenu
# resterait verte sur un écran blanc. « --type=service » garantit le suffixe de
# tout ce que list-units renvoie, et ni l'en-tête de tableau ni les paragraphes
# de « note() » ne le portent.
nb_unites_section() {
    local ligne_lue n=0
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        if contient "$ligne_lue" ".service"; then
            n=$(( n + 1 ))
        fi
    done < <(region_section "$1")
    printf '%s' "$n"
}

# --- Mesures de contrôle, indépendantes du script ---------------------------

# champ_unite <unité> <propriété> — ce que SYSTEMD dit de l'unité.
#
# En contexte de condition (TASK-018) : sous la forme nue, un systemctl en échec
# ferait parler le trap ERR de lib/common.sh sans nommer la cause. LC_ALL=C pour
# que les horodatages restent comparables à ceux que le script affiche, qu'il
# lit lui aussi sous cette locale.
champ_unite() {
    local valeur=""
    if ! valeur="$(LC_ALL=C systemctl show -p "$2" --value -- "$1" 2>/dev/null)"; then
        valeur=""
    fi
    printf '%s' "$valeur"
}

# attendu_affiche <valeur systemd> — ce que « ligne() » affiche pour cette
# valeur : la valeur elle-même, ou « non disponible » quand elle est vide.
#
# Une propriété sans valeur — UnitFileState d'une unité inconnue,
# ActiveEnterTimestamp d'un service jamais démarré — produit une ligne « Clé= »
# que systemctl rend vide. Le script affiche alors « non disponible » plutôt
# qu'un blanc, et c'est ce contrat que cette fonction permet d'asserter sans
# figer laquelle des deux formes l'environnement produira.
attendu_affiche() {
    if [ -z "$1" ]; then
        printf 'non disponible'
    else
        printf '%s' "$1"
    fi
}

# premier_champ <ligne de list-units> — le nom d'unité d'une ligne de tableau.
# La première colonne peut porter un marqueur — un point médian devant les
# unités en échec — que « --no-legend » ne retire pas.
premier_champ() {
    local premier reste
    read -r premier reste <<< "$1"
    if [ "${premier%.service}" = "$premier" ]; then
        read -r premier _ <<< "$reste"
    fi
    printf '%s' "$premier"
}

# --- Preuve de la lecture seule --------------------------------------------

# empreinte <destination> — l'état de tout /etc, contenu compris.
#
# Tout /etc et non une liste arrêtée d'avance : c'est ce qui permet de voir une
# écriture qu'on n'attendait pas. LOG_DIR en est absent par construction — il
# vaut /var/log/mgnetworking sous root — et lib/common.sh y écrit au seul
# chargement, avant que le script n'ait lu ses arguments.
empreinte() {
    local destination="$1"
    local code=0
    {
        find /etc -type f -exec cksum {} + 2>/dev/null | sort
        find /etc -type l -printf 'lien %p -> %l\n' 2>/dev/null | sort
    } > "$destination" || code=$?
    if [ "$code" -ne 0 ]; then
        warn "Relevé d'empreinte incomplet (code $code) : $destination"
    fi
}

# assert_aucune_ecriture <témoin> <libellé> — aucun fichier modifié depuis le
# témoin, hors journaux.
#
# La référence est un FICHIER et non une date : « find -newer » compare à la
# précision du système de fichiers, là où « -newermt @secondes » arrondit et
# ferait remonter tout ce que le système a écrit dans la même seconde.
#
# /var, /tmp ET /home SONT SURVEILLÉS, et c'est le seul montage qui donne au
# critère « le script n'écrit rien en dehors du journal ouvert par
# lib/common.sh » une portée POSITIVE : sous root, LOG_DIR vaut
# /var/log/mgnetworking (lib/common.sh) — écarter /var en entier retirerait du
# même geste le seul endroit où le script a le droit d'écrire, et le critère
# resterait muet sur la moitié qui compte.
#
# LES EXCLUSIONS SONT MESURÉES, une par une, dans le conteneur du profil
# systemd — « touch témoin ; check-services.sh ; check-services.sh --service … ;
# find /var /tmp /home -newer témoin ». Trois passes successives, puis une
# quatrième sur une fenêtre de 15 s englobant trois exécutions :
#
#   passe 1  /var/log/mgnetworking et /var/log/mgnetworking/check-services.log
#   passes 2 et 3  /var/log/mgnetworking/check-services.log seul
#   fenêtre de 15 s  rien d'autre — ni /var/lib/systemd, ni /var/cache, ni
#                    /var/spool, ni /var/log/journal, ni /tmp, ni /home
#
# D'où les exclusions retenues, et elles seules :
#
#   $LOG_DIR et son contenu   le journal de lib/common.sh — celui du script
#                             (check-services.log) et celui de ce fichier de cas
#                             (check-services.test.log), tous deux écrits dans la
#                             fenêtre de mesure. C'est l'écriture AUTORISÉE par
#                             le critère, et la seule qui ait été mesurée ;
#   /var/log/journal          journald. Mesuré immobile pendant une exécution du
#                             script, mais mesuré en mouvement — system.journal —
#                             dès qu'une unité journalise : un « systemctl stop »
#                             puis « start » du témoin le fait bouger. Il écrit
#                             pour des raisons étrangères au script, et il
#                             synchronise de lui-même ;
#   /tmp et /var/tmp, LE NŒUD SEUL  leur horodatage change quand systemd crée ou
#                             retire un répertoire « systemd-private-* » au
#                             démarrage d'une unité — mesuré lors du stop/start
#                             du témoin. Le contenu de /tmp reste surveillé : un
#                             fichier que le script y déposerait serait vu ;
#   les « systemd-private-* » ces répertoires appartiennent à systemd, jamais au
#                             script — mesurés créés par paires sous /tmp et
#                             /var/tmp au démarrage d'une unité à PrivateTmp ;
#   $REP_TMP et son contenu   le bac à sable de CE FICHIER DE CAS, qui vit sous
#                             /tmp : sorties capturées, empreintes, bac à sable
#                             de PATH. Ce sont les écritures du harnais, pas
#                             celles du script.
#
# La SENSIBILITÉ de ce relevé a été mesurée elle aussi, et c'est ce qui sépare
# une exclusion étroite d'une exclusion qui aveugle : quatre écritures
# délibérées — /var/lib/mgnet-sonde, /var/log/mgnet-sonde, /tmp/mgnet-sonde,
# /home/mgnet-sonde — ont TOUTES été remontées par cette commande, répertoire
# parent compris. Aucune n'est masquée par les motifs ci-dessus.
assert_aucune_ecriture() {
    local temoin="$1" libelle="$2"
    local racine code=0
    local -a racines=()

    for racine in /etc /root /usr /opt /srv /boot /var /tmp /home; do
        if [ -d "$racine" ]; then
            racines+=("$racine")
        fi
    done

    find "${racines[@]}" -newer "$temoin" \
        -not -path "$LOG_DIR" \
        -not -path "$LOG_DIR/*" \
        -not -path '/var/log/journal' \
        -not -path '/var/log/journal/*' \
        -not -path '/tmp' \
        -not -path '/var/tmp' \
        -not -path '/tmp/systemd-private-*' \
        -not -path '/var/tmp/systemd-private-*' \
        -not -path "$REP_TMP" \
        -not -path "$REP_TMP/*" \
        2>/dev/null | sort > "$REP_TMP/ecritures" || code=$?

    if [ "$code" -ne 0 ]; then
        warn "Relevé des écritures incomplet (code $code)"
    fi
    if [ -s "$REP_TMP/ecritures" ]; then
        ko "$libelle" "$(tr '\n' ' ' < "$REP_TMP/ecritures")"
    else
        ok "$libelle"
    fi
}

# --- Assertions composées ---------------------------------------------------

# refus_usage <libellé> <motif attendu> <arguments...>
#
# Le refus, et ce qui compte au moins autant : QUE RIEN N'AIT ÉTÉ PRODUIT AVANT
# LUI, et que le trap ERR de lib/common.sh n'ait pas doublé le diagnostic. Le
# second point est le motif tranché par TASK-018, qu'un script neuf ne doit pas
# réintroduire.
refus_usage() {
    local libelle="$1" motif="$2"; shift 2

    lancer bash "$CHECK_SERVICES_SH" "$@"
    assert_code 2 "$CODE" "check-services.sh refuse $libelle"
    assert_contient "$(erreur)" "$motif" "check-services.sh, $libelle : la cause est nommée"
    assert_absent "$(erreur)" "Échec (code" \
        "check-services.sh, $libelle : le trap ERR n'ajoute aucune ligne"
    assert_absent "$(erreur)" "check-services.sh: line" \
        "check-services.sh, $libelle : aucun message brut de bash sur stderr"
    assert_absent "$(erreur)" "Usage :" \
        "check-services.sh, $libelle : l'aide n'est pas déversée sur stderr"
    assert_egal "" "$(sortie)" \
        "check-services.sh, $libelle : AUCUNE sortie de diagnostic avant le refus"
}

# invariants_diagnostic <libellé> — ce qu'aucune exécution aboutie ne doit
# violer, quel que soit son code de retour.
invariants_diagnostic() {
    local libelle="$1"
    assert_absent "$(erreur)" "Échec (code" \
        "check-services.sh, $libelle : le trap ERR n'ajoute aucune ligne"
    assert_absent "$(erreur)" "check-services.sh: line" \
        "check-services.sh, $libelle : aucun message brut de bash sur stderr"
    assert_absent "$(erreur)" "command not found" \
        "check-services.sh, $libelle : aucun « command not found » sur stderr"
}

# --- Bac à sable de PATH ----------------------------------------------------
# Un PATH reproduit par liens symboliques, SANS la commande visée. La mettre en
# échec ne suffirait pas : « command -v » réussirait encore et require_cmd ne
# verrait rien. Rien n'est touché sur le système.
sablonner() {
    local destination="$1" exclu="$2" repertoire binaire nom
    mkdir -p "$destination"
    for repertoire in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        [ -d "$repertoire" ] || continue
        for binaire in "$repertoire"/*; do
            nom="${binaire##*/}"
            [ "$nom" != "$exclu" ] || continue
            [ -e "$destination/$nom" ] || ln -s "$binaire" "$destination/$nom" 2>/dev/null || true
        done
    done
}

# ===================================================================
# 0. Reconnaissance de l'environnement
# ===================================================================
titre "0. Environnement"

EST_LINUX="false"
if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    EST_LINUX="true"
fi

EST_ROOT="false"
if [ "$(id -u)" -eq 0 ]; then
    EST_ROOT="true"
fi

# Un système jetable, et rien d'autre, autorise les groupes modifiants.
JETABLE="false"
if [ -f /.dockerenv ]; then
    JETABLE="true"
elif grep -qE '(docker|containerd|lxc)' /proc/1/cgroup 2>/dev/null; then
    JETABLE="true"
elif [ "${MGNET_TEST_JETABLE:-}" = "1" ]; then
    JETABLE="true"
fi

# La MESURE de systemd, jamais le nom du profil. Deux sources indépendantes : ce
# que le noyau dit du PID 1, et ce que le manager dit de lui-même. La seconde
# seule ne suffirait pas — un systemctl présent sans init répond « offline ».
INIT_PID1="$(cat /proc/1/comm 2>/dev/null || true)"

SYSTEMCTL="non"
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMCTL="oui"
fi

ETAT_SYSTEME=""
if [ "$SYSTEMCTL" = "oui" ]; then
    ETAT_SYSTEME="$(systemctl is-system-running 2>/dev/null || true)"
fi

SYSTEMD="non"
case "$ETAT_SYSTEME" in
    running|degraded|starting|maintenance)
        if [ "$INIT_PID1" = "systemd" ]; then
            SYSTEMD="oui"
        fi
        ;;
esac

info "Linux : $EST_LINUX — root : $EST_ROOT — jetable : $JETABLE"
info "systemctl présent : $SYSTEMCTL — PID 1 : « ${INIT_PID1:-inconnu} » — is-system-running : « ${ETAT_SYSTEME:-aucune réponse} » — systemd : $SYSTEMD"

if [ ! -f "$CHECK_SERVICES_SH" ]; then
    ko "Linux/System/check-services.sh existe" "fichier introuvable : $CHECK_SERVICES_SH"
    bilan "environment / check-services.sh"
    exit 1
fi
ok "Linux/System/check-services.sh existe"

if [ "$EST_LINUX" != "true" ]; then
    # Hors Linux, ni /proc/1/comm ni systemctl n'existent : le script démarrerait
    # pour buter sur require_cmd, et les cas ne diraient rien de son
    # comportement réel.
    saute_par_nature "l'ensemble des cas de check-services.sh" \
        "cet hôte n'est pas un Linux — ni systemd ni son outillage n'y existent"
    bilan "environment / check-services.sh"
    exit 0
fi

# Raison unique des sauts liés à l'absence d'init, calculée une fois : un NON
# EXÉCUTÉ sans motif ne renseigne personne. Elle nomme ce qui a été MESURÉ, et
# non le profil — c'est la même phrase qui vaudra pour tout environnement sans
# init.
SANS_SYSTEMD="aucun systemd interrogeable : « systemctl présent » vaut « $SYSTEMCTL », le PID 1 est « ${INIT_PID1:-inconnu} » et « systemctl is-system-running » rend « ${ETAT_SYSTEME:-aucune réponse} » — ce n'est pas une lacune de l'image, un init tient au mode de lancement du conteneur"

# Les groupes modifiants exigent en plus le privilège et un système jetable.
MODIFIANT="oui"
if [ "$SYSTEMD" != "oui" ]; then
    MODIFIANT="$SANS_SYSTEMD"
elif [ "$EST_ROOT" != "true" ]; then
    MODIFIANT="arrêter un service et déposer une unité demandent root"
elif [ "$JETABLE" != "true" ]; then
    MODIFIANT="cet hôte n'est pas un système jetable — aucun service ne sera arrêté, aucune unité déposée"
fi

# saute_modifiant <libellé> — saut d'un cas des groupes 6 et 7, QUALIFIÉ selon
# ce qui manque.
#
# L'absence d'init est une limite PAR NATURE : un profil sans PID 1 systemd ne
# rendra jamais ces cas atteignables, et c'est l'exemple canonique que
# tests/README.md §2 donne de cette qualification. Le manque de privilège ou un
# système non jetable, eux, sont des propriétés de la MACHINE courante — ils
# tombent ailleurs sur une autre machine — et n'autorisent que le saut neutre.
saute_modifiant() {
    if [ "$MODIFIANT" = "$SANS_SYSTEMD" ]; then
        saute_par_nature "$1" "$MODIFIANT"
    else
        saute "$1" "$MODIFIANT"
    fi
}

# Le témoin est-il utilisable ? MESURÉ une seule fois, à l'entrée du fichier, et
# jamais supposé : plusieurs groupes s'y adossent, et l'état relevé ici est
# celui d'AVANT toute modification. C'est aussi la référence à laquelle le
# groupe 9 compare la restitution.
TEMOIN_UTILISABLE="non"
if [ "$SYSTEMD" = "oui" ]; then
    if [ "$(champ_unite "$TEMOIN" LoadState)" = "loaded" ] \
       && [ "$(champ_unite "$TEMOIN" ActiveState)" = "active" ]; then
        TEMOIN_UTILISABLE="oui"
    fi
fi
info "Témoin « $TEMOIN » utilisable : $TEMOIN_UTILISABLE"

# ===================================================================
# 1. Ce qui ne dépend d'aucun systemd
# ===================================================================
# Ce groupe s'exécute sous TOUS les profils, et il le doit : sans au moins une
# réussite, le fichier sortirait en 3 sous le profil debian. Il sert en outre de
# GARDE DE CONTRASTE aux groupes suivants — si le script ne démarrait plus du
# tout, on le saurait ici avant de conclure quoi que ce soit sur systemd.
titre "1. Ce qui ne dépend d'aucun systemd"

# --- 1.1 L'aide -------------------------------------------------------------
lancer bash "$CHECK_SERVICES_SH" --help
assert_code 0 "$CODE" "check-services.sh --help sort en 0"
aide="$(sortie)"
assert_contient "$aide" "Usage : check-services.sh" \
    "check-services.sh --help écrit son usage sur stdout"
assert_contient "$aide" "--service <nom>" "l'aide documente --service"
assert_contient "$aide" "-h, --help" "l'aide documente --help"

# LES SEPT ISSUES de --service, nommées une par une, chacune AVEC SON CODE.
# Chacune tient sur une seule ligne de l'aide : le motif complet la verrouille
# bien mieux qu'un mot isolé, et c'est le contrat que TASK-023 exige de voir
# documenté.
#
# La phrase d'introduction est assertée elle aussi, sur le MOT QUI LES COMPTE.
# Une ligne ajoutée au tableau sans que « six » ne devienne « sept » rendrait
# l'aide contradictoire avec elle-même, et aucune assertion de tableau ne le
# verrait — c'est exactement ce qui s'est produit quand « unité non chargée » y
# est entrée.
#
# Deux des sept sont PROUVÉES ailleurs dans ce fichier : « état inétablissable »
# au groupe 4.4 sur « --service @ », « service en échec » au groupe 7 sur une
# unité fabriquée. UNE SEULE NE L'EST PAS — « unité non chargée » : l'atteindre
# demanderait une seconde unité déposée dans /etc/systemd/system, portant une
# faute qui fasse échouer son chargement, et un second chemin de restitution.
# Elle n'est donc éprouvée ici QUE comme ligne d'aide. Elle est DÉCLARÉE au
# groupe 8, avec sa mesure, pour qu'elle pèse au bilan plutôt que de reposer sur
# ce seul commentaire.
assert_contient "$aide" "une seule vaut 0, les six autres valent 1" \
    "l'aide annonce le compte exact des issues — une en 0, six en 1"
assert_contient "$aide" "service actif       l'unité est chargée et active                     code 0" \
    "l'aide documente l'issue « service actif », en code 0"
assert_contient "$aide" "service inconnu     systemd ne connaît aucune unité de ce nom         code 1" \
    "l'aide documente l'issue « service inconnu », en code 1"
assert_contient "$aide" "service masqué      l'unité est masquée : elle ne peut pas démarrer   code 1" \
    "l'aide documente l'issue « service masqué », en code 1"
assert_contient "$aide" "unité non chargée   systemd n'a pas pu charger son fichier d'unité    code 1" \
    "l'aide documente l'issue « unité non chargée », en code 1"
assert_contient "$aide" "service en échec    l'unité est chargée, son exécution a échoué       code 1" \
    "l'aide documente l'issue « service en échec », en code 1"
assert_contient "$aide" "service inactif     l'unité est chargée mais n'est pas active         code 1" \
    "l'aide documente l'issue « service inactif », en code 1"
assert_contient "$aide" "état inétablissable « systemctl show » n'a rien rendu d'exploitable   code 1" \
    "l'aide documente l'issue « état inétablissable », en code 1"

# LE REFUS DES UNITÉS QUI NE SONT PAS DES SERVICES, documenté lui aussi : c'est
# un code 2, et l'appelant doit savoir où lire l'état d'un timer ou d'un socket.
assert_contient "$aide" "SEULES LES UNITÉS « .service » sont" \
    "l'aide dit que seules les unités « .service » sont acceptées"
assert_contient "$aide" "il porte un suffixe autre que « .service »" \
    "l'aide range le suffixe étranger parmi les refus antérieurs à l'interrogation du système"
assert_contient "$aide" "L'état des autres unités se lit avec « systemctl status »." \
    "l'aide dit où lire l'état d'une unité qui n'est pas un service"

# Les TROIS CODES de retour, et ce que chacun recouvre.
#
# LES MOTIFS SONT DES FRAGMENTS, JAMAIS DES LIGNES ENTIÈRES, et c'est une leçon
# payée : la rubrique est enroulée à la main, et l'énumération du code 1 s'est
# recoupée sur deux lignes le jour où « non chargé » y est entré. Un motif qui
# épousait toute la ligne a rougi sans qu'aucun contrat n'ait changé. Chaque
# fragment ci-dessous tient dans une ligne, et nomme UNE chose : l'enroulement
# peut bouger sans les casser, un terme retiré les fait rougir.
assert_contient "$aide" "Codes de retour :" "l'aide porte une rubrique des codes de retour"
assert_contient "$aide" "0  inventaire produit" "l'aide documente le code 0"
assert_contient "$aide" "ou service demandé ACTIF" \
    "l'aide range « service demandé actif » dans le code 0"
assert_contient "$aide" "1  --service : service inactif" "l'aide documente le code 1"
assert_contient "$aide" "en échec, masqué, non chargé ou inconnu" \
    "l'aide énumère les cinq états de --service qui valent 1, « non chargé » compris"
assert_contient "$aide" "« systemctl » absent ; état impossible à établir" \
    "l'aide range « systemctl absent » et « état impossible à établir » dans le code 1"
assert_contient "$aide" "2  erreur d'usage : option inconnue, --service sans valeur" \
    "l'aide documente le code 2"
assert_contient "$aide" "manifestement invalide, unité autre qu'un service" \
    "l'aide range « unité autre qu'un service » dans le code 2"

# Le contrat des deux modes, que l'aide doit dire — sans quoi un appelant
# attendrait un code non nul d'un inventaire portant un service en échec.
assert_contient "$aide" "TOUJOURS 0" \
    "l'aide dit que l'inventaire rend toujours 0"
assert_contient "$aide" "aucune modification, aucun privilège requis, aucune" \
    "l'aide annonce la lecture seule et l'absence de privilège"
assert_contient "$aide" "L'absence de « systemctl » rend 1, et non 2" \
    "l'aide dit que la dépendance absente vaut 1, jamais 2"

lancer bash "$CHECK_SERVICES_SH" -h
assert_code 0 "$CODE" "check-services.sh -h sort en 0 lui aussi"
assert_contient "$(sortie)" "Usage : check-services.sh" "check-services.sh -h écrit la même aide"

# --- 1.2 Les refus d'usage --------------------------------------------------
refus_usage "une option inconnue" \
    "[ERROR] Option inconnue : --inconnue" --inconnue

refus_usage "--service sans valeur" \
    "[ERROR] --service attend un nom de service." --service

# LE CAS QUI PROUVE L'ORDRE DES GARDES. Un nom qui ne peut pas être un nom
# d'unité est reproché à l'appelant AVANT toute interrogation du système. Sous
# le profil debian, où systemctl est absent, l'assertion d'absence est décisive :
# si le refus tombait après le préflight, c'est require_cmd qui parlerait, et le
# code serait 1.
refus_usage "un nom de service manifestement invalide" \
    "[ERROR] Nom de service invalide : « a b »." --service "a b"
assert_contient "$(erreur)" "n'admet que lettres, chiffres" \
    "check-services.sh, nom invalide : le message dit le JEU DE CARACTÈRES admis"
assert_absent "$(erreur)" "Commande(s) requise(s) introuvable(s)" \
    "check-services.sh : le nom invalide est refusé AVANT le préflight de systemctl"
# La première ligne de ce refus est MOT POUR MOT celle du refus d'un nom à
# points (1.2 bis) : « Nom de service invalide : « … ». ». Ce sont les lignes
# suivantes qui départagent les deux, et cette assertion d'absence est la moitié
# ici de ce que l'autre moitié asserte là-bas.
assert_absent "$(erreur)" "ne désigne donc aucune unité" \
    "check-services.sh, nom invalide : ce n'est pas le refus d'un nom à points"

# Une valeur commençant par un tiret est une option avalée comme nom :
# « --service --help » demanderait l'état d'un service nommé « --help », et
# l'aide serait perdue en silence.
refus_usage "une valeur de --service commençant par un tiret" \
    "[ERROR] Valeur refusée pour --service : « --help »." --service --help
assert_absent "$(sortie)" "Usage : check-services.sh" \
    "check-services.sh : « --service --help » n'affiche pas l'aide en douce"

# --- 1.2 bis Les unités qui ne sont pas des services -------------------------
# TASK-023 met « les unités autres que les services » hors périmètre, et le
# script en tire un REFUS D'USAGE : demander l'état d'un timer à
# check-services.sh est une faute d'appel — code 2 —, pas un constat du système.
# Répondre « Service actif : local-fs.target » serait de surcroît faux.
#
# Ce refus tombe AVANT « require_cmd systemctl », comme celui du nom invalide :
# les cinq cas s'exécutent donc partout, y compris sous un profil sans init.
# C'est ce que les assertions d'absence ci-dessous établissent, et non un
# commentaire — si le refus glissait après le préflight, ce serait require_cmd
# qui parlerait, et le code serait 1.
#
# DEUX REFUS DISTINCTS VIVENT SOUS CE POINT, et les confondre était le défaut
# corrigé après la première passe de ce fichier. Le départage se fait sur le
# SUFFIXE, comparé à la liste close des types d'unités de systemd :
#
#   - suffixe de TYPE CONNU — « .socket », « .target », « .timer », « .mount »… :
#     le nom désigne une unité RÉELLE d'un autre type. « systemctl status » est
#     conseillé, et il apprendra effectivement quelque chose à l'appelant ;
#   - TOUT AUTRE POINT — « com.exemple.app », « .. » : le nom ne désigne aucune
#     unité, d'aucun type. Y renvoyer vers « systemctl status » enverrait sur une
#     commande qui ne peut rien dire. Le message est donc autre, et l'ABSENCE du
#     conseil est assertée : c'est l'objet même de la correction.
#
# Les deux moitiés sont éprouvées ensemble, à dessein. La seconde est la
# nouveauté ; la première est la NON-RÉGRESSION, et c'est elle qu'un départage
# retouché casserait sans qu'on le voie.

# --- La moitié « type connu » : messages inchangés, « systemctl status » conseillé.
#
# LES QUATRE LIGNES du diagnostic sont assertées, et non la seule première :
# c'est la seule forme qui voie une ligne disparaître ou changer de conseil.
refus_type_connu() {
    local nom="$1" libelle="$2"

    refus_usage "$libelle" "[ERROR] Unité refusée pour --service : « $nom »." --service "$nom"
    assert_contient "$(erreur)" \
        "[ERROR] Ce script ne diagnostique que les services : seules les unités « .service » sont acceptées." \
        "check-services.sh, $libelle : le message dit la règle qui a valu le refus"
    assert_contient "$(erreur)" \
        "[ERROR] L'état d'une autre unité — timer, socket, target, mount — se lit avec : systemctl status $nom" \
        "check-services.sh, $libelle : le message conseille « systemctl status $nom »"
    assert_contient "$(erreur)" \
        "[ERROR] Un service dont le nom contient un point s'écrit avec son suffixe — par exemple : --service com.exemple.app.service" \
        "check-services.sh, $libelle : le message donne la forme d'un service dont le nom porte un point"
    # L'unité EXISTE : son nom n'est pas fautif, et le refus n'est pas celui d'un
    # nom qui ne désigne rien. Les deux motifs appartiennent à l'autre moitié.
    assert_absent "$(erreur)" "Nom de service invalide" \
        "check-services.sh, $libelle : le nom n'est pas déclaré invalide — l'unité existe"
    assert_absent "$(erreur)" "ne désigne donc aucune unité" \
        "check-services.sh, $libelle : le refus n'est pas celui d'un nom qui ne désigne rien"
    assert_absent "$(erreur)" "Service inconnu : «" \
        "check-services.sh, $libelle : le refus n'est pas présenté comme une inexistence"
    assert_absent "$(erreur)" "Commande(s) requise(s) introuvable(s)" \
        "check-services.sh, $libelle : le refus tombe AVANT le préflight de systemctl"
}

refus_type_connu "dbus.socket" "une unité de type socket"
refus_type_connu "local-fs.target" "une unité de type target"
refus_type_connu "systemd-tmpfiles-clean.timer" "une unité de type timer"

# --- La moitié « aucun type » : le message NOUVEAU, et l'absence du conseil.
#
# Le script ne peut pas deviner si « app » est le type de l'unité ou la fin du
# nom ; il constate que « app » n'est le type d'AUCUNE unité, et le dit — plutôt
# que de renvoyer vers un « systemctl status » qui ne pourrait rien répondre.
refus_nom_a_points() {
    local nom="$1" libelle="$2"

    refus_usage "$libelle" "[ERROR] Nom de service invalide : « $nom »." --service "$nom"
    assert_contient "$(erreur)" \
        "[ERROR] Le point d'un nom d'unité sépare un nom d'un TYPE connu — service, socket, timer, target, mount…" \
        "check-services.sh, $libelle : le message dit ce que le point d'un nom d'unité sépare"
    assert_contient "$(erreur)" "[ERROR] « $nom » ne désigne donc aucune unité, d'aucun type." \
        "check-services.sh, $libelle : le message conclut que le nom ne désigne aucune unité"
    assert_contient "$(erreur)" \
        "[ERROR] Corriger le nom — par exemple : --service ssh, ou --service com.exemple.app.service" \
        "check-services.sh, $libelle : le message donne la forme attendue"
    # L'OBJET MÊME DE LA CORRECTION. « systemctl status com.exemple.app »
    # n'apprendrait rien à personne : le conseil a quitté ce refus-ci, et il doit
    # y rester absent. Le motif est volontairement le plus large possible.
    assert_absent "$(erreur)" "systemctl status" \
        "check-services.sh, $libelle : « systemctl status » n'est PAS conseillé"
    assert_absent "$(erreur)" "Unité refusée pour --service" \
        "check-services.sh, $libelle : le refus n'est pas celui d'une unité d'un autre type"
    assert_absent "$(erreur)" "seules les unités « .service » sont acceptées" \
        "check-services.sh, $libelle : la règle du suffixe n'est pas invoquée — il n'y a pas de suffixe"
    # La première ligne est commune avec le refus du jeu de caractères
    # (« --service "a b" », au 1.2) : ce sont les lignes suivantes qui départagent
    # les deux, et celle du jeu de caractères doit rester absente ici.
    assert_absent "$(erreur)" "n'admet que lettres, chiffres" \
        "check-services.sh, $libelle : ce n'est pas le refus du jeu de caractères"
    assert_absent "$(erreur)" "Commande(s) requise(s) introuvable(s)" \
        "check-services.sh, $libelle : le refus tombe AVANT le préflight de systemctl"
}

refus_nom_a_points "com.exemple.app" "un nom à points sans suffixe « .service »"
# « .. » : un suffixe VIDE, donc d'aucun type connu, et pas davantage un nom.
# C'est le cas qui a fait corriger le message — « systemctl status .. » ne peut
# rien apprendre à personne.
refus_nom_a_points ".." "« .. », qui n'est le nom d'aucune unité d'aucun type"

# --- 1.3 L'absence de systemctl ---------------------------------------------
# Code 1, et un message qui NOMME la dépendance — jamais un message brut du
# shell. Joué partout : par une exécution nue là où systemctl est absent, par un
# bac à sable de PATH là où il est présent.
if [ "$SYSTEMCTL" = "oui" ]; then
    REP_SANS_SYSTEMCTL="$REP_TMP/bin-sans-systemctl"
    sablonner "$REP_SANS_SYSTEMCTL" "systemctl"
    if PATH="$REP_SANS_SYSTEMCTL" command -v systemctl >/dev/null 2>&1; then
        ko "garde : « systemctl » est bien masqué dans le bac à sable" \
            "il y reste visible — require_cmd ne verrait rien"
        saute_indisponible "check-services.sh sans systemctl" \
            "le bac à sable n'a pas masqué systemctl : le cas serait vert pour la mauvaise raison"
    else
        ok "garde : « systemctl » est bien masqué dans le bac à sable"
        lancer env "PATH=$REP_SANS_SYSTEMCTL" bash "$CHECK_SERVICES_SH"
        SANS_OUTIL="oui"
    fi
else
    ok "garde : « systemctl » est réellement absent de cet environnement"
    lancer bash "$CHECK_SERVICES_SH"
    SANS_OUTIL="oui"
fi

if [ "${SANS_OUTIL:-non}" = "oui" ]; then
    assert_code 1 "$CODE" "check-services.sh sans systemctl sort en 1, et non en 2"
    assert_contient "$(erreur)" "[ERROR] Commande(s) requise(s) introuvable(s) : systemctl" \
        "check-services.sh sans systemctl : le message NOMME la dépendance"
    assert_egal "1" "$(nb_lignes_contenant '[ERROR]')" \
        "check-services.sh sans systemctl : une seule ligne [ERROR]"
    assert_egal "1" "$(nb_lignes_erreur)" \
        "check-services.sh sans systemctl : stderr ne porte QUE ce diagnostic"
    assert_absent "$(erreur)" "command not found" \
        "check-services.sh sans systemctl : aucun message brut du shell"
    assert_absent "$(erreur)" "Échec (code" \
        "check-services.sh sans systemctl : le trap ERR n'ajoute aucune ligne"
    assert_egal "" "$(sortie)" \
        "check-services.sh sans systemctl : aucun diagnostic n'est produit"
fi

# ===================================================================
# 2. L'inventaire
# ===================================================================
titre "2. L'inventaire"

if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh inventorie les services" "$SANS_SYSTEMD"
    saute_par_nature "l'inventaire donne le nombre ET la liste des services actifs" "$SANS_SYSTEMD"
    saute_par_nature "l'inventaire porte une section des services en échec" "$SANS_SYSTEMD"
else
    lancer bash "$CHECK_SERVICES_SH"
    assert_code 0 "$CODE" "check-services.sh sans argument sort en 0"
    invariants_diagnostic "inventaire"
    assert_egal "0" "$(nb_lignes_contenant '[ERROR]')" \
        "check-services.sh, inventaire : aucune ligne [ERROR] — c'est un constat, pas un verdict"

    inventaire="$(sortie)"
    assert_contient "$inventaire" "Diagnostic des services systemd" \
        "l'inventaire affiche sa section d'en-tête"
    assert_contient "$inventaire" "Services actifs" \
        "l'inventaire affiche la section des services actifs"
    assert_contient "$inventaire" "Services en échec" \
        "l'inventaire affiche la section des services en échec"

    assert_egal "inventaire — le code de retour est toujours 0" \
        "$(valeur_ligne "Diagnostic des services systemd" "Mode")" \
        "l'en-tête annonce le mode et son contrat de sortie"
    # L'état global est vérifié par son APPARTENANCE aux états que systemd
    # connaît, jamais par égalité avec la valeur relevée au groupe 0 : les deux
    # lectures sont prises à des instants différents, et une unité qui bascule
    # entre-temps ferait rougir ce cas sans qu'aucun script ne soit en défaut.
    ETAT_AFFICHE="$(valeur_ligne "Diagnostic des services systemd" "État global")"
    case "$ETAT_AFFICHE" in
        initializing|starting|running|degraded|maintenance|stopping|offline|unknown)
            ok "l'en-tête reporte un état global que systemd connaît — « $ETAT_AFFICHE »" ;;
        *)
            ko "l'en-tête reporte un état global que systemd connaît" \
                "obtenu « $ETAT_AFFICHE »" ;;
    esac
    assert_contient "$inventaire" "n'est pas une panne du" \
        "l'en-tête dédramatise l'état « degraded »"

    # LE NOMBRE, ET LA LISTE. Le décompte affiché doit être celui du tableau :
    # une assertion de contenu resterait verte sur un écran blanc, et un nombre
    # seul ne prouverait pas que la liste suit.
    NB_ANNONCE="$(valeur_ligne "Services actifs" "Services actifs")"
    NB_LISTE="$(nb_unites_section "Services actifs")"
    if [ -n "$NB_ANNONCE" ] && [ -z "${NB_ANNONCE//[0-9]/}" ] && [ "$NB_ANNONCE" -ge 1 ]; then
        ok "l'inventaire annonce un nombre de services actifs — $NB_ANNONCE"
    else
        ko "l'inventaire annonce un nombre de services actifs" "obtenu « $NB_ANNONCE »"
    fi
    assert_egal "$NB_ANNONCE" "$NB_LISTE" \
        "la liste des services actifs porte exactement autant d'unités que le décompte annoncé"
    assert_contient "$inventaire" "Sous-état" \
        "la liste des services actifs est présentée en tableau, sous-état compris"

    # Contrôle INDÉPENDANT du script, mais SANS recompter : deux relevés pris à
    # une seconde d'intervalle peuvent différer légitimement — getty@tty1
    # bascule seul dans cette image. Ce qui est exigé, et qui ne dépend d'aucun
    # aléa, c'est qu'une unité dont on a MESURÉ qu'elle est active figure bien
    # dans la liste rendue.
    if [ "$TEMOIN_UTILISABLE" = "oui" ]; then
        assert_contient "$inventaire" "$TEMOIN" \
            "la liste des services actifs nomme « $TEMOIN », dont l'activité est mesurée par ailleurs"
    else
        saute_indisponible "la liste des services actifs nomme une unité mesurée active" \
            "« $TEMOIN » n'est pas actif ici — LoadState « $(champ_unite "$TEMOIN" LoadState) », ActiveState « $(champ_unite "$TEMOIN" ActiveState) »"
    fi

    # La section des services en échec conclut, quel que soit l'état de la
    # machine. Rien n'est affirmé sur son CONTENU ici : une unité échouée est
    # banale en conteneur, et getty@tty1 y bascule seul de façon instable. Le
    # cas déterministe est le groupe 7, sur une unité fabriquée.
    ETAT_ECHEC="$(valeur_ligne "Services en échec" "Services en échec")"
    assert_non_vide "$ETAT_ECHEC" "la section des services en échec conclut"
    assert_contient "$inventaire" "n'est PAS un état de santé complet du serveur" \
        "l'inventaire dit que la liste des unités en échec n'est pas exhaustive"
fi

# ===================================================================
# 3. --service sur un service ACTIF, et la normalisation du nom
# ===================================================================
titre "3. --service sur un service actif, et la normalisation du nom"

if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh --service sur un service actif" "$SANS_SYSTEMD"
    saute_par_nature "--service affiche activation, exécution et dernier démarrage" "$SANS_SYSTEMD"
    saute_par_nature "un nom sans suffixe reçoit « .service »" "$SANS_SYSTEMD"
elif [ "$TEMOIN_UTILISABLE" != "oui" ]; then
    RAISON_TEMOIN="« $TEMOIN » n'est pas chargé et actif ici — LoadState « $(champ_unite "$TEMOIN" LoadState) », ActiveState « $(champ_unite "$TEMOIN" ActiveState) »"
    saute_indisponible "check-services.sh --service sur un service actif" "$RAISON_TEMOIN"
    saute_indisponible "--service affiche activation, exécution et dernier démarrage" "$RAISON_TEMOIN"
    saute_indisponible "un nom sans suffixe reçoit « .service »" "$RAISON_TEMOIN"
else
    lancer bash "$CHECK_SERVICES_SH" --service "$TEMOIN"
    assert_code 0 "$CODE" "check-services.sh --service sur un service ACTIF sort en 0"
    invariants_diagnostic "--service sur un service actif"
    actif="$(sortie)"
    assert_contient "$actif" "Vérification d'un service" \
        "--service affiche la section de vérification"
    assert_egal "$TEMOIN" "$(valeur_ligne "Vérification d'un service" "Unité")" \
        "--service nomme l'unité interrogée"
    assert_egal "loaded" "$(valeur_ligne "Vérification d'un service" "Chargement")" \
        "--service affiche l'état de chargement"

    # LES TROIS RUBRIQUES EXIGÉES PAR LE CRITÈRE, comparées à ce que systemd
    # rapporte lui-même — et non au message que le script a bien voulu écrire.
    assert_egal "$(attendu_affiche "$(champ_unite "$TEMOIN" UnitFileState)")" \
        "$(valeur_ligne "Vérification d'un service" "État d'activation")" \
        "--service affiche l'état d'activation, celui que systemd rapporte"
    assert_egal "$(champ_unite "$TEMOIN" ActiveState) ($(champ_unite "$TEMOIN" SubState))" \
        "$(valeur_ligne "Vérification d'un service" "État d'exécution")" \
        "--service affiche l'état d'exécution et son sous-état"
    assert_egal "$(attendu_affiche "$(champ_unite "$TEMOIN" ActiveEnterTimestamp)")" \
        "$(valeur_ligne "Vérification d'un service" "Dernier démarrage")" \
        "--service affiche la date du dernier démarrage, celle que systemd rapporte"

    assert_contient "$(erreur)" "[SUCCESS] Service actif : « $TEMOIN »" \
        "--service conclut par un [SUCCESS] nommant l'unité"
    # Les quatre issues en 1 sont ABSENTES : le message d'un service actif ne se
    # confond avec aucune d'elles.
    for motif in "Service inconnu : «" "Service masqué : «" "Service inactif : «" "Service en échec : «"; do
        assert_absent "$(erreur)" "$motif" \
            "--service sur un service actif : le message « $motif… » est absent"
    done

    # Le suffixe est ajouté une fois pour toutes, et c'est l'unité RÉELLE qui est
    # nommée ensuite — jamais ce que l'appelant a tapé.
    lancer bash "$CHECK_SERVICES_SH" --service "${TEMOIN%.service}"
    assert_code 0 "$CODE" "check-services.sh --service « ${TEMOIN%.service} » sort en 0"
    assert_egal "$TEMOIN" "$(valeur_ligne "Vérification d'un service" "Unité")" \
        "un nom sans suffixe reçoit « .service », et l'unité réelle est affichée"
fi

# --- 3.2 La normalisation, indépendamment de l'état du témoin ---------------
# Non-régression du suffixe implicite, depuis que « --service » refuse les
# unités qui ne sont pas des services : le refus ne doit mordre ni sur un nom nu
# — « cron » vaut « cron.service » —, ni sur un nom d'instance — « getty@tty1 »
# vaut « getty@tty1.service » —, ni sur un nom qui porte déjà son suffixe.
#
# CE QUI EST ASSERTÉ ICI EST LE NOM AFFICHÉ, ET RIEN D'AUTRE. Le code de retour
# et l'état dépendent de ce que l'image embarque, et getty@tty1.service est
# mesuré instable — il part en boucle de redémarrage et bascule seul en
# « failed » en deux à trois secondes, ou pas. Une assertion de code sur lui
# rougirait au hasard. Les codes, eux, sont prouvés là où ils sont
# déterministes : sur le témoin au 3.1, sur un nom fabriqué juste en dessous.
cas_normalisation() {
    local saisie="$1" attendue="$2"
    lancer bash "$CHECK_SERVICES_SH" --service "$saisie"
    assert_egal "$attendue" "$(valeur_ligne "Vérification d'un service" "Unité")" \
        "--service « $saisie » interroge et affiche « $attendue »"
    assert_contient "$(erreur)" "« $attendue »" \
        "--service « $saisie » : le message final nomme « $attendue », et non ce qui a été tapé"
    assert_absent "$(erreur)" "Unité refusée pour --service" \
        "--service « $saisie » n'est pas confondu avec une unité d'un autre type"
    invariants_diagnostic "normalisation de « $saisie »"
}

if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "la normalisation d'un nom nu, d'un nom d'instance et d'un nom déjà suffixé" "$SANS_SYSTEMD"
else
    cas_normalisation "cron" "cron.service"
    cas_normalisation "getty@tty1" "getty@tty1.service"
    cas_normalisation "ssh.service" "ssh.service"

    # LE CAS DÉTERMINISTE, code compris : un nom nu fabriqué, que systemd ne
    # connaîtra jamais. Le suffixe est ajouté, l'unité normalisée est nommée
    # dans le message, et l'inexistence vaut 1 — jamais 2.
    lancer bash "$CHECK_SERVICES_SH" --service "${UNITE_INCONNUE%.service}"
    assert_code 1 "$CODE" "check-services.sh --service « ${UNITE_INCONNUE%.service} » sort en 1 — l'inexistence est un constat, pas une faute d'usage"
    assert_contient "$(erreur)" "[ERROR] Service inconnu : « $UNITE_INCONNUE »" \
        "un nom nu inconnu est rapporté sous son nom normalisé"
fi

# ===================================================================
# 4. --service : inconnu, masqué, inactif — trois messages distincts
# ===================================================================
# Les trois issues que le critère d'acceptation exige de distinguer PAR LE
# MESSAGE, jamais par le code. Aucune ne modifie quoi que ce soit : le service
# inconnu n'existe pas, le service masqué et le service inactif sont pris tels
# que l'image les fournit.
titre "4. --service : inconnu, masqué, inactif"

# Le service MASQUÉ : console-getty.service est masqué dans l'image du profil
# systemd. Mesuré et non supposé — à défaut, la première unité masquée que
# systemd déclare fait l'affaire.
UNITE_MASQUEE=""
if [ "$SYSTEMD" = "oui" ]; then
    if [ "$(champ_unite console-getty.service LoadState)" = "masked" ]; then
        UNITE_MASQUEE="console-getty.service"
    else
        while IFS= read -r ligne_lue; do
            [ -n "$ligne_lue" ] || continue
            candidate="$(premier_champ "$ligne_lue")"
            [ -n "$candidate" ] || continue
            if [ "$(champ_unite "$candidate" LoadState)" = "masked" ]; then
                UNITE_MASQUEE="$candidate"
                break
            fi
        done < <(LC_ALL=C systemctl list-unit-files --type=service --state=masked \
                    --no-pager --no-legend 2>/dev/null)
    fi
fi

# Le service INACTIF, sans rien modifier : systemd-timedated.service est chargé
# et n'a jamais démarré dans l'image. Le témoin en est exclu — il a son propre
# groupe, et il est encore actif à ce stade.
UNITE_INACTIVE=""
if [ "$SYSTEMD" = "oui" ]; then
    for candidate in systemd-timedated.service systemd-localed.service systemd-hostnamed.service; do
        [ "$candidate" != "$TEMOIN" ] || continue
        if [ "$(champ_unite "$candidate" LoadState)" = "loaded" ] \
           && [ "$(champ_unite "$candidate" ActiveState)" = "inactive" ]; then
            UNITE_INACTIVE="$candidate"
            break
        fi
    done
    if [ -z "$UNITE_INACTIVE" ]; then
        while IFS= read -r ligne_lue; do
            [ -n "$ligne_lue" ] || continue
            candidate="$(premier_champ "$ligne_lue")"
            [ -n "$candidate" ] || continue
            [ "$candidate" != "$TEMOIN" ] || continue
            if [ "$(champ_unite "$candidate" LoadState)" = "loaded" ] \
               && [ "$(champ_unite "$candidate" ActiveState)" = "inactive" ]; then
                UNITE_INACTIVE="$candidate"
                break
            fi
        done < <(LC_ALL=C systemctl list-units --type=service --all --state=inactive \
                    --no-pager --no-legend --full 2>/dev/null)
    fi
fi

MESSAGE_INCONNU=""
MESSAGE_MASQUE=""
MESSAGE_INACTIF=""
MESSAGE_INETABLISSABLE=""

# --- 4.1 Service INCONNU ----------------------------------------------------
if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh --service sur un service INCONNU" "$SANS_SYSTEMD"
else
    lancer bash "$CHECK_SERVICES_SH" --service "$UNITE_INCONNUE"
    assert_code 1 "$CODE" "check-services.sh --service sur un service INCONNU sort en 1"
    invariants_diagnostic "--service sur un service inconnu"
    MESSAGE_INCONNU="$(erreur)"
    assert_contient "$MESSAGE_INCONNU" "[ERROR] Service inconnu : « $UNITE_INCONNUE » — systemd ne connaît aucune unité de ce nom." \
        "--service sur un service inconnu : le message dit l'inconnu et nomme l'unité"
    assert_contient "$MESSAGE_INCONNU" "systemctl list-unit-files --type=service" \
        "--service sur un service inconnu : le message dit comment lister les services installés"
    assert_egal "not-found" "$(valeur_ligne "Vérification d'un service" "Chargement")" \
        "--service sur un service inconnu : le tableau affiche LoadState « not-found »"

    # UNE UNITÉ INCONNUE N'A PAS D'ÉTAT D'EXÉCUTION, et le tableau ne doit plus
    # lui en prêter un. « systemctl show » rapporte pourtant « inactive (dead) »
    # pour un nom qu'il ne connaît pas — mesuré : la propriété est servie même
    # pour une unité absente — et l'afficher tel quel se lisait « le service
    # existe, il est arrêté », l'inverse exact du [ERROR] émis deux lignes plus
    # bas. Le script efface désormais la valeur, et « ligne() » affiche
    # « non disponible », comme pour l'état d'activation et le dernier démarrage
    # de la même unité.
    #
    # L'assertion d'ABSENCE est la moitié qui compte : sans elle, un « inactive
    # (dead) » revenu ailleurs dans la section passerait inaperçu. Elle porte sur
    # toute la sortie, et non sur la seule ligne.
    assert_egal "non disponible" \
        "$(valeur_ligne "Vérification d'un service" "État d'exécution")" \
        "--service sur un service inconnu : l'état d'exécution est « non disponible » — on n'en prête pas un à ce qui n'existe pas"
    assert_absent "$(sortie)" "inactive (dead)" \
        "--service sur un service inconnu : « inactive (dead) » n'apparaît NULLE PART dans la sortie"
    # Les deux autres lignes que systemd laisse vides pour une unité inconnue,
    # comparées à ce que systemd rapporte lui-même.
    assert_egal "$(attendu_affiche "$(champ_unite "$UNITE_INCONNUE" UnitFileState)")" \
        "$(valeur_ligne "Vérification d'un service" "État d'activation")" \
        "--service sur un service inconnu : l'état d'activation est celui que systemd rapporte"
    assert_egal "$(attendu_affiche "$(champ_unite "$UNITE_INCONNUE" ActiveEnterTimestamp)")" \
        "$(valeur_ligne "Vérification d'un service" "Dernier démarrage")" \
        "--service sur un service inconnu : le dernier démarrage est celui que systemd rapporte"

    # L'inexistence est un CONSTAT du système, pas une faute de l'appelant : le
    # code doit être 1, et surtout pas 2. L'assertion de code ci-dessus le dit ;
    # celle-ci vérifie qu'aucun message d'usage ne vient brouiller la lecture.
    assert_absent "$MESSAGE_INCONNU" "Nom de service invalide" \
        "--service sur un service inconnu : le nom n'est pas reproché à l'appelant"
fi

# --- 4.2 Service MASQUÉ -----------------------------------------------------
if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh --service sur un service MASQUÉ" "$SANS_SYSTEMD"
elif [ -z "$UNITE_MASQUEE" ]; then
    saute_indisponible "check-services.sh --service sur un service MASQUÉ" \
        "aucune unité masquée dans cet environnement — « systemctl list-unit-files --state=masked » n'en liste aucune"
else
    lancer bash "$CHECK_SERVICES_SH" --service "$UNITE_MASQUEE"
    assert_code 1 "$CODE" "check-services.sh --service sur un service MASQUÉ sort en 1"
    invariants_diagnostic "--service sur un service masqué"
    MESSAGE_MASQUE="$(erreur)"
    assert_contient "$MESSAGE_MASQUE" "[ERROR] Service masqué : « $UNITE_MASQUEE » — son unité est liée à /dev/null." \
        "--service sur un service masqué : le message dit le masquage et nomme l'unité"
    assert_contient "$MESSAGE_MASQUE" "systemctl unmask $UNITE_MASQUEE" \
        "--service sur un service masqué : le message dit comment le démasquer"
    assert_egal "masked" "$(valeur_ligne "Vérification d'un service" "Chargement")" \
        "--service sur un service masqué : le tableau affiche LoadState « masked »"

    # L'AUTRE MOITIÉ DE LA CORRECTION DU 4.1, et celle qu'on peut casser sans
    # s'en apercevoir : l'effacement de l'état d'exécution ne vaut QUE pour
    # « not-found ». Une unité masquée, elle, EXISTE — systemd la connaît, son
    # fichier est lié à /dev/null — et dire qu'elle n'est pas en cours
    # d'exécution est exact. Élargir l'effacement à « masked » ferait perdre une
    # information vraie ; sans ces deux assertions, personne ne le verrait.
    #
    # La première compare à ce que SYSTEMD rapporte — c'est la garde durable,
    # celle qui rougit si le script se met à effacer. La seconde fige la valeur
    # attendue d'une unité masquée, qui n'a rien d'aléatoire : systemd rapporte
    # « inactive/dead » pour toute unité masquée, mesuré sur console-getty.
    ETAT_EXEC_MASQUE="$(valeur_ligne "Vérification d'un service" "État d'exécution")"
    assert_egal "$(champ_unite "$UNITE_MASQUEE" ActiveState) ($(champ_unite "$UNITE_MASQUEE" SubState))" \
        "$ETAT_EXEC_MASQUE" \
        "--service sur un service masqué : l'état d'exécution est celui que systemd rapporte, non effacé"
    assert_egal "inactive (dead)" "$ETAT_EXEC_MASQUE" \
        "--service sur un service masqué : l'état d'exécution affiche TOUJOURS « inactive (dead) »"
    assert_egal "masked" "$(valeur_ligne "Vérification d'un service" "État d'activation")" \
        "--service sur un service masqué : l'état d'activation affiche « masked », qui dit pourquoi l'unité ne tourne pas"
fi

# --- 4.3 Service INACTIF, sans rien modifier --------------------------------
if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh --service sur un service INACTIF" "$SANS_SYSTEMD"
elif [ -z "$UNITE_INACTIVE" ]; then
    saute_indisponible "check-services.sh --service sur un service INACTIF sans rien modifier" \
        "aucune unité chargée et inactive n'a été trouvée dans cet environnement"
else
    lancer bash "$CHECK_SERVICES_SH" --service "$UNITE_INACTIVE"
    assert_code 1 "$CODE" "check-services.sh --service sur un service INACTIF sort en 1"
    invariants_diagnostic "--service sur un service inactif"
    MESSAGE_INACTIF="$(erreur)"
    assert_contient "$MESSAGE_INACTIF" "[ERROR] Service inactif : « $UNITE_INACTIVE » n'est pas actif" \
        "--service sur un service inactif : le message dit l'inactivité et nomme l'unité"
    assert_contient "$MESSAGE_INACTIF" "systemctl start $UNITE_INACTIVE" \
        "--service sur un service inactif : le message dit comment le démarrer"
    assert_egal "loaded" "$(valeur_ligne "Vérification d'un service" "Chargement")" \
        "--service sur un service inactif : l'unité est bien CHARGÉE, et non inconnue"
    # Une unité chargée qui n'a jamais démarré n'a pas d'ActiveEnterTimestamp :
    # systemd rend une valeur vide, que le script affiche « non disponible » — il
    # n'invente pas de date. L'assertion suit ce que systemd rapporte, et vaut
    # donc aussi pour une unité qui aurait déjà tourné.
    HORODATAGE_INACTIF="$(champ_unite "$UNITE_INACTIVE" ActiveEnterTimestamp)"
    assert_egal "$(attendu_affiche "$HORODATAGE_INACTIF")" \
        "$(valeur_ligne "Vérification d'un service" "Dernier démarrage")" \
        "--service : le dernier démarrage est celui que systemd rapporte — « non disponible » quand l'unité n'a jamais démarré, jamais une date inventée"
fi

# --- 4.4 État INÉTABLISSABLE ------------------------------------------------
# LA CINQUIÈME ISSUE DU CODE 1, prouvée et non déclarée. Elle s'atteint avec le
# VRAI systemctl, en une seule commande et sans aucun faux binaire :
#
#   « @ » ne porte pas de point : le script lui ajoute « .service » et interroge
#   « @.service ». C'est une INSTANCE VIDE — un nom de gabarit sans nom
#   d'instance —, que systemd refuse de décrire : « systemctl show » sort en
#   échec, lire_etat_unite rend 1, et mode_service emprunte sa première branche.
#
# Mesuré dans le conteneur du profil systemd : code 1, « L'état de « @.service »
# n'a pas pu être établi ». Le nom passe la validation de forme — « @ » est un
# caractère admis d'un nom d'unité —, ce qui est cohérent : le refus en 2 porte
# sur la FORME, et systemd seul sait qu'il ne peut rien dire de cette unité-là.
if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh --service dont l'état est INÉTABLISSABLE" "$SANS_SYSTEMD"
else
    lancer bash "$CHECK_SERVICES_SH" --service "@"
    assert_code 1 "$CODE" "check-services.sh --service « @ » sort en 1 — l'état n'a pas pu être établi"
    invariants_diagnostic "--service dont l'état est inétablissable"
    MESSAGE_INETABLISSABLE="$(erreur)"
    assert_contient "$MESSAGE_INETABLISSABLE" "[ERROR] L'état de « @.service » n'a pas pu être établi : « systemctl show » n'a rien rendu d'exploitable." \
        "--service « @ » : le message dit que l'état n'a pas pu être établi et nomme l'unité"
    assert_contient "$MESSAGE_INETABLISSABLE" "systemctl is-system-running" \
        "--service « @ » : le message dit comment trancher la seconde hypothèse"
    assert_egal "@.service" "$(valeur_ligne "Vérification d'un service" "Unité")" \
        "--service « @ » : l'unité normalisée est affichée malgré l'échec de la lecture"
    assert_egal "non disponible" "$(valeur_ligne "Vérification d'un service" "État")" \
        "--service « @ » : l'état est affiché « non disponible », et non inventé"
    # Le refus de forme ne doit PAS s'être déclenché : « @ » est un caractère
    # admis d'un nom d'unité, et c'est bien systemd qui n'a rien pu dire.
    assert_absent "$MESSAGE_INETABLISSABLE" "Nom de service invalide" \
        "--service « @ » : l'échec vient du système, il n'est pas reproché à l'appelant"
fi

# --- 4.5 Les cinq messages du code 1 diffèrent RÉELLEMENT --------------------
# C'est le critère « en distinguant les cas par le message ». Le prouver demande
# de croiser les sorties : un motif présent dans l'une doit être absent des
# autres. Sans ce croisement, des messages identiques passeraient les cas
# ci-dessus. La cinquième issue — l'état inétablissable — entre ici dans le
# croisement au même titre que les autres ; la quatrième, l'unité en échec, est
# croisée au groupe 7, où elle est fabriquée.
if [ -z "$MESSAGE_INCONNU" ] || [ -z "$MESSAGE_MASQUE" ] || [ -z "$MESSAGE_INACTIF" ] \
   || [ -z "${MESSAGE_INETABLISSABLE:-}" ]; then
    if [ "$SYSTEMD" != "oui" ]; then
        saute_par_nature "les messages du code 1 diffèrent réellement" "$SANS_SYSTEMD"
    else
        saute_indisponible "les messages du code 1 diffèrent réellement" \
            "l'un des quatre cas n'a pas pu être joué : sans ses sorties, le croisement ne prouverait rien"
    fi
else
    assert_absent "$MESSAGE_INCONNU" "Service masqué : «" \
        "le message du service inconnu ne parle pas de masquage"
    assert_absent "$MESSAGE_INCONNU" "Service inactif : «" \
        "le message du service inconnu ne parle pas d'inactivité"
    assert_absent "$MESSAGE_INCONNU" "n'a pas pu être établi" \
        "le message du service inconnu ne parle pas d'un état inétablissable"
    assert_absent "$MESSAGE_MASQUE" "Service inconnu : «" \
        "le message du service masqué ne parle pas d'unité inconnue"
    assert_absent "$MESSAGE_MASQUE" "Service inactif : «" \
        "le message du service masqué ne parle pas d'inactivité"
    assert_absent "$MESSAGE_MASQUE" "n'a pas pu être établi" \
        "le message du service masqué ne parle pas d'un état inétablissable"
    assert_absent "$MESSAGE_INACTIF" "Service inconnu : «" \
        "le message du service inactif ne parle pas d'unité inconnue"
    assert_absent "$MESSAGE_INACTIF" "Service masqué : «" \
        "le message du service inactif ne parle pas de masquage"
    assert_absent "$MESSAGE_INACTIF" "n'a pas pu être établi" \
        "le message du service inactif ne parle pas d'un état inétablissable"
    assert_absent "$MESSAGE_INETABLISSABLE" "Service inconnu : «" \
        "le message de l'état inétablissable ne parle pas d'unité inconnue"
    assert_absent "$MESSAGE_INETABLISSABLE" "Service masqué : «" \
        "le message de l'état inétablissable ne parle pas de masquage"
    assert_absent "$MESSAGE_INETABLISSABLE" "Service inactif : «" \
        "le message de l'état inétablissable ne parle pas d'inactivité"
    assert_absent "$MESSAGE_INETABLISSABLE" "Service en échec : «" \
        "le message de l'état inétablissable ne parle pas d'un échec d'exécution"
fi

# ===================================================================
# 5. La lecture seule
# ===================================================================
# Le contrat le plus fort de ce script — « aucune action sur un service : ni
# start, ni stop, ni restart » — et le seul qu'une régression pourrait violer
# sans que rien d'autre ne bouge.
titre "5. La lecture seule"

if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "check-services.sh ne modifie rien dans /etc" "$SANS_SYSTEMD"
    saute_par_nature "check-services.sh n'écrit nulle part hors du journal de lib/common.sh" "$SANS_SYSTEMD"
    saute_par_nature "check-services.sh laisse l'état du service interrogé inchangé" "$SANS_SYSTEMD"
elif [ "$TEMOIN_UTILISABLE" != "oui" ]; then
    saute_indisponible "check-services.sh laisse l'état du service interrogé inchangé" \
        "« $TEMOIN » n'est pas exploitable ici — voir le groupe 3"
    saute_indisponible "check-services.sh ne modifie rien dans /etc" \
        "le groupe s'appuie sur une interrogation du témoin, indisponible ici"
    saute_indisponible "check-services.sh n'écrit nulle part hors du journal de lib/common.sh" \
        "le groupe s'appuie sur une interrogation du témoin, indisponible ici"
else
    ETAT_AVANT="$(champ_unite "$TEMOIN" LoadState)/$(champ_unite "$TEMOIN" ActiveState)/$(champ_unite "$TEMOIN" SubState)"

    touch "$REP_TMP/temoin-lecture"
    empreinte "$REP_TMP/etc-avant"
    lancer bash "$CHECK_SERVICES_SH" --service "$TEMOIN"
    assert_code 0 "$CODE" "check-services.sh --service, avant la comparaison d'empreinte"
    lancer bash "$CHECK_SERVICES_SH"
    assert_code 0 "$CODE" "check-services.sh inventaire, avant la comparaison d'empreinte"
    empreinte "$REP_TMP/etc-apres"

    if diff -u "$REP_TMP/etc-avant" "$REP_TMP/etc-apres" > "$REP_TMP/diff-etc" 2>&1; then
        ok "check-services.sh ne modifie rien dans /etc"
    else
        ko "check-services.sh ne modifie rien dans /etc" \
            "$(head -n 12 "$REP_TMP/diff-etc" | tr '\n' '|')"
    fi
    assert_aucune_ecriture "$REP_TMP/temoin-lecture" \
        "check-services.sh n'écrit nulle part hors du journal de lib/common.sh"

    ETAT_APRES="$(champ_unite "$TEMOIN" LoadState)/$(champ_unite "$TEMOIN" ActiveState)/$(champ_unite "$TEMOIN" SubState)"
    assert_egal "$ETAT_AVANT" "$ETAT_APRES" \
        "check-services.sh laisse « $TEMOIN » dans l'état où il l'a trouvé"
fi

# ===================================================================
# 6. Le témoin arrêté, puis relancé
# ===================================================================
# LE CAS NOMINAL EXIGÉ PAR LE DERNIER CRITÈRE D'ACCEPTATION : « un service
# arrêté volontairement fait rendre 1, le même service relancé fait rendre 0 ».
# Le fichier de cas crée lui-même la situation qu'il éprouve — compter sur
# l'état du conteneur ne prouverait rien.
titre "6. Le témoin arrêté, puis relancé"

if [ "$MODIFIANT" != "oui" ]; then
    saute_modifiant "check-services.sh rend 1 sur un service volontairement arrêté"
    saute_modifiant "check-services.sh rend 0 sur le même service une fois relancé"
    saute_modifiant "le service témoin est restitué dans son état de départ"
elif [ "$TEMOIN_UTILISABLE" != "oui" ]; then
    RAISON_TEMOIN_6="« $TEMOIN » n'était pas chargé et actif à l'entrée du fichier — l'arrêter ne prouverait rien"
    saute_indisponible "check-services.sh rend 1 sur un service volontairement arrêté" "$RAISON_TEMOIN_6"
    saute_indisponible "check-services.sh rend 0 sur le même service une fois relancé" "$RAISON_TEMOIN_6"
    saute_indisponible "le service témoin est restitué dans son état de départ" "$RAISON_TEMOIN_6"
else
    # L'arrêt lui-même, en contexte de condition. TEMOIN_ARRETE est renseigné
    # AVANT l'appel : si systemctl échoue à mi-course, le filet posé sur EXIT
    # doit tout de même tenter la relance.
    TEMOIN_ARRETE="$TEMOIN"
    ARRET="ok"
    if ! systemctl stop "$TEMOIN" >"$REP_TMP/arret" 2>&1; then
        ARRET="échec"
    elif [ "$(champ_unite "$TEMOIN" ActiveState)" = "active" ]; then
        # Certains services reviennent seuls — activation par socket ou par bus.
        # Le constater est un motif d'indisponibilité, jamais d'échec du script.
        ARRET="revenu"
    fi

    if [ "$ARRET" != "ok" ]; then
        RAISON_ARRET="« systemctl stop $TEMOIN » n'a pas laissé le service inactif ($ARRET) : $(tr '\n' ' ' < "$REP_TMP/arret")"
        saute_indisponible "check-services.sh rend 1 sur un service volontairement arrêté" "$RAISON_ARRET"
        saute_indisponible "check-services.sh rend 0 sur le même service une fois relancé" "$RAISON_ARRET"
    else
        ok "préparation : « $TEMOIN » est réellement arrêté — ActiveState « $(champ_unite "$TEMOIN" ActiveState) »"

        lancer bash "$CHECK_SERVICES_SH" --service "$TEMOIN"
        assert_code 1 "$CODE" "check-services.sh rend 1 sur « $TEMOIN » volontairement arrêté"
        invariants_diagnostic "témoin arrêté"
        assert_contient "$(erreur)" "[ERROR] Service inactif : « $TEMOIN » n'est pas actif" \
            "témoin arrêté : le message est celui de l'INACTIVITÉ"
        assert_absent "$(erreur)" "Service inconnu : «" \
            "témoin arrêté : le message n'est pas celui d'une unité inconnue"
        assert_absent "$(erreur)" "Service masqué : «" \
            "témoin arrêté : le message n'est pas celui d'une unité masquée"
        assert_egal "loaded" "$(valeur_ligne "Vérification d'un service" "Chargement")" \
            "témoin arrêté : l'unité reste CHARGÉE"

        # La relance, et sa vérification par une lecture indépendante du script.
        RELANCE="ok"
        if ! systemctl start "$TEMOIN" >"$REP_TMP/relance" 2>&1; then
            RELANCE="échec"
        elif [ "$(champ_unite "$TEMOIN" ActiveState)" != "active" ]; then
            RELANCE="inactif"
        fi

        if [ "$RELANCE" != "ok" ]; then
            ko "restitution : « $TEMOIN » est relancé" \
                "« systemctl start » n'a pas rendu le service actif ($RELANCE) : $(tr '\n' ' ' < "$REP_TMP/relance")"
            saute_indisponible "check-services.sh rend 0 sur le même service une fois relancé" \
                "le service n'a pas pu être relancé — voir l'échec ci-dessus"
        else
            ok "restitution : « $TEMOIN » est de nouveau actif — ActiveState « $(champ_unite "$TEMOIN" ActiveState) »"
            TEMOIN_ARRETE=""

            lancer bash "$CHECK_SERVICES_SH" --service "$TEMOIN"
            assert_code 0 "$CODE" "check-services.sh rend 0 sur « $TEMOIN » une fois relancé"
            invariants_diagnostic "témoin relancé"
            assert_contient "$(erreur)" "[SUCCESS] Service actif : « $TEMOIN »" \
                "témoin relancé : le message est de nouveau celui d'un service actif"
            assert_absent "$(erreur)" "Service inactif : «" \
                "témoin relancé : le message d'inactivité a disparu"
        fi
    fi
fi

# ===================================================================
# 7. Une unité délibérément en échec
# ===================================================================
# Deux critères d'acceptation tiennent ici, et aucun des deux ne peut s'appuyer
# sur l'état du conteneur : getty@tty1 y bascule seul en « failed » de façon
# instable — deux lancements de la même image ont donné « running » puis
# « degraded ». Une unité fabriquée, elle, échoue à coup sûr et se retire.
#
#   - « --service » sur une unité en échec rend 1, avec un message distinct des
#     trois autres ;
#   - UN SERVICE EN ÉCHEC NE CHANGE PAS LE CODE DE L'INVENTAIRE : il y figure,
#     il y est mis en évidence par un [WARN], et le code reste 0.
titre "7. Une unité délibérément en échec"

if [ "$MODIFIANT" != "oui" ]; then
    saute_modifiant "check-services.sh rend 1 sur une unité en échec, avec un message distinct"
    saute_modifiant "une unité en échec figure dans l'inventaire, mise en évidence"
    saute_modifiant "une unité en échec ne change pas le code de retour de l'inventaire"
    saute_modifiant "l'unité fabriquée est retirée du système"
else
    UNITE_ECHEC_POSEE="$UNITE_ECHEC"
    cat > "$FICHIER_UNITE_ECHEC" <<'UNITE_FABRIQUEE'
[Unit]
Description=Unité fabriquée par tests/environment/check-services.test.sh

[Service]
Type=oneshot
ExecStart=/bin/false
UNITE_FABRIQUEE

    PREPARATION_ECHEC="ok"
    if ! systemctl daemon-reload >"$REP_TMP/fabrication" 2>&1; then
        PREPARATION_ECHEC="daemon-reload"
    else
        # « systemctl start » rend un code non nul sur une unité qui échoue :
        # c'est attendu, et c'est même le but. En contexte de condition, sans
        # quoi le trap ERR de lib/common.sh parlerait pour rien. Seul l'ÉTAT
        # atteint tranche, jamais ce code.
        if systemctl start "$UNITE_ECHEC" >>"$REP_TMP/fabrication" 2>&1; then
            printf 'systemctl start a rendu 0\n' >> "$REP_TMP/fabrication"
        fi
        if [ "$(champ_unite "$UNITE_ECHEC" ActiveState)" != "failed" ]; then
            PREPARATION_ECHEC="etat-non-failed"
        fi
    fi

    if [ "$PREPARATION_ECHEC" != "ok" ]; then
        RAISON_ECHEC="l'unité fabriquée n'a pas atteint l'état « failed » ($PREPARATION_ECHEC) : $(tr '\n' ' ' < "$REP_TMP/fabrication")"
        saute_indisponible "check-services.sh rend 1 sur une unité en échec, avec un message distinct" "$RAISON_ECHEC"
        saute_indisponible "une unité en échec figure dans l'inventaire, mise en évidence" "$RAISON_ECHEC"
        saute_indisponible "une unité en échec ne change pas le code de retour de l'inventaire" "$RAISON_ECHEC"
    else
        ok "préparation : « $UNITE_ECHEC » est réellement en échec — SubState « $(champ_unite "$UNITE_ECHEC" SubState) »"

        # 7.1 — la quatrième issue de --service.
        lancer bash "$CHECK_SERVICES_SH" --service "$UNITE_ECHEC"
        assert_code 1 "$CODE" "check-services.sh rend 1 sur une unité EN ÉCHEC"
        invariants_diagnostic "unité en échec"
        MESSAGE_ECHEC="$(erreur)"
        assert_contient "$MESSAGE_ECHEC" "[ERROR] Service en échec : « $UNITE_ECHEC »" \
            "unité en échec : le message dit l'ÉCHEC et nomme l'unité"
        assert_contient "$MESSAGE_ECHEC" "journalctl -u $UNITE_ECHEC" \
            "unité en échec : le message dit où lire la cause"
        assert_absent "$MESSAGE_ECHEC" "Service inconnu : «" \
            "unité en échec : le message n'est pas celui d'une unité inconnue"
        assert_absent "$MESSAGE_ECHEC" "Service masqué : «" \
            "unité en échec : le message n'est pas celui d'une unité masquée"
        assert_absent "$MESSAGE_ECHEC" "Service inactif : «" \
            "unité en échec : le message n'est pas celui d'une unité simplement inactive"
        assert_absent "$MESSAGE_ECHEC" "n'a pas pu être établi" \
            "unité en échec : le message n'est pas celui d'un état inétablissable"
        assert_egal "$(champ_unite "$UNITE_ECHEC" ActiveState) ($(champ_unite "$UNITE_ECHEC" SubState))" \
            "$(valeur_ligne "Vérification d'un service" "État d'exécution")" \
            "unité en échec : le tableau affiche l'état et le sous-état d'échec"

        # 7.2 — L'INVENTAIRE NE CHANGE PAS DE CODE POUR AUTANT.
        lancer bash "$CHECK_SERVICES_SH"
        assert_code 0 "$CODE" "l'inventaire rend 0 alors qu'une unité est en échec"
        invariants_diagnostic "inventaire avec une unité en échec"
        assert_egal "0" "$(nb_lignes_contenant '[ERROR]')" \
            "l'inventaire ne produit aucune ligne [ERROR] pour une unité en échec"
        assert_contient "$(sortie)" "$UNITE_ECHEC" \
            "l'unité en échec figure dans la liste des services en échec"
        assert_contient "$(erreur)" "[WARN] Service en échec : $UNITE_ECHEC" \
            "l'unité en échec est mise en évidence par un [WARN]"
        assert_contient "$(erreur)" "systemctl status $UNITE_ECHEC" \
            "l'avertissement dit où lire la cause de l'échec"
        NB_ECHEC="$(valeur_ligne "Services en échec" "Services en échec")"
        if [ -n "$NB_ECHEC" ] && [ -z "${NB_ECHEC//[0-9]/}" ] && [ "$NB_ECHEC" -ge 1 ]; then
            ok "l'inventaire annonce un nombre de services en échec — $NB_ECHEC"
        else
            ko "l'inventaire annonce un nombre de services en échec" "obtenu « $NB_ECHEC »"
        fi
    fi

    # Retrait de l'unité fabriquée, et VÉRIFICATION du retrait. Le filet posé
    # sur EXIT ne rend compte de rien : il rattrape.
    systemctl stop "$UNITE_ECHEC" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNITE_ECHEC" >/dev/null 2>&1 || true
    rm -f "$FICHIER_UNITE_ECHEC"
    if ! systemctl daemon-reload >"$REP_TMP/retrait" 2>&1; then
        ko "retrait : systemd relit ses unités après suppression du fichier" \
            "$(tr '\n' ' ' < "$REP_TMP/retrait")"
    else
        assert_egal "not-found" "$(champ_unite "$UNITE_ECHEC" LoadState)" \
            "retrait : « $UNITE_ECHEC » n'est plus connue de systemd"
        if [ -e "$FICHIER_UNITE_ECHEC" ]; then
            ko "retrait : le fichier d'unité fabriqué est supprimé" "$FICHIER_UNITE_ECHEC subsiste"
        else
            ok "retrait : le fichier d'unité fabriqué est supprimé"
        fi
        UNITE_ECHEC_POSEE=""
    fi
fi

# ===================================================================
# 8. Hors de portée de cet environnement
# ===================================================================
# Ces lignes ne sont pas des cas manqués : ce sont des cas dont on sait qu'ils
# ne peuvent pas être joués ici. Les taire ferait croire à une couverture
# complète.
titre "8. Hors de portée de cet environnement"

# La branche « état impossible à établir » N'EST PLUS ICI : elle s'atteint avec
# le vrai systemctl, par « --service @ », et elle est prouvée au groupe 4.4.
# L'écriture sous /var non plus : assert_aucune_ecriture surveille désormais
# /var, /tmp et /home, exclusions mesurées à l'appui.

saute_par_nature "les branches dégradées des deux « list-units » de l'inventaire" \
    "elles ne s'ouvrent que si « systemctl list-units » rend un code non nul. MESURÉ dans le conteneur du profil systemd : une adresse de bus inexistante — DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent — ne suffit pas, systemctl passe par la socket privée /run/systemd/private et rend 0 comme si de rien n'était ; le script produit alors son inventaire complet. Sur l'autre profil, systemctl est absent et require_cmd tranche avant. Il ne reste qu'un faux systemctl en tête de PATH, qui couperait du même coup toutes les mesures de contrôle indépendantes de ce fichier — la preuve porterait sur le montage, plus sur le script"

# Saut NEUTRE, et non « par nature » : ce qui empêche d'asserter ici est une
# propriété de l'IMAGE — quels services elle embarque et comment ils se
# comportent —, pas une limite de nature. Une autre image, un autre verdict.
saute "l'état « degraded » et le nombre d'unités en échec de l'image" \
    "getty@tty1.service part en boucle de redémarrage et bascule seul en « failed » au bout de deux à trois secondes — ou pas : trois lancements de la même image ont donné « running » puis « degraded » puis « running », ce dernier avec zéro unité en échec. Aucune assertion ne peut porter là-dessus. Le cas déterministe est le groupe 7, sur une unité fabriquée"

# Saut NEUTRE lui aussi, et pour la même raison : ce cas EST atteignable avec le
# vrai systemctl. Ce qui l'écarte est une décision de PÉRIMÈTRE, pas une limite
# de nature — « saute_par_nature » serait ici une signature mensongère, au sens
# que tests/lib/assert.sh donne à ce mot.
#
# Sans cette ligne, les sept issues de --service assertées au groupe 1.1 se
# liraient comme sept comportements prouvés, alors que six seulement le sont :
# le groupe 8 pose lui-même que taire un cas non prouvé ferait croire à une
# couverture complète.
saute "la septième issue de --service — « unité non chargée »" \
    "elle EST atteignable avec le vrai systemctl. MESURÉ dans le conteneur du profil systemd : un fichier d'unité au contenu invalide déposé dans /etc/systemd/system, suivi d'un « systemctl daemon-reload », donne « LoadState=bad-setting », et « --service » rend alors 1 avec « Unité non chargée : « … » — LoadState vaut « bad-setting » ». Ce qui l'écarte est une décision de périmètre : l'éprouver demanderait une SECONDE unité fabriquée et un second chemin de restitution avant que systemd.test.sh ne tourne, et aucun critère d'acceptation de TASK-023 ne l'exige. La ligne d'aide qui la documente est assertée au groupe 1.1 ; son message d'exécution, lui, n'est pas éprouvé"

# ===================================================================
# 9. Restitution vérifiée, et nettoyage
# ===================================================================
# Dernier garde-fou, et le plus important de ce fichier : run-environment.sh
# exécute systemd.test.sh JUSTE APRÈS celui-ci. Un témoin laissé à terre s'y
# verrait, loin de sa cause.
titre "9. Restitution vérifiée, et nettoyage"

if [ "$SYSTEMD" != "oui" ]; then
    saute_par_nature "le service témoin est actif à la sortie du fichier" "$SANS_SYSTEMD"
elif [ "$TEMOIN_UTILISABLE" != "oui" ]; then
    saute_indisponible "le service témoin est actif à la sortie du fichier" \
        "« $TEMOIN » n'était pas actif à l'entrée : il n'y a rien à restituer, et rien à vérifier"
else
    assert_egal "active" "$(champ_unite "$TEMOIN" ActiveState)" \
        "restitution : « $TEMOIN » est ACTIF à la sortie du fichier"
    assert_egal "loaded" "$(champ_unite "$TEMOIN" LoadState)" \
        "restitution : « $TEMOIN » est toujours chargé"
fi

if [ "$SYSTEMD" = "oui" ]; then
    if [ -e "$FICHIER_UNITE_ECHEC" ]; then
        ko "aucune unité fabriquée ne subsiste dans /etc/systemd/system" \
            "$FICHIER_UNITE_ECHEC subsiste"
    else
        ok "aucune unité fabriquée ne subsiste dans /etc/systemd/system"
    fi
else
    saute_par_nature "l'absence d'unité fabriquée résiduelle" "$SANS_SYSTEMD"
fi

rm -rf "$REP_TMP"
if [ -e "$REP_TMP" ]; then
    ko "le répertoire jetable du fichier de cas est supprimé" "$REP_TMP subsiste"
else
    ok "le répertoire jetable du fichier de cas est supprimé"
fi

bilan "environment / check-services.sh"
