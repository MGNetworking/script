#!/usr/bin/env bash
# tests/integration/check-memory.test.sh — Linux/System/check-memory.sh, exécuté.
#
# TASK-022. Huitième script du domaine, et le troisième — avec system-info.sh et
# check-disk.sh — à ne rien modifier et à n'exiger aucun privilège. Son contrat
# tient en une phrase : IL REND 0 QUOI QU'IL CONSTATE. Seule une erreur d'usage
# tapée sur la ligne de commande rend 2.
#
# FICHIER DE CAS SÉPARÉ, ET NON UNE SECTION DE linux-system.test.sh. Ce dernier
# passe les 4 900 lignes et porte les six scripts modifiants du domaine, dont
# l'ordre des groupes est contraint par une garde d'état — l'empreinte relevée
# au groupe 2 est comparée à celle du groupe 4. Un script qui n'écrit rien n'a
# aucune raison d'entrer dans cette contrainte, et run-integration.sh ramasse
# tout tests/integration/*.test.sh : déposer ce fichier suffit. C'est aussi ce
# que le périmètre de TASK-022 demande explicitement.
#
# ---------------------------------------------------------------------------
# Ce que ce fichier éprouve, par ordre d'importance
# ---------------------------------------------------------------------------
#
#   a. les refus en 2, ET L'ABSENCE DE TOUTE SORTIE avant le refus — les valeurs
#      sont validées avant qu'un seul chiffre ne soit lu, et un stdout
#      strictement vide est la seule assertion qui le voie ;
#   b. le chemin nominal sur les mesures réelles de la machine, et surtout que
#      LES TABLEAUX NE SONT PAS VIDES : un décompte des lignes, jamais une
#      assertion de contenu, qui resterait verte sur un écran blanc ;
#   c. la lecture seule — empreinte de tout /etc et « find -newer » à l'appui ;
#   d. deux exécutions consécutives, système inchangé et sortie identique. La
#      seconde moitié n'est possible que sous faux « free » et faux « ps » : sur
#      les mesures réelles, deux exécutions diffèrent forcément ;
#   e. LA DÉGRADATION, une source en échec à la fois — « free » en échec,
#      « free » muet, « free » ABSENT, « ps » en échec, « ps » muet, « ps »
#      absent. Chaque fois : un [WARN] nommant la cause, « non disponible » à
#      l'affichage, code 0, et AUCUNE ligne « Échec (code » du trap ERR — le
#      motif de TASK-018, qu'un script neuf ne doit pas réintroduire ;
#   f. LE SEUIL, et le fait qu'il est ATTEINT (« -ge ») et non DÉPASSÉ
#      (« -gt ») : à occupation égale au seuil, le [WARN] doit sortir. Éprouvé
#      sous faux « free », seule façon de fixer l'occupation à une valeur connue ;
#   g. LA RÈGLE DE LA CONJONCTION du fichier d'échange : un échange saturé SEUL
#      ne vaut aucun avertissement, un échange saturé PENDANT que la mémoire
#      l'est aussi en vaut un. C'est la seule règle propre à ce script, et le
#      cas négatif est le plus important des deux ;
#   h. la distinction IGNORANCE / CONSTAT, deux fois : « aucune zone d'échange
#      active » quand /proc/swaps a été lu et ne liste rien, « non disponible »
#      quand rien n'a pu être lu. Les faire aboutir au même message affirmerait
#      une absence que personne n'a établie ;
#   i. la règle d'ORIGINE des valeurs fautives — ligne de commande fautive → 2,
#      SRV_MEM_* fautif → [WARN], repli, code 0. L'assertion décisive n'est ni
#      le code ni le message : c'est QUE LE DIAGNOSTIC EST QUAND MÊME PRODUIT ;
#   j. la borne de --top, mesurée sur un faux « ps » de cinq lignes — le seul
#      montage où « trois lignes affichées » se distingue de « la machine n'avait
#      que trois processus ».
#
# ---------------------------------------------------------------------------
# Le montage qui ouvre la branche /proc/meminfo
# ---------------------------------------------------------------------------
#
# Cette branche ne s'atteint qu'en rendant « free » INTROUVABLE. Le mettre en
# échec ne suffit pas : « command -v free » réussirait encore et le script
# emprunterait le repli « free a échoué » et non le repli « free est absent »,
# qui sont deux chemins distincts et deux messages distincts. Un bac à sable de
# liens symboliques reproduit le PATH sans lui, et rien n'est touché sur le
# système. Le montage est celui de TASK-018, décrit dans tests/README.md.
#
# ---------------------------------------------------------------------------
# Ce qui ne peut PAS être affirmé ici, et pourquoi
# ---------------------------------------------------------------------------
#
# Sans lxcfs, « free » et /proc/meminfo décrivent la MACHINE HÔTE et non le
# conteneur. Aucune assertion ne porte donc sur une valeur absolue ni sur un
# ordre de grandeur : ce qui est éprouvé sur les mesures réelles, ce sont la
# présence des rubriques, la cohérence interne des chiffres — un pourcentage
# entre 0 et 100, une somme qui se retrouve — et les codes de retour. Tout ce
# qui exige une valeur connue passe par un faux « free ».
#
# Le CHARGEMENT de config/server.env n'est pas emprunté non plus : SRV_MEM_SEUIL
# et SRV_MEM_TOP sont transmises par l'ENVIRONNEMENT. C'est la même variable et
# le même « set -a » de lib/common.sh, mais l'écriture du fichier imposerait de
# créer config/server.env dans le dépôt monté, qui n'est pas un système jetable.
# La limite est déclarée en fin de fichier plutôt que passée sous silence.

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
# shellcheck source=/dev/null
source "$_dir/lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPTS_ROOT/tests/lib/assert.sh"

SYS="$SCRIPTS_ROOT/Linux/System"
CHECK_MEMORY_SH="$SYS/check-memory.sh"

REP_TMP="$(mktemp -d)"
F_OUT="$REP_TMP/stdout"
F_ERR="$REP_TMP/stderr"
CODE=0

trap 'rm -rf "$REP_TMP"' EXIT

# ===================================================================
# Outillage
# ===================================================================

# lancer <commande...> — exécute dans un SOUS-SHELL et capture le code.
#
# Le sous-shell est indispensable : le script pose « set -Eeuo pipefail » et
# lib/common.sh un « trap ERR ». Un script qui meurt en 2 tuerait le harnais si
# on ne l'isolait pas. L'entrée standard est fermée, comme partout ailleurs dans
# tests/integration/.
lancer() {
    CODE=0
    ( "$@" ) >"$F_OUT" 2>"$F_ERR" </dev/null || CODE=$?
}

sortie() { cat "$F_OUT"; }
erreur() { cat "$F_ERR"; }

# --- Lecture de la sortie du script ----------------------------------------
# La mise en page vient de « titre() » et de « ligne() » : un titre, une ligne de
# tirets, des lignes « libellé <remplissage> valeur », puis une ligne vide avant
# les paragraphes explicatifs. Les lecteurs qui suivent épousent cette forme.

# corps_section <titre> — le corps d'une section, tirets et notes exclus.
# Une section commence à son titre et s'arrête à la première ligne vide, ce qui
# laisse les paragraphes de « note() » hors du corps : ils appartiennent à la
# lecture du tableau, pas au tableau.
corps_section() {
    local titre_section="$1" ligne_lue dans="non"
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        if [ "$ligne_lue" = "$titre_section" ]; then
            dans="oui"
            continue
        fi
        [ "$dans" = "oui" ] || continue
        case "$ligne_lue" in '---'*) continue ;; esac
        if [ -z "$ligne_lue" ]; then
            dans="non"
            continue
        fi
        printf '%s\n' "$ligne_lue"
    done < "$F_OUT"
}

# valeur_dans_section <titre> <libellé> — la valeur affichée en face de ce
# libellé, DANS CETTE SECTION.
#
# La section est nécessaire, elle n'est pas un ornement : « Libre » figure dans
# « Mémoire vive » comme dans « Fichier d'échange », et une recherche sur tout le
# flux rendrait la première des deux sans qu'on sache laquelle.
#
# Le contrôle du caractère qui suit le libellé l'est tout autant : sans lui,
# « Total » capturerait « Totale ». Le remplissage de « ligne() » vaut au moins
# un espace, ce caractère est donc toujours un espace pour un libellé complet.
valeur_dans_section() {
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
    done < <(corps_section "$titre_section")
    return 0
}

# nb_lignes_section <titre> — le nombre de lignes du corps d'une section.
# C'EST LE DÉCOMPTE QUI VOIT UN TABLEAU VIDE. Une assertion de contenu, elle,
# resterait verte sur un écran blanc.
nb_lignes_section() {
    local ligne_lue n=0
    while IFS= read -r ligne_lue || [ -n "$ligne_lue" ]; do
        [ -n "$ligne_lue" ] || continue
        n=$(( n + 1 ))
    done < <(corps_section "$1")
    printf '%s' "$n"
}

# --- Mesure du VOLUME de stderr --------------------------------------------
# Ce que ces deux fonctions permettent d'exiger n'est pas dans le contenu d'un
# message mais dans sa QUANTITÉ. C'est la seule forme d'assertion qui empêche
# une aide entière ou un second diagnostic de revenir sur stderr.
#
# Le « || [ -n "$ligne_lue" ] » compte la dernière ligne même sans saut de ligne
# final : sans lui, un diagnostic non terminé serait décompté à zéro et
# l'assertion passerait pour de mauvaises raisons.

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

# --- Invariants et refus ----------------------------------------------------

# invariants_memoire <libellé> — les quatre invariants de TOUTE dégradation de
# ce script. Le code 0 est l'assertion décisive ; les trois autres verrouillent
# le motif de TASK-018, qu'un script neuf pourrait réintroduire sans que
# personne ne le voie.
invariants_memoire() {
    local libelle="$1"
    assert_code 0 "$CODE" "check-memory.sh, $libelle : sort en 0"
    assert_egal "0" "$(nb_lignes_contenant '[ERROR]')" \
        "check-memory.sh, $libelle : aucune ligne [ERROR] — ce n'est pas une erreur, c'est une lacune"
    assert_absent "$(erreur)" "Échec (code" \
        "check-memory.sh, $libelle : le trap ERR n'ajoute aucune ligne"
    assert_absent "$(erreur)" "check-memory.sh: line" \
        "check-memory.sh, $libelle : aucun message brut de bash sur stderr"
}

# refus_memoire <libellé> <motif attendu> <arguments...>
# Le refus, et ce qui compte davantage : QUE RIEN N'AIT ÉTÉ PRODUIT AVANT LUI.
# Un stdout strictement vide est la seule forme qui le voie — une assertion
# d'absence de titre resterait verte sur un flux vide comme sur un flux mal
# capturé. Sa garde de contraste est le chemin nominal du groupe b, qui exige au
# contraire un stdout riche.
refus_memoire() {
    local libelle="$1" motif="$2"; shift 2

    lancer bash "$CHECK_MEMORY_SH" "$@"
    assert_code 2 "$CODE" "check-memory.sh refuse $libelle"
    assert_contient "$(erreur)" "$motif" "check-memory.sh, $libelle : la cause est nommée"
    assert_egal "1" "$(nb_lignes_contenant '[ERROR]')" \
        "check-memory.sh, $libelle : une seule ligne [ERROR]"
    assert_egal "1" "$(nb_lignes_erreur)" \
        "check-memory.sh, $libelle : stderr ne porte QUE ce diagnostic"
    assert_absent "$(erreur)" "Usage :" \
        "check-memory.sh, $libelle : l'aide n'est pas déversée sur stderr"
    assert_absent "$(erreur)" "Échec (code" \
        "check-memory.sh, $libelle : le trap ERR n'ajoute aucune ligne"
    assert_egal "" "$(sortie)" \
        "check-memory.sh, $libelle : AUCUNE sortie de diagnostic avant le refus"
}

# --- Preuve de la lecture seule --------------------------------------------

# empreinte <destination> — l'état de tout /etc, contenu compris.
#
# Tout /etc est relevé et non une liste arrêtée d'avance : c'est ce qui permet
# de voir une écriture qu'on n'attendait pas. LOG_DIR en est délibérément
# absent — lib/common.sh y écrit un journal au seul chargement, avant que le
# script n'ait lu ses arguments, et l'y inclure rendrait toute empreinte
# différente de la précédente.
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
# ferait remonter tout ce que le conteneur a écrit dans la même seconde.
assert_aucune_ecriture() {
    local temoin="$1" libelle="$2"
    local racine code=0
    local -a racines=()

    for racine in /etc /root /usr /opt /srv /var /boot; do
        if [ -d "$racine" ]; then
            racines+=("$racine")
        fi
    done

    find "${racines[@]}" -newer "$temoin" \
        -not -path '/var/log' \
        -not -path '/var/log/*' \
        -not -path "$LOG_DIR" \
        -not -path "$LOG_DIR/*" \
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

# ===================================================================
# Reconnaissance de l'environnement
# ===================================================================
titre "0. Environnement"

# oui_non <commande...> — « oui » si la commande réussit, « non » sinon.
# Écrit en « if » et non en « A && oui || non » : la seconde forme rend « non »
# lorsque « oui » échoue, et c'est le piège que SC2015 signale.
oui_non() {
    if "$@" >/dev/null 2>&1; then
        printf 'oui'
    else
        printf 'non'
    fi
}

SYSTEME=""
if ! SYSTEME="$(uname -s 2>/dev/null)"; then
    SYSTEME="inconnu"
fi
EST_LINUX="false"
if [ "$SYSTEME" = "Linux" ]; then
    EST_LINUX="true"
fi
info "Système : $SYSTEME"
info "/proc/meminfo lisible : $(oui_non test -r /proc/meminfo)"
info "/proc/swaps lisible : $(oui_non test -r /proc/swaps)"
info "« free » présent : $(oui_non command -v free)"
info "« ps » présent : $(oui_non command -v ps)"

if [ ! -f "$CHECK_MEMORY_SH" ]; then
    ko "Linux/System/check-memory.sh existe" "fichier introuvable : $CHECK_MEMORY_SH"
    bilan "TASK-022 / check-memory.sh"
    exit 1
fi
ok "Linux/System/check-memory.sh existe"

if [ "$EST_LINUX" != "true" ]; then
    # Hors Linux, ni /proc/meminfo ni « free » ni « ps --sort » n'existent : le
    # script démarrerait pour tout déclarer non disponible, et les cas ne
    # diraient rien de son comportement réel.
    saute_par_nature "l'ensemble des cas de check-memory.sh" \
        "cet hôte n'est pas un Linux — ni /proc/meminfo ni procps n'y existent"
    bilan "TASK-022 / check-memory.sh"
    exit 0
fi

# ===================================================================
# a. Aide et refus d'usage
# ===================================================================
titre "a. Aide et refus d'usage"

lancer bash "$CHECK_MEMORY_SH" --help
assert_code 0 "$CODE" "check-memory.sh --help sort en 0"
aide="$(sortie)"
assert_contient "$aide" "Usage : check-memory.sh" "check-memory.sh --help écrit son usage sur stdout"
assert_contient "$aide" "--seuil <1-100>" "l'aide documente --seuil"
assert_contient "$aide" "--top <1-100>" "l'aide documente --top"
assert_contient "$aide" "Défaut : 90" "l'aide donne la valeur par défaut du seuil"
assert_contient "$aide" "Défaut : 10" "l'aide donne le nombre de processus par défaut"
assert_contient "$aide" "SRV_MEM_SEUIL" "l'aide nomme l'origine du seuil"
assert_contient "$aide" "SRV_MEM_TOP" "l'aide nomme l'origine du nombre de processus"
assert_contient "$aide" "Codes de retour :" "l'aide documente les codes de retour"
# La règle d'origine fait partie du contrat : l'aide doit la dire, sans quoi un
# appelant attendrait un 2 d'un server.env mal saisi et ne le verrait jamais.
assert_contient "$aide" "erreur d'usage sur la LIGNE DE COMMANDE" \
    "l'aide borne le code 2 à la ligne de commande"
assert_contient "$aide" "Une valeur fautive venue de config/server.env ne rend jamais 2" \
    "l'aide documente le repli d'une valeur de configuration fautive"
# La distinction « libre » / « disponible » est le piège que ce script existe
# pour désamorcer : elle appartient à l'aide autant qu'à la sortie.
assert_contient "$aide" "jamais sur la mémoire LIBRE" \
    "l'aide dit sur quelle grandeur porte le seuil"

lancer bash "$CHECK_MEMORY_SH" -h
assert_code 0 "$CODE" "check-memory.sh -h sort en 0 lui aussi"
assert_contient "$(sortie)" "Usage : check-memory.sh" "check-memory.sh -h écrit la même aide"

refus_memoire "une option inconnue" \
    "Option inconnue : --nawak" --nawak
refus_memoire "--seuil sans valeur" \
    "--seuil attend un entier de 1 à 100." --seuil
refus_memoire "--top sans valeur" \
    "--top attend un entier de 1 à 100." --top
refus_memoire "--seuil non entier" \
    "--seuil : « abc » n'est pas un entier (ligne de commande)." --seuil abc
refus_memoire "--seuil à zéro" \
    "--seuil : « 0 » est hors bornes (ligne de commande) — attendu un entier de 1 à 100, sans zéro initial." \
    --seuil 0
refus_memoire "--seuil au-delà de 100" \
    "--seuil : « 101 » est hors bornes (ligne de commande)" --seuil 101
# « 010 » est bien une suite de chiffres : c'est le second « case » qui le
# refuse. Sans ce cas, un passage à l'arithmétique le lirait en octal et
# personne ne le verrait.
refus_memoire "--seuil à zéro initial" \
    "--seuil : « 010 » est hors bornes (ligne de commande)" --seuil 010
refus_memoire "--top non entier" \
    "--top : « beaucoup » n'est pas un entier (ligne de commande)." --top beaucoup
refus_memoire "--top à zéro" \
    "--top : « 0 » est hors bornes (ligne de commande)" --top 0

# La valeur qui suit l'option est bien CONSOMMÉE : sans cela, « --seuil 50 »
# laisserait « 50 » être relu comme une option et le refus viendrait pour la
# mauvaise raison. Le chemin nominal du groupe b le confirme par l'en-tête.
lancer bash "$CHECK_MEMORY_SH" --seuil 50 --top 3
assert_code 0 "$CODE" "check-memory.sh accepte --seuil et --top valides"

# ===================================================================
# b. Le chemin nominal, sur les mesures réelles
# ===================================================================
# Aucune valeur absolue n'est affirmée ici — dans un conteneur, « free » décrit
# l'hôte. Ce qui est éprouvé : les quatre sections existent, leurs tableaux ne
# sont pas vides, et les chiffres sont cohérents ENTRE EUX.
titre "b. Le chemin nominal"

lancer bash "$CHECK_MEMORY_SH"
assert_code 0 "$CODE" "check-memory.sh sort en 0 sans argument"
assert_egal "0" "$(nb_lignes_contenant '[ERROR]')" \
    "check-memory.sh nominal : aucune ligne [ERROR]"
assert_absent "$(erreur)" "Échec (code" \
    "check-memory.sh nominal : le trap ERR n'ajoute aucune ligne"

nominal="$(sortie)"
assert_contient "$nominal" "Diagnostic mémoire" "la section des paramètres est affichée"
assert_contient "$nominal" "Mémoire vive" "la section de la mémoire vive est affichée"
assert_contient "$nominal" "Fichier d'échange" "la section du fichier d'échange est affichée"
assert_contient "$nominal" "Processus les plus consommateurs" "la section des processus est affichée"

assert_egal "90 % de mémoire non disponible (valeur par défaut)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Seuil d'alerte")" \
    "l'en-tête donne le seuil et son origine"
assert_egal "10 (valeur par défaut)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Processus affichés")" \
    "l'en-tête donne le nombre de processus et son origine"

SOURCE_NOMINALE="$(valeur_dans_section "Diagnostic mémoire" "Source des mesures")"
assert_non_vide "$SOURCE_NOMINALE" "l'en-tête nomme la source des mesures"
if [ "$SOURCE_NOMINALE" = "non disponible" ]; then
    ko "la source des mesures est réellement renseignée" \
        "aucune source n'a répondu : tous les cas de ce groupe seraient vides"
else
    ok "la source des mesures est réellement renseignée — « $SOURCE_NOMINALE »"
fi

# Les cinq rubriques exigées par l'énoncé, chacune renseignée : totale, utilisée,
# libre, cache, disponible. « non disponible » y vaut échec — c'est précisément
# ce que ce script ne doit pas afficher sur une machine ordinaire.
for rubrique in "Totale" "Utilisée" "Libre" "Tampons et cache" "Disponible"; do
    valeur="$(valeur_dans_section "Mémoire vive" "$rubrique")"
    if [ -n "$valeur" ] && [ "$valeur" != "non disponible" ]; then
        ok "« Mémoire vive » renseigne « $rubrique » — « $valeur »"
    else
        ko "« Mémoire vive » renseigne « $rubrique »" "obtenu « $valeur »"
    fi
done

# La grandeur sur laquelle porte le seuil est affichée, et son intitulé le dit.
NON_DISPO="$(valeur_dans_section "Mémoire vive" "Non disponible")"
assert_contient "$NON_DISPO" "% — grandeur comparée au seuil" \
    "« Non disponible » dit qu'elle est la grandeur comparée au seuil"
# Cohérence interne : le pourcentage est un entier de 0 à 100. C'est tout ce
# qu'on peut exiger d'une mesure prise sur l'hôte.
part_non_dispo="${NON_DISPO%% *}"
if [ -n "$part_non_dispo" ] && [ -z "${part_non_dispo//[0-9]/}" ] \
    && [ "$part_non_dispo" -ge 0 ] && [ "$part_non_dispo" -le 100 ]; then
    ok "la part non disponible est un pourcentage cohérent — $part_non_dispo %"
else
    ko "la part non disponible est un pourcentage cohérent" "obtenu « $part_non_dispo »"
fi

# LA DISTINCTION QUI JUSTIFIE CE SCRIPT. Sans ce paragraphe, un lecteur
# conclurait d'une mémoire libre proche de zéro que la machine manque de
# mémoire, ce qui est faux sur tout serveur en fonctionnement.
assert_contient "$nominal" "« Disponible » est la grandeur qui compte" \
    "la sortie explique pourquoi « libre » n'est pas « disponible »"

# Le classement des processus : le DÉCOMPTE, seul à voir un tableau vide. Le
# corps porte l'en-tête plus une ligne par processus.
NB_PROCESSUS=$(( $(nb_lignes_section "Processus les plus consommateurs") - 1 ))
if [ "$NB_PROCESSUS" -ge 1 ]; then
    ok "le classement des processus n'est pas vide — $NB_PROCESSUS ligne(s)"
else
    ko "le classement des processus n'est pas vide" "$NB_PROCESSUS ligne(s) de données"
fi
if [ "$NB_PROCESSUS" -le 10 ]; then
    ok "le classement respecte la borne par défaut de 10 — $NB_PROCESSUS ligne(s)"
else
    ko "le classement respecte la borne par défaut de 10" "$NB_PROCESSUS ligne(s)"
fi
assert_contient "$nominal" "Elle classe, elle n'additionne pas." \
    "la sortie dit que la colonne RSS ne s'additionne pas"

# La section du fichier d'échange dit quelque chose, quoi qu'il en soit de la
# machine : soit l'absence constatée, soit des totaux. Le cas déterministe est
# éprouvé au groupe g, sous faux « free ».
ETAT_SWAP="$(valeur_dans_section "Fichier d'échange" "État")"
TOTAL_SWAP="$(valeur_dans_section "Fichier d'échange" "Total")"
if [ "$ETAT_SWAP" = "aucune zone d'échange active" ] || [ -n "$TOTAL_SWAP" ]; then
    ok "la section du fichier d'échange conclut — « ${ETAT_SWAP:-total : $TOTAL_SWAP} »"
else
    ko "la section du fichier d'échange conclut" \
        "ni état, ni total : état « $ETAT_SWAP », total « $TOTAL_SWAP »"
fi

# ===================================================================
# c. La lecture seule
# ===================================================================
# Le contrat le plus fort de ce script, et le seul qu'une régression pourrait
# violer sans que rien d'autre ne bouge.
titre "c. La lecture seule"

touch "$REP_TMP/temoin-lecture"
empreinte "$REP_TMP/etc-avant"
lancer bash "$CHECK_MEMORY_SH" --top 5
assert_code 0 "$CODE" "check-memory.sh sort en 0 avant la comparaison d'empreinte"
empreinte "$REP_TMP/etc-apres"

if diff -u "$REP_TMP/etc-avant" "$REP_TMP/etc-apres" > "$REP_TMP/diff-etc" 2>&1; then
    ok "check-memory.sh ne modifie rien dans /etc"
else
    ko "check-memory.sh ne modifie rien dans /etc" \
        "$(head -n 12 "$REP_TMP/diff-etc" | tr '\n' '|')"
fi
assert_aucune_ecriture "$REP_TMP/temoin-lecture" \
    "check-memory.sh n'écrit nulle part hors du répertoire de journaux"

# ===================================================================
# d. Deux exécutions consécutives
# ===================================================================
titre "d. Deux exécutions consécutives"

# La garde « la première exécution a modifié quelque chose » n'a pas de sens
# ici, et son absence est délibérée : elle interdit une idempotence prouvée à
# vide sur un script qui MODIFIE. Celui-ci ne modifie rien par contrat — exiger
# qu'il ait changé quelque chose reviendrait à exiger qu'il le viole.
touch "$REP_TMP/temoin-idem"
empreinte "$REP_TMP/etc-idem-avant"
lancer bash "$CHECK_MEMORY_SH"
CODE_IDEM_1="$CODE"
lancer bash "$CHECK_MEMORY_SH"
CODE_IDEM_2="$CODE"
empreinte "$REP_TMP/etc-idem-apres"

assert_egal "0" "$CODE_IDEM_1" "check-memory.sh, première exécution : code 0"
assert_egal "0" "$CODE_IDEM_2" "check-memory.sh, seconde exécution : code 0"
if diff -q "$REP_TMP/etc-idem-avant" "$REP_TMP/etc-idem-apres" >/dev/null 2>&1; then
    ok "check-memory.sh exécuté deux fois laisse le système inchangé"
else
    ko "check-memory.sh exécuté deux fois laisse le système inchangé" \
        "$(diff -u "$REP_TMP/etc-idem-avant" "$REP_TMP/etc-idem-apres" | head -n 12 | tr '\n' '|')"
fi
assert_aucune_ecriture "$REP_TMP/temoin-idem" \
    "deux exécutions consécutives n'écrivent nulle part hors des journaux"

# ===================================================================
# Les faux « free » et « ps »
# ===================================================================
# Un binaire homonyme en tête de PATH : la mutation la moins coûteuse du dépôt.
# Elle sert ici à deux fins distinctes — mettre une source EN ÉCHEC, et lui
# faire rendre des MESURES CONNUES. La seconde est la seule façon d'éprouver un
# seuil dans un conteneur, où les chiffres réels sont ceux de l'hôte.
#
# Les tableaux reproduisent la sortie de « free -k » sous LC_ALL=C : un en-tête,
# une ligne « Mem: », une ligne « Swap: ». Le script lit les champs par position.
REP_FREE_ECHEC="$REP_TMP/stub-free-echec"
REP_FREE_MUET="$REP_TMP/stub-free-muet"
REP_FREE_NORMAL="$REP_TMP/stub-free-normal"
REP_FREE_SATURE="$REP_TMP/stub-free-sature"
REP_FREE_ECHANGE_SEUL="$REP_TMP/stub-free-echange-seul"
REP_FREE_SANS_DISPO="$REP_TMP/stub-free-sans-dispo"
REP_PS_ECHEC="$REP_TMP/stub-ps-echec"
REP_PS_MUET="$REP_TMP/stub-ps-muet"
REP_PS_CINQ="$REP_TMP/stub-ps-cinq"
REP_SANS_FREE="$REP_TMP/bin-sans-free"
REP_SANS_PS="$REP_TMP/bin-sans-ps"

mkdir -p "$REP_FREE_ECHEC" "$REP_FREE_MUET" "$REP_FREE_NORMAL" "$REP_FREE_SATURE" \
    "$REP_FREE_ECHANGE_SEUL" "$REP_FREE_SANS_DISPO" \
    "$REP_PS_ECHEC" "$REP_PS_MUET" "$REP_PS_CINQ"

printf '#!/bin/sh\nexit 1\n' > "$REP_FREE_ECHEC/free"
printf '#!/bin/sh\nexit 0\n' > "$REP_FREE_MUET/free"
printf '#!/bin/sh\nexit 1\n' > "$REP_PS_ECHEC/ps"
printf '#!/bin/sh\nexit 0\n' > "$REP_PS_MUET/ps"

# Mémoire de 4 000 000 Ko, disponible 2 800 000 Ko : 70 % du total disponible,
# donc 30 % NON disponible. Le seuil est éprouvé sur cette valeur connue.
# Aucune zone d'échange — le cas nominal d'un conteneur et de bien des VPS.
cat > "$REP_FREE_NORMAL/free" <<'FAUX_FREE'
#!/bin/sh
cat <<'SORTIE'
               total        used        free      shared  buff/cache   available
Mem:         4000000     1000000      500000       10000     2500000     2800000
Swap:              0           0           0
SORTIE
FAUX_FREE

# Mémoire non disponible à 95 %, échange occupé à 95 % : la CONJONCTION.
cat > "$REP_FREE_SATURE/free" <<'FAUX_FREE'
#!/bin/sh
cat <<'SORTIE'
               total        used        free      shared  buff/cache   available
Mem:         1000000      900000       20000       10000       80000       50000
Swap:        1000000      950000       50000
SORTIE
FAUX_FREE

# Échange occupé à 95 % alors que la mémoire va bien — 15 % non disponible.
# LE CAS NÉGATIF DE LA CONJONCTION, et le plus important des deux.
cat > "$REP_FREE_ECHANGE_SEUL/free" <<'FAUX_FREE'
#!/bin/sh
cat <<'SORTIE'
               total        used        free      shared  buff/cache   available
Mem:         1000000      100000      700000       10000      200000      850000
Swap:        1000000      950000       50000
SORTIE
FAUX_FREE

# La colonne « available » n'existe que depuis procps-ng 3.3.10 : sans elle, le
# seuil n'a rien à comparer, et le script doit le dire plutôt que d'inventer.
cat > "$REP_FREE_SANS_DISPO/free" <<'FAUX_FREE'
#!/bin/sh
cat <<'SORTIE'
               total        used        free      shared  buff/cache
Mem:         1000000      400000      100000        5000      500000
Swap:              0           0           0
SORTIE
FAUX_FREE

# Cinq processus, et cinq exactement : c'est le seul montage où « trois lignes
# affichées » se distingue de « la machine n'en avait que trois ».
cat > "$REP_PS_CINQ/ps" <<'FAUX_PS'
#!/bin/sh
cat <<'SORTIE'
    PID USER        RSS %MEM COMMAND
    101 root     500000  5.0 postgres
    102 root     400000  4.0 java
    103 www-data 300000  3.0 nginx
    104 root     200000  2.0 dockerd
    105 nobody   100000  1.0 sshd
SORTIE
FAUX_PS

chmod +x "$REP_FREE_ECHEC/free" "$REP_FREE_MUET/free" "$REP_FREE_NORMAL/free" \
    "$REP_FREE_SATURE/free" "$REP_FREE_ECHANGE_SEUL/free" "$REP_FREE_SANS_DISPO/free" \
    "$REP_PS_ECHEC/ps" "$REP_PS_MUET/ps" "$REP_PS_CINQ/ps"

# Bacs à sable de liens symboliques : le PATH reproduit SANS la commande visée.
# Le mettre en échec ne suffirait pas — « command -v » réussirait encore et la
# branche « absent » resterait fermée. Rien n'est touché sur le système.
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
sablonner "$REP_SANS_FREE" "free"
sablonner "$REP_SANS_PS" "ps"

# garde_stub_echoue <nom> <commande...> — sans elle, un stub mal posé rendrait
# le cas vert pour la plus mauvaise des raisons : la commande n'a jamais échoué.
garde_stub_echoue() {
    local nom="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ko "garde : le faux « $nom » échoue bien" "le stub a rendu 0"
    else
        ok "garde : le faux « $nom » échoue bien"
    fi
}

# ===================================================================
# e. La dégradation, une source en échec à la fois
# ===================================================================
titre "e. La dégradation"

garde_stub_echoue "free (en échec)" "$REP_FREE_ECHEC/free" -k
garde_stub_echoue "ps (en échec)" "$REP_PS_ECHEC/ps" -eo pid

if PATH="$REP_SANS_FREE" command -v free >/dev/null 2>&1; then
    ko "garde : « free » est bien masqué dans le bac à sable" \
        "il y reste visible — la branche /proc/meminfo ne serait pas atteinte"
else
    ok "garde : « free » est bien masqué dans le bac à sable"
fi
if PATH="$REP_SANS_PS" command -v ps >/dev/null 2>&1; then
    ko "garde : « ps » est bien masqué dans le bac à sable" "il y reste visible"
else
    ok "garde : « ps » est bien masqué dans le bac à sable"
fi

# e.1 — « free » en échec : repli annoncé sur /proc/meminfo, et il aboutit.
lancer env "PATH=$REP_FREE_ECHEC:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "« free » en échec"
assert_contient "$(erreur)" "[WARN] « free » a échoué : lecture de la mémoire par cette voie impossible." \
    "check-memory.sh, « free » en échec : la cause est nommée"
assert_contient "$(erreur)" "[WARN] Repli sur /proc/meminfo." \
    "check-memory.sh, « free » en échec : le repli est annoncé"
if [ -r /proc/meminfo ]; then
    assert_egal "/proc/meminfo (repli, « free » a échoué)" \
        "$(valeur_dans_section "Diagnostic mémoire" "Source des mesures")" \
        "check-memory.sh, « free » en échec : la source retenue est nommée sans ambiguïté"
    valeur="$(valeur_dans_section "Mémoire vive" "Totale")"
    if [ -n "$valeur" ] && [ "$valeur" != "non disponible" ]; then
        ok "check-memory.sh, « free » en échec : le repli rend une mesure réelle — « $valeur »"
    else
        ko "check-memory.sh, « free » en échec : le repli rend une mesure réelle" \
            "obtenu « $valeur » — le repli n'a rien produit"
    fi
else
    saute_indisponible "le repli de « free » vers /proc/meminfo" "/proc/meminfo est illisible ici"
fi

# e.2 — « free » muet : un code 0 sans sortie n'est pas une lecture réussie.
lancer env "PATH=$REP_FREE_MUET:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "« free » muet"
assert_contient "$(erreur)" "[WARN] « free » n'a rien écrit : lecture de la mémoire par cette voie impossible." \
    "check-memory.sh, « free » muet : un code 0 sans sortie est traité comme un échec"

# e.3 — « free » ABSENT : l'autre chemin, et l'autre message. Le critère
# « il lit /proc/meminfo lorsque free est absent, ET IL LE DIT » tient ici.
if [ ! -r /proc/meminfo ]; then
    saute_indisponible "check-memory.sh sans « free »" "/proc/meminfo est illisible ici"
else
    lancer env "PATH=$REP_SANS_FREE" bash "$CHECK_MEMORY_SH"
    invariants_memoire "« free » absent"
    assert_contient "$(erreur)" "[INFO] « free » est introuvable (paquet procps) : lecture de /proc/meminfo." \
        "check-memory.sh, « free » absent : l'absence est dite, et comme une information et non comme un défaut"
    assert_egal "/proc/meminfo (« free » est absent)" \
        "$(valeur_dans_section "Diagnostic mémoire" "Source des mesures")" \
        "check-memory.sh, « free » absent : la source retenue le dit"
    # La garde de contraste : la branche rend de VRAIS nombres. Sans elle, le cas
    # resterait vert sur un tableau intégralement « non disponible ».
    for rubrique in "Totale" "Libre" "Disponible"; do
        valeur="$(valeur_dans_section "Mémoire vive" "$rubrique")"
        if [ -n "$valeur" ] && [ "$valeur" != "non disponible" ]; then
            ok "check-memory.sh sans « free » : /proc/meminfo renseigne « $rubrique » — « $valeur »"
        else
            ko "check-memory.sh sans « free » : /proc/meminfo renseigne « $rubrique »" \
                "obtenu « $valeur »"
        fi
    done
    # Le classement des processus survit au bac à sable : « ps » y est resté.
    NB_SANS_FREE=$(( $(nb_lignes_section "Processus les plus consommateurs") - 1 ))
    if [ "$NB_SANS_FREE" -ge 1 ]; then
        ok "check-memory.sh sans « free » : le classement des processus tient toujours"
    else
        ko "check-memory.sh sans « free » : le classement des processus tient toujours" \
            "$NB_SANS_FREE ligne(s)"
    fi
fi

# e.4 — « ps » en échec : seule la troisième section dégrade.
lancer env "PATH=$REP_PS_ECHEC:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "« ps » en échec"
assert_contient "$(erreur)" "[WARN] « ps » a échoué : processus consommateurs non disponibles." \
    "check-memory.sh, « ps » en échec : la cause est nommée"
assert_egal "non disponible" "$(valeur_dans_section "Processus les plus consommateurs" "Processus")" \
    "check-memory.sh, « ps » en échec : le classement dégrade en « non disponible »"
# La garde qui borne la dégradation : les deux autres sections sont intactes.
valeur="$(valeur_dans_section "Mémoire vive" "Totale")"
if [ -n "$valeur" ] && [ "$valeur" != "non disponible" ]; then
    ok "check-memory.sh, « ps » en échec : la section mémoire reste renseignée — « $valeur »"
else
    ko "check-memory.sh, « ps » en échec : la section mémoire reste renseignée" \
        "obtenu « $valeur » — la dégradation a débordé de sa section"
fi

# e.5 — « ps » muet.
lancer env "PATH=$REP_PS_MUET:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "« ps » muet"
assert_contient "$(erreur)" "[WARN] « ps » n'a rien écrit : processus consommateurs non disponibles." \
    "check-memory.sh, « ps » muet : un code 0 sans sortie est traité comme un échec"

# e.6 — « ps » ABSENT : l'autre message, qui nomme le paquet à installer.
lancer env "PATH=$REP_SANS_PS" bash "$CHECK_MEMORY_SH"
invariants_memoire "« ps » absent"
assert_contient "$(erreur)" "[WARN] « ps » est introuvable (paquet procps) : processus consommateurs non disponibles." \
    "check-memory.sh, « ps » absent : la cause nomme le paquet"
assert_egal "non disponible" "$(valeur_dans_section "Processus les plus consommateurs" "Processus")" \
    "check-memory.sh, « ps » absent : le classement dégrade en « non disponible »"

# ===================================================================
# f. Le seuil — atteint, et non dépassé
# ===================================================================
# Sous faux « free », la part non disponible vaut exactement 30 % : 4 000 000 Ko
# au total, 2 800 000 Ko disponibles. Les trois cas qui suivent encadrent cette
# valeur, et le cas d'égalité est celui qui tranche entre « -ge » et « -gt ».
titre "f. Le seuil"

# Garde de contraste : le faux « free » est bien celui qu'on croit.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "faux « free » nominal"
assert_egal "free" "$(valeur_dans_section "Diagnostic mémoire" "Source des mesures")" \
    "garde : le faux « free » est bien la source retenue"
assert_egal "30 % — grandeur comparée au seuil" \
    "$(valeur_dans_section "Mémoire vive" "Non disponible")" \
    "garde : le faux « free » donne bien 30 % de mémoire non disponible"
assert_egal "3,8 Go" "$(valeur_dans_section "Mémoire vive" "Totale")" \
    "garde : les kibioctets sont convertis en multiples binaires"
assert_absent "$(erreur)" "Seuil de 90 %" \
    "check-memory.sh, 30 % sous un seuil de 90 % : aucun avertissement"

# f.1 — le seuil ATTEINT, à l'égalité stricte. Sans ce cas, un « -gt » écrit à
# la place du « -ge » passerait inaperçu.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH" --seuil 30
invariants_memoire "seuil atteint à l'égalité"
assert_contient "$(erreur)" "[WARN] Seuil de 30 % atteint — 30 % de la mémoire est non disponible" \
    "check-memory.sh : un seuil ATTEINT — et pas seulement dépassé — vaut un avertissement"
assert_contient "$(erreur)" "(reste 2,6 Go (70 % du total))" \
    "check-memory.sh : l'avertissement dit ce qui reste"

# f.2 — un cran au-dessus : plus rien. C'est ce cas qui prouve que le précédent
# tenait à l'égalité et non à un avertissement émis systématiquement.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH" --seuil 31
invariants_memoire "seuil non atteint"
assert_absent "$(erreur)" "Seuil de 31 % atteint" \
    "check-memory.sh : un seuil d'un point au-dessus ne déclenche rien"

# f.3 — le seuil dépassé ne change pas le code de retour. Le contrat du script.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH" --seuil 1
assert_code 0 "$CODE" "check-memory.sh rend 0 même seuil largement dépassé"
assert_contient "$(erreur)" "[WARN] Seuil de 1 % atteint" \
    "check-memory.sh : le dépassement est bien signalé, il n'est simplement pas un échec"
assert_egal "0" "$(nb_lignes_contenant '[ERROR]')" \
    "check-memory.sh : un seuil dépassé n'est pas une erreur"

# f.4 — sans colonne « available », le seuil n'a rien à comparer : le script le
# dit au lieu d'inventer une valeur.
lancer env "PATH=$REP_FREE_SANS_DISPO:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "« free » sans colonne « available »"
assert_egal "non disponible" "$(valeur_dans_section "Mémoire vive" "Disponible")" \
    "check-memory.sh, sans « available » : la mémoire disponible est « non disponible »"
assert_egal "non disponible" "$(valeur_dans_section "Mémoire vive" "Non disponible")" \
    "check-memory.sh, sans « available » : la part non disponible ne se calcule pas"
assert_contient "$(erreur)" "[WARN] Mémoire disponible inconnue : le seuil de 90 % n'a pas pu être comparé." \
    "check-memory.sh, sans « available » : l'impossibilité de comparer est dite"
assert_contient "$(erreur)" "procps-ng 3.3.10" \
    "check-memory.sh, sans « available » : la cause historique est nommée"
# La garde qui borne : le reste du tableau tient debout.
assert_egal "976,5 Mo" "$(valeur_dans_section "Mémoire vive" "Totale")" \
    "check-memory.sh, sans « available » : le reste du tableau reste renseigné"

# ===================================================================
# g. Le fichier d'échange — absence, conjonction, et son cas négatif
# ===================================================================
titre "g. Le fichier d'échange"

# g.1 — aucune zone active. CONSTAT et non ignorance : le script l'a lu, et il
# ne traite pas ce cas comme une anomalie.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH"
invariants_memoire "aucune zone d'échange"
assert_egal "aucune zone d'échange active" \
    "$(valeur_dans_section "Fichier d'échange" "État")" \
    "check-memory.sh : l'absence de zone d'échange est un CONSTAT, pas un « non disponible »"
assert_contient "$(sortie)" "Ce n'est pas une anomalie" \
    "check-memory.sh : l'absence de zone d'échange est explicitement dédramatisée"
assert_egal "0" "$(nb_lignes_contenant '[WARN]')" \
    "check-memory.sh : aucune zone d'échange ne vaut aucun avertissement"

# g.2 — LE CAS NÉGATIF DE LA CONJONCTION, le plus important du groupe. Un
# échange occupé à 95 % pendant que la mémoire va bien : le noyau y déplace des
# pages inactives, c'est son travail. Rien à signaler.
lancer env "PATH=$REP_FREE_ECHANGE_SEUL:$PATH" bash "$CHECK_MEMORY_SH" --seuil 90
invariants_memoire "échange saturé, mémoire ample"
assert_egal "976,5 Mo" "$(valeur_dans_section "Fichier d'échange" "Total")" \
    "check-memory.sh : l'échange actif affiche son total"
assert_contient "$(valeur_dans_section "Fichier d'échange" "Utilisé")" "(95 % du total)" \
    "check-memory.sh : l'échange actif affiche sa part occupée"
assert_absent "$(erreur)" "des deux côtés" \
    "check-memory.sh : un échange saturé SEUL ne vaut AUCUN avertissement"
assert_egal "0" "$(nb_lignes_contenant '[WARN]')" \
    "check-memory.sh : mémoire ample et échange occupé — rien à signaler du tout"

# g.3 — la conjonction, elle, alarme : plus de réserve nulle part.
lancer env "PATH=$REP_FREE_SATURE:$PATH" bash "$CHECK_MEMORY_SH" --seuil 90
invariants_memoire "échange et mémoire saturés"
assert_contient "$(erreur)" "[WARN] Seuil de 90 % atteint des deux côtés — échange occupé à 95 % alors que 95 % de la mémoire est non disponible" \
    "check-memory.sh : la CONJONCTION des deux saturations vaut un avertissement"
assert_contient "$(erreur)" "il ne reste de réserve ni en mémoire, ni en échange." \
    "check-memory.sh : l'avertissement de conjonction dit ce qui est en jeu"
assert_egal "2" "$(nb_lignes_contenant '[WARN]')" \
    "check-memory.sh : deux avertissements mesurés — la mémoire, puis la conjonction"

# g.4 — les zones actives, listées depuis /proc/swaps. « aucune » y est un
# constat, exactement comme « aucune zone d'échange active » plus haut : le
# fichier a été lu, il ne liste rien. C'est le cas d'un conteneur, où « free »
# décrit l'hôte tandis que /proc/swaps ne montre que ce qui lui est monté.
if [ ! -r /proc/swaps ]; then
    saute_indisponible "la liste des zones d'échange actives" "/proc/swaps est illisible ici"
else
    ZONES="$(valeur_dans_section "Fichier d'échange" "Zones actives")"
    if [ -n "$ZONES" ]; then
        assert_egal "aucune — /proc/swaps ne liste aucune zone" "$ZONES" \
            "check-memory.sh : un /proc/swaps lu et vide donne un CONSTAT, jamais « non disponible »"
    elif contient "$(sortie)" "Zone active"; then
        ok "check-memory.sh : les zones d'échange de cet hôte sont listées dans un tableau"
    else
        ko "check-memory.sh : la liste des zones d'échange conclut" \
            "ni « aucune », ni tableau"
    fi
fi

# ===================================================================
# h. La borne de --top
# ===================================================================
# Sous un faux « ps » de cinq lignes exactement : c'est le seul montage où
# « trois lignes affichées » se distingue de « la machine n'en avait que trois ».
titre "h. La borne de --top"

lancer env "PATH=$REP_PS_CINQ:$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH" --top 5
invariants_memoire "faux « ps », --top 5"
NB_CINQ=$(( $(nb_lignes_section "Processus les plus consommateurs") - 1 ))
assert_egal "5" "$NB_CINQ" "garde : le faux « ps » fournit bien cinq processus"
assert_contient "$(sortie)" "postgres" "garde : le classement porte bien les processus du faux « ps »"

lancer env "PATH=$REP_PS_CINQ:$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH" --top 3
invariants_memoire "faux « ps », --top 3"
NB_TROIS=$(( $(nb_lignes_section "Processus les plus consommateurs") - 1 ))
assert_egal "3" "$NB_TROIS" "check-memory.sh : --top 3 borne le classement à trois lignes"
assert_egal "3 (ligne de commande)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Processus affichés")" \
    "check-memory.sh : l'en-tête rappelle la borne et son origine"
# La borne coupe par le BAS du classement, trié sur la mémoire résidente
# décroissante : les trois premiers restent, les deux derniers partent.
assert_contient "$(sortie)" "postgres" "check-memory.sh, --top 3 : le premier du classement est conservé"
assert_absent "$(sortie)" "sshd" "check-memory.sh, --top 3 : le dernier du classement est écarté"

# ===================================================================
# i. L'origine des valeurs — configuration contre ligne de commande
# ===================================================================
# SRV_MEM_SEUIL et SRV_MEM_TOP sont transmises par l'ENVIRONNEMENT : même
# variable et même « set -a » de lib/common.sh, mais le CHARGEMENT de
# config/server.env n'est pas emprunté. La limite est déclarée en fin de fichier.
titre "i. L'origine des valeurs"

# i.1 — une valeur de configuration valide est prise, et son origine est dite.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" SRV_MEM_SEUIL=25 SRV_MEM_TOP=4 bash "$CHECK_MEMORY_SH"
invariants_memoire "SRV_MEM_SEUIL et SRV_MEM_TOP valides"
assert_egal "25 % de mémoire non disponible (config/server.env)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Seuil d'alerte")" \
    "check-memory.sh : SRV_MEM_SEUIL est pris, et son origine est affichée"
assert_egal "4 (config/server.env)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Processus affichés")" \
    "check-memory.sh : SRV_MEM_TOP est pris, et son origine est affichée"
assert_contient "$(erreur)" "[WARN] Seuil de 25 % atteint" \
    "check-memory.sh : le seuil venu de la configuration s'applique réellement"

# i.2 — la ligne de commande prime sur la configuration.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" SRV_MEM_SEUIL=25 SRV_MEM_TOP=4 \
    bash "$CHECK_MEMORY_SH" --seuil 80 --top 2
invariants_memoire "la ligne de commande contre la configuration"
assert_egal "80 % de mémoire non disponible (ligne de commande)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Seuil d'alerte")" \
    "check-memory.sh : --seuil prime sur SRV_MEM_SEUIL"
assert_egal "2 (ligne de commande)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Processus affichés")" \
    "check-memory.sh : --top prime sur SRV_MEM_TOP"
assert_absent "$(erreur)" "Seuil de 25 %" \
    "check-memory.sh : le seuil de la configuration est bien écarté, pas seulement masqué"

# i.3 — UNE VALEUR FAUTIVE DE LA CONFIGURATION NE REND JAMAIS 2. L'assertion
# décisive n'est ni le code ni le message : c'est QUE LE DIAGNOSTIC EST PRODUIT.
# Priver l'appelant de tout son état mémoire parce qu'une variable qu'il n'a
# peut-être pas écrite lui-même est mal saisie serait disproportionné.
lancer env "PATH=$REP_FREE_NORMAL:$PATH" SRV_MEM_SEUIL=abc bash "$CHECK_MEMORY_SH"
invariants_memoire "SRV_MEM_SEUIL non entier"
assert_contient "$(erreur)" "[WARN] « abc » (config/server.env, SRV_MEM_SEUIL) n'est pas un entier :" \
    "check-memory.sh : un SRV_MEM_SEUIL fautif vaut un avertissement qui nomme la variable"
assert_contient "$(erreur)" "[WARN] repli sur le seuil par défaut, 90 %." \
    "check-memory.sh : l'avertissement dit ce qui est retenu à la place"
assert_egal "90 % de mémoire non disponible (valeur par défaut, SRV_MEM_SEUIL refusé)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Seuil d'alerte")" \
    "check-memory.sh : l'en-tête porte le repli et dit que SRV_MEM_SEUIL a été refusé"
assert_egal "30 % — grandeur comparée au seuil" \
    "$(valeur_dans_section "Mémoire vive" "Non disponible")" \
    "check-memory.sh : LE DIAGNOSTIC EST PRODUIT MALGRÉ LA VALEUR REFUSÉE"

lancer env "PATH=$REP_FREE_NORMAL:$PATH" SRV_MEM_SEUIL=0 bash "$CHECK_MEMORY_SH"
invariants_memoire "SRV_MEM_SEUIL hors bornes"
assert_contient "$(erreur)" "[WARN] « 0 » (config/server.env, SRV_MEM_SEUIL) est hors bornes — attendu un entier de 1 à 100, sans zéro initial :" \
    "check-memory.sh : un SRV_MEM_SEUIL hors bornes est diagnostiqué comme tel"
assert_egal "90 % de mémoire non disponible (valeur par défaut, SRV_MEM_SEUIL refusé)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Seuil d'alerte")" \
    "check-memory.sh : le repli vaut aussi pour une valeur hors bornes"

lancer env "PATH=$REP_PS_CINQ:$REP_FREE_NORMAL:$PATH" SRV_MEM_TOP=zero bash "$CHECK_MEMORY_SH"
invariants_memoire "SRV_MEM_TOP non entier"
assert_contient "$(erreur)" "[WARN] « zero » (config/server.env, SRV_MEM_TOP) n'est pas un entier :" \
    "check-memory.sh : un SRV_MEM_TOP fautif vaut un avertissement qui nomme la variable"
assert_contient "$(erreur)" "[WARN] repli sur la valeur par défaut, 10 processus." \
    "check-memory.sh : le repli de SRV_MEM_TOP dit ce qui est retenu"
assert_egal "10 (valeur par défaut, SRV_MEM_TOP refusé)" \
    "$(valeur_dans_section "Diagnostic mémoire" "Processus affichés")" \
    "check-memory.sh : l'en-tête porte le repli de SRV_MEM_TOP"
assert_egal "5" "$(( $(nb_lignes_section "Processus les plus consommateurs") - 1 ))" \
    "check-memory.sh : le classement est produit malgré le SRV_MEM_TOP refusé"

# i.4 — une valeur fautive sur la LIGNE DE COMMANDE rend 2, même quand la
# configuration en fournit une bonne. C'est l'origine qui décide, jamais la
# valeur retenue.
lancer env SRV_MEM_SEUIL=50 bash "$CHECK_MEMORY_SH" --seuil abc
assert_code 2 "$CODE" "check-memory.sh refuse un --seuil fautif même avec un SRV_MEM_SEUIL valide"
assert_contient "$(erreur)" "--seuil : « abc » n'est pas un entier (ligne de commande)." \
    "check-memory.sh : c'est bien la ligne de commande qui est reprochée"
assert_absent "$(erreur)" "SRV_MEM_SEUIL" \
    "check-memory.sh : la variable de configuration n'est pas mise en cause à tort"
assert_egal "" "$(sortie)" \
    "check-memory.sh : le refus précède toute lecture, ici aussi"

# ===================================================================
# j. Deux exécutions consécutives, sortie comparée à l'octet près
# ===================================================================
# Sur les mesures réelles, deux exécutions diffèrent forcément — c'est le propre
# d'une machine qui travaille. Sous faux « free » et faux « ps », toutes les
# valeurs sont fixées : la sortie doit alors être rigoureusement identique. C'est
# la seule forme sous laquelle « la même sortie » veut dire quelque chose.
titre "j. Deux sorties identiques sous sources fixées"

lancer env "PATH=$REP_PS_CINQ:$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH"
CODE_FIXE_1="$CODE"
cp "$F_OUT" "$REP_TMP/sortie-1"
lancer env "PATH=$REP_PS_CINQ:$REP_FREE_NORMAL:$PATH" bash "$CHECK_MEMORY_SH"
CODE_FIXE_2="$CODE"
cp "$F_OUT" "$REP_TMP/sortie-2"

assert_egal "0" "$CODE_FIXE_1" "sources fixées, première exécution : code 0"
assert_egal "0" "$CODE_FIXE_2" "sources fixées, seconde exécution : code 0"
if diff -u "$REP_TMP/sortie-1" "$REP_TMP/sortie-2" > "$REP_TMP/diff-sortie" 2>&1; then
    ok "check-memory.sh, sources fixées : deux exécutions rendent la même sortie"
else
    ko "check-memory.sh, sources fixées : deux exécutions rendent la même sortie" \
        "$(head -n 12 "$REP_TMP/diff-sortie" | tr '\n' '|')"
fi

# ===================================================================
# k. Hors de portée de cet environnement
# ===================================================================
titre "k. Hors de portée de cet environnement"

saute_par_nature "le CHARGEMENT de config/server.env" \
    "les groupes i transmettent SRV_MEM_SEUIL et SRV_MEM_TOP par l'environnement — même variable, même « set -a » de lib/common.sh, mais le chargement du fichier n'est pas emprunté. L'écrire imposerait de créer config/server.env dans le dépôt monté, qui n'est pas un système jetable"

saute_par_nature "les valeurs absolues de mémoire" \
    "sans lxcfs, « free » et /proc/meminfo décrivent la machine hôte et non le conteneur : aucune assertion ne peut porter sur une valeur réelle, et toutes celles qui exigent un chiffre connu passent par un faux « free »"

saute_par_nature "une zone d'échange réellement active" \
    "/proc/swaps est vide dans le conteneur, et le remplir supposerait CAP_SYS_ADMIN et « swapon ». Le tableau des zones actives n'est donc éprouvé que par sa branche « aucune » ; la conjonction mémoire/échange l'est, elle, par un faux « free »"

bilan "TASK-022 / check-memory.sh"
