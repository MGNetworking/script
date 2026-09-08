#!/usr/bin/env bash
# check-memory.sh — diagnostic mémoire, en lecture seule.
#
# Trois sections : mémoire vive, fichier d'échange, processus les plus
# consommateurs.
#
# N'écrit rien, ne modifie rien, ne nécessite aucun privilège. Une information
# manquante devient « non disponible » : le script rend 0 quoi qu'il constate.
# Usage : ./check-memory.sh [--seuil N] [--top N] [--help]

set -Eeuo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$_dir/lib/common.sh" ] && [ "$_dir" != "/" ]; do _dir="$(dirname "$_dir")"; done
source "$_dir/lib/common.sh"

# -------------------------------------------------------------------
# Valeurs par défaut et origine des valeurs
# -------------------------------------------------------------------
# Trois niveaux, du plus faible au plus fort : la valeur écrite ici,
# config/server.env, la ligne de commande. L'origine est conservée pour être
# affichée et pour nommer le fautif dans un diagnostic de valeur invalide.
#
# POURQUOI 90 %, ET POURQUOI PAS LES 85 % DE check-disk.sh. Le seuil ne porte
# pas sur la même grandeur, et la mémoire ne se dégrade pas comme un disque.
#
#   - il porte sur la part NON DISPONIBLE de la mémoire — (MemTotal -
#     MemAvailable) / MemTotal —, jamais sur l'occupation apparente. Linux
#     emploie toute mémoire inemployée en cache et en tampons, qu'il rend dès
#     qu'un programme en demande : une machine parfaitement saine affiche
#     couramment 95 % d'occupation apparente et une mémoire libre proche de
#     zéro. Un seuil posé là-dessus crierait au loup à chaque exécution ;
#   - la mémoire ne prévient pas. Un disque qui se remplit ralentit et laisse le
#     temps de voir venir ; une mémoire qui manque déclenche le tueur de mémoire
#     du noyau, qui abat un processus sans préavis. Ce qui est mesuré ici est
#     donc une MARGE — de quoi absorber le prochain pic —, pas une tendance ;
#   - 10 % de marge reste une marge utile : 6,4 Go sur un hôte de 64 Go, 200 Mo
#     sur une machine de 2 Go. Sur les petites machines, la marge en valeur
#     absolue devient mince — c'est précisément pour cela que le seuil est
#     réglable, et 80 % y donne plus de temps de réaction ;
#   - plus bas, le signal deviendrait du bruit, pour la même raison que sur le
#     disque : un serveur qui travaille garde peu de mémoire disponible, et une
#     alerte qui se déclenche à chaque passage n'est plus lue au bout de trois
#     fois.
#
# La comparaison est « atteint » — supérieur ou égal —, comme dans
# check-disk.sh : deux scripts jumeaux ne peuvent pas comparer différemment.
SEUIL_DEFAUT="90"
SEUIL="$SEUIL_DEFAUT"
ORIGINE_SEUIL="valeur par défaut"
if [ -n "${SRV_MEM_SEUIL:-}" ]; then
    SEUIL="$SRV_MEM_SEUIL"
    ORIGINE_SEUIL="config/server.env"
fi

# Nombre de processus affichés. Contrairement au --top de check-disk.sh, qui
# n'est qu'un confort d'affichage, celui-ci se surcharge aussi par
# config/server.env : le classement des processus est la section qu'on relit le
# plus souvent, et le nombre d'entrées utile dépend de la machine — dix lignes
# sur un serveur applicatif, trois sur un VPS qui n'héberge qu'un service.
TOP_DEFAUT="10"
TOP="$TOP_DEFAUT"
ORIGINE_TOP="valeur par défaut"
if [ -n "${SRV_MEM_TOP:-}" ]; then
    TOP="$SRV_MEM_TOP"
    ORIGINE_TOP="config/server.env"
fi

# -------------------------------------------------------------------
# Aide
# -------------------------------------------------------------------
show_help() {
    cat <<'AIDE'
Usage : check-memory.sh [options]

Diagnostic mémoire, en trois sections : mémoire vive, fichier d'échange,
processus les plus consommateurs.

Script en lecture seule : aucune modification, aucun privilège requis. Une
commande absente ou en échec produit un avertissement et « non disponible »,
jamais un arrêt. Un seuil dépassé ne change pas non plus le code de retour :
ce script constate, il ne juge pas.

Options :
      --seuil <1-100>   Seuil d'alerte, en pourcentage de mémoire NON
                        DISPONIBLE — (totale - disponible) / totale. Un
                        dépassement est signalé par un [WARN].
                        Défaut : 90, ou SRV_MEM_SEUIL de config/server.env.
      --top <1-100>     Nombre de processus affichés, triés sur la mémoire
                        résidente décroissante.
                        Défaut : 10, ou SRV_MEM_TOP de config/server.env.
  -h, --help            Afficher cette aide

La ligne de commande prime sur config/server.env, qui prime sur les valeurs
par défaut écrites dans le script. L'origine de chaque valeur est rappelée en
tête de la sortie.

Le seuil porte sur la mémoire DISPONIBLE, jamais sur la mémoire LIBRE : Linux
emploie toute mémoire inemployée en cache, qu'il rend à la demande, si bien
qu'un serveur sain affiche presque toujours une mémoire libre proche de zéro.

Un fichier d'échange absent n'est pas une anomalie, et un fichier d'échange
utilisé non plus. Seule la conjonction — échange occupé à hauteur du seuil
ALORS QUE la mémoire l'atteint aussi — vaut un [WARN] : il n'y a alors plus de
réserve nulle part.

Sources lues, dans cet ordre : « free » ; à défaut /proc/meminfo, et le script
le dit. Le classement des processus vient de « ps » (paquet procps).

Codes de retour :
  0  diagnostic produit — y compris lorsqu'un seuil est dépassé, qu'une
     information manque ou qu'une valeur de config/server.env est refusée
  2  erreur d'usage sur la LIGNE DE COMMANDE : option inconnue, valeur de
     --seuil ou de --top invalide

Une valeur fautive venue de config/server.env ne rend jamais 2 : la ligne de
commande étant juste, elle vaut un [WARN] nommant la variable, la valeur
refusée et le repli sur la valeur par défaut.

Aucun échec d'exécution (code 1) n'est prévu : ce script n'exige aucune
dépendance et ne modifie rien.
AIDE
}

# -------------------------------------------------------------------
# Arguments
# -------------------------------------------------------------------
while [ "${1:-}" != "" ]; do
    case "$1" in
        --seuil)
            shift
            [ -n "${1:-}" ] || die "--seuil attend un entier de 1 à 100." 2
            SEUIL="$1"; ORIGINE_SEUIL="ligne de commande"; shift ;;
        --top)
            shift
            [ -n "${1:-}" ] || die "--top attend un entier de 1 à 100." 2
            TOP="$1"; ORIGINE_TOP="ligne de commande"; shift ;;
        -h|--help)  show_help; exit 0 ;;
        *)          die "Option inconnue : $1" 2 ;;
    esac
done

# -------------------------------------------------------------------
# Préflight
# -------------------------------------------------------------------
# Ni privilège, ni distribution, ni dépendance à exiger : ce script lit ce qu'il
# trouve et dégrade le reste. Le préflight se réduit donc à la validation des
# valeurs, faite avant toute lecture pour qu'une ligne de commande fautive soit
# reprochée avant qu'un seul chiffre ne soit affiché.
#
# UNE SEULE RÈGLE, POUR TOUTES LES VALEURS — celle de check-disk.sh. Le
# traitement d'une valeur fautive dépend de son ORIGINE, jamais de la valeur
# elle-même, et c'est la convention des codes de retour du dépôt qui le dicte :
# le 2 reproche quelque chose à l'appelant.
#
#   - tapée sur la ligne de commande, elle vaut un refus en 2. L'appelant s'est
#     trompé en tapant, et le reproche lui est utile ;
#   - héritée de config/server.env, elle ne reproche rien à la commande tapée.
#     Un diagnostic en lecture seule doit diagnostiquer : priver l'appelant de
#     tout son état mémoire parce qu'une variable qu'il n'a peut-être pas écrite
#     lui-même est mal saisie serait disproportionné. Elle vaut donc un [WARN]
#     qui nomme la variable, la valeur refusée et ce qui est retenu à la place,
#     puis le diagnostic se poursuit.
#
# Les deux valeurs de ce script ont une valeur par défaut utilisable, et le
# repli est donc le même pour les deux — contrairement à check-disk.sh, dont le
# répertoire analysé n'en avait pas.

# Entier de 1 à 100, sans zéro initial. Les deux « case » distinguent les deux
# reproches — pas un entier, hors bornes — et n'utilisent aucune arithmétique :
# « 010 » y serait lu en octal, et une valeur de trente chiffres déborderait.
#
# La fonction NE MEURT PAS : elle rend 1 et renseigne le motif du refus. C'est
# à l'appelante de trancher entre le refus et le repli, selon l'origine de la
# valeur — un « die » posé ici lui ôterait ce choix.
MOTIF_INVALIDE=""
PRECISION_INVALIDE=""
valider_entier() {
    local valeur="$1"

    MOTIF_INVALIDE=""
    PRECISION_INVALIDE=""
    case "$valeur" in
        ''|*[!0-9]*)
            MOTIF_INVALIDE="n'est pas un entier"
            return 1 ;;
    esac
    case "$valeur" in
        [1-9]|[1-9][0-9]|100) return 0 ;;
    esac
    MOTIF_INVALIDE="est hors bornes"
    PRECISION_INVALIDE=" — attendu un entier de 1 à 100, sans zéro initial"
    return 1
}

if ! valider_entier "$SEUIL"; then
    if [ "$ORIGINE_SEUIL" = "ligne de commande" ]; then
        die "--seuil : « $SEUIL » $MOTIF_INVALIDE ($ORIGINE_SEUIL)$PRECISION_INVALIDE." 2
    fi
    warn "« $SEUIL » ($ORIGINE_SEUIL, SRV_MEM_SEUIL) $MOTIF_INVALIDE$PRECISION_INVALIDE :"
    warn "repli sur le seuil par défaut, $SEUIL_DEFAUT %."
    SEUIL="$SEUIL_DEFAUT"
    ORIGINE_SEUIL="valeur par défaut, SRV_MEM_SEUIL refusé"
fi

if ! valider_entier "$TOP"; then
    if [ "$ORIGINE_TOP" = "ligne de commande" ]; then
        die "--top : « $TOP » $MOTIF_INVALIDE ($ORIGINE_TOP)$PRECISION_INVALIDE." 2
    fi
    warn "« $TOP » ($ORIGINE_TOP, SRV_MEM_TOP) $MOTIF_INVALIDE$PRECISION_INVALIDE :"
    warn "repli sur la valeur par défaut, $TOP_DEFAUT processus."
    TOP="$TOP_DEFAUT"
    ORIGINE_TOP="valeur par défaut, SRV_MEM_TOP refusé"
fi

# -------------------------------------------------------------------
# Présentation
# -------------------------------------------------------------------
# Les trois premières fonctions sont celles de check-disk.sh et de
# system-info.sh, à l'identique : même titre, même ligne « libellé : valeur »,
# même cellule. Deux scripts jumeaux se lisent de la même façon.

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
# du tableau qui le précède.
note() {
    local texte
    for texte in "$@"; do
        printf '  %s\n' "$texte"
    done
}

# -------------------------------------------------------------------
# Outils de calcul
# -------------------------------------------------------------------
# Tout est calculé en Bash, sans « awk » ni « bc » : les grandeurs manipulées
# sont des entiers de kibioctets, et l'arithmétique de Bash les traite sur
# 64 bits — un pébioctet tient sans déborder. Une commande externe de moins est
# une cause d'échec de moins.

# Vrai si la valeur est une suite de chiffres. Tout ce qui vient de « free », de
# /proc/meminfo ou de « ps » passe par ici avant la moindre arithmétique : sous
# « set -u », un $(( )) sur une chaîne non numérique arrête le script.
est_entier() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Kibioctets vers une grandeur lisible. Renseigne FORMATE, vide si l'entrée
# n'est pas un entier — « ligne » affichera alors « non disponible ».
#
# Multiples binaires, comme « free -h » et « df -h » : 1 Go = 1024 Mo.
FORMATE=""
formater_ko() {
    local ko="${1:-}"

    FORMATE=""
    est_entier "$ko" || return 0

    if [ "$ko" -ge 1048576 ]; then
        FORMATE="$(( ko / 1048576 )),$(( ko % 1048576 * 10 / 1048576 )) Go"
    elif [ "$ko" -ge 1024 ]; then
        FORMATE="$(( ko / 1024 )),$(( ko % 1024 * 10 / 1024 )) Mo"
    else
        FORMATE="$ko Ko"
    fi
    return 0
}

# Part de <valeur> dans <total>, en pourcentage entier arrondi. Renseigne
# POURCENTAGE, vide si le calcul n'est pas possible.
POURCENTAGE=""
pourcentage_de() {
    local valeur="${1:-}" total="${2:-}"

    POURCENTAGE=""
    est_entier "$valeur" || return 0
    est_entier "$total"  || return 0
    [ "$total" -gt 0 ]   || return 0

    POURCENTAGE=$(( ( valeur * 100 + total / 2 ) / total ))
    return 0
}

# -------------------------------------------------------------------
# Lecture des mesures
# -------------------------------------------------------------------
# Toutes les grandeurs sont en kibioctets, comme les sources qui les fournissent.
# La chaîne vide vaut « non lu » ; elle n'est jamais confondue avec un zéro, qui
# est un constat.
MEM_TOTAL_KO=""
MEM_UTILISE_KO=""
MEM_LIBRE_KO=""
MEM_CACHE_KO=""
MEM_DISPO_KO=""

# SWAP_LU sépare l'IGNORANCE du CONSTAT, comme le fait check-disk.sh pour
# /proc/partitions : « non » signifie que rien n'a pu être lu — « non
# disponible » —, tandis qu'un SWAP_TOTAL_KO à zéro après une lecture réussie
# est l'état parfaitement normal « aucune zone d'échange active ». Les faire
# aboutir au même message reviendrait à affirmer une absence qu'on n'a pas
# établie.
SWAP_LU="non"
SWAP_TOTAL_KO=""
SWAP_UTILISE_KO=""
SWAP_LIBRE_KO=""

SOURCE_MEMOIRE=""

# Lecture par « free », source de premier rang.
#
# LC_ALL=C n'est pas un ornement : les étiquettes de « free » sont traduites, et
# la version française écrit « Mém. : » — deux champs au lieu d'un, qui décalent
# toute la ligne. Sous C, les étiquettes sont « Mem: » et « Swap: ».
#
# L'affectation est en contexte de condition (TASK-018) : sous la forme nue, un
# « free » en échec ferait parler deux fois le trap ERR de lib/common.sh sans
# nommer la cause, puis arrêterait le script.
lire_par_free() {
    local sortie=""
    if ! sortie="$(LC_ALL=C free -k 2>/dev/null)"; then
        warn "« free » a échoué : lecture de la mémoire par cette voie impossible."
        return 1
    fi
    if [ -z "$sortie" ]; then
        warn "« free » n'a rien écrit : lecture de la mémoire par cette voie impossible."
        return 1
    fi

    local enregistrement etiquette total utilise libre partage cache dispo
    local trouve="non"

    while IFS= read -r enregistrement; do
        [ -n "$enregistrement" ] || continue

        # Les colonnes de « free » varient selon les versions : les champs sont
        # lus par position sur les lignes « Mem: » et « Swap: », et l'en-tête est
        # écarté de lui-même, aucune étiquette ne lui correspondant.
        read -r etiquette total utilise libre partage cache dispo <<< "$enregistrement"

        case "$etiquette" in
            Mem*)
                est_entier "$total" || continue
                [ "$total" -gt 0 ]  || continue
                trouve="oui"
                MEM_TOTAL_KO="$total"
                if est_entier "$utilise"; then MEM_UTILISE_KO="$utilise"; fi
                if est_entier "$libre";   then MEM_LIBRE_KO="$libre";     fi
                if est_entier "$cache";   then MEM_CACHE_KO="$cache";     fi
                # La colonne « available » n'existe que depuis procps-ng 3.3.10.
                # Absente, elle laisse MEM_DISPO_KO vide : le seuil ne sera pas
                # comparé, et la section le dira.
                if est_entier "$dispo";   then MEM_DISPO_KO="$dispo";     fi
                ;;
            Swap*)
                est_entier "$total" || continue
                SWAP_LU="oui"
                SWAP_TOTAL_KO="$total"
                if est_entier "$utilise"; then SWAP_UTILISE_KO="$utilise"; fi
                if est_entier "$libre";   then SWAP_LIBRE_KO="$libre";     fi
                ;;
        esac
    done <<< "$sortie"

    if [ "$trouve" != "oui" ]; then
        warn "« free » n'a produit aucune ligne « Mem: » exploitable."
        return 1
    fi
    return 0
}

# Lecture par /proc/meminfo, branche de repli.
#
# Elle n'appelle AUCUNE commande externe — la lecture est une redirection Bash,
# l'analyse un « case » — contrairement à celle de system-info.sh, que deux
# « awk » exposaient à un homonyme placé en tête de PATH. Elle reste malgré tout
# en contexte de condition : l'échec d'une redirection dans une substitution
# ferait parler le trap ERR tout autant.
#
# Conséquence pour qui voudra l'éprouver : cette branche ne s'atteint qu'en
# rendant « free » INTROUVABLE. Le mettre en échec ne suffit pas — « command -v
# free » réussirait encore — ; il faut un PATH reconstruit sans lui, en bac à
# sable de liens symboliques. Le montage est décrit dans tests/README.md.
lire_par_meminfo() {
    if [ ! -r /proc/meminfo ]; then
        warn "/proc/meminfo est illisible : mesures de la mémoire non disponibles."
        return 1
    fi

    local contenu=""
    if ! contenu="$(< /proc/meminfo)"; then
        warn "/proc/meminfo n'a pas pu être lu : mesures de la mémoire non disponibles."
        return 1
    fi

    local enregistrement cle valeur
    local tampons="" cache="" reclamable="" partage="" swap_libre=""

    while IFS= read -r enregistrement; do
        [ -n "$enregistrement" ] || continue
        # Le troisième champ est l'unité affichée par /proc/meminfo — « kB »,
        # quelle que soit l'architecture. Elle n'est pas lue : les valeurs sont
        # en kibioctets, et le nommer donnerait à croire qu'on en tient compte.
        read -r cle valeur _ <<< "$enregistrement"
        est_entier "$valeur" || continue

        # Les valeurs de /proc/meminfo sont en kibioctets, quoi qu'en dise leur
        # unité affichée (« kB »).
        case "$cle" in
            MemTotal:)     MEM_TOTAL_KO="$valeur" ;;
            MemFree:)      MEM_LIBRE_KO="$valeur" ;;
            MemAvailable:) MEM_DISPO_KO="$valeur" ;;
            Buffers:)      tampons="$valeur" ;;
            Cached:)       cache="$valeur" ;;
            SReclaimable:) reclamable="$valeur" ;;
            Shmem:)        partage="$valeur" ;;
            SwapTotal:)    SWAP_LU="oui"; SWAP_TOTAL_KO="$valeur" ;;
            SwapFree:)     swap_libre="$valeur" ;;
        esac
    done <<< "$contenu"

    if ! est_entier "$MEM_TOTAL_KO" || [ "$MEM_TOTAL_KO" -le 0 ]; then
        warn "MemTotal absent ou illisible dans /proc/meminfo : mesures non disponibles."
        return 1
    fi

    # « Tampons et cache » et « utilisée » suivent la définition de procps-ng
    # depuis la 3.3.10, afin que les deux sources donnent les mêmes chiffres :
    #   cache    = Cached + SReclaimable
    #   utilisée = MemTotal - MemFree - Buffers - cache
    # La mémoire partagée (Shmem) est comprise dans Cached ; elle n'est pas
    # retranchée ici, faute de colonne pour l'afficher à part.
    if est_entier "$cache" && est_entier "$reclamable" && est_entier "$tampons"; then
        MEM_CACHE_KO=$(( tampons + cache + reclamable ))
        if est_entier "$MEM_LIBRE_KO"; then
            MEM_UTILISE_KO=$(( MEM_TOTAL_KO - MEM_LIBRE_KO - MEM_CACHE_KO ))
            if [ "$MEM_UTILISE_KO" -lt 0 ]; then
                MEM_UTILISE_KO=""
            fi
        fi
    fi
    # « partage » n'est lu que pour mémoire : il documente ce que Cached
    # recouvre. Le référencer ici évite qu'il passe pour une lecture morte.
    if [ -n "$partage" ] && [ -z "$MEM_CACHE_KO" ]; then
        MEM_CACHE_KO=""
    fi

    if est_entier "$SWAP_TOTAL_KO" && est_entier "$swap_libre"; then
        SWAP_LIBRE_KO="$swap_libre"
        SWAP_UTILISE_KO=$(( SWAP_TOTAL_KO - swap_libre ))
        if [ "$SWAP_UTILISE_KO" -lt 0 ]; then
            SWAP_UTILISE_KO=""
        fi
    fi
    return 0
}

# Choix de la source, une fois pour tout le script : les trois sections lisent
# ensuite les mêmes variables globales.
lire_memoire() {
    if command -v free >/dev/null 2>&1; then
        if lire_par_free; then
            SOURCE_MEMOIRE="free"
            return 0
        fi
        warn "Repli sur /proc/meminfo."
        if lire_par_meminfo; then
            SOURCE_MEMOIRE="/proc/meminfo (repli, « free » a échoué)"
            return 0
        fi
        SOURCE_MEMOIRE=""
        return 0
    fi

    info "« free » est introuvable (paquet procps) : lecture de /proc/meminfo."
    if lire_par_meminfo; then
        SOURCE_MEMOIRE="/proc/meminfo (« free » est absent)"
        return 0
    fi
    SOURCE_MEMOIRE=""
    return 0
}

# -------------------------------------------------------------------
# Sections
# -------------------------------------------------------------------

# Part de la mémoire non disponible, sur laquelle porte le seuil. Vide tant
# qu'elle n'a pas pu être calculée — c'est le cas d'un « free » sans colonne
# « available ».
OCCUPATION=""

section_parametres() {
    titre "Diagnostic mémoire"
    ligne "Seuil d'alerte" "$SEUIL % de mémoire non disponible ($ORIGINE_SEUIL)"
    ligne "Processus affichés" "$TOP ($ORIGINE_TOP)"
    ligne "Source des mesures" "$SOURCE_MEMOIRE"
}

section_memoire() {
    titre "Mémoire vive"

    if [ -z "$SOURCE_MEMOIRE" ]; then
        # Ignorance, et non constat : aucune source n'a répondu. Les
        # avertissements qui le disent ont déjà été émis par la lecture.
        ligne "Mémoire" ""
        return 0
    fi

    formater_ko "$MEM_TOTAL_KO";   local total="$FORMATE"
    formater_ko "$MEM_UTILISE_KO"; local utilise="$FORMATE"
    formater_ko "$MEM_LIBRE_KO";   local libre="$FORMATE"
    formater_ko "$MEM_CACHE_KO";   local cache="$FORMATE"
    formater_ko "$MEM_DISPO_KO";   local dispo="$FORMATE"

    pourcentage_de "$MEM_UTILISE_KO" "$MEM_TOTAL_KO"
    if [ -n "$POURCENTAGE" ] && [ -n "$utilise" ]; then
        utilise="$utilise ($POURCENTAGE % du total)"
    fi
    pourcentage_de "$MEM_DISPO_KO" "$MEM_TOTAL_KO"
    if [ -n "$POURCENTAGE" ] && [ -n "$dispo" ]; then
        dispo="$dispo ($POURCENTAGE % du total)"
        OCCUPATION=$(( 100 - POURCENTAGE ))
    fi

    ligne "Totale" "$total"
    ligne "Utilisée" "$utilise"
    ligne "Libre" "$libre"
    ligne "Tampons et cache" "$cache"
    ligne "Disponible" "$dispo"

    if [ -n "$OCCUPATION" ]; then
        ligne "Non disponible" "$OCCUPATION % — grandeur comparée au seuil"
    else
        ligne "Non disponible" ""
    fi

    printf '\n'
    note "« Libre » exclut les tampons et le cache, que le noyau rend dès qu'un" \
         "programme réclame de la mémoire : sur un serveur sain, cette valeur est" \
         "presque toujours proche de zéro, et ce n'est pas un manque." \
         "« Disponible » est la grandeur qui compte — ce qu'un programme peut" \
         "obtenir sans que la machine ait à paginer. Le seuil porte sur elle."

    if [ -z "$OCCUPATION" ]; then
        warn "Mémoire disponible inconnue : le seuil de $SEUIL % n'a pas pu être comparé."
        warn "La colonne « available » de « free » n'existe que depuis procps-ng 3.3.10, et MemAvailable que depuis Linux 3.14."
        return 0
    fi

    # L'avertissement est émis après le tableau, et non pendant : il part sur
    # stderr quand le tableau part sur stdout, et s'y intercalerait.
    if [ "$OCCUPATION" -ge "$SEUIL" ]; then
        warn "Seuil de $SEUIL % atteint — $OCCUPATION % de la mémoire est non disponible (reste ${dispo:-non disponible})."
    fi
}

# Zones d'échange actives, telles que /proc/swaps les liste. Affichées en
# complément des totaux : elles disent où est le swap — fichier ou partition —
# ce que les totaux ne disent pas.
zones_echange() {
    local contenu=""
    if [ ! -r /proc/swaps ]; then
        warn "/proc/swaps est illisible : zones d'échange non disponibles."
        ligne "Zones actives" ""
        return 0
    fi
    if ! contenu="$(< /proc/swaps)"; then
        warn "/proc/swaps n'a pas pu être lu : zones d'échange non disponibles."
        ligne "Zones actives" ""
        return 0
    fi

    local enregistrement nom type taille utilise priorite
    local premiere="oui" affichees=0
    local lignes=()

    while IFS= read -r enregistrement; do
        # La première ligne est l'en-tête de /proc/swaps ; elle est écartée par
        # sa position, comme celle de « df » dans check-disk.sh.
        if [ "$premiere" = "oui" ]; then
            premiere="non"
            continue
        fi
        [ -n "$enregistrement" ] || continue

        read -r nom type taille utilise priorite <<< "$enregistrement"
        [ -n "$nom" ] || continue
        affichees=$(( affichees + 1 ))

        formater_ko "$taille";  local taille_lisible="$FORMATE"
        formater_ko "$utilise"; local utilise_lisible="$FORMATE"

        lignes+=("$(printf '  %s%s%s%s%s' \
            "$(cellule "$nom" 30 gauche)" \
            "$(cellule "$type" 12 gauche)" \
            "$(cellule "${taille_lisible:-?}" 11 droite)" \
            "$(cellule "${utilise_lisible:-?}" 11 droite)" \
            "$(cellule "${priorite:-?}" 6 droite)")")
    done <<< "$contenu"

    if [ "$affichees" -eq 0 ]; then
        # Constat, non ignorance : le fichier a été lu, il ne liste rien. Le cas
        # se rencontre dans un conteneur, où « free » décrit l'hôte tandis que
        # /proc/swaps ne montre que ce qui est monté pour le conteneur.
        ligne "Zones actives" "aucune — /proc/swaps ne liste aucune zone"
        return 0
    fi

    printf '\n'
    printf '  %s%s%s%s%s\n' \
        "$(cellule "Zone active" 30 gauche)" \
        "$(cellule "Type" 12 gauche)" \
        "$(cellule "Taille" 11 droite)" \
        "$(cellule "Utilisé" 11 droite)" \
        "$(cellule "Prio." 6 droite)"

    local sortie
    for sortie in "${lignes[@]}"; do
        printf '%s\n' "$sortie"
    done
}

section_swap() {
    titre "Fichier d'échange"

    if [ "$SWAP_LU" != "oui" ]; then
        warn "L'état du fichier d'échange n'a pas pu être lu : aucune source exploitable."
        ligne "État" ""
        return 0
    fi

    if [ "$SWAP_TOTAL_KO" = "0" ]; then
        ligne "État" "aucune zone d'échange active"
        printf '\n'
        note "Ce n'est pas une anomalie : beaucoup de VPS et tous les conteneurs" \
             "tournent sans fichier d'échange. Linux/System/configure-swap.sh en" \
             "crée un si la machine en a besoin."
        return 0
    fi

    formater_ko "$SWAP_TOTAL_KO";   local total="$FORMATE"
    formater_ko "$SWAP_UTILISE_KO"; local utilise="$FORMATE"
    formater_ko "$SWAP_LIBRE_KO";   local libre="$FORMATE"

    local occupation_swap=""
    pourcentage_de "$SWAP_UTILISE_KO" "$SWAP_TOTAL_KO"
    if [ -n "$POURCENTAGE" ]; then
        occupation_swap="$POURCENTAGE"
        if [ -n "$utilise" ]; then
            utilise="$utilise ($POURCENTAGE % du total)"
        fi
    fi

    ligne "Total" "$total"
    ligne "Utilisé" "$utilise"
    ligne "Libre" "$libre"

    zones_echange

    printf '\n'
    note "Un fichier d'échange utilisé n'est pas une anomalie : le noyau y déplace" \
         "des pages inactives même quand la mémoire est ample, et ne les rapatrie" \
         "pas tant que personne ne les lit. C'est la CONJONCTION qui alarme — un" \
         "échange qui se remplit alors que la mémoire est saturée."

    # LA RÈGLE DU SWAP, ET POURQUOI IL N'A PAS SON PROPRE SEUIL. Un seul seuil
    # est réglable, et il s'applique aux deux grandeurs ; l'avertissement n'est
    # émis qu'à leur conjonction. Un échange occupé seul ne dit rien de
    # mauvais — c'est le fonctionnement normal du noyau — et un échange absent
    # non plus. Les deux ensemble, si : plus aucune réserve nulle part, et la
    # machine part en pagination continue puis en OOM. Un second seuil
    # configurable donnerait un réglage de plus pour une décision qui n'existe
    # pas séparément.
    if [ -n "$occupation_swap" ] && [ -n "$OCCUPATION" ] \
        && [ "$occupation_swap" -ge "$SEUIL" ] && [ "$OCCUPATION" -ge "$SEUIL" ]; then
        warn "Seuil de $SEUIL % atteint des deux côtés — échange occupé à $occupation_swap % alors que $OCCUPATION % de la mémoire est non disponible : il ne reste de réserve ni en mémoire, ni en échange."
    fi
}

section_processus() {
    titre "Processus les plus consommateurs"

    if ! command -v ps >/dev/null 2>&1; then
        warn "« ps » est introuvable (paquet procps) : processus consommateurs non disponibles."
        ligne "Processus" ""
        return 0
    fi

    # « comm » et non « args » : le nom de l'exécutable suffit au classement, et
    # la ligne de commande complète ferait entrer dans le journal du dépôt des
    # arguments qui n'ont rien à y faire — un jeton passé en argv, par exemple.
    #
    # « --sort=-rss » appartient à procps ; une autre implémentation de « ps »
    # rendra un code non nul, que la condition recueille.
    local sortie=""
    if ! sortie="$(LC_ALL=C ps -eo pid,user,rss,pmem,comm --sort=-rss 2>/dev/null)"; then
        warn "« ps » a échoué : processus consommateurs non disponibles."
        ligne "Processus" ""
        return 0
    fi
    if [ -z "$sortie" ]; then
        warn "« ps » n'a rien écrit : processus consommateurs non disponibles."
        ligne "Processus" ""
        return 0
    fi

    local enregistrement pid utilisateur rss pmem commande
    local premiere="oui" affichees=0
    local lignes=()

    while IFS= read -r enregistrement; do
        # En-tête écarté par sa position, jamais par son texte.
        if [ "$premiere" = "oui" ]; then
            premiere="non"
            continue
        fi
        [ -n "$enregistrement" ] || continue
        [ "$affichees" -lt "$TOP" ] || break

        read -r pid utilisateur rss pmem commande <<< "$enregistrement"
        [ -n "$commande" ] || continue
        affichees=$(( affichees + 1 ))

        # La colonne RSS de « ps » est en kibioctets.
        formater_ko "$rss"
        lignes+=("$(printf '  %s  %s%s%s  %s' \
            "$(cellule "$pid" 7 droite)" \
            "$(cellule "$utilisateur" 14 gauche)" \
            "$(cellule "${FORMATE:-?}" 11 droite)" \
            "$(cellule "$pmem %" 9 droite)" \
            "$commande")")
    done <<< "$sortie"

    if [ "$affichees" -eq 0 ]; then
        # Constat : « ps » a répondu, il n'a listé aucun processus.
        ligne "Processus" "aucun processus visible"
        return 0
    fi

    printf '  %s  %s%s%s  %s\n' \
        "$(cellule "PID" 7 droite)" \
        "$(cellule "Utilisateur" 14 gauche)" \
        "$(cellule "Mémoire" 11 droite)" \
        "$(cellule "% total" 9 droite)" \
        "Commande"

    local sortie_ligne
    for sortie_ligne in "${lignes[@]}"; do
        printf '%s\n' "$sortie_ligne"
    done

    printf '\n'
    note "La mémoire résidente (RSS) compte les pages partagées dans chaque" \
         "processus qui les emploie : additionner cette colonne donne un total" \
         "supérieur à la mémoire réellement occupée. Elle classe, elle n'additionne pas."
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
# La lecture précède l'affichage : les trois sections lisent les mêmes globales,
# et la source retenue est annoncée dès l'en-tête.
lire_memoire

section_parametres
section_memoire
section_swap
section_processus
printf '\n'

# Un seuil dépassé ne change pas le code de retour : ce script est une lecture,
# pas un verdict. Le rendre non nul ferait échouer chaque passage en tâche
# planifiée sur une machine simplement bien remplie — et une machine qui emploie
# sa mémoire fait exactement ce qu'on attend d'elle.
exit 0
