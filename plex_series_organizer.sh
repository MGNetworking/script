#!/bin/bash

# 🎬 Script de renommage interactif pour Plex - Compatible Synology DSM
# Version adaptée pour l'environnement DSM

# 📄 Fichier de log
LOG_FILE="/volume1/development/scripts/log_plex_organizer.txt"

# Fonction pour écrire dans le log
log_message() {
    echo "$(date '+%d/%m/%Y %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Fonction pour créer l'interface web simple
create_input_form() {
    cat > /tmp/plex_form.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Plex Renommage - Configuration</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 500px; }
        h2 { color: #333; text-align: center; margin-bottom: 30px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 5px; font-weight: bold; color: #555; }
        input[type="text"] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; font-size: 14px; }
        .buttons { text-align: center; margin-top: 30px; }
        button { padding: 10px 20px; margin: 0 10px; border: none; border-radius: 5px; cursor: pointer; font-size: 14px; }
        .btn-ok { background: #4CAF50; color: white; }
        .btn-cancel { background: #f44336; color: white; }
        .btn-ok:hover { background: #45a049; }
        .btn-cancel:hover { background: #da190b; }
        .example { font-size: 12px; color: #888; margin-top: 3px; }
    </style>
</head>
<body>
    <div class="container">
        <h2>🎬 Plex Renommage - Configuration</h2>
        <form method="post" action="">
            <div class="form-group">
                <label for="nom_base">Nom de base :</label>
                <input type="text" id="nom_base" name="nom_base" required>
                <div class="example">Exemple: Yi Nian Yong Heng</div>
            </div>
            
            <div class="form-group">
                <label for="saison">Saison :</label>
                <input type="text" id="saison" name="saison" pattern="S[0-9]{2}" required>
                <div class="example">Format: S01, S02, S03...</div>
            </div>
            
            <div class="form-group">
                <label for="dossier">Dossier cible :</label>
                <input type="text" id="dossier" name="dossier" required>
                <div class="example">Exemple: /volume3/Plex/media/mangas/Ma_Serie</div>
            </div>
            
            <div class="buttons">
                <button type="submit" name="action" value="process" class="btn-ok">▶️ Lancer le renommage</button>
                <button type="submit" name="action" value="cancel" class="btn-cancel">❌ Annuler</button>
            </div>
        </form>
    </div>
</body>
</html>
EOF
}

# Fonction pour lire les paramètres depuis un fichier de configuration temporaire
get_user_input() {
    # Créer le formulaire HTML
    create_input_form
    
    echo "================================================"
    echo "🎬 PLEX RENOMMAGE INTERACTIF - SYNOLOGY DSM"
    echo "================================================"
    echo ""
    echo "⚠️  ATTENTION : Interface de saisie requise"
    echo ""
    echo "Pour utiliser ce script de manière interactive,"
    echo "veuillez saisir les paramètres ci-dessous :"
    echo ""
    
    # Saisie interactive via terminal
    echo -n "📝 Nom de base (ex: Yi Nian Yong Heng) : "
    read NOM_BASE
    
    echo -n "📅 Saison (ex: S01) : "
    read SAISON
    
    echo -n "📁 Dossier cible (chemin complet) : "
    read DOSSIER_CIBLE
    
    echo ""
}

# Fonction de validation des entrées
validate_input() {
    local errors=""
    
    if [ -z "$NOM_BASE" ]; then
        errors="${errors}- Le nom de base ne peut pas être vide\n"
    fi
    
    if [ -z "$SAISON" ]; then
        errors="${errors}- Le numéro de saison ne peut pas être vide\n"
    elif [[ ! "$SAISON" =~ ^S[0-9]{2}$ ]]; then
        errors="${errors}- Le format de saison doit être SXX (ex: S01)\n"
    fi
    
    if [ -z "$DOSSIER_CIBLE" ]; then
        errors="${errors}- Le dossier cible ne peut pas être vide\n"
    elif [ ! -d "$DOSSIER_CIBLE" ]; then
        errors="${errors}- Le dossier cible n'existe pas : $DOSSIER_CIBLE\n"
    fi
    
    if [ -n "$errors" ]; then
        echo "❌ ERREURS DÉTECTÉES :"
        echo -e "$errors"
        echo ""
        echo -n "Voulez-vous corriger les informations ? (o/N) : "
        read response
        if [[ "$response" =~ ^[oO]$ ]]; then
            return 1
        else
            echo "Opération annulée."
            exit 0
        fi
    fi
    
    return 0
}

# Fonction de confirmation avant traitement
confirm_processing() {
    # Compter les fichiers à traiter
    local file_count=$(find "$DOSSIER_CIBLE" -maxdepth 1 -type f | wc -l)
    
    echo "================================================"
    echo "📋 CONFIRMATION DU TRAITEMENT"
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
    
    log_message "🚀 Début du traitement des fichiers..."
    
    # Créer un tableau temporaire pour trier les fichiers
    local temp_file="/tmp/files_to_process.txt"
    find "$DOSSIER_CIBLE" -maxdepth 1 -type f | sort > "$temp_file"
    
    # Traiter les fichiers dans l'ordre alphabétique
    while IFS= read -r fichier; do
        if [ -f "$fichier" ]; then
            # Extraire l'extension et nom original
            extension="${fichier##*.}"
            nom_original=$(basename "$fichier")
            
            # Formater le numéro d'épisode sur 2 chiffres
            episode_format=$(printf "%02d" $episode)
            
            # Créer le nouveau nom
            nouveau_nom="${NOM_BASE} ${SAISON}E${episode_format}.${extension}"
            nouveau_chemin="${DOSSIER_CIBLE}/${nouveau_nom}"
            
            # Vérifier si le nouveau nom existe déjà
            if [ -e "$nouveau_chemin" ] && [ "$fichier" != "$nouveau_chemin" ]; then
                log_message "⚠️  ATTENTION : Le fichier $nouveau_nom existe déjà - ignoré"
                ((errors++))
            else
                # Renommer le fichier
                if mv "$fichier" "$nouveau_chemin" 2>/dev/null; then
                    log_message "✅ Renommé : $nom_original → $nouveau_nom"
                    echo "✅ $nom_original → $nouveau_nom"
                    ((processed++))
                    ((episode++))
                else
                    log_message "❌ ERREUR lors du renommage : $nom_original"
                    echo "❌ ERREUR : $nom_original"
                    ((errors++))
                fi
            fi
        fi
    done < "$temp_file"
    
    # Nettoyer le fichier temporaire
    rm -f "$temp_file"
    
    return $processed
}

# Fonction d'affichage du résultat final
show_results() {
    local processed=$1
    local errors=$2
    local start_time="$3"
    local end_time=$(date '+%d/%m/%Y à %H:%M:%S')
    
    echo ""
    echo "================================================"
    echo "🎯 ÉTAT DE L'EXÉCUTION"
    echo "================================================"
    
    if [ $errors -eq 0 ]; then
        echo "✅ STATUT : SUCCÈS"
    else
        echo "⚠️  STATUT : TERMINÉ AVEC AVERTISSEMENTS"
    fi
    
    echo ""
    echo "📊 STATISTIQUES :"
    echo "• Fichiers traités : $processed"
    echo "• Erreurs/Avertissements : $errors"
    echo "• Début : $start_time"
    echo "• Fin : $end_time"
    echo ""
    echo "📁 PARAMÈTRES UTILISÉS :"
    echo "• Nom de base : $NOM_BASE"
    echo "• Saison : $SAISON"
    echo "• Dossier : $DOSSIER_CIBLE"
    echo ""
    echo "📋 FICHIER DE LOG :"
    echo "$LOG_FILE"
    echo ""
    echo "💡 Les logs complets sont disponibles dans le fichier ci-dessus"
    echo "   pour consultation détaillée."
    echo "================================================"
}

# 🎯 PROGRAMME PRINCIPAL
main() {
    # Capturer l'heure de début
    local start_time=$(date '+%d/%m/%Y à %H:%M:%S')
    
    # Créer le répertoire de log si nécessaire
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Initialiser le log
    log_message "========================================="
    log_message "🎬 PLEX RENOMMAGE INTERACTIF - SYNOLOGY"
    log_message "Démarré le $start_time"
    log_message "========================================="
    
    # Boucle principale pour permettre les corrections
    while true; do
        # Récupérer les données utilisateur
        get_user_input
        
        # Valider les entrées
        if validate_input; then
            break
        fi
    done
    
    # Logger les paramètres
    log_message "📋 Paramètres de traitement :"
    log_message "   • Nom de base : $NOM_BASE"
    log_message "   • Saison : $SAISON" 
    log_message "   • Dossier cible : $DOSSIER_CIBLE"
    
    # Confirmation finale
    if ! confirm_processing; then
        log_message "❌ Opération annulée par l'utilisateur"
        echo "Opération annulée."
        exit 0
    fi
    
    # Traitement des fichiers
    echo ""
    echo "🚀 Traitement en cours..."
    echo ""
    
    process_files
    local processed=$?
    
    # Compter les erreurs dans le log
    local errors=$(grep -c "ERREUR\|ATTENTION" "$LOG_FILE" 2>/dev/null || echo "0")
    
    # Finalisation
    log_message "========================================="
    log_message "✅ Traitement terminé le $(date '+%d/%m/%Y à %H:%M:%S')"
    log_message "📊 Résultats : $processed fichiers traités, $errors erreurs"
    log_message "========================================="
    
    # Afficher les résultats avec toutes les informations
    show_results $processed $errors "$start_time"
}

# Vérification de l'environnement et lancement
echo "🔍 Vérification de l'environnement Synology DSM..."

# Créer le répertoire de scripts si nécessaire
if [ ! -d "/volume1/scripts" ]; then
    mkdir -p "/volume1/scripts"
    echo "📁 Répertoire /volume1/scripts créé"
fi

# Lancer le programme principal
main