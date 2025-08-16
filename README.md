# 🛠️ Projet de Scripting - Collection de Scripts Bash

Ce répertoire contient une collection de scripts bash utiles pour l'administration et l'automatisation sur NAS Synology.

## 📁 Structure du projet

```
/volume1/development/scripts/
├── README.md                       # Ce fichier (documentation principale)
├── install.sh                      # Script d'installation de l'environnement
├── Wake-on-LAN.sh                  # Réveil à distance de machines réseau
├── exemple_option.sh               # Exemples et modèles pour scripts bash
├── mytest.sh                       # Script de test et développement
├── plex_series_organizer.sh        # Organisateur de séries pour Plex
├── readme_plex_organizer.md        # Documentation détaillée pour Plex Organizer
└── logs/                           # Répertoire des fichiers de logs
    └── *.log
```

## 📜 Description des Scripts

### 🚀 **install.sh**

**Description** : Script d'installation pour mettre en place rapidement un environnement de développement sur NAS Synology.

**Fonctionnalités** :

- Configuration automatique de l'environnement de développement
- Installation des dépendances nécessaires
- Création de la structure de répertoires
- Configuration des permissions

**Utilisation** :

```bash
chmod +x install.sh
./install.sh
```

**Status** : ✅ Production

---

### 🌐 **Wake-on-LAN.sh**

**Description** : Script pour réveiller des machines distantes via Wake-on-LAN (WoL).

**Fonctionnalités** :

- Réveil à distance de PC/serveurs
- Support de multiples adresses MAC
- Logging des tentatives de réveil
- Vérification de connectivité post-réveil

**Utilisation** :

```bash
./Wake-on-LAN.sh [adresse_MAC] [adresse_IP_optionnelle]
```

**Exemple** :

```bash
./Wake-on-LAN.sh "AA:BB:CC:DD:EE:FF" "192.168.1.100"
```

**Status** : ✅ Production

---

### 📚 **exemple_option.sh**

**Description** : Script d'exemples et modèles pour l'apprentissage et le développement de scripts bash.

**Fonctionnalités** :

- Exemples de gestion des options en ligne de commande
- Modèles de fonctions courantes
- Exemples de validation d'entrées
- Patterns de logging et gestion d'erreurs

**Utilisation** :

```bash
./exemple_option.sh [options] [paramètres]
```

**Exemples** :

```bash
./exemple_option.sh --help
./exemple_option.sh -v --debug
./exemple_option.sh --file "monfichier.txt"
```

**Status** : 📖 Documentation/Formation

---

### 🧪 **mytest.sh**

**Description** : Script de test et développement pour expérimentation et validation de concepts.

**Fonctionnalités** :

- Tests de nouvelles fonctionnalités
- Validation de concepts avant intégration
- Banc d'essai pour debug
- Environnement de développement rapide

**Utilisation** :

```bash
./mytest.sh [paramètres_de_test]
```

**⚠️ Note** : Script en développement, utilisation à des fins de test uniquement.

**Status** : 🚧 Développement

---

### 🎬 **plex_series_organizer.sh**

**Description** : Script principal pour renommer automatiquement les épisodes de séries selon les conventions Plex Media Server.

**Fonctionnalités** :

- Renommage en lot des fichiers de série
- Format standardisé : `Série S01E01.extension`
- Tri alphabétique automatique
- Logging détaillé des opérations
- Validation des paramètres
- Compatible interface DSM

**Utilisation** :

```bash
./plex_series_organizer.sh "Nom de série" "S01" "/chemin/vers/dossier"
```

**Exemples** :

```bash
./plex_series_organizer.sh "Yi Nian Yong Heng" "S01" "/volume3/Plex/media/mangas/Yi_Nian_Yong_Heng/S01"
./plex_series_organizer.sh "Game of Thrones" "S08" "/volume1/series/GoT/Season_8"
```

**Documentation complète** : Voir `readme_plex_organizer.md`

**Status** : ✅ Production - ⭐ **Script Principal**

---

### 📖 **readme_plex_organizer.md**

**Description** : Documentation détaillée et complète pour le script `plex_series_organizer.sh`.

**Contenu** :

- Guide d'installation complet
- Exemples d'utilisation détaillés
- Intégration avec DSM (interface web)
- Guide de dépannage
- Bonnes pratiques
- Format des logs

**Status** : 📚 Documentation

## 🚀 Installation Rapide

### Prérequis

- NAS Synology avec DSM 6.x ou 7.x
- Accès SSH activé
- Utilisateur avec privilèges admin

### Installation

```bash
# 1. Connexion SSH
ssh admin@votre-nas-ip

# 2. Création du répertoire
mkdir -p /volume1/development/scripts/

# 3. Navigation vers le répertoire
cd /volume1/development/scripts/

# 4. Installation de l'environnement (optionnel)
chmod +x install.sh
./install.sh

# 5. Rendre tous les scripts exécutables
chmod +x *.sh
```

## 🔧 Configuration

### Variables d'environnement communes

Les scripts utilisent ces chemins par défaut :

- **Répertoire de scripts** : `/volume1/development/scripts/`
- **Répertoire de logs** : `/v
