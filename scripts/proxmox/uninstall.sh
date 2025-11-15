#!/bin/bash
#
# ========================================================================================
# Script de Désinstallation pour Panel IPTV
# ========================================================================================
# Ce script désinstalle proprement le panel IPTV:
# - Arrêt des conteneurs Docker
# - Suppression des conteneurs et images
# - Suppression des volumes (optionnel)
# - Nettoyage des fichiers de configuration (optionnel)
# - Préservation des sauvegardes
#
# USAGE:
#   ./uninstall.sh [--keep-data] [--keep-backups]
#
# ========================================================================================

set -euo pipefail

# ========================================================================================
# CONFIGURATION
# ========================================================================================

INSTALL_DIR="/opt/IpTvPanel_Docker_Complet"
BACKUP_DIR="/opt/backups/iptv"
LOG_FILE="/var/log/iptv-panel/uninstall.log"

# Options
KEEP_DATA=false
KEEP_BACKUPS=false
KEEP_CONFIG=false

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ========================================================================================
# FONCTIONS UTILITAIRES
# ========================================================================================

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}✅ $*${NC}"
    log "SUCCESS: $*"
}

print_error() {
    echo -e "${RED}❌ $*${NC}" >&2
    log "ERROR: $*"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
    log "WARNING: $*"
}

print_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
    log "INFO: $*"
}

print_section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$*${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ========================================================================================
# FONCTIONS DE DÉSINSTALLATION
# ========================================================================================

# Créer une sauvegarde finale avant désinstallation
create_final_backup() {
    print_section "Sauvegarde Finale (Optionnelle)"
    
    read -p "Voulez-vous créer une sauvegarde finale avant la désinstallation? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Sauvegarde ignorée"
        return
    fi
    
    local backup_script="$INSTALL_DIR/scripts/proxmox/backup_iptv.sh"
    
    if [ -f "$backup_script" ]; then
        print_info "Création de la sauvegarde finale..."
        bash "$backup_script" || print_warning "La sauvegarde a échoué"
    else
        print_warning "Script de sauvegarde non trouvé"
    fi
}

# Arrêter les conteneurs Docker
stop_containers() {
    print_section "Arrêt des Conteneurs Docker"
    
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        
        if docker compose ps --quiet 2>/dev/null | grep -q .; then
            print_info "Arrêt des conteneurs..."
            docker compose down || print_warning "Certains conteneurs n'ont pas pu être arrêtés"
            print_success "Conteneurs arrêtés"
        else
            print_info "Aucun conteneur en cours d'exécution"
        fi
    else
        print_warning "Répertoire d'installation introuvable"
    fi
}

# Supprimer les conteneurs et images
remove_containers_and_images() {
    print_section "Suppression des Conteneurs et Images"
    
    # Supprimer les conteneurs
    local containers=$(docker ps -a --filter "name=iptv_" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        print_info "Suppression des conteneurs..."
        echo "$containers" | xargs docker rm -f 2>/dev/null || true
        print_success "Conteneurs supprimés"
    else
        print_info "Aucun conteneur à supprimer"
    fi
    
    # Supprimer les images
    print_info "Voulez-vous supprimer les images Docker?"
    read -p "Cela libérera de l'espace disque mais nécessitera un nouveau téléchargement en cas de réinstallation (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local images=$(docker images --filter "reference=*iptv*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)
        if [ -n "$images" ]; then
            print_info "Suppression des images..."
            echo "$images" | xargs docker rmi -f 2>/dev/null || true
            print_success "Images supprimées"
        else
            print_info "Aucune image à supprimer"
        fi
    fi
}

# Supprimer les volumes Docker
remove_volumes() {
    print_section "Suppression des Volumes Docker"
    
    if [ "$KEEP_DATA" = true ]; then
        print_warning "Conservation des données demandée, volumes préservés"
        return
    fi
    
    local volumes=$(docker volume ls --filter "name=iptv" --format "{{.Name}}" 2>/dev/null || true)
    
    if [ -z "$volumes" ]; then
        print_info "Aucun volume à supprimer"
        return
    fi
    
    print_warning "Les volumes suivants seront supprimés:"
    echo "$volumes" | while read vol; do
        echo "  - $vol"
    done
    
    echo ""
    print_warning "⚠️  ATTENTION: Cela supprimera définitivement:"
    print_warning "   - La base de données PostgreSQL"
    print_warning "   - Les certificats SSL"
    print_warning "   - Toutes les données persistantes"
    echo ""
    
    read -p "Êtes-vous sûr de vouloir supprimer les volumes? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Suppression des volumes..."
        echo "$volumes" | xargs docker volume rm -f 2>/dev/null || true
        print_success "Volumes supprimés"
    else
        print_info "Volumes préservés"
        KEEP_DATA=true
    fi
}

# Supprimer les fichiers d'installation
remove_installation_files() {
    print_section "Suppression des Fichiers d'Installation"
    
    if [ "$KEEP_CONFIG" = true ]; then
        print_warning "Conservation de la configuration demandée"
        
        # Conserver uniquement .env et docker-compose.yml
        if [ -d "$INSTALL_DIR" ]; then
            local config_backup="/tmp/iptv_config_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$config_backup"
            
            cp "$INSTALL_DIR/.env" "$config_backup/" 2>/dev/null || true
            cp "$INSTALL_DIR/docker-compose.yml" "$config_backup/" 2>/dev/null || true
            
            print_info "Configuration sauvegardée dans: $config_backup"
        fi
    fi
    
    if [ -d "$INSTALL_DIR" ]; then
        print_warning "Suppression du répertoire: $INSTALL_DIR"
        
        read -p "Confirmer la suppression? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            print_success "Fichiers d'installation supprimés"
        else
            print_info "Fichiers d'installation préservés"
        fi
    else
        print_info "Répertoire d'installation déjà absent"
    fi
}

# Gérer les sauvegardes
handle_backups() {
    print_section "Gestion des Sauvegardes"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_info "Aucune sauvegarde trouvée"
        return
    fi
    
    local backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "inconnu")
    local backup_count=$(find "$BACKUP_DIR" -name "iptv_panel_backup_*.tar.gz" -type f 2>/dev/null | wc -l)
    
    print_info "Sauvegardes trouvées: $backup_count fichier(s) ($backup_size)"
    print_info "Emplacement: $BACKUP_DIR"
    
    if [ "$KEEP_BACKUPS" = true ]; then
        print_success "Sauvegardes préservées"
        return
    fi
    
    echo ""
    read -p "Voulez-vous supprimer les sauvegardes? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$BACKUP_DIR"
        print_success "Sauvegardes supprimées"
    else
        print_success "Sauvegardes préservées"
    fi
}

# Nettoyer les logs
clean_logs() {
    print_section "Nettoyage des Logs"
    
    local log_dir="/var/log/iptv-panel"
    
    if [ -d "$log_dir" ]; then
        local log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1 || echo "inconnu")
        print_info "Logs trouvés: $log_size"
        
        read -p "Supprimer les logs? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Garder le log de désinstallation
            find "$log_dir" -type f ! -name "uninstall.log" -delete 2>/dev/null || true
            print_success "Logs nettoyés (uninstall.log conservé)"
        else
            print_info "Logs préservés"
        fi
    else
        print_info "Aucun log à nettoyer"
    fi
}

# Nettoyer les entrées cron
clean_cron_jobs() {
    print_section "Nettoyage des Tâches Cron"
    
    # Chercher les tâches cron liées au panel IPTV
    local cron_entries=$(crontab -l 2>/dev/null | grep -i "iptv" || true)
    
    if [ -z "$cron_entries" ]; then
        print_info "Aucune tâche cron trouvée"
        return
    fi
    
    print_warning "Tâches cron détectées:"
    echo "$cron_entries" | while read line; do
        echo "  $line"
    done
    
    echo ""
    read -p "Voulez-vous les supprimer? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        crontab -l 2>/dev/null | grep -v -i "iptv" | crontab - 2>/dev/null || true
        print_success "Tâches cron supprimées"
    else
        print_info "Tâches cron préservées"
    fi
}

# Afficher le résumé
display_summary() {
    print_section "Résumé de la Désinstallation"
    
    cat <<EOF

${GREEN}✅ Désinstallation terminée${NC}

${BOLD}Éléments supprimés:${NC}
✓ Conteneurs Docker arrêtés
✓ Images Docker (selon choix)
✓ Volumes Docker (selon choix)
✓ Fichiers d'installation (selon choix)

${BOLD}Éléments préservés:${NC}
EOF

    if [ "$KEEP_DATA" = true ]; then
        echo "✓ Volumes de données"
    fi
    
    if [ "$KEEP_BACKUPS" = true ] || [ -d "$BACKUP_DIR" ]; then
        echo "✓ Sauvegardes ($BACKUP_DIR)"
    fi
    
    if [ -f "$LOG_FILE" ]; then
        echo "✓ Log de désinstallation ($LOG_FILE)"
    fi
    
    cat <<EOF

${CYAN}Pour réinstaller le panel:${NC}
  bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)

${CYAN}Pour nettoyer complètement Docker:${NC}
  docker system prune -a --volumes

EOF
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

main() {
    clear
    cat <<EOF
${BOLD}${RED}
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║        DÉSINSTALLATION PANEL IPTV                        ║
║                                                           ║
║        ⚠️  ATTENTION: Cette action est irréversible       ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
${NC}

EOF

    log "=== Début de la désinstallation ==="
    
    # Afficher les avertissements
    print_warning "Cette opération va:"
    echo "  • Arrêter tous les conteneurs du panel IPTV"
    echo "  • Supprimer les conteneurs et images Docker"
    echo "  • Supprimer les volumes (base de données, certificats)"
    echo "  • Supprimer les fichiers d'installation"
    echo ""
    
    print_info "Options de préservation:"
    if [ "$KEEP_DATA" = true ]; then
        echo "  ✓ Les données seront préservées (--keep-data)"
    fi
    if [ "$KEEP_BACKUPS" = true ]; then
        echo "  ✓ Les sauvegardes seront préservées (--keep-backups)"
    fi
    echo ""
    
    # Demander confirmation
    read -p "Êtes-vous sûr de vouloir désinstaller le Panel IPTV? (yes/NO) " -r
    echo
    if [[ ! $REPLY = "yes" ]]; then
        print_info "Désinstallation annulée"
        exit 0
    fi
    
    # Effectuer la désinstallation
    create_final_backup
    stop_containers
    remove_containers_and_images
    remove_volumes
    remove_installation_files
    handle_backups
    clean_logs
    clean_cron_jobs
    
    # Afficher le résumé
    display_summary
    
    log "=== Désinstallation terminée ==="
}

# ========================================================================================
# GESTION DES ARGUMENTS
# ========================================================================================

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --keep-data              Préserver les volumes de données
  --keep-backups           Préserver les sauvegardes
  --keep-config            Sauvegarder la configuration (.env)
  --help                   Afficher cette aide

Exemples:
  # Désinstallation complète (interactive)
  $0

  # Désinstaller en gardant les données
  $0 --keep-data

  # Désinstaller en gardant les sauvegardes
  $0 --keep-backups

  # Désinstaller en gardant données et sauvegardes
  $0 --keep-data --keep-backups

Avertissement:
  Sans --keep-data, toutes les données de la base de données
  et les certificats SSL seront définitivement supprimés.

EOF
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
        --keep-backups)
            KEEP_BACKUPS=true
            shift
            ;;
        --keep-config)
            KEEP_CONFIG=true
            shift
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

# Vérifier les droits root
if [ "$EUID" -ne 0 ]; then
    print_error "Ce script doit être exécuté en tant que root (sudo)"
    exit 1
fi

# Point d'entrée
main
