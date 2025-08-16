#!/bin/bash

# Plex Series Organizer - Compatible Synology DSM
# Usage: ./plex_series_organizer.sh "Nom de base" "S01" "/chemin/vers/dossier"

# Fichier de log
LOG_FILE="/volume1/development/scripts/logs/plex_series_organizer.log"

# Fonction pour ecrire dans le log
log_message() {
    echo "$(date '+%d/%m/%Y %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# Fonction d'aide
show_help() {
    echo "================================================"
    echo "PLEX SERIES ORGANIZER - AIDE"
    echo "================================================"
    echo ""
    echo "USAGE :"
    echo "  ./plex_series_organizer.sh \"Nom de base\" \"Saison\" \"/chemin/dossier\""
    echo ""
    echo "EXEMPLES :"
    echo "  ./plex_series_organizer.sh \"Yi Nian Yong Heng\" \"S01\" \"/volume3/Plex/media\""
    echo "  ./plex_series_organizer.sh \"One Piece\" \"S20\" \"/volume1/series/One_Piece\""
    echo ""
    echo "PARAMETRES :"
    echo "  1. Nom de base  : Le nom de la serie (entre guillemets)"
    echo "  2. Saison       : Format SXX (S01, S02, S03...)"
    echo "  3. Dossier      : Chemin complet vers le dossier a traiter"
    echo ""
    echo "RESULTAT :"
    echo "  Les fichiers seront renommes selon le format :"
    echo "  \"Nom de base SaisonEpisode.extension\""
    echo "  Exemple: \"Yi Nian Yong Heng S01E01.mkv\""
    echo "================================================"
}

# Fonction de validation des parametres
validate_parameters() {
    local errors=""
    
    # Verifier le nombre de parametres
    if [ $# -ne 3 ]; then
        echo "ERREUR : Nombre de parametres incorrect"
        show_help
        exit 1
    fi
    
    # Verifier le nom de base
    if [ -z "$1" ]; then
        errors="${errors}- Le nom de base ne peut pas etre vide\n"
    fi
    
    # Verifier le format de la saison
    if [ -z "$2" ]; then
        errors="${errors}- Le numero de saison ne peut pas etre vide\n"
    elif [[ ! "$2" =~ ^S[0-9]{2}$ ]]; then
        errors="${errors}- Le format de saison doit etre SXX (ex: S01)\n"
    fi
    
    # Verifier l'existence du dossier
    if [ -z "$3" ]; then
        errors="${errors}- Le dossier cible ne peut pas etre vide\n"
    elif [ ! -d "$3" ]; then
        errors="${errors}- Le dossier cible n'existe pas : $3\n"
    fi
    
    # Afficher les erreurs s'il y en a
    if [ -n "$errors" ]; then
        echo "ERREURS DETECTEES :"
        echo -e "$errors"
        echo ""
        show_help
        exit 1
    fi
    
    return 0
}

# Fonction d'affichage des parametres
show_parameters() {
    local file_count=$(find "$3" -maxdepth 1 -type f | wc -l)
    
    echo "================================================"
    echo "PARAMETRES DE TRAITEMENT"
    echo "================================================"
    echo "Nom de base : $1"
    echo "Saison : $2"
    echo "Dossier : $3"
    echo "Nombre de fichiers detectes : $file_count"
    echo "================================================"
    echo ""
}

# Fonction principale de renommage
process_files() {
    local nom_base="$1"
    local saison="$2"
    local dossier_cible="$3"
    local episode=1
    local processed=0
    local errors=0
    
    log_message "Debut du traitement des fichiers..."
    log_message "Parametres: '$nom_base' / '$saison' / '$dossier_cible'"
    
    # Creer un tableau temporaire pour trier les fichiers
    local temp_file="/tmp/files_to_process_$$.txt"
    find "$dossier_cible" -maxdepth 1 -type f | sort > "$temp_file"
    
    echo "Traitement en cours..."
    echo ""
    
    # Traiter les fichiers dans l'ordre alphabetique
    while IFS= read -r fichier; do
        if [ -f "$fichier" ]; then
            # Extraire l'extension et nom original
            extension="${fichier##*.}"
            nom_original=$(basename "$fichier")
            
            # Formater le numero d'episode sur 2 chiffres
            episode_format=$(printf "%02d" $episode)
            
            # Creer le nouveau nom
            nouveau_nom="${nom_base} ${saison}E${episode_format}.${extension}"
            nouveau_chemin="${dossier_cible}/${nouveau_nom}"
            
            # Verifier si le nouveau nom existe deja
            if [ -e "$nouveau_chemin" ] && [ "$fichier" != "$nouveau_chemin" ]; then
                log_message "ATTENTION : Le fichier $nouveau_nom existe deja - ignore"
                echo "ATTENTION : $nouveau_nom existe deja - ignore"
                ((errors++))
            else
                # Renommer le fichier
                if mv "$fichier" "$nouveau_chemin" 2>/dev/null; then
                    log_message "RENOMME : $nom_original -> $nouveau_nom"
                    echo "RENOMME : $nom_original -> $nouveau_nom"
                    ((processed++))
                    ((episode++))
                else
                    log_message "ERREUR lors du renommage : $nom_original"
                    echo "ERREUR : Impossible de renommer $nom_original"
                    ((errors++))
                fi
            fi
        fi
    done < "$temp_file"
    
    # Nettoyer le fichier temporaire
    rm -f "$temp_file"
    
    return $processed
}

# Fonction d'affichage du resultat final
show_results() {
    local processed=$1
    local errors=$2
    local start_time="$3"
    local end_time=$(date '+%d/%m/%Y a %H:%M:%S')
    
    echo ""
    echo "================================================"
    echo "RESULTAT DE L'EXECUTION"
    echo "================================================"
    
    if [ $errors -eq 0 ]; then
        echo "STATUT : SUCCES COMPLET"
    else
        echo "STATUT : TERMINE AVEC AVERTISSEMENTS"
    fi
    
    echo ""
    echo "STATISTIQUES :"
    echo "• Fichiers traites avec succes : $processed"
    echo "• Erreurs/Avertissements : $errors"
    echo "• Heure de debut : $start_time"
    echo "• Heure de fin : $end_time"
    echo ""
    echo "FICHIER DE LOG COMPLET :"
    echo "$LOG_FILE"
    echo "================================================"
}

# PROGRAMME PRINCIPAL
main() {
    # Verification des parametres
    validate_parameters "$@"
    
    # Assigner les parametres a des variables
    local nom_base="$1"
    local saison="$2"
    local dossier_cible="$3"
    
    # Capturer l'heure de debut
    local start_time=$(date '+%d/%m/%Y a %H:%M:%S')
    
    # Creer le repertoire de log si necessaire
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Initialiser le log
    log_message "========================================="
    log_message "PLEX SERIES ORGANIZER - DEBUT"
    log_message "Demarre le $start_time"
    log_message "========================================="
    
    # Afficher les parametres
    show_parameters "$nom_base" "$saison" "$dossier_cible"
    
    # Logger les parametres
    log_message "Parametres de traitement :"
    log_message "   • Nom de base : $nom_base"
    log_message "   • Saison : $saison" 
    log_message "   • Dossier cible : $dossier_cible"
    
    # Traitement des fichiers
    process_files "$nom_base" "$saison" "$dossier_cible"
    local processed=$?
    
    # Compter les erreurs dans le log de cette session
    local errors=$(grep "ERREUR\|ATTENTION" "$LOG_FILE" | grep "$(date '+%d/%m/%Y')" | wc -l)
    
    # Finalisation
    log_message "========================================="
    log_message "TRAITEMENT TERMINE le $(date '+%d/%m/%Y a %H:%M:%S')"
    log_message "RESULTATS : $processed fichiers traites, $errors erreurs"
    log_message "========================================="
    
    # Afficher les resultats
    show_results $processed $errors "$start_time"
}

# Verification des parametres et aide
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# Verification de l'environnement
echo "Verification de l'environnement Synology DSM..."

# Creer le repertoire de logs si necessaire
if [ ! -d "/volume1/development/scripts/logs" ]; then
    mkdir -p "/volume1/development/scripts/logs"
    echo "Repertoire de logs cree : /volume1/development/scripts/logs"
fi

echo ""

# Lancer le programme principal
main "$@"