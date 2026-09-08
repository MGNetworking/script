#!/usr/bin/env bash
# check-services.sh — diagnostic des services systemd, en lecture seule.
#
# Deux modes : l'inventaire — services actifs, services en échec —, qui rend
# toujours 0, et la vérification d'un service nommé, dont le code de retour
# porte la réponse.
#
# N'écrit rien, ne modifie rien, ne nécessite aucun privilège et n'agit sur
# aucun service : ni start, ni stop, ni restart, ni enable, ni disable.
# Usage : ./check-services.sh [--service NOM] [--help]

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
source "$_dir/lib/common.sh"

# -------------------------------------------------------------------
# État
# -------------------------------------------------------------------
# SERVICE porte la valeur brute de --service, vide en mode inventaire ; UNITE
# porte le nom d'unité effectivement interrogé, suffixe « .service » compris.
# Les deux sont distincts pour que les messages nomment l'unité réelle, et non
# ce que l'appelant a tapé.
SERVICE=""
UNITE=""

# -------------------------------------------------------------------
# Aide
# -------------------------------------------------------------------
show_help() {
    cat <<'AIDE'
Usage : check-services.sh [options]

Diagnostic des services systemd, en lecture seule.

Sans option, le script INVENTORIE : nombre et liste des services actifs, puis
liste des services en échec, mise en évidence par un [WARN]. Il rend alors
TOUJOURS 0, même si des services sont en échec — c'est un diagnostic, il rend
compte, il ne juge pas.

Avec --service, il répond à une question fermée — ce service tourne-t-il ? —
et son code de retour porte la réponse.

Script en lecture seule : aucune modification, aucun privilège requis, aucune
action sur un service. Ni start, ni stop, ni restart, ni enable, ni disable.

Options :
      --service <nom>   Vérifier un service précis : état d'activation, état
                        d'exécution et date du dernier démarrage. Un nom sans
                        suffixe reçoit « .service » — « cron » vaut
                        « cron.service ». SEULES LES UNITÉS « .service » sont
                        acceptées : un timer, un socket, un target ou un mount
                        est refusé en 2.
  -h, --help            Afficher cette aide

Les issues de --service : une seule vaut 0, les six autres valent 1 et se
distinguent par le message, jamais par le code :

  service actif       l'unité est chargée et active                     code 0
  service inconnu     systemd ne connaît aucune unité de ce nom         code 1
  service masqué      l'unité est masquée : elle ne peut pas démarrer   code 1
  unité non chargée   systemd n'a pas pu charger son fichier d'unité    code 1
  service en échec    l'unité est chargée, son exécution a échoué       code 1
  service inactif     l'unité est chargée mais n'est pas active         code 1
  état inétablissable « systemctl show » n'a rien rendu d'exploitable   code 1

Codes de retour :
  0  inventaire produit — y compris lorsqu'un service est en échec ou qu'une
     information manque — ou service demandé ACTIF
  1  --service : service inactif, en échec, masqué, non chargé ou inconnu ;
     « systemctl » absent ; état impossible à établir
  2  erreur d'usage : option inconnue, --service sans valeur, nom de service
     manifestement invalide, unité autre qu'un service

Le nom donné à --service est refusé en 2 AVANT toute interrogation du système
dans deux cas :

  - il ne peut pas être un nom d'unité : lettres, chiffres, « - », « _ »,
    « . », « @ », « \ » et « : » sont seuls admis ;
  - il porte un suffixe autre que « .service ». Ce script ne diagnostique que
    les services : répondre « service actif » à propos de « local-fs.target »
    serait faux. L'état des autres unités se lit avec « systemctl status ».

Le refus porte sur ce qui ne peut pas être un service, jamais sur ce qui
n'existe pas — l'inexistence est un constat du système, elle vaut 1.

L'absence de « systemctl » rend 1, et non 2 : la ligne de commande était juste,
c'est la machine qui n'a pas la dépendance. Le message la nomme.

« systemctl list-units --state=failed » ne montre que les unités CHARGÉES dont
l'exécution a échoué : une unité masquée, désactivée ou qui n'a jamais démarré
n'y figure pas. La liste des services en échec n'est donc pas un état de santé
complet du serveur.

L'« état global » affiché en tête vient de « systemctl is-system-running ». Sa
valeur « degraded » signifie qu'au moins une unité a échoué — c'est banal, en
conteneur notamment, et ce n'est pas une panne.
AIDE
}

# -------------------------------------------------------------------
# Arguments
# -------------------------------------------------------------------
while [ "${1:-}" != "" ]; do
    case "$1" in
        --service)
            shift
            [ -n "${1:-}" ] || die "--service attend un nom de service." 2
            SERVICE="$1"; shift ;;
        -h|--help)  show_help; exit 0 ;;
        *)          die "Option inconnue : $1" 2 ;;
    esac
done

# -------------------------------------------------------------------
# Validation du nom de service
# -------------------------------------------------------------------
# Renseigne UNITE plutôt que d'écrire sur stdout, et n'est jamais appelée dans
# une substitution de commande : son « die » quitterait sinon le seul sous-shell,
# et le code remonté déclencherait le trap ERR de lib/common.sh — le refus se
# verrait doublé d'un « Échec (code 2) à la ligne … » sans intérêt. C'est le
# motif de valider_fichier_swap, dans configure-swap.sh.
#
# LE REFUS PORTE SUR LA FORME, JAMAIS SUR L'EXISTENCE. Un nom que systemd ne
# pourrait pas porter — comme un nom qui désigne autre chose qu'un service — est
# une faute de l'appelant : code 2, avant la moindre interrogation du système.
# Un nom bien formé qui ne désigne aucune unité est au contraire un CONSTAT du
# système : il vaut 1, et il est rendu plus bas, après lecture de l'état.
valider_nom_unite() {
    local nom="$1"

    # Une valeur commençant par un tiret est une option du script, avalée comme
    # nom : « check-services.sh --service --help » demanderait l'état d'un
    # service nommé « --help », et l'aide serait perdue en silence.
    case "$nom" in
        -*)
            error "Valeur refusée pour --service : « $nom »."
            error "Une valeur commençant par un tiret est une option, pas un nom de service :"
            error "elle serait consommée par --service, et l'option perdue en silence."
            die "Écrire le nom après --service — par exemple : --service cron" 2
            ;;
    esac

    # Jeu de caractères d'un nom d'unité systemd : lettres, chiffres, « - »,
    # « _ », « . », « @ » (instance), « \ » (échappement) et « : ». Tout le
    # reste — espace, barre oblique, guillemet, caractère de contrôle — ne peut
    # pas composer un nom d'unité.
    case "$nom" in
        *[!A-Za-z0-9@:._\\-]*)
            error "Nom de service invalide : « $nom »."
            error "Un nom d'unité systemd n'admet que lettres, chiffres, « - », « _ », « . », « @ », « \\ » et « : »."
            die "Corriger le nom — par exemple : --service ssh" 2
            ;;
    esac

    # Ce script ne répond QUE des services — TASK-023 met hors périmètre « les
    # unités autres que les services : timers, sockets, mounts, targets ». Une
    # unité d'un autre type est donc refusée ICI, avec les autres refus d'usage
    # et avant la moindre interrogation du système : demander l'état d'un timer
    # à check-services.sh est une erreur d'appel — code 2 —, pas un constat du
    # système. Répondre « Service actif : local-fs.target » serait de surcroît
    # faux : un target n'est pas un service.
    #
    # Un nom SANS point n'est pas concerné : il reçoit « .service » juste en
    # dessous. Un nom qui porte un point doit donc porter « .service » en
    # entier, y compris lorsque le point appartient au nom du service lui-même
    # — « com.exemple.app.service ».
    #
    # DEUX FAUTES SE CACHENT SOUS CE REFUS, et le conseil n'est juste que pour la
    # première : « dbus.socket » nomme une unité RÉELLE d'un autre type, dont
    # l'état se lit effectivement avec « systemctl status » ; « .. » n'est une
    # unité d'aucun type, et y renvoyer enverrait l'appelant sur une commande qui
    # ne peut rien lui apprendre. Les deux restent refusés en 2, avant toute
    # interrogation du système — seul le message change.
    #
    # Le départage se fait sur le suffixe, comparé à la liste CLOSE des types
    # d'unités de systemd, et sur la présence d'un nom devant lui : « .socket »
    # n'est pas plus une unité que « .. ».
    case "$nom" in
        *.service) ;;
        *.*)
            local suffixe="${nom##*.}" base="${nom%.*}" autre_type="non"
            case "$suffixe" in
                socket|target|timer|mount|automount|swap|path|device|slice|scope)
                    if [ -n "$base" ]; then
                        autre_type="oui"
                    fi
                    ;;
            esac

            if [ "$autre_type" = "oui" ]; then
                error "Unité refusée pour --service : « $nom »."
                error "Ce script ne diagnostique que les services : seules les unités « .service » sont acceptées."
                error "L'état d'une autre unité — timer, socket, target, mount — se lit avec : systemctl status $nom"
                die "Un service dont le nom contient un point s'écrit avec son suffixe — par exemple : --service com.exemple.app.service" 2
            fi

            error "Nom de service invalide : « $nom »."
            error "Le point d'un nom d'unité sépare un nom d'un TYPE connu — service, socket, timer, target, mount…"
            error "« $nom » ne désigne donc aucune unité, d'aucun type."
            die "Corriger le nom — par exemple : --service ssh, ou --service com.exemple.app.service" 2
            ;;
    esac

    # Un nom sans suffixe désigne un service : « cron » vaut « cron.service ».
    # Le suffixe est ajouté ici, une fois pour toutes, pour que tout ce qui est
    # affiché ou interrogé ensuite nomme l'unité réellement lue. Un nom qui porte
    # déjà « .service » est transmis tel quel — c'est systemd qui tranche s'il
    # connaît l'unité, et son refus vaut alors 1 comme n'importe quel autre
    # constat.
    UNITE="$nom"
    case "$UNITE" in
        *.*) ;;
        *)   UNITE="$UNITE.service" ;;
    esac
}

if [ -n "$SERVICE" ]; then
    valider_nom_unite "$SERVICE"
fi

# -------------------------------------------------------------------
# Préflight
# -------------------------------------------------------------------
# Les arguments sont vérifiés au-dessus, avant tout le reste : une ligne de
# commande fautive doit être reprochée avant qu'un seul état ne soit lu.
#
# Aucun privilège n'est exigé — « systemctl show » et « systemctl list-units »
# répondent à n'importe quel compte —, et aucune distribution n'est imposée : ce
# qui compte n'est pas le nom de l'OS mais la présence de systemd, que
# require_cmd établit. ADR-0003 décision 14 pose systemd partout, sans repli sur
# SysV ni OpenRC.
#
# require_cmd sort en 1 avec un message nommant la dépendance (ADR-0003
# décision 10) : la ligne de commande était juste, c'est la machine qui n'a pas
# ce qu'il faut. Rien n'est redéfini ici, le socle le fait déjà.
#
# Ni conflit, ni résumé, ni confirmation : ce script ne modifie rien, il n'y a
# rien à annoncer avant de le faire.
require_cmd systemctl

# -------------------------------------------------------------------
# Présentation
# -------------------------------------------------------------------
# Les quatre fonctions sont celles de check-disk.sh et de check-memory.sh, à
# l'identique : deux scripts jumeaux se lisent de la même façon.

# Titre de section
titre() {
    printf '\n%s\n' "$1"
    printf '%s\n' "------------------------------------------------------------"
}

# Ligne « libellé : valeur ». Une valeur vide devient « non disponible ».
#
# Le remplissage est calculé sur le nombre de caractères et non d'octets :
# « %-22s » de printf compte les octets, ce qui décale les libellés accentués.
ligne() {
    local libelle="$1"
    local valeur="${2:-non disponible}"
    local remplissage=$(( 23 - ${#libelle} ))

    if [ "$remplissage" -lt 1 ]; then
        remplissage=1
    fi
    printf '  %s%*s%s\n' "$libelle" "$remplissage" "" "$valeur"
}

# Cellule de largeur fixe, comptée en caractères.
# Usage : cellule <texte> <largeur> <gauche|droite>
cellule() {
    local texte="$1" largeur="$2" cote="$3"
    local remplissage=$(( largeur - ${#texte} ))

    if [ "$remplissage" -lt 0 ]; then
        remplissage=0
    fi
    if [ "$cote" = "droite" ]; then
        printf '%*s%s' "$remplissage" "" "$texte"
    else
        printf '%s%*s' "$texte" "$remplissage" ""
    fi
}

# Paragraphe explicatif, indenté comme les lignes de valeur. Il part sur stdout,
# avec le reste du diagnostic : ce n'est pas un avertissement, c'est une lecture
# de ce qui précède.
note() {
    local texte
    for texte in "$@"; do
        printf '  %s\n' "$texte"
    done
}

# -------------------------------------------------------------------
# Lecture de l'état d'une unité
# -------------------------------------------------------------------
# TOUTE interrogation de systemctl est placée en CONTEXTE DE CONDITION (TASK-018)
# — « if ! sortie="$(systemctl …)" ». Sous la forme nue, un systemctl en échec
# ferait parler deux fois le trap ERR de lib/common.sh sans nommer la cause, puis
# arrêterait le script.
#
# LC_ALL=C n'est pas un ornement : la date de dernier démarrage est écrite dans
# la locale du système, et la sortie doit rester la même d'une machine à l'autre.
#
# « systemctl show » est le SEUL appel qui distingue les trois issues de
# --service en une fois — inconnu, masqué, chargé — et il rend 0 dans tous les
# cas, y compris pour une unité qui n'existe pas. « is-active » les confond
# toutes en un code 3 : il ne peut pas servir de base à ce mode.
#
# Les valeurs sont lues PAR CLÉ et non par position : systemctl n'assure pas que
# l'ordre de sortie suive celui des « -p ». Une propriété sans valeur — le cas de
# UnitFileState et de ActiveEnterTimestamp pour une unité inconnue, celui de
# ActiveEnterTimestamp pour un service jamais démarré — produit une ligne
# « Clé= » : la variable reste vide, et « ligne » affichera « non disponible ».
LOAD_STATE=""
ACTIVE_STATE=""
SUB_STATE=""
UNIT_FILE_STATE=""
DERNIER_DEMARRAGE=""
lire_etat_unite() {
    local unite="$1"
    local sortie=""

    LOAD_STATE=""
    ACTIVE_STATE=""
    SUB_STATE=""
    UNIT_FILE_STATE=""
    DERNIER_DEMARRAGE=""

    if ! sortie="$(LC_ALL=C systemctl show \
            -p LoadState -p ActiveState -p SubState \
            -p UnitFileState -p ActiveEnterTimestamp \
            -- "$unite" 2>/dev/null)"; then
        return 1
    fi
    if [ -z "$sortie" ]; then
        return 1
    fi

    local enregistrement
    while IFS= read -r enregistrement; do
        case "$enregistrement" in
            LoadState=*)            LOAD_STATE="${enregistrement#*=}" ;;
            ActiveState=*)          ACTIVE_STATE="${enregistrement#*=}" ;;
            SubState=*)             SUB_STATE="${enregistrement#*=}" ;;
            UnitFileState=*)        UNIT_FILE_STATE="${enregistrement#*=}" ;;
            ActiveEnterTimestamp=*) DERNIER_DEMARRAGE="${enregistrement#*=}" ;;
        esac
    done <<< "$sortie"

    # LoadState est la clé de tout le verdict : sans elle, rien n'a été établi.
    if [ -z "$LOAD_STATE" ]; then
        return 1
    fi
    return 0
}

# -------------------------------------------------------------------
# Analyse d'une liste d'unités
# -------------------------------------------------------------------
# Renseigne UNITES (les noms) et LIGNES (le tableau formaté) à partir de la
# sortie de « systemctl list-units ». Les deux tableaux vont de pair : le
# décompte affiché et les avertissements se lisent sur le premier, l'affichage
# sur le second.
UNITES=()
LIGNES=()
analyser_liste() {
    local sortie="$1"
    local enregistrement premier reste unite sous description

    UNITES=()
    LIGNES=()

    while IFS= read -r enregistrement; do
        [ -n "$enregistrement" ] || continue

        # La première colonne peut porter un MARQUEUR — un point médian devant
        # les unités en échec — que « --no-legend » ne retire pas. Il est reconnu
        # à ce qu'il n'est pas un nom d'unité : « --type=service » garantit le
        # suffixe de tout ce qui est listé.
        read -r premier reste <<< "$enregistrement"
        if [ "${premier%.service}" = "$premier" ]; then
            enregistrement="$reste"
        fi

        # Colonnes de « list-units » : UNIT LOAD ACTIVE SUB DESCRIPTION. LOAD et
        # ACTIVE ne sont pas affichés — ils sont connus, c'est le filtre
        # « --state » qui les a choisis.
        read -r unite _ _ sous description <<< "$enregistrement"
        [ -n "$unite" ] || continue

        UNITES+=("$unite")
        LIGNES+=("$(printf '  %s%s%s' \
            "$(cellule "$unite" 36 gauche)" \
            "$(cellule "${sous:-?}" 12 gauche)" \
            "$description")")
    done <<< "$sortie"
}

# En-tête commun aux deux tableaux d'unités.
entete_unites() {
    printf '  %s%s%s\n' \
        "$(cellule "Unité" 36 gauche)" \
        "$(cellule "Sous-état" 12 gauche)" \
        "Description"
}

# Affiche le tableau construit par analyser_liste.
afficher_lignes() {
    local sortie
    for sortie in "${LIGNES[@]}"; do
        printf '%s\n' "$sortie"
    done
}

# -------------------------------------------------------------------
# Sections — mode inventaire
# -------------------------------------------------------------------

section_parametres() {
    titre "Diagnostic des services systemd"

    # « is-system-running » rend un code NON NUL dès que l'état n'est pas
    # « running » — « degraded » suffit —, d'où le contexte de condition. La
    # valeur, elle, est écrite sur stdout dans les deux cas, et l'affectation a
    # lieu quel que soit le code : elle est conservée telle quelle.
    local etat="" echoue="non"
    if ! etat="$(LC_ALL=C systemctl is-system-running 2>/dev/null)"; then
        echoue="oui"
    fi
    if [ -z "$etat" ] && [ "$echoue" = "oui" ]; then
        warn "« systemctl is-system-running » n'a rien répondu : état global non disponible."
    fi

    ligne "Mode" "inventaire — le code de retour est toujours 0"
    ligne "État global" "$etat"

    printf '\n'
    note "« État global » est la réponse de « systemctl is-system-running ». La" \
         "valeur « degraded » signifie qu'au moins une unité a échoué : c'est" \
         "banal, en conteneur notamment, et ce n'est pas une panne du" \
         "gestionnaire de services."
}

section_actifs() {
    titre "Services actifs"

    # « --full » empêche systemctl de tronquer les noms d'unité et les
    # descriptions ; « --no-pager » évite que la sortie parte dans un pagineur ;
    # « --no-legend » retire l'en-tête et le pied de tableau, qui seraient lus
    # comme des unités.
    local sortie=""
    if ! sortie="$(LC_ALL=C systemctl list-units --type=service --state=active \
            --no-pager --no-legend --full 2>/dev/null)"; then
        warn "« systemctl list-units --state=active » a échoué : liste des services actifs non disponible."
        ligne "Services actifs" ""
        return 0
    fi

    analyser_liste "$sortie"

    if [ "${#UNITES[@]}" -eq 0 ]; then
        # Constat, et non ignorance : systemctl a répondu, il ne liste rien.
        ligne "Services actifs" "aucun — systemd ne liste aucun service actif"
        return 0
    fi

    ligne "Services actifs" "${#UNITES[@]}"
    printf '\n'
    entete_unites
    afficher_lignes
}

section_echec() {
    titre "Services en échec"

    local sortie=""
    if ! sortie="$(LC_ALL=C systemctl list-units --type=service --state=failed \
            --no-pager --no-legend --full 2>/dev/null)"; then
        warn "« systemctl list-units --state=failed » a échoué : liste des services en échec non disponible."
        ligne "Services en échec" ""
        return 0
    fi

    analyser_liste "$sortie"

    if [ "${#UNITES[@]}" -eq 0 ]; then
        ligne "Services en échec" "aucun"
    else
        ligne "Services en échec" "${#UNITES[@]}"
        printf '\n'
        entete_unites
        afficher_lignes
    fi

    printf '\n'
    note "Cette liste n'est PAS un état de santé complet du serveur :" \
         "« systemctl list-units --state=failed » ne montre que les unités" \
         "CHARGÉES dont l'exécution a échoué. Une unité masquée, désactivée ou" \
         "qui n'a jamais démarré n'y figure pas."

    # Les avertissements sont émis APRÈS le tableau et la note, et non pendant :
    # ils partent sur stderr quand le tableau part sur stdout, et s'y
    # intercaleraient. C'est ce qui met la liste en évidence sans la disperser.
    local unite
    for unite in "${UNITES[@]}"; do
        warn "Service en échec : $unite — la cause se lit dans « systemctl status $unite »."
    done
}

# -------------------------------------------------------------------
# Mode --service
# -------------------------------------------------------------------
# Ce mode répond à une question fermée : ce service tourne-t-il ? Le code de
# retour porte la réponse — 0 actif, 1 sinon —, et les six façons de ne pas être
# actif — inconnu, masqué, non chargé, en échec, inactif, état inétablissable —
# se distinguent PAR LE MESSAGE, jamais par le code : un appelant qui teste le
# code veut savoir si le service tourne, pas pourquoi il ne tourne pas.
#
# La lecture de LoadState PRÉCÈDE celle d'ActiveState, et l'ordre n'est pas
# indifférent : une unité inconnue comme une unité masquée annoncent toutes deux
# « ActiveState=inactive », état qu'elles partagent avec un service simplement
# arrêté. Les confondre reviendrait à conseiller « systemctl start » pour une
# unité qui n'existe pas.
mode_service() {
    titre "Vérification d'un service"

    if ! lire_etat_unite "$UNITE"; then
        ligne "Unité" "$UNITE"
        ligne "État" ""
        error "L'état de « $UNITE » n'a pas pu être établi : « systemctl show » n'a rien rendu d'exploitable."
        error "Nom d'unité refusé par systemd, ou systemd n'est pas le gestionnaire de services de cette machine."
        error "« systemctl is-system-running » répond à la seconde question."
        exit 1
    fi

    local execution="$ACTIVE_STATE"
    if [ -n "$execution" ] && [ -n "$SUB_STATE" ]; then
        execution="$execution ($SUB_STATE)"
    fi

    # UNE UNITÉ INCONNUE N'A PAS D'ÉTAT D'EXÉCUTION. « systemctl show » rapporte
    # pourtant « inactive (dead) » pour un nom qu'il ne connaît pas : afficher
    # cette valeur telle quelle se lirait « le service existe, il est arrêté » —
    # l'inverse de ce que dit le [ERROR] émis quelques lignes plus bas. La valeur
    # est donc effacée, et la ligne affiche « non disponible », comme le font déjà
    # « État d'activation » et « Dernier démarrage » pour la même unité.
    #
    # LE CAS « masked » N'EST PAS TRAITÉ DE MÊME, bien que systemctl y rapporte
    # lui aussi « inactive (dead) » : l'unité, elle, EXISTE — systemd la connaît,
    # son fichier est lié à /dev/null —, et dire qu'elle n'est pas en cours
    # d'exécution est exact. Sa ligne « État d'activation » affiche « masked »,
    # qui dit en outre pourquoi elle ne tourne pas. Effacer l'état d'exécution y
    # ferait perdre une information vraie ; ne l'effacer que pour « not-found »
    # n'en fait perdre aucune, puisqu'il n'y en avait pas.
    if [ "$LOAD_STATE" = "not-found" ]; then
        execution=""
    fi

    ligne "Unité" "$UNITE"
    ligne "Chargement" "$LOAD_STATE"
    ligne "État d'activation" "$UNIT_FILE_STATE"
    ligne "État d'exécution" "$execution"
    ligne "Dernier démarrage" "$DERNIER_DEMARRAGE"

    printf '\n'
    note "« État d'activation » dit ce que le service fait AU DÉMARRAGE de la" \
         "machine — enabled, disabled, static, masked — et « état d'exécution »" \
         "ce qu'il fait MAINTENANT. Les deux sont indépendants : un service" \
         "« disabled » peut tourner, un service « enabled » peut être arrêté." \
         "Un service qui n'a pas démarré depuis l'amorçage n'a pas de date de" \
         "dernier démarrage — la ligne affiche alors « non disponible »."
    printf '\n'

    case "$LOAD_STATE" in
        not-found)
            error "Service inconnu : « $UNITE » — systemd ne connaît aucune unité de ce nom."
            error "Vérifier l'orthographe, ou lister les services installés :"
            error "  systemctl list-unit-files --type=service"
            exit 1
            ;;
        masked)
            error "Service masqué : « $UNITE » — son unité est liée à /dev/null."
            error "Un service masqué ne peut démarrer ni à la main, ni par dépendance."
            error "Le démasquer demande root : systemctl unmask $UNITE"
            exit 1
            ;;
        loaded)
            ;;
        *)
            error "Unité non chargée : « $UNITE » — LoadState vaut « $LOAD_STATE »."
            error "L'unité existe peut-être, mais systemd n'a pas pu la charger."
            error "« systemctl status $UNITE » en dit la raison."
            exit 1
            ;;
    esac

    case "$ACTIVE_STATE" in
        active)
            success "Service actif : « $UNITE » (sous-état « ${SUB_STATE:-inconnu} »)."
            exit 0
            ;;
        failed)
            error "Service en échec : « $UNITE » (sous-état « ${SUB_STATE:-inconnu} »)."
            error "La cause se lit dans « systemctl status $UNITE » et « journalctl -u $UNITE »."
            exit 1
            ;;
        *)
            error "Service inactif : « $UNITE » n'est pas actif (état « ${ACTIVE_STATE:-inconnu} », sous-état « ${SUB_STATE:-inconnu} »)."
            error "Le démarrer demande root : systemctl start $UNITE"
            exit 1
            ;;
    esac
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
if [ -n "$SERVICE" ]; then
    # mode_service sort toujours lui-même : la ligne qui suit n'est pas atteinte.
    mode_service
fi

section_parametres
section_actifs
section_echec
printf '\n'

# Un service en échec ne change pas le code de retour de l'inventaire : ce mode
# est une lecture, pas un verdict. Le rendre non nul ferait échouer chaque
# passage en tâche planifiée sur un serveur qui porte une unité en échec — état
# banal —, et la production de statuts est le rôle du futur security-check.sh.
exit 0
