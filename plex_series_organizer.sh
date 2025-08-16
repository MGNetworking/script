#!/bin/bash

# Plex Series Organizer - Compatible Synology DSM
# Version adaptee pour l'environnement DSM (sans emojis)

# Fichier de log
LOG_FILE="/volume1/development/scripts/logs/plex_series_organizer.log"

# Fonction pour ecrire dans le log
log_message() {
    echo "$(date '+%d/%m/%Y %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Fonction pour lire les parametres depuis l'utilisateur
get_user_input() {
    echo "================================================"
    echo "PLEX SERIES ORGANIZER - SYNOLOGY DSM"
    echo "================================================"
    echo ""
    echo "ATTENTION : Interface de saisie requise"
    echo ""
    echo "Veuillez saisir les parametres ci-dessous :"
    echo ""
    
    # Saisie interactive via terminal
    echo -n "Nom de base (ex: Yi Nian Yong Heng) : "
    read NOM_BASE
    
    echo -n "Saison (ex: S01) : "
    read SAISON
    
    echo -n "Dossier cible (chemin complet) : "
    read DOSSIER_CIBLE
    
    echo ""
}

# Fonction de validation des entrees
validate_input() {
    local errors=""
    
    if [ -z "$NOM_BASE" ]; then
        errors="${errors}- Le nom de base ne peut pas etre vide\n"
    fi
    
    if [ -z "$SAISON" ]; then
        errors="${errors}- Le numero de saison ne peut pas etre vide\n"
    elif [[ ! "$SAISON" =~ ^S[0-9]{2}$ ]]; then
        errors="${errors}- Le format de saison doit etre SXX (ex: S01)\n"
    fi
    
    if [ -z "$DOSSIER_CIBLE" ]; then
        errors="${errors}- Le dossier cible ne peut pas etre vide\n"
    elif [ ! -d "$DOSSIER_CIBLE" ]; then
        errors="${errors}- Le dossier cible n'existe pas : $DOSSIER_CIBLE\n"
    fi
    
    if [ -n "$errors" ]; then
        echo "ERREURS DETECTEES :"
        echo -e "$errors"
        echo ""
        echo -n "Voulez-vous corriger les informations ? (o/N) : "
        read response
        if [[ "$response" =~ ^[oO]$ ]]; then
            return 1
        else
            echo "Operation annulee."
            exit 0
        fi
    fi
    
    return 0
}

# Fonction de confirmation avant traitement
confirm_processing() {
    # Compter les fichiers a traiter
    local file_count=$(find "$DOSSIER_CIBLE" -maxdepth 1 -type f | wc -l)
    
    echo "================================================"
    echo "CONFIRMATION DU TRAITEMENT"
    echo "================================================"
    echo "Nom de base : $NOM_BASE"
    echo "Saison : $SAISON"
    echo "Dossier : $DOSSIER_CIBLE"
    echo "Nombre de fichiers : $file_count"
    echo ""
    echo -n "Confirmer le renommage ? (o/N) : "
    read response
    
    if [[ "$response" =~ ^[oO]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Fonction principale de renommage
process_files() {
    local episode=1
    local processed=0
    local errors=0
    
    log_message "Debut du traitement des fichiers..."
    
    # Creer un tableau temporaire pour trier les fichiers
    local temp_file="/tmp/files_to_process.txt"
    find "$DOSSIER_CIBLE" -maxdepth 1 -type f | sort > "$temp_file"
    
    # Traiter les fichiers dans l'ordre alphabetique
    while IFS= read -r fichier; do
        if [ -f "$fichier" ]; then
            # Extraire l'extension et nom original
            extension="${fichier##*.}"
            nom_original=$(basename "$fichier")
            
            # Formater le numero d'episode sur 2 chiffres
            episode_format=$(printf "%02d" $episode)
            
            # Creer le nouveau nom
            nouveau_nom="${NOM_BASE} ${SAISON}E${episode_format}.${extension}"
            nouveau_chemin="${DOSSIER_CIBLE}/${nouveau_nom}"
            
            # Verifier si le nouveau nom existe deja
            if [ -e "$nouveau_chemin" ] && [ "$fichier" != "$nouveau_chemin" ]; then
                log_message "ATTENTION : Le fichier $nouveau_nom existe deja - ignore"
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
                    echo "ERREUR : $nom_original"
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
    echo "ETAT DE L'EXECUTION"
    echo "================================================"
    
    if [ $errors -eq 0 ]; then
        echo "STATUT : SUCCES"
    else
        echo "STATUT : TERMINE AVEC AVERTISSEMENTS"
    fi
    
    echo ""
    echo "STATISTIQUES :"
    echo "• Fichiers traites : $processed"
    echo "• Erreurs/Avertissements : $errors"
    echo "• Debut : $start_time"
    echo "• Fin : $end_time"
    echo ""
    echo "PARAMETRES UTILISES :"
    echo "• Nom de base : $NOM_BASE"
    echo "• Saison : $SAISON"
    echo "• Dossier : $DOSSIER_CIBLE"
    echo ""
    echo "FICHIER DE LOG :"
    echo "$LOG_FILE"
    echo ""
    echo "Les logs complets sont disponibles dans le fichier ci-dessus"
    echo "pour consultation detaillee."
    echo "================================================"
}

# PROGRAMME PRINCIPAL
main() {
    # Capturer l'heure de debut
    local start_time=$(date '+%d/%m/%Y a %H:%M:%S')
    
    # Creer le repertoire de log si necessaire
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Initialiser le log
    log_message "========================================="
    log_message "PLEX SERIES ORGANIZER - SYNOLOGY"
    log_message "Demarre le $start_time"
    log_message "========================================="
    
    # Boucle principale pour permettre les corrections
    while true; do
        # Recuperer les donnees utilisateur
        get_user_input
        
        # Valider les entrees
        if validate_input; then
            break
        fi
    done
    
    # Logger les parametres
    log_message "Parametres de traitement :"
    log_message "   • Nom de base : $NOM_BASE"
    log_message "   • Saison : $SAISON" 
    log_message "   • Dossier cible : $DOSSIER_CIBLE"
    
    # Confirmation finale
    if ! confirm_processing; then
        log_message "Operation annulee par l'utilisateur"
        echo "Operation annulee."
        exit 0
    fi
    
    # Traitement des fichiers
    echo ""
    echo "Traitement en cours..."
    echo ""
    
    process_files
    local processed=$?
    
    # Compter les erreurs dans le log
    local errors=$(grep -c "ERREUR\|ATTENTION" "$LOG_FILE" 2>/dev/null || echo "0")
    
    # Finalisation
    log_message "========================================="
    log_message "Traitement termine le $(date '+%d/%m/%Y a %H:%M:%S')"
    log_message "Resultats : $processed fichiers traites, $errors erreurs"
    log_message "========================================="
    
    # Afficher les resultats avec toutes les informations
    show_results $processed $errors "$start_time"
}

# Verification de l'environnement et lancement
echo "Verification de l'environnement Synology DSM..."

# Creer le repertoire de scripts et logs si necessaire
if [ ! -d "/volume1/development/scripts/logs" ]; then
    mkdir -p "/volume1/development/scripts/logs"
    echo "Repertoire /volume1/development/scripts/logs cree"
fi

# Lancer le programme principal
main