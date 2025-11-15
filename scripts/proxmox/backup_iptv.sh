#!/bin/bash
#
# ========================================================================================
# Script de Sauvegarde Automatique pour Panel IPTV
# ========================================================================================
# Ce script effectue une sauvegarde complète du panel IPTV incluant:
# - Base de données PostgreSQL
# - Fichiers de configuration (.env, docker-compose.yml)
# - Volumes Docker importants
# - Compression et rotation automatique (7 jours)
#
# USAGE:
#   ./backup_iptv.sh [--destination /path/to/backup]
#
# CRON:
#   0 2 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh
#
# ========================================================================================

set -euo pipefail

# ========================================================================================
# CONFIGURATION
# ========================================================================================

INSTALL_DIR="/opt/IpTvPanel_Docker_Complet"
DEFAULT_BACKUP_DIR="/opt/backups/iptv"
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
LOG_DIR="/var/log/iptv-panel"
LOG_FILE="${LOG_DIR}/backup.log"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Notification email (optionnel)
ENABLE_EMAIL_NOTIFICATION=false
NOTIFICATION_EMAIL=""

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ========================================================================================
# FONCTIONS UTILITAIRES
# ========================================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_and_print() {
    echo -e "$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

print_success() {
    log_and_print "${GREEN}✅ $*${NC}"
}

print_error() {
    log_and_print "${RED}❌ $*${NC}" >&2
}

print_warning() {
    log_and_print "${YELLOW}⚠️  $*${NC}"
}

print_info() {
    log_and_print "${BLUE}ℹ️  $*${NC}"
}

print_section() {
    log_and_print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_and_print "$*"
    log_and_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

error_exit() {
    print_error "$1"
    send_notification "ÉCHEC" "La sauvegarde a échoué: $1"
    exit 1
}

# ========================================================================================
# FONCTIONS DE NOTIFICATION
# ========================================================================================

send_notification() {
    local status=$1
    local message=$2
    
    if [ "$ENABLE_EMAIL_NOTIFICATION" = true ] && [ -n "$NOTIFICATION_EMAIL" ]; then
        local subject="Panel IPTV - Sauvegarde ${status}"
        echo "$message" | mail -s "$subject" "$NOTIFICATION_EMAIL" 2>/dev/null || true
    fi
}

# ========================================================================================
# FONCTIONS DE SAUVEGARDE
# ========================================================================================

# Créer les répertoires nécessaires
setup_directories() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "${BACKUP_DIR}/temp_${TIMESTAMP}"
}

# Sauvegarder la base de données PostgreSQL
backup_database() {
    print_section "Sauvegarde de la base de données PostgreSQL"
    
    cd "$INSTALL_DIR"
    
    # Charger les variables d'environnement
    if [ ! -f .env ]; then
        error_exit "Fichier .env introuvable dans $INSTALL_DIR"
    fi
    
    source .env
    
    local backup_file="${BACKUP_DIR}/temp_${TIMESTAMP}/database_${TIMESTAMP}.sql"
    
    print_info "Sauvegarde de la base de données: $DB_NAME"
    
    # Créer le dump de la base de données
    if docker compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" > "$backup_file" 2>/dev/null; then
        local db_size=$(du -h "$backup_file" | cut -f1)
        print_success "Base de données sauvegardée: $db_size"
    else
        error_exit "Échec de la sauvegarde de la base de données"
    fi
    
    # Compresser le dump
    print_info "Compression de la base de données..."
    if gzip -9 "$backup_file"; then
        local compressed_size=$(du -h "${backup_file}.gz" | cut -f1)
        print_success "Base de données compressée: $compressed_size"
    else
        error_exit "Échec de la compression de la base de données"
    fi
}

# Sauvegarder les fichiers de configuration
backup_config_files() {
    print_section "Sauvegarde des fichiers de configuration"
    
    local config_dir="${BACKUP_DIR}/temp_${TIMESTAMP}/config"
    mkdir -p "$config_dir"
    
    # Liste des fichiers à sauvegarder
    local files_to_backup=(
        ".env"
        "docker-compose.yml"
        "docker/nginx/nginx.conf"
        "docker/nginx/app.conf"
    )
    
    cd "$INSTALL_DIR"
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            local dest_dir="$config_dir/$(dirname "$file")"
            mkdir -p "$dest_dir"
            cp -p "$file" "$dest_dir/"
            print_success "Sauvegardé: $file"
        else
            print_warning "Fichier non trouvé: $file"
        fi
    done
}

# Sauvegarder les volumes Docker
backup_docker_volumes() {
    print_section "Sauvegarde des volumes Docker"
    
    local volumes_dir="${BACKUP_DIR}/temp_${TIMESTAMP}/volumes"
    mkdir -p "$volumes_dir"
    
    cd "$INSTALL_DIR"
    
    # Lister les volumes Docker du projet
    local volumes=$(docker compose ps -q | xargs docker inspect --format='{{range .Mounts}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$')
    
    if [ -z "$volumes" ]; then
        print_warning "Aucun volume Docker trouvé"
        return
    fi
    
    for volume in $volumes; do
        print_info "Sauvegarde du volume: $volume"
        
        # Créer une archive du volume
        docker run --rm \
            -v "${volume}:/data:ro" \
            -v "${volumes_dir}:/backup" \
            alpine:latest \
            tar czf "/backup/${volume}_${TIMESTAMP}.tar.gz" -C /data . 2>/dev/null || {
                print_warning "Impossible de sauvegarder le volume: $volume"
                continue
            }
        
        local volume_size=$(du -h "${volumes_dir}/${volume}_${TIMESTAMP}.tar.gz" | cut -f1)
        print_success "Volume sauvegardé: $volume ($volume_size)"
    done
}

# Créer l'archive finale
create_final_archive() {
    print_section "Création de l'archive finale"
    
    local temp_dir="${BACKUP_DIR}/temp_${TIMESTAMP}"
    local archive_name="iptv_panel_backup_${TIMESTAMP}.tar.gz"
    local archive_path="${BACKUP_DIR}/${archive_name}"
    
    print_info "Compression de la sauvegarde..."
    
    cd "$BACKUP_DIR"
    if tar czf "$archive_path" -C "$BACKUP_DIR" "temp_${TIMESTAMP}" 2>/dev/null; then
        local archive_size=$(du -h "$archive_path" | cut -f1)
        print_success "Archive créée: $archive_name ($archive_size)"
        
        # Supprimer le répertoire temporaire
        rm -rf "$temp_dir"
        print_info "Répertoire temporaire nettoyé"
        
        return 0
    else
        error_exit "Échec de la création de l'archive finale"
    fi
}

# Créer un fichier manifest
create_manifest() {
    print_section "Création du manifeste de sauvegarde"
    
    local manifest_file="${BACKUP_DIR}/iptv_panel_backup_${TIMESTAMP}_manifest.txt"
    
    cat > "$manifest_file" <<EOF
Panel IPTV - Manifeste de Sauvegarde
=====================================
Date: $(date)
Timestamp: $TIMESTAMP
Host: $(hostname)

Contenu de la sauvegarde:
-------------------------
✓ Base de données PostgreSQL (compressée)
✓ Fichiers de configuration (.env, docker-compose.yml, etc.)
✓ Volumes Docker

Informations système:
---------------------
OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
Kernel: $(uname -r)
Docker: $(docker --version)
Docker Compose: $(docker compose version)

Emplacement:
------------
Archive: iptv_panel_backup_${TIMESTAMP}.tar.gz
Répertoire: $BACKUP_DIR

Pour restaurer:
---------------
1. Copier l'archive sur le serveur cible
2. Exécuter: tar xzf iptv_panel_backup_${TIMESTAMP}.tar.gz
3. Consulter le guide de restauration

EOF

    print_success "Manifeste créé: $(basename "$manifest_file")"
}

# Rotation des sauvegardes
rotate_backups() {
    print_section "Rotation des sauvegardes"
    
    print_info "Conservation des sauvegardes des $RETENTION_DAYS derniers jours"
    
    # Compter les sauvegardes avant rotation
    local before_count=$(find "$BACKUP_DIR" -name "iptv_panel_backup_*.tar.gz" -type f | wc -l)
    
    # Supprimer les anciennes sauvegardes
    find "$BACKUP_DIR" -name "iptv_panel_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
    find "$BACKUP_DIR" -name "iptv_panel_backup_*_manifest.txt" -type f -mtime +$RETENTION_DAYS -delete
    
    # Compter les sauvegardes après rotation
    local after_count=$(find "$BACKUP_DIR" -name "iptv_panel_backup_*.tar.gz" -type f | wc -l)
    local deleted_count=$((before_count - after_count))
    
    if [ $deleted_count -gt 0 ]; then
        print_success "$deleted_count ancienne(s) sauvegarde(s) supprimée(s)"
    else
        print_info "Aucune sauvegarde expirée"
    fi
    
    print_info "Nombre de sauvegardes conservées: $after_count"
}

# Afficher le résumé
display_summary() {
    print_section "Résumé de la sauvegarde"
    
    local archive_path="${BACKUP_DIR}/iptv_panel_backup_${TIMESTAMP}.tar.gz"
    local archive_size=$(du -h "$archive_path" | cut -f1)
    local backup_count=$(find "$BACKUP_DIR" -name "iptv_panel_backup_*.tar.gz" -type f | wc -l)
    
    cat <<EOF

${GREEN}✅ Sauvegarde terminée avec succès!${NC}

Archive:       iptv_panel_backup_${TIMESTAMP}.tar.gz
Taille:        $archive_size
Emplacement:   $BACKUP_DIR
Sauvegardes:   $backup_count fichier(s)
Retention:     $RETENTION_DAYS jours

Pour restaurer cette sauvegarde:
  cd $BACKUP_DIR
  tar xzf iptv_panel_backup_${TIMESTAMP}.tar.gz
  # Suivez les instructions dans le manifeste

EOF

    send_notification "SUCCÈS" "Sauvegarde terminée avec succès. Taille: $archive_size"
}

# Vérifier l'intégrité de la sauvegarde
verify_backup() {
    print_section "Vérification de l'intégrité"
    
    local archive_path="${BACKUP_DIR}/iptv_panel_backup_${TIMESTAMP}.tar.gz"
    
    print_info "Vérification de l'archive..."
    
    if tar tzf "$archive_path" >/dev/null 2>&1; then
        print_success "Archive valide"
    else
        error_exit "Archive corrompue!"
    fi
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Panel IPTV - Sauvegarde Automatique"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log "=== Début de la sauvegarde ==="
    log "Timestamp: $TIMESTAMP"
    log "Répertoire de destination: $BACKUP_DIR"
    
    # Vérifier les prérequis
    if [ ! -d "$INSTALL_DIR" ]; then
        error_exit "Répertoire d'installation introuvable: $INSTALL_DIR"
    fi
    
    if ! command -v docker &> /dev/null; then
        error_exit "Docker n'est pas installé"
    fi
    
    # Vérifier que les conteneurs sont en cours d'exécution
    cd "$INSTALL_DIR"
    if ! docker compose ps | grep -q "Up"; then
        print_warning "Certains conteneurs ne sont pas en cours d'exécution"
        read -p "Continuer quand même? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    # Créer les répertoires
    setup_directories
    
    # Effectuer les sauvegardes
    backup_database
    backup_config_files
    backup_docker_volumes
    
    # Créer l'archive finale
    create_final_archive
    
    # Créer le manifeste
    create_manifest
    
    # Vérifier l'intégrité
    verify_backup
    
    # Rotation des anciennes sauvegardes
    rotate_backups
    
    # Afficher le résumé
    display_summary
    
    log "=== Sauvegarde terminée avec succès ==="
}

# ========================================================================================
# GESTION DES ARGUMENTS
# ========================================================================================

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --destination DIR         Répertoire de destination des sauvegardes
                           (défaut: $DEFAULT_BACKUP_DIR)
  --retention DAYS         Nombre de jours de rétention (défaut: 7)
  --email ADDRESS          Email pour les notifications d'échec
  --help                   Afficher cette aide

Exemples:
  # Sauvegarde standard
  $0

  # Sauvegarde dans un répertoire personnalisé
  $0 --destination /mnt/nas/backups

  # Sauvegarde avec 14 jours de rétention
  $0 --retention 14

  # Sauvegarde avec notification email
  $0 --email admin@example.com

Configuration cron (sauvegarde quotidienne à 2h):
  0 2 * * * $0 --email admin@example.com >> /var/log/iptv-panel/backup-cron.log 2>&1

EOF
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --destination)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --email)
            ENABLE_EMAIL_NOTIFICATION=true
            NOTIFICATION_EMAIL="$2"
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

# Point d'entrée
main
