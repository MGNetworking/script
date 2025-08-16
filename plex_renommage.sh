#!/bin/bash

# 🚀 Dossier cible (à adapter)
DOSSIER="/volume3/Plex/media/mangas/One Punch Man/Saison 1"

# Définir explicitement le nom final de base
NOM_FINAL="One Punch Man"

# Définir le numéro de la saison (par exemple 1 pour S01)
SAISON=S01

# Initialiser le compteur d'épisode
EPISODE=1

# 📄 Fichier de sortie pour le journal
LOG_FILE="/volume1/scripts/log_renommage.txt"
echo "----------------------------------------" >> "$LOG_FILE"
echo "Renommage lancé le $(date)" >> "$LOG_FILE"
echo "Nom final de base : $NOM_FINAL" >> "$LOG_FILE"
echo "Dossier cible : $DOSSIER" >> "$LOG_FILE"


# Parcourir les fichiers du dossier
for FICHIER in "$DOSSIER"/*; do
  if [ -f "$FICHIER" ]; then
    EXTENSION="${FICHIER##*.}"
    EPISODE_FORMAT=$(printf "%02d" $EPISODE)

    # Créer le nouveau nom de fichier
    NOUVEAU_NOM="${NOM_FINAL} ${SAISON}E${EPISODE_FORMAT}.${EXTENSION}"

    # Renommer le fichier
    mv "$FICHIER" "$DOSSIER/$NOUVEAU_NOM"

    # Écrire dans le log
    echo "Renommé : $FICHIER -> $DOSSIER/$NOUVEAU_NOM"
    echo "Renommé : $FICHIER -> $DOSSIER/$NOUVEAU_NOM" >> "$LOG_FILE"

    EPISODE=$((EPISODE + 1))
  fi
done

echo "Fin de l'exécution." >> "$LOG_FILE"
