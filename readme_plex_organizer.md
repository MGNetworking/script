# 🎬 Plex Series Organizer

Script bash pour renommer automatiquement les épisodes de séries selon les conventions Plex Media Server sur NAS Synology.

## 📋 Description

Ce script permet de renommer en lot tous les fichiers d'un dossier selon le format standard Plex :
- **Format de sortie** : `[Nom de série] [Saison]E[Episode].[extension]`
- **Exemple** : `Yi Nian Yong Heng S01E01.mkv`

## 🚀 Installation

### 1. Téléchargement
```bash
# Connectez-vous en SSH à votre NAS
ssh admin@votre-nas-ip

# Créez le répertoire si nécessaire
mkdir -p /volume1/development/scripts/

# Copiez le script dans ce répertoire
# (utilisez nano, vim ou File Station)
nano /volume1/development/scripts/plex_series_organizer.sh
```

### 2. Permissions
```bash
# Rendez le script exécutable
chmod +x /volume1/development/scripts/plex_series_organizer.sh
```

## 📖 Utilisation

### Syntaxe générale
```bash
./plex_series_organizer.sh "Nom de base" "Saison" "/chemin/vers/dossier"
```

### Paramètres
1. **Nom de base** : Le nom de la série (entre guillemets)
2. **Saison** : Format SXX (S01, S02, S03...)
3. **Dossier** : Chemin complet vers le dossier contenant les épisodes

### Exemples d'utilisation

#### Exemple 1 : Série animée
```bash
cd /volume1/development/scripts/
./plex_series_organizer.sh "Yi Nian Yong Heng" "S01" "/volume3/Plex/media/mangas/Yi_Nian_Yong_Heng/S01"
```

#### Exemple 2 : Série classique
```bash
./plex_series_organizer.sh "Game of Thrones" "S08" "/volume1/series/GoT/Season_8"
```

#### Exemple 3 : Anime avec numéros de saison élevés
```bash
./plex_series_organizer.sh "One Piece" "S20" "/volume2/anime/One_Piece/Saison_20"
```

### Aide intégrée
```bash
# Afficher l'aide
./plex_series_organizer.sh --help
```

## 🔧 Intégration DSM (Interface Web)

### Via le Planificateur de tâches

1. **Accédez au Panneau de configuration** → **Planificateur de tâches**
2. **Créer** → **Tâche planifiée** → **Script défini par l'utilisateur**
3. **Onglet Général** :
   - Nom de la tâche : `Renommage Plex - [Nom série]`
   - Utilisateur : `admin` (ou votre utilisateur principal)
4. **Onglet Planification** : Configurez selon vos besoins (ou laissez désactivé pour exécution manuelle)
5. **Onglet Paramètres de tâche** :
   - **Script défini par l'utilisateur** :
   ```bash
   /volume1/development/scripts/plex_series_organizer.sh "Nom de votre série" "S01" "/chemin/vers/votre/dossier"
   ```

### Notifications par email (optionnel)
- Cochez **"Envoyer les détails d'exécution par e-mail"**
- Configurez votre adresse email
- Activez **"uniquement lorsque le script se termine de manière anormale"** pour recevoir les erreurs

## 📁 Structure des fichiers

```
/volume1/development/scripts/
├── plex_series_organizer.sh        # Script principal
├── logs/
│   └── plex_series_organizer.log   # Fichier de logs
└── README.md                       # Ce fichier d'aide
```

## 🎯 Exemple de transformation

### Avant renommage :
```
[Namae_FS] Yi Nian Yong Heng 01V2 VOSTFR [1080p].mp4
[Namae_FS] Yi Nian Yong Heng 02V2 VOSTFR [1080p].mp4
[Namae_FS] Yi Nian Yong Heng 03V2 VOSTFR [1080p].mp4
```

### Après renommage :
```
Yi Nian Yong Heng S01E01.mp4
Yi Nian Yong Heng S01E02.mp4
Yi Nian Yong Heng S01E03.mp4
```

## 📊 Fonctionnalités

### ✅ Ce que fait le script
- **Renommage en lot** de tous les fichiers d'un dossier
- **Tri alphabétique** automatique des fichiers avant traitement
- **Numérotation séquentielle** des épisodes (E01, E02, E03...)
- **Conservation des extensions** originales
- **Logging détaillé** de toutes les opérations
- **Validation des paramètres** avant exécution
- **Gestion des conflits** (fichiers existants)

### ⚠️ Sécurités intégrées
- **Validation du format de saison** (doit être SXX)
- **Vérification d'existence du dossier** cible
- **Détection des fichiers déjà existants** avec le nouveau nom
- **Messages d'erreur explicites** en cas de problème

## 📋 Logs et suivi

### Consultation des logs
```bash
# Voir les dernières opérations
cat /volume1/development/scripts/logs/plex_series_organizer.log

# Voir les 20 dernières lignes
tail -20 /volume1/development/scripts/logs/plex_series_organizer.log

# Rechercher une opération spécifique
grep "Yi Nian Yong Heng" /volume1/development/scripts/logs/plex_series_organizer.log
```

### Format des logs
```
16/08/2025 21:45:01 - PLEX SERIES ORGANIZER - DEBUT
16/08/2025 21:45:01 - Demarre le 16/08/2025 a 21:45:01
16/08/2025 21:45:02 - Parametres de traitement :
16/08/2025 21:45:02 -    • Nom de base : Yi Nian Yong Heng
16/08/2025 21:45:02 -    • Saison : S01
16/08/2025 21:45:02 -    • Dossier cible : /volume3/Plex/media/mangas/...
16/08/2025 21:45:03 - RENOMME : [Namae_FS] Yi Nian Yong Heng 01V2 VOSTFR [1080p].mp4 -> Yi Nian Yong Heng S01E01.mp4
```

## 🔍 Dépannage

### Problème : "Permission denied"
```bash
# Vérifiez les permissions
ls -la /volume1/development/scripts/plex_series_organizer.sh

# Corrigez les permissions si nécessaire
chmod +x /volume1/development/scripts/plex_series_organizer.sh
```

### Problème : "No such file or directory"
- Vérifiez que le chemin du dossier cible existe
- Utilisez des chemins absolus (commençant par `/volume1/` ou `/volume2/`)
- Mettez les chemins entre guillemets s'ils contiennent des espaces

### Problème : "Format de saison incorrect"
- Le format doit être exactement `SXX` (S01, S02, S10, etc.)
- Utilisez toujours 2 chiffres pour le numéro de saison

### Debug avancé
```bash
# Exécution avec debug détaillé
bash -x /volume1/development/scripts/plex_series_organizer.sh "Test" "S01" "/chemin/test"
```

## 📞 Support

### Fichiers importants à vérifier en cas de problème :
1. **Script principal** : `/volume1/development/scripts/plex_series_organizer.sh`
2. **Logs détaillés** : `/volume1/development/scripts/logs/plex_series_organizer.log`
3. **Permissions du dossier** cible
4. **Espace disque disponible**

### Informations utiles pour le support :
- Version DSM de votre Synology
- Modèle de votre NAS
- Contenu du fichier de log
- Commande exacte utilisée
- Message d'erreur complet

## 🎖️ Bonnes pratiques

### Avant utilisation
1. **Testez sur un petit dossier** d'abord
2. **Faites une sauvegarde** des fichiers importants
3. **Vérifiez l'espace disque** disponible

### Nommage des séries
- Utilisez des noms **sans caractères spéciaux** dans la mesure du possible
- **Cohérence** avec les noms déjà utilisés dans Plex
- **Vérifiez l'orthographe** pour éviter les doublons

### Organisation des dossiers
```
/volume3/Plex/media/
├── series/
│   ├── Yi_Nian_Yong_Heng/
│   │   ├── Season_01/     # ← Dossier à traiter
│   │   └── Season_02/
│   └── Game_of_Thrones/
│       ├── Season_01/
│       └── Season_08/
└── movies/
```

## 📄 Licence

Script libre d'utilisation pour usage personnel sur NAS Synology.

---

**Version** : 1.0  
**Compatibilité** : Synology DSM 6.x / 7.x  
**Testé sur** : DSM 7.2