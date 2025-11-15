#!/bin/bash
#
# ========================================================================================
# Script d'Installation Automatique du Panel IPTV pour Proxmox
# ========================================================================================
# Ce script automatise le déploiement complet du Panel IPTV sur Proxmox (VM ou LXC)
# avec configuration locale et nom de domaine personnalisé.
#
# USAGE:
#   Installation interactive:
#     bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)
#
#   Installation silencieuse:
#     ./install_proxmox.sh --silent \
#       --domain panel.example.com \
#       --admin-password "SecurePass123!" \
#       --db-password "DBPass456!" \
#       --email admin@example.com
#
# ========================================================================================

set -euo pipefail

# ========================================================================================
# VARIABLES GLOBALES
# ========================================================================================

VERSION="1.0.0"
LOG_FILE="/var/log/iptv-panel-install.log"
INSTALL_DIR="/opt/IpTvPanel_Docker_Complet"
BACKUP_DIR="/opt/backups/iptv"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Mode d'installation
SILENT_MODE=false
DOMAIN=""
ADMIN_PASSWORD=""
DB_PASSWORD=""
EMAIL=""

# ========================================================================================
# FONCTIONS UTILITAIRES
# ========================================================================================

# Logger les messages dans un fichier
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Afficher un message de succès
print_success() {
    echo -e "${GREEN}✅ $*${NC}"
    log "SUCCESS: $*"
}

# Afficher un message d'erreur
print_error() {
    echo -e "${RED}❌ $*${NC}" >&2
    log "ERROR: $*"
}

# Afficher un message d'avertissement
print_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
    log "WARNING: $*"
}

# Afficher un message d'information
print_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
    log "INFO: $*"
}

# Afficher une section
print_section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$*${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "SECTION: $*"
}

# Gestion des erreurs avec nettoyage
error_exit() {
    print_error "$1"
    print_error "Installation échouée. Consultez le log: $LOG_FILE"
    exit 1
}

# Gestion de Ctrl+C
trap_ctrlc() {
    print_warning "\nInstallation annulée par l'utilisateur."
    exit 130
}

trap trap_ctrlc INT

# ========================================================================================
# FONCTIONS DE VALIDATION
# ========================================================================================

# Valider le format d'un email
validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Valider le format d'un nom de domaine
validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?\.[a-zA-Z]{2,}$ ]] && \
       [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Valider la force d'un mot de passe
validate_password() {
    local password=$1
    if [ ${#password} -lt 8 ]; then
        return 1
    fi
    return 0
}

# ========================================================================================
# FONCTIONS DE DÉTECTION SYSTÈME
# ========================================================================================

# Détecter l'environnement (VM ou LXC)
detect_environment() {
    print_section "Détection de l'environnement"
    
    if [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ 2>/dev/null; then
        print_info "Environnement détecté: Conteneur LXC Proxmox"
        echo "lxc"
    elif systemd-detect-virt -q -c; then
        print_info "Environnement détecté: Conteneur"
        echo "container"
    elif systemd-detect-virt -q -v; then
        print_info "Environnement détecté: Machine Virtuelle"
        echo "vm"
    else
        print_info "Environnement détecté: Machine physique"
        echo "physical"
    fi
}

# Détecter la distribution Linux
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        error_exit "Impossible de détecter la distribution Linux"
    fi
}

# Vérifier l'architecture
check_architecture() {
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]] && [[ "$arch" != "aarch64" ]] && [[ "$arch" != "arm64" ]]; then
        error_exit "Architecture non supportée: $arch. Seuls x86_64 et ARM64 sont supportés."
    fi
    print_success "Architecture supportée: $arch"
}

# ========================================================================================
# FONCTIONS DE VÉRIFICATION DES PRÉREQUIS
# ========================================================================================

# Vérifier les droits root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Ce script doit être exécuté en tant que root (sudo)"
    fi
}

# Vérifier l'espace disque disponible
check_disk_space() {
    print_info "Vérification de l'espace disque..."
    local available_space=$(df / | tail -1 | awk '{print $4}')
    local required_space=$((10 * 1024 * 1024)) # 10 GB en KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        error_exit "Espace disque insuffisant. Requis: 10GB, Disponible: $(($available_space / 1024 / 1024))GB"
    fi
    print_success "Espace disque suffisant"
}

# Vérifier les ports disponibles
check_ports() {
    print_info "Vérification des ports disponibles..."
    local ports_to_check=(80 443 5432 6379)
    local ports_in_use=()
    
    for port in "${ports_to_check[@]}"; do
        if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
            ports_in_use+=($port)
        fi
    done
    
    if [ ${#ports_in_use[@]} -gt 0 ]; then
        print_warning "Ports déjà utilisés: ${ports_in_use[*]}"
        if [ "$SILENT_MODE" = false ]; then
            read -p "Continuer quand même? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        print_success "Tous les ports nécessaires sont disponibles"
    fi
}

# ========================================================================================
# FONCTIONS D'INSTALLATION DES DÉPENDANCES
# ========================================================================================

# Installer Docker
install_docker() {
    print_section "Installation de Docker"
    
    if command -v docker &> /dev/null; then
        print_info "Docker est déjà installé: $(docker --version)"
        return 0
    fi
    
    print_info "Installation de Docker..."
    
    # Installer les prérequis
    apt-get update -qq || error_exit "Échec de la mise à jour des paquets"
    apt-get install -y -qq ca-certificates curl gnupg lsb-release || error_exit "Échec de l'installation des prérequis"
    
    # Ajouter la clé GPG de Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(detect_distro)/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Ajouter le dépôt Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(detect_distro) \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Installer Docker
    apt-get update -qq || error_exit "Échec de la mise à jour des dépôts Docker"
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error_exit "Échec de l'installation de Docker"
    
    # Démarrer Docker
    systemctl enable docker
    systemctl start docker
    
    print_success "Docker installé avec succès: $(docker --version)"
}

# Installer Docker Compose (version standalone si nécessaire)
install_docker_compose() {
    print_section "Vérification de Docker Compose"
    
    if docker compose version &> /dev/null; then
        print_info "Docker Compose est disponible: $(docker compose version)"
        return 0
    fi
    
    if command -v docker-compose &> /dev/null; then
        print_info "Docker Compose (standalone) est disponible: $(docker-compose --version)"
        return 0
    fi
    
    print_info "Installation de Docker Compose..."
    local compose_version="v2.23.0"
    local arch=$(uname -m)
    
    curl -SL "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${arch}" \
        -o /usr/local/bin/docker-compose || error_exit "Échec du téléchargement de Docker Compose"
    
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose installé avec succès"
}

# Installer les outils nécessaires
install_tools() {
    print_section "Installation des outils système"
    
    local tools=(curl wget git net-tools netcat openssl)
    print_info "Installation des outils: ${tools[*]}"
    
    apt-get update -qq || error_exit "Échec de la mise à jour des paquets"
    apt-get install -y -qq "${tools[@]}" || error_exit "Échec de l'installation des outils"
    
    print_success "Outils système installés"
}

# ========================================================================================
# FONCTIONS DE CONFIGURATION
# ========================================================================================

# Demander les informations à l'utilisateur (mode interactif)
prompt_user_input() {
    print_section "Configuration du Panel IPTV"
    
    # Nom de domaine
    while true; do
        read -p "Nom de domaine (ex: panel.mondomaine.com): " DOMAIN
        if validate_domain "$DOMAIN"; then
            break
        else
            print_error "Format de domaine invalide. Veuillez réessayer."
        fi
    done
    
    # Email
    while true; do
        read -p "Email pour les notifications: " EMAIL
        if validate_email "$EMAIL"; then
            break
        else
            print_error "Format d'email invalide. Veuillez réessayer."
        fi
    done
    
    # Mot de passe admin
    while true; do
        read -s -p "Mot de passe administrateur (min 8 caractères): " ADMIN_PASSWORD
        echo
        if validate_password "$ADMIN_PASSWORD"; then
            read -s -p "Confirmez le mot de passe administrateur: " ADMIN_PASSWORD_CONFIRM
            echo
            if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
                break
            else
                print_error "Les mots de passe ne correspondent pas. Veuillez réessayer."
            fi
        else
            print_error "Mot de passe trop faible (minimum 8 caractères)."
        fi
    done
    
    # Mot de passe base de données
    while true; do
        read -s -p "Mot de passe base de données (min 8 caractères, ou Entrée pour générer): " DB_PASSWORD
        echo
        if [ -z "$DB_PASSWORD" ]; then
            DB_PASSWORD=$(openssl rand -hex 16)
            print_info "Mot de passe base de données généré automatiquement"
            break
        elif validate_password "$DB_PASSWORD"; then
            break
        else
            print_error "Mot de passe trop faible (minimum 8 caractères)."
        fi
    done
    
    # Afficher le résumé
    echo ""
    print_info "Configuration:"
    echo "  Domaine: $DOMAIN"
    echo "  Email: $EMAIL"
    echo "  Mot de passe admin: $(echo "$ADMIN_PASSWORD" | sed 's/./*/g')"
    echo "  Mot de passe DB: $(echo "$DB_PASSWORD" | sed 's/./*/g')"
    echo ""
    
    read -p "Confirmer et continuer? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
}

# Créer le fichier .env
create_env_file() {
    print_section "Configuration de l'environnement"
    
    local env_file="$INSTALL_DIR/.env"
    local secret_key=$(openssl rand -hex 32)
    local api_token=$(openssl rand -hex 32)
    
    print_info "Création du fichier .env..."
    
    cat > "$env_file" <<EOF
# IPTV Panel Docker Environment Configuration
# Généré automatiquement le $(date)

# --- Domain & SSL ---
PANEL_DOMAIN=$DOMAIN
CERTBOT_EMAIL=$EMAIL

# --- Database Settings ---
DB_NAME=iptv_panel
DB_USER=iptv_admin
DB_PASS=$DB_PASSWORD

# --- Application Settings ---
SECRET_KEY=$secret_key
ADMIN_PASSWORD=$ADMIN_PASSWORD
ADMIN_API_TOKEN=$api_token

# --- Optional: Streaming Server ---
STREAM_DOMAIN=
STREAM_SERVER_IP=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=
STREAMING_API_BASE_URL=
STREAMING_API_TOKEN=
STREAMING_API_TIMEOUT=10
STREAMING_SERVER_USER=
STREAMING_SERVER_PASS=
EOF
    
    chmod 600 "$env_file"
    print_success "Fichier .env créé avec succès"
}

# ========================================================================================
# FONCTIONS DE DÉPLOIEMENT
# ========================================================================================

# Cloner ou mettre à jour le dépôt
setup_repository() {
    print_section "Configuration du dépôt"
    
    if [ -d "$INSTALL_DIR" ]; then
        print_warning "Le répertoire $INSTALL_DIR existe déjà"
        if [ "$SILENT_MODE" = false ]; then
            read -p "Voulez-vous le sauvegarder et continuer? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local backup_name="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                mv "$INSTALL_DIR" "$backup_name"
                print_info "Sauvegarde créée: $backup_name"
            else
                exit 0
            fi
        fi
    fi
    
    print_info "Clonage du dépôt..."
    git clone https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet.git "$INSTALL_DIR" || error_exit "Échec du clonage du dépôt"
    cd "$INSTALL_DIR"
    
    print_success "Dépôt configuré"
}

# Créer les répertoires nécessaires
create_directories() {
    print_info "Création des répertoires..."
    
    mkdir -p "$BACKUP_DIR"
    mkdir -p /var/log/iptv-panel
    
    print_success "Répertoires créés"
}

# Déployer les conteneurs Docker
deploy_containers() {
    print_section "Déploiement des conteneurs Docker"
    
    cd "$INSTALL_DIR"
    
    print_info "Construction et démarrage des conteneurs..."
    docker compose up -d --build || error_exit "Échec du déploiement des conteneurs"
    
    print_info "Attente du démarrage complet des services (60 secondes)..."
    sleep 60
    
    print_success "Conteneurs déployés"
}

# Créer le compte administrateur
create_admin_account() {
    print_section "Création du compte administrateur"
    
    cd "$INSTALL_DIR"
    
    print_info "Création de l'utilisateur admin..."
    
    # Attendre que la base de données soit prête
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T db pg_isready -U iptv_admin -d iptv_panel &>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    # Créer le compte admin via le conteneur panel
    docker compose exec -T panel python3 -c "
from app import app, db
from database.models import Admin
import sys

with app.app_context():
    try:
        # Vérifier si admin existe déjà
        existing_admin = Admin.query.filter_by(username='admin').first()
        if existing_admin:
            print('Admin existe déjà, mise à jour du mot de passe...')
            existing_admin.set_password('$ADMIN_PASSWORD')
            existing_admin.email = '$EMAIL'
        else:
            print('Création du compte admin...')
            admin = Admin(username='admin', email='$EMAIL')
            admin.set_password('$ADMIN_PASSWORD')
            db.session.add(admin)
        
        db.session.commit()
        print('✅ Compte admin créé/mis à jour avec succès')
    except Exception as e:
        print(f'❌ Erreur: {e}', file=sys.stderr)
        sys.exit(1)
" || print_warning "Impossible de créer le compte admin automatiquement. Vous devrez le créer manuellement."
    
    print_success "Compte administrateur configuré"
}

# Générer un certificat SSL auto-signé
generate_self_signed_cert() {
    print_section "Génération du certificat SSL"
    
    print_info "Génération d'un certificat SSL auto-signé..."
    
    local cert_dir="$INSTALL_DIR/docker/letsencrypt/live/$DOMAIN"
    mkdir -p "$cert_dir"
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/C=FR/ST=France/L=Paris/O=IPTV Panel/CN=$DOMAIN" \
        2>/dev/null || print_warning "Impossible de générer le certificat SSL auto-signé"
    
    # Redémarrer nginx pour prendre en compte le certificat
    docker compose restart nginx 2>/dev/null
    
    print_success "Certificat SSL auto-signé généré"
    print_warning "Pour un certificat valide, configurez Let's Encrypt après l'installation"
}

# ========================================================================================
# FONCTION D'AFFICHAGE DU RÉSUMÉ
# ========================================================================================

display_summary() {
    print_section "Installation terminée avec succès!"
    
    local server_ip=$(hostname -I | awk '{print $1}')
    
    cat <<EOF

${GREEN}✅ Installation terminée avec succès!${NC}

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}📋 INFORMATIONS DE CONNEXION${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
🌐 URL Panel:     https://$DOMAIN
   IP directe:    http://$server_ip
👤 Username:      admin
🔑 Password:      $ADMIN_PASSWORD
📧 Email:         $EMAIL

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}📊 SERVICES${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF

    # Vérifier l'état des services
    cd "$INSTALL_DIR"
    docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" | tail -n +2 | while read line; do
        echo "  $line"
    done

    cat <<EOF

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}📁 FICHIERS IMPORTANTS${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
Config:           $INSTALL_DIR/.env
Logs:             /var/log/iptv-panel/
Backups:          $BACKUP_DIR
Installation:     $LOG_FILE

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}🔧 COMMANDES UTILES${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
Monitoring:       $INSTALL_DIR/scripts/proxmox/monitor_panel.sh
Backup:           $INSTALL_DIR/scripts/proxmox/backup_iptv.sh
Update:           $INSTALL_DIR/scripts/proxmox/update_panel.sh
Logs:             cd $INSTALL_DIR && docker compose logs -f
Restart:          cd $INSTALL_DIR && docker compose restart
Stop:             cd $INSTALL_DIR && docker compose stop
Start:            cd $INSTALL_DIR && docker compose start

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}⚠️  PROCHAINES ÉTAPES${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
1. ${YELLOW}Configurer votre DNS/hosts pour pointer vers $server_ip${NC}
   Utilisez: $INSTALL_DIR/scripts/proxmox/configure_dns.sh

2. ${YELLOW}Accepter le certificat SSL auto-signé dans votre navigateur${NC}
   Ou configurer Let's Encrypt pour un certificat valide

3. ${YELLOW}Se connecter et changer le mot de passe admin${NC}
   URL: https://$DOMAIN

4. ${YELLOW}Configurer le cron pour les sauvegardes automatiques${NC}
   Exemple: 0 2 * * * $INSTALL_DIR/scripts/proxmox/backup_iptv.sh

5. ${YELLOW}Importer vos playlists M3U${NC}
   Via l'interface web: /channels/import

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}📖 DOCUMENTATION${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
Guide Proxmox:    $INSTALL_DIR/docs/PROXMOX_GUIDE.md
README:           $INSTALL_DIR/README.md

${GREEN}Merci d'utiliser le Panel IPTV!${NC}

EOF

    # Sauvegarder les informations dans un fichier
    local summary_file="$INSTALL_DIR/INSTALLATION_INFO.txt"
    cat > "$summary_file" <<SUMMARY
Panel IPTV - Informations d'installation
=========================================
Date: $(date)

INFORMATIONS DE CONNEXION
--------------------------
URL Panel:     https://$DOMAIN
IP directe:    http://$server_ip
Username:      admin
Password:      $ADMIN_PASSWORD
Email:         $EMAIL

BASE DE DONNÉES
---------------
DB Name:       iptv_panel
DB User:       iptv_admin
DB Password:   $DB_PASSWORD

RÉPERTOIRES
-----------
Installation:  $INSTALL_DIR
Backups:       $BACKUP_DIR
Logs:          /var/log/iptv-panel/

COMMANDES UTILES
----------------
Monitoring:    $INSTALL_DIR/scripts/proxmox/monitor_panel.sh
Backup:        $INSTALL_DIR/scripts/proxmox/backup_iptv.sh
Update:        $INSTALL_DIR/scripts/proxmox/update_panel.sh
SUMMARY

    chmod 600 "$summary_file"
    print_info "Informations sauvegardées dans: $summary_file"
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

main() {
    # Afficher le header
    clear
    cat <<EOF
${BOLD}${CYAN}
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║         INSTALLATION AUTOMATIQUE PANEL IPTV              ║
║              pour Proxmox (VM & LXC)                     ║
║                                                           ║
║                    Version $VERSION                          ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
${NC}

EOF

    # Créer le fichier de log
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    log "=== Début de l'installation ==="
    log "Version: $VERSION"
    log "Date: $(date)"
    
    # Vérifications préalables
    check_root
    check_architecture
    detect_environment
    check_disk_space
    
    # Installation des outils
    install_tools
    install_docker
    install_docker_compose
    
    # Vérifier les ports
    check_ports
    
    # Configuration
    if [ "$SILENT_MODE" = false ]; then
        prompt_user_input
    else
        # Vérifier que tous les paramètres sont fournis en mode silencieux
        if [ -z "$DOMAIN" ] || [ -z "$ADMIN_PASSWORD" ] || [ -z "$DB_PASSWORD" ] || [ -z "$EMAIL" ]; then
            error_exit "En mode silencieux, tous les paramètres doivent être fournis: --domain, --admin-password, --db-password, --email"
        fi
    fi
    
    # Déploiement
    setup_repository
    create_directories
    create_env_file
    deploy_containers
    create_admin_account
    generate_self_signed_cert
    
    # Afficher le résumé
    display_summary
    
    log "=== Installation terminée avec succès ==="
}

# ========================================================================================
# GESTION DES ARGUMENTS
# ========================================================================================

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --silent                  Mode silencieux (non-interactif)
  --domain DOMAIN           Nom de domaine (ex: panel.example.com)
  --admin-password PASS     Mot de passe administrateur
  --db-password PASS        Mot de passe base de données
  --email EMAIL             Email pour les notifications
  --help                    Afficher cette aide

Exemples:
  # Installation interactive
  sudo $0

  # Installation silencieuse
  sudo $0 --silent \\
    --domain panel.example.com \\
    --admin-password "SecurePass123!" \\
    --db-password "DBPass456!" \\
    --email admin@example.com

EOF
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --admin-password)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Option inconnue: $1"
            show_help
            exit 1
            ;;
    esac
done

# ========================================================================================
# POINT D'ENTRÉE
# ========================================================================================

main
