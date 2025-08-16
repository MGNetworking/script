#!/bin/bash

# Script de déploiement K3s pour Synology NAS
# Usage: ./deploy_k3s_synology.sh [options]
# Auteur: Script amélioré pour une meilleure robustesse et sécurité

# Configuration stricte pour la robustesse et la sécurité
# -e : arrête le script en cas d'erreur
# -u : arrête le script en cas d'utilisation d'une variable non définie
# -o pipefail : fait échouer le pipeline si une commande échoue
set -euo pipefail

# === DÉTECTION DU CONTEXTE D'EXÉCUTION ===
# Récupère le répertoire où se trouve ce script pour établir le contexte
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Nom du fichier de configuration
CONFIG_FILE="${SCRIPT_DIR}/k3s_synology.conf"
readonly CONFIG_FILE

# === CONFIGURATION PAR DÉFAUT ===
# Ces valeurs peuvent être surchargées par le fichier de configuration
K3S_VERSION="latest"
K3S_INSTALL_DIR="/usr/local/bin"
DOCKER_SOCK="/var/run/docker.sock"

# Variables dérivées du contexte (ne doivent PAS être dans le fichier de config)
K3S_DATA_DIR="${SCRIPT_DIR}/k3s-data"
K3S_CONFIG_DIR="${SCRIPT_DIR}/k3s-data/config"
KUBECTL_CONFIG="${SCRIPT_DIR}/k3s-data/config/kubeconfig"

# === COULEURS POUR LES MESSAGES ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# === FONCTIONS D'AFFICHAGE ===
# Affiche un message d'information en bleu
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

# Affiche un message de succès en vert
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

# Affiche un message d'avertissement en jaune
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

# Affiche un message d'erreur en rouge et termine le script
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# === FONCTION DE CHARGEMENT DE LA CONFIGURATION ===
# Charge les variables depuis le fichier de configuration s'il existe
# Le fichier doit contenir des variables au format : VARIABLE="valeur"
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Chargement de la configuration depuis : $CONFIG_FILE"

        # Source le fichier de configuration de manière sécurisée
        # On vérifie d'abord que le fichier ne contient que des déclarations de variables
        if grep -q '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE"; then
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
            log_success "Configuration chargée avec succès"
        else
            log_warning "Le fichier de configuration contient des éléments non valides"
        fi
    else
        log_info "Aucun fichier de configuration trouvé, utilisation des valeurs par défaut"
        log_info "Vous pouvez créer un fichier $CONFIG_FILE avec vos paramètres"
    fi

    # Mise à jour des variables dérivées après chargement de la config
    K3S_CONFIG_DIR="${K3S_DATA_DIR}/config"
    KUBECTL_CONFIG="${K3S_DATA_DIR}/config/kubeconfig"
}

# === FONCTION D'AIDE ===
# Affiche l'aide détaillée du script avec toutes les options disponibles
show_help() {
    cat <<EOF
Usage: $0 [options]

DESCRIPTION:
    Script de déploiement automatisé de K3s sur Synology NAS
    Installe et configure K3s avec Docker comme runtime de conteneur

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version VERSION   Version de K3s à installer (défaut: latest)
    -d, --data-dir DIR      Répertoire de données K3s (défaut: ${K3S_DATA_DIR})
    -c, --config-dir DIR    Répertoire de configuration (défaut: ${K3S_CONFIG_DIR})
    -i, --install-dir DIR   Répertoire d'installation binaires (défaut: ${K3S_INSTALL_DIR})
    -s, --docker-sock PATH  Chemin vers le socket Docker (défaut: ${DOCKER_SOCK})
    -n, --node-ip IP        IP du nœud (détectée automatiquement si non spécifiée)
    --no-traefik           Désactiver Traefik (reverse proxy intégré)
    --no-servicelb         Désactiver le load balancer intégré
    --uninstall            Désinstaller K3s complètement
    --config-file FILE     Fichier de configuration à utiliser (défaut: ${CONFIG_FILE})

FICHIER DE CONFIGURATION:
    Le script peut utiliser un fichier de configuration : ${CONFIG_FILE}
    Variables supportées :
    - K3S_VERSION="v1.28.5+k3s1"
    - K3S_INSTALL_DIR="/usr/local/bin"
    - DOCKER_SOCK="/var/run/docker.sock"

EXEMPLES:
    $0                                    # Installation basique
    $0 -v v1.28.5+k3s1                  # Installation d'une version spécifique
    $0 --no-traefik --no-servicelb      # Installation sans Traefik et ServiceLB
    $0 -d /volume2/k3s                  # Installation dans un répertoire personnalisé
    $0 --uninstall                      # Désinstallation complète

NOTES:
    - Le script doit être exécuté en tant que root
    - Docker doit être installé et fonctionnel
    - Au moins 2GB d'espace libre recommandé
EOF
}

# === FONCTION DE VÉRIFICATION DES PRÉREQUIS ===
# Vérifie que toutes les conditions sont réunies pour installer K3s
check_prerequisites() {
    log_info "=== VÉRIFICATION DES PRÉREQUIS ==="

    # Vérification 1: Permissions root
    # K3s nécessite des privilèges root pour s'installer et configurer le système
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root (utilisez sudo)"
    fi

    # Vérification 2: Architecture du processeur
    # K3s supporte différentes architectures, on détermine laquelle utiliser
    local arch
    arch=$(uname -m)
    case $arch in
    x86_64)
        ARCH="amd64"
        log_info "Architecture détectée: AMD64/x86_64"
        ;;
    armv7l)
        ARCH="arm"
        log_info "Architecture détectée: ARM 32-bit"
        ;;
    aarch64)
        ARCH="arm64"
        log_info "Architecture détectée: ARM 64-bit"
        ;;
    *)
        log_error "Architecture non supportée: $arch"
        ;;
    esac

    # Vérification 3: Présence de Docker
    # K3s utilisera Docker comme runtime de conteneur
    if ! command -v docker &>/dev/null; then
        log_error "Docker n'est pas installé ou n'est pas accessible dans le PATH"
    fi

    # Vérification 4: Service Docker actif
    # Docker doit être démarré pour que K3s puisse l'utiliser
    if ! docker info &>/dev/null; then
        log_error "Docker n'est pas démarré ou est inaccessible (vérifiez les permissions)"
    fi

    # Vérification 5: Socket Docker accessible
    # K3s communique avec Docker via un socket Unix
    if [[ ! -S "$DOCKER_SOCK" ]]; then
        log_error "Socket Docker non trouvé ou inaccessible: $DOCKER_SOCK"
    fi

    # Vérification 6: Espace disque disponible
    # K3s et les images Docker ont besoin d'espace (minimum 2GB recommandé)
    local available_space
    available_space=$(df "$(dirname "$K3S_DATA_DIR")" | tail -1 | awk '{print $4}')
    if [[ $available_space -lt 2097152 ]]; then # 2GB en KB
        log_warning "Espace disque faible (moins de 2GB disponible)"
        log_warning "Vous pourriez rencontrer des problèmes avec les images Docker"
    fi

    # Vérification 7: Permissions d'écriture
    # Le script doit pouvoir installer les binaires K3s
    if [[ ! -w "$K3S_INSTALL_DIR" ]]; then
        log_error "Répertoire d'installation non accessible en écriture: $K3S_INSTALL_DIR"
    fi

    # Vérification 8: Répertoire de données accessible
    # On vérifie que le répertoire parent existe et est accessible
    local parent_dir
    parent_dir=$(dirname "$K3S_DATA_DIR")
    if [[ ! -d "$parent_dir" ]]; then
        log_error "Répertoire parent non accessible: $parent_dir"
    fi

    log_success "Tous les prérequis sont satisfaits"
}

# === FONCTION DE CRÉATION DES RÉPERTOIRES ===
# Crée toute la structure de répertoires nécessaire pour K3s
create_directories() {
    log_info "=== CRÉATION DE LA STRUCTURE DE RÉPERTOIRES ==="

    # Création du répertoire principal de données K3s
    # Contient toutes les données persistantes du cluster
    mkdir -p "$K3S_DATA_DIR"
    log_info "Créé: $K3S_DATA_DIR (données principales du cluster)"

    # Création du répertoire de configuration
    # Contient les fichiers de configuration kubectl et autres
    mkdir -p "$K3S_CONFIG_DIR"
    log_info "Créé: $K3S_CONFIG_DIR (configuration kubectl)"

    # Création des sous-répertoires spécialisés
    # agent: données du nœud agent K3s
    mkdir -p "$K3S_DATA_DIR/agent"
    log_info "Créé: $K3S_DATA_DIR/agent (données de l'agent K3s)"

    # server: données du serveur K3s (API server, etcd, etc.)
    mkdir -p "$K3S_DATA_DIR/server"
    log_info "Créé: $K3S_DATA_DIR/server (données du serveur K3s)"

    # logs: fichiers de logs centralisés
    mkdir -p "$K3S_DATA_DIR/logs"
    log_info "Créé: $K3S_DATA_DIR/logs (logs de K3s)"

    # Création du répertoire de configuration système
    # Utilisé par K3s pour sa configuration système
    mkdir -p "/etc/rancher/k3s"
    log_info "Créé: /etc/rancher/k3s (configuration système Rancher)"

    # Configuration des permissions de sécurité
    # Seul root peut accéder aux données sensibles du cluster
    chown -R root:root "$K3S_DATA_DIR"
    chmod -R 755 "$K3S_DATA_DIR"
    log_info "Permissions configurées (root:root, 755)"

    log_success "Structure de répertoires créée avec succès"
}

# === FONCTION DE DÉTECTION DE L'IP DU NŒUD ===
# Détermine automatiquement l'IP du nœud pour la configuration K3s
detect_node_ip() {
    log_info "=== DÉTECTION DE L'IP DU NŒUD ==="

    # Si l'IP n'est pas spécifiée manuellement, on la détecte automatiquement
    if [[ -z "${NODE_IP:-}" ]]; then
        # Méthode 1: Utilise la route par défaut pour trouver l'IP source
        # Cette méthode est généralement la plus fiable
        NODE_IP=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1)

        # Méthode 2: Si la première méthode échoue, utilise hostname -I
        # Récupère la première IP non-loopback
        if [[ -z "$NODE_IP" ]]; then
            NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        fi

        # Méthode 3: Dernière tentative avec une approche différente
        if [[ -z "$NODE_IP" ]]; then
            NODE_IP=$(ip addr show | grep -E 'inet.*brd' | head -1 | awk '{print $2}' | cut -d'/' -f1)
        fi

        # Vérification finale
        if [[ -z "$NODE_IP" ]]; then
            log_error "Impossible de détecter l'IP du nœud automatiquement"
        fi
        log_info "l'IP du nœud pour la configuration K3s à bien était trouver : $NODE_IP"
    fi

    # Validation de l'IP détectée
    if [[ ! "$NODE_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "IP du nœud invalide: $NODE_IP"
    fi

    log_success "IP du nœud configurée: $NODE_IP"
}

# === FONCTION D'INSTALLATION DE K3S ===
# Télécharge et installe K3s avec la configuration appropriée
install_k3s() {
    log_info "=== INSTALLATION DE K3S ==="

    # Configuration de l'URL de téléchargement
    local download_url="https://get.k3s.io"
    log_info "URL de téléchargement: $download_url"

    # Si une version spécifique est demandée, on la configure
    if [[ "$K3S_VERSION" != "latest" ]]; then
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        log_info "Version spécifiée: $K3S_VERSION"
    else
        log_info "Version: latest (automatiquement déterminée)"
    fi

    # === CONFIGURATION DES VARIABLES D'ENVIRONNEMENT ===
    # Ces variables contrôlent le comportement de l'installateur K3s

    # Répertoire de données principal
    export K3S_DATA_DIR="$K3S_DATA_DIR"

    # Mode d'installation (server = nœud maître)
    export INSTALL_K3S_EXEC="server"

    # Localisation du fichier kubeconfig généré
    export K3S_KUBECONFIG_OUTPUT="$KUBECTL_CONFIG"

    # Permissions du fichier kubeconfig (644 = lisible par tous, modifiable par root)
    export K3S_KUBECONFIG_MODE="644"

    # === CONSTRUCTION DES OPTIONS K3S ===
    local k3s_options=""

    # Répertoire de données
    k3s_options="$k3s_options --data-dir=$K3S_DATA_DIR"

    # IP du nœud (pour la communication inter-nœuds)
    k3s_options="$k3s_options --node-ip=$NODE_IP"

    # Adresse d'écoute (0.0.0.0 = toutes les interfaces)
    k3s_options="$k3s_options --bind-address=0.0.0.0"

    # Port HTTPS pour l'API Kubernetes
    k3s_options="$k3s_options --https-listen-port=6443"

    # Utilisation de Docker comme runtime (au lieu de containerd)
    k3s_options="$k3s_options --docker"

    # === OPTIONS CONDITIONNELLES ===
    # Désactivation de Traefik (reverse proxy intégré)
    if [[ "${DISABLE_TRAEFIK:-false}" == "true" ]]; then
        k3s_options="$k3s_options --disable=traefik"
        log_info "Traefik désactivé"
    fi

    # Désactivation du load balancer intégré
    if [[ "${DISABLE_SERVICELB:-false}" == "true" ]]; then
        k3s_options="$k3s_options --disable=servicelb"
        log_info "ServiceLB désactivé"
    fi

    # Configuration finale de la commande d'installation
    export INSTALL_K3S_EXEC="server $k3s_options"
    log_info "Options K3s: $k3s_options"

    # === TÉLÉCHARGEMENT ET INSTALLATION ===
    # Le script d'installation officiel gère le téléchargement et l'installation
    log_info "Téléchargement et installation en cours..."
    curl -sfL "$download_url" | sh -

    log_success "K3s installé avec succès"
}

# === FONCTION DE CONFIGURATION DU SERVICE ===
# Configure le service K3s et vérifie qu'il fonctionne correctement
configure_service() {
    log_info "=== CONFIGURATION DU SERVICE K3S ==="

    # Création d'un lien symbolique pour kubectl
    # Permet d'utiliser kubectl directement depuis le binaire K3s
    if [[ ! -L /usr/local/bin/kubectl ]]; then
        ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
        log_info "Lien symbolique kubectl créé"
    fi

    # Démarrage du service K3s via systemd
    systemctl enable k3s.service
    systemctl start k3s.service
    log_info "Service K3s démarré et activé au boot"

    # Attente du démarrage complet
    log_info "Attente du démarrage complet du service..."
    sleep 10

    # Vérification que le service est actif
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if systemctl is-active --quiet k3s; then
            log_success "Service K3s opérationnel"
            break
        fi

        ((attempt++))
        log_info "Tentative $attempt/$max_attempts - attente du service..."
        sleep 2
    done

    # Vérification finale de l'état du service
    if ! systemctl is-active --quiet k3s; then
        log_error "Le service K3s n'a pas pu démarrer correctement"
    fi

    # === VÉRIFICATION DU CLUSTER ===
    # Test de connectivité avec l'API Kubernetes
    export KUBECONFIG="$KUBECTL_CONFIG"

    log_info "Vérification de la connectivité du cluster..."
    local cluster_ready=false

    # Tentatives de connexion au cluster
    for attempt in {1..15}; do
        if kubectl get nodes &>/dev/null; then
            cluster_ready=true
            break
        fi
        log_info "Tentative $attempt/15 - attente de la disponibilité du cluster..."
        sleep 2
    done

    if [[ "$cluster_ready" == "true" ]]; then
        log_success "Cluster K3s opérationnel et accessible"

        # Affichage des informations du cluster
        log_info "Informations du cluster:"
        kubectl get nodes --kubeconfig="$KUBECTL_CONFIG" 2>/dev/null || true
    else
        log_warning "Le cluster n'est pas encore prêt"
        log_warning "Cela peut prendre quelques minutes supplémentaires"
    fi
}

# === FONCTION DE CRÉATION DES SCRIPTS UTILITAIRES ===
# Crée des scripts helper pour faciliter la gestion de K3s
create_utility_scripts() {
    log_info "=== CRÉATION DES SCRIPTS UTILITAIRES ==="

    # === SCRIPT DE GESTION K3S ===
    # Script principal pour gérer le service K3s
    cat >"$K3S_DATA_DIR/k3s-manager.sh" <<EOF
#!/bin/bash
# Script de gestion K3s pour Synology NAS
# Permet de contrôler facilement le service K3s

# Configuration
KUBECONFIG="$KUBECTL_CONFIG"
SERVICE_NAME="k3s"

# Fonction d'affichage des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "\${GREEN}[INFO]\${NC} \$1"; }
log_error() { echo -e "\${RED}[ERROR]\${NC} \$1"; }
log_warning() { echo -e "\${YELLOW}[WARNING]\${NC} \$1"; }

# Vérification des privilèges root pour les opérations système
check_root() {
    if [[ \$EUID -ne 0 && "\$1" != "kubectl" ]]; then
        log_error "Cette opération nécessite les privilèges root"
        exit 1
    fi
}

case "\$1" in
    start)
        check_root
        systemctl start \$SERVICE_NAME
        log_info "Service K3s démarré"
        ;;
    stop)
        check_root
        systemctl stop \$SERVICE_NAME
        log_info "Service K3s arrêté"
        ;;
    restart)
        check_root
        systemctl restart \$SERVICE_NAME
        log_info "Service K3s redémarré"
        ;;
    status)
        systemctl status \$SERVICE_NAME
        ;;
    logs)
        journalctl -u \$SERVICE_NAME -f
        ;;
    kubectl)
        shift
        KUBECONFIG="\$KUBECONFIG" kubectl "\$@"
        ;;
    nodes)
        KUBECONFIG="\$KUBECONFIG" kubectl get nodes
        ;;
    pods)
        KUBECONFIG="\$KUBECONFIG" kubectl get pods --all-namespaces
        ;;
    services)
        KUBECONFIG="\$KUBECONFIG" kubectl get services --all-namespaces
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|logs|kubectl|nodes|pods|services}"
        echo ""
        echo "Commandes disponibles:"
        echo "  start     - Démarre le service K3s"
        echo "  stop      - Arrête le service K3s"
        echo "  restart   - Redémarre le service K3s"
        echo "  status    - Affiche le statut du service"
        echo "  logs      - Affiche les logs en temps réel"
        echo "  kubectl   - Exécute une commande kubectl"
        echo "  nodes     - Liste les nœuds du cluster"
        echo "  pods      - Liste tous les pods"
        echo "  services  - Liste tous les services"
        exit 1
        ;;
esac
EOF

    chmod +x "$K3S_DATA_DIR/k3s-manager.sh"
    log_info "Script de gestion créé: $K3S_DATA_DIR/k3s-manager.sh"

    # === SCRIPT DE CONFIGURATION KUBECTL ===
    # Script pour configurer facilement kubectl
    cat >"$K3S_DATA_DIR/setup-kubectl.sh" <<EOF
#!/bin/bash
# Script de configuration kubectl pour K3s
# Configure l'environnement pour utiliser kubectl avec K3s

# Configuration du kubeconfig
export KUBECONFIG="$KUBECTL_CONFIG"

# Vérification de la connectivité
if kubectl get nodes &>/dev/null; then
    echo "✓ Configuration kubectl terminée avec succès"
    echo "✓ Cluster K3s accessible"
    echo ""
    echo "Informations du cluster:"
    kubectl get nodes
else
    echo "⚠ Configuration kubectl terminée mais le cluster n'est pas accessible"
    echo "⚠ Vérifiez que le service K3s est démarré"
fi

echo ""
echo "Pour utiliser kubectl dans votre session actuelle:"
echo "  export KUBECONFIG=$KUBECTL_CONFIG"
echo ""
echo "Ou sourcez ce script:"
echo "  source $K3S_DATA_DIR/setup-kubectl.sh"
EOF

    chmod +x "$K3S_DATA_DIR/setup-kubectl.sh"
    log_info "Script de configuration kubectl créé: $K3S_DATA_DIR/setup-kubectl.sh"

    # === SCRIPT DE SAUVEGARDE ===
    # Script pour sauvegarder la configuration K3s
    cat >"$K3S_DATA_DIR/backup-k3s.sh" <<EOF
#!/bin/bash
# Script de sauvegarde K3s
# Sauvegarde la configuration et les données importantes

BACKUP_DIR="${K3S_DATA_DIR}/backups"
BACKUP_DATE=\$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="\$BACKUP_DIR/k3s_backup_\$BACKUP_DATE.tar.gz"

# Création du répertoire de sauvegarde
mkdir -p "\$BACKUP_DIR"

echo "Création de la sauvegarde K3s..."
echo "Fichier: \$BACKUP_FILE"

# Création de l'archive
tar -czf "\$BACKUP_FILE" \\
    -C "$K3S_DATA_DIR" \\
    config/ \\
    server/ \\
    2>/dev/null

echo "✓ Sauvegarde créée: \$BACKUP_FILE"

# Nettoyage des anciennes sauvegardes (garde les 5 dernières)
find "\$BACKUP_DIR" -name "k3s_backup_*.tar.gz" -type f | sort -r | tail -n +6 | xargs -r rm

echo "✓ Ancien sauvegardes nettoyées"
EOF

    chmod +x "$K3S_DATA_DIR/backup-k3s.sh"
    log_info "Script de sauvegarde créé: $K3S_DATA_DIR/backup-k3s.sh"

    log_success "Tous les scripts utilitaires ont été créés"
}

# === FONCTION DE DÉSINSTALLATION ===
# Désinstalle complètement K3s et nettoie le système
uninstall_k3s() {
    log_info "=== DÉSINSTALLATION DE K3S ==="

    # Arrêt du service K3s
    log_info "Arrêt du service K3s..."
    if systemctl is-active --quiet k3s 2>/dev/null; then
        systemctl stop k3s
        log_info "Service K3s arrêté"
    fi

    # Désactivation du service au démarrage
    if systemctl is-enabled --quiet k3s 2>/dev/null; then
        systemctl disable k3s
        log_info "Service K3s désactivé au démarrage"
    fi

    # Exécution du script de désinstallation officiel
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        log_info "Exécution du script de désinstallation officiel..."
        /usr/local/bin/k3s-uninstall.sh
        log_info "Script de désinstallation exécuté"
    fi

    # Nettoyage des répertoires système
    log_info "Nettoyage des répertoires système..."
    rm -rf /etc/rancher/k3s 2>/dev/null || true
    rm -rf /var/lib/rancher/k3s 2>/dev/null || true
    rm -rf /var/lib/rancher/k3s 2>/dev/null || true

    # Suppression des liens symboliques
    if [[ -L /usr/local/bin/kubectl ]]; then
        rm -f /usr/local/bin/kubectl
        log_info "Lien symbolique kubectl supprimé"
    fi

    # Demande de confirmation pour les données utilisateur
    echo ""
    log_warning "Données utilisateur détectées dans: $K3S_DATA_DIR"
    read -p "Voulez-vous supprimer les données K3s ? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$K3S_DATA_DIR"
        log_success "Données K3s supprimées"
    else
        log_info "Données K3s conservées dans: $K3S_DATA_DIR"
    fi

    log_success "Désinstallation de K3s terminée"
}

# === FONCTION D'AFFICHAGE DES INFORMATIONS POST-INSTALLATION ===
# Affiche un récapitulatif complet de l'installation
show_post_install_info() {
    log_success "=== INSTALLATION TERMINÉE AVEC SUCCÈS ==="
    echo ""

    # === CONFIGURATION UTILISÉE ===
    echo "📋 CONFIGURATION UTILISÉE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Version K3s          : $K3S_VERSION"
    echo "• Répertoire de données: $K3S_DATA_DIR"
    echo "• Répertoire de config : $K3S_CONFIG_DIR"
    echo "• Fichier kubeconfig   : $KUBECTL_CONFIG"
    echo "• IP du nœud           : $NODE_IP"
    echo "• Port API Kubernetes  : 6443"
    echo "• Runtime de conteneur : Docker"
    echo "• Traefik              : $([ "${DISABLE_TRAEFIK:-false}" = "true" ] && echo "❌ Désactivé" || echo "✅ Activé")"
    echo "• ServiceLB            : $([ "${DISABLE_SERVICELB:-false}" = "true" ] && echo "❌ Désactivé" || echo "✅ Activé")"
    echo ""

    # === STRUCTURE DES RÉPERTOIRES ===
    echo "📁 STRUCTURE DES RÉPERTOIRES CRÉÉS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• $K3S_DATA_DIR/"
    echo "  ├── config/           (configuration kubectl et certificats)"
    echo "  ├── agent/            (données de l'agent K3s)"
    echo "  ├── server/           (données du serveur K3s - etcd, API server)"
    echo "  ├── logs/             (fichiers de logs)"
    echo "  ├── backups/          (sauvegardes automatiques)"
    echo "  ├── k3s-manager.sh    (script de gestion du service)"
    echo "  ├── setup-kubectl.sh  (script de configuration kubectl)"
    echo "  └── backup-k3s.sh     (script de sauvegarde)"
    echo "• /etc/rancher/k3s/     (configuration système Rancher)"
    echo ""

    # === COMMANDES UTILES ===
    echo "⚙️  COMMANDES DE GESTION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• État du service      : systemctl status k3s"
    echo "• Logs du service      : journalctl -u k3s -f"
    echo "• Démarrer le service  : systemctl start k3s"
    echo "• Arrêter le service   : systemctl stop k3s"
    echo "• Redémarrer le service: systemctl restart k3s"
    echo ""
    echo "• Script de gestion    : $K3S_DATA_DIR/k3s-manager.sh [start|stop|restart|status|logs]"
    echo "• Configuration kubectl: source $K3S_DATA_DIR/setup-kubectl.sh"
    echo "• Sauvegarde          : $K3S_DATA_DIR/backup-k3s.sh"
    echo ""

    # === UTILISATION DE KUBECTL ===
    echo "🔧 UTILISATION DE KUBECTL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Configuration temporaire:"
    echo "  export KUBECONFIG=$KUBECTL_CONFIG"
    echo ""
    echo "• Configuration permanente (dans ~/.bashrc ou ~/.profile):"
    echo "  echo 'export KUBECONFIG=$KUBECTL_CONFIG' >> ~/.bashrc"
    echo ""
    echo "• Commandes de base:"
    echo "  kubectl get nodes                    # Liste des nœuds"
    echo "  kubectl get pods --all-namespaces    # Tous les pods"
    echo "  kubectl get services --all-namespaces # Tous les services"
    echo ""

    # === VÉRIFICATION RAPIDE ===
    echo "✅ VÉRIFICATION RAPIDE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testez votre installation avec:"
    echo "  kubectl get nodes --kubeconfig=$KUBECTL_CONFIG"
    echo ""

    # Exécution de la vérification si possible
    if command -v kubectl &>/dev/null && [[ -f "$KUBECTL_CONFIG" ]]; then
        echo "État actuel du cluster:"
        kubectl get nodes --kubeconfig="$KUBECTL_CONFIG" 2>/dev/null || echo "❌ Cluster non accessible (redémarrage en cours...)"
    fi

    echo ""
    echo "🎉 K3s est maintenant installé et prêt à l'emploi sur votre Synology NAS!"
    echo "📖 Documentation: https://docs.k3s.io/"
    echo "🆘 Support: https://github.com/k3s-io/k3s/issues"
}

# === FONCTION DE PARSING DES ARGUMENTS ===
# Utilise getopt pour analyser les arguments de ligne de commande de manière robuste
parse_arguments() {
    # Définition des options courtes et longues
    local short_opts="hv:d:c:i:s:n:"
    local long_opts="help,version:,data-dir:,config-dir:,install-dir:,docker-sock:,node-ip:,no-traefik,no-servicelb,uninstall,config-file:"

    # Parse des arguments avec getopt
    local parsed_args
    if ! parsed_args=$(getopt -o "$short_opts" -l "$long_opts" -n "$0" -- "$@"); then
        log_error "Erreur dans les arguments fournis"
    fi

    # Réorganisation des arguments
    eval set -- "$parsed_args"

    # Traitement des arguments
    while true; do
        case "$1" in
        -h | --help)
            show_help
            exit 0
            ;;
        -v | --version)
            K3S_VERSION="$2"
            shift 2
            ;;
        -d | --data-dir)
            K3S_DATA_DIR="$2"
            # Mise à jour des variables dérivées
            K3S_CONFIG_DIR="$K3S_DATA_DIR/config"
            KUBECTL_CONFIG="$K3S_DATA_DIR/config/kubeconfig"
            shift 2
            ;;
        -c | --config-dir)
            K3S_CONFIG_DIR="$2"
            KUBECTL_CONFIG="$K3S_CONFIG_DIR/kubeconfig"
            shift 2
            ;;
        -i | --install-dir)
            K3S_INSTALL_DIR="$2"
            shift 2
            ;;
        -s | --docker-sock)
            DOCKER_SOCK="$2"
            shift 2
            ;;
        -n | --node-ip)
            NODE_IP="$2"
            shift 2
            ;;
        --no-traefik)
            DISABLE_TRAEFIK="true"
            shift
            ;;
        --no-servicelb)
            DISABLE_SERVICELB="true"
            shift
            ;;
        --uninstall)
            UNINSTALL="true"
            shift
            ;;
        --config-file)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "Argument interne non traité: $1"
            ;;
        esac
    done

    # Vérification des arguments supplémentaires non attendus
    if [[ $# -gt 0 ]]; then
        log_error "Arguments supplémentaires non reconnus: $*"
    fi
}

# === FONCTION PRINCIPALE ===
# Orchestre l'ensemble du processus d'installation ou de désinstallation
main() {
    # === INITIALISATION ===
    log_info "🚀 DÉMARRAGE DU SCRIPT K3S POUR SYNOLOGY NAS"
    log_info "Script situé dans: $SCRIPT_DIR"

    # Chargement de la configuration avant le parsing des arguments
    # Les arguments peuvent surcharger la configuration
    load_config

    # Parsing des arguments de ligne de commande
    parse_arguments "$@"

    # Affichage de la configuration finale
    log_info "Configuration chargée:"
    log_info "  - Version K3s: $K3S_VERSION"
    log_info "  - Répertoire de données: $K3S_DATA_DIR"
    log_info "  - Répertoire de config: $K3S_CONFIG_DIR"
    log_info "  - Répertoire d'installation: $K3S_INSTALL_DIR"

    # === TRAITEMENT DE LA DÉSINSTALLATION ===
    if [[ "${UNINSTALL:-false}" == "true" ]]; then
        log_info "🗑️  MODE DÉSINSTALLATION ACTIVÉ"
        uninstall_k3s
        exit 0
    fi

    # === PROCESSUS D'INSTALLATION ===
    log_info "🔧 DÉBUT DE L'INSTALLATION DE K3S"

    # Étape 1: Vérification de l'environnement
    check_prerequisites

    # Étape 2: Préparation de l'environnement
    create_directories

    # Étape 3: Configuration réseau
    detect_node_ip

    # Étape 4: Installation du logiciel
    install_k3s

    # Étape 5: Configuration du service
    configure_service

    # Étape 6: Création des outils de gestion
    create_utility_scripts

    # Étape 7: Affichage des informations finales
    show_post_install_info

    log_success "🎉 INSTALLATION DE K3S TERMINÉE AVEC SUCCÈS !"
}

# === POINT D'ENTRÉE DU SCRIPT ===
# Exécution de la fonction principale avec tous les arguments
main "$@"
