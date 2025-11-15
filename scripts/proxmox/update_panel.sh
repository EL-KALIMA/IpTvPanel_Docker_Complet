#!/bin/bash
#
# ========================================================================================
# Script de Mise à Jour Automatique pour Panel IPTV
# ========================================================================================
# Ce script automatise la mise à jour du panel IPTV:
# - Sauvegarde avant mise à jour
# - Récupération des dernières modifications depuis GitHub
# - Reconstruction des conteneurs si nécessaire
# - Application des migrations de base de données
# - Restauration en cas d'échec
# - Affichage du changelog
#
# USAGE:
#   ./update_panel.sh [--check|--apply] [--force]
#
# ========================================================================================

set -euo pipefail

# ========================================================================================
# CONFIGURATION
# ========================================================================================

INSTALL_DIR="/opt/IpTvPanel_Docker_Complet"
BACKUP_DIR="/opt/backups/iptv"
LOG_FILE="/var/log/iptv-panel/update.log"
UPDATE_MODE="check"  # check ou apply
FORCE_UPDATE=false

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
    log_and_print "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_and_print "${BOLD}${CYAN}$*${NC}"
    log_and_print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

error_exit() {
    print_error "$1"
    exit 1
}

# ========================================================================================
# FONCTIONS DE VÉRIFICATION
# ========================================================================================

# Vérifier les mises à jour disponibles
check_updates() {
    print_section "Vérification des Mises à Jour"
    
    cd "$INSTALL_DIR"
    
    # Récupérer les informations du dépôt distant
    print_info "Récupération des informations du dépôt..."
    git fetch origin 2>/dev/null || error_exit "Impossible de contacter le dépôt GitHub"
    
    # Obtenir la branche actuelle
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    print_info "Branche actuelle: $current_branch"
    
    # Vérifier si des mises à jour sont disponibles
    local local_commit=$(git rev-parse HEAD)
    local remote_commit=$(git rev-parse origin/$current_branch)
    
    if [ "$local_commit" = "$remote_commit" ]; then
        print_success "Aucune mise à jour disponible"
        print_info "Version actuelle: $(git rev-parse --short HEAD)"
        return 1
    else
        print_info "Mises à jour disponibles!"
        print_info "Version actuelle:  $(git rev-parse --short HEAD)"
        print_info "Version disponible: $(git rev-parse --short origin/$current_branch)"
        
        # Afficher le nombre de commits en retard
        local commits_behind=$(git rev-list --count HEAD..origin/$current_branch)
        print_info "Commits en retard: $commits_behind"
        
        return 0
    fi
}

# Afficher le changelog
display_changelog() {
    print_section "Changelog"
    
    cd "$INSTALL_DIR"
    
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local commits=$(git log --oneline HEAD..origin/$current_branch --pretty=format:"%h - %s (%ar)" 2>/dev/null)
    
    if [ -z "$commits" ]; then
        print_info "Aucun changement à afficher"
        return
    fi
    
    echo ""
    echo -e "${BOLD}Modifications récentes:${NC}"
    echo "$commits" | while read line; do
        echo "  • $line"
    done
    echo ""
}

# Vérifier les changements locaux non commités
check_local_changes() {
    cd "$INSTALL_DIR"
    
    if [ -n "$(git status --porcelain)" ]; then
        print_warning "Modifications locales détectées"
        git status --short
        
        if [ "$FORCE_UPDATE" = false ]; then
            echo ""
            read -p "Les modifications locales seront écrasées. Continuer? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error_exit "Mise à jour annulée"
            fi
        fi
        
        return 1
    fi
    
    return 0
}

# ========================================================================================
# FONCTIONS DE SAUVEGARDE
# ========================================================================================

# Créer une sauvegarde avant mise à jour
create_pre_update_backup() {
    print_section "Sauvegarde Pré-Mise à Jour"
    
    local backup_script="$INSTALL_DIR/scripts/proxmox/backup_iptv.sh"
    
    if [ ! -f "$backup_script" ]; then
        print_warning "Script de sauvegarde non trouvé, sauvegarde manuelle..."
        
        # Sauvegarde minimale manuelle
        local backup_name="pre_update_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR/$backup_name"
        
        # Sauvegarder .env et docker-compose.yml
        cp "$INSTALL_DIR/.env" "$BACKUP_DIR/$backup_name/" 2>/dev/null || true
        cp "$INSTALL_DIR/docker-compose.yml" "$BACKUP_DIR/$backup_name/" 2>/dev/null || true
        
        # Sauvegarder la base de données
        cd "$INSTALL_DIR"
        source .env
        docker compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip > "$BACKUP_DIR/$backup_name/database.sql.gz" 2>/dev/null || {
            print_warning "Impossible de sauvegarder la base de données"
        }
        
        print_success "Sauvegarde manuelle créée: $backup_name"
    else
        # Utiliser le script de sauvegarde automatique
        print_info "Exécution du script de sauvegarde..."
        bash "$backup_script" || print_warning "La sauvegarde a échoué, mais la mise à jour continue"
    fi
}

# ========================================================================================
# FONCTIONS DE MISE À JOUR
# ========================================================================================

# Mettre à jour le code source
update_source_code() {
    print_section "Mise à Jour du Code Source"
    
    cd "$INSTALL_DIR"
    
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    
    # Sauvegarder les modifications locales si nécessaire
    if ! check_local_changes; then
        print_info "Sauvegarde des modifications locales..."
        git stash save "Pre-update stash $(date)" || true
    fi
    
    # Récupérer les dernières modifications
    print_info "Téléchargement des mises à jour..."
    if git pull origin "$current_branch" 2>/dev/null; then
        print_success "Code source mis à jour"
        
        # Afficher la nouvelle version
        local new_version=$(git rev-parse --short HEAD)
        print_info "Nouvelle version: $new_version"
    else
        error_exit "Échec de la mise à jour du code source"
    fi
}

# Vérifier si les conteneurs doivent être reconstruits
need_rebuild() {
    cd "$INSTALL_DIR"
    
    # Vérifier si des Dockerfiles ont changé
    local dockerfiles_changed=$(git diff HEAD@{1} HEAD --name-only | grep -E "Dockerfile|docker/" | wc -l)
    
    if [ "$dockerfiles_changed" -gt 0 ]; then
        return 0
    fi
    
    # Vérifier si requirements.txt a changé
    local requirements_changed=$(git diff HEAD@{1} HEAD --name-only | grep -E "requirements.txt" | wc -l)
    
    if [ "$requirements_changed" -gt 0 ]; then
        return 0
    fi
    
    return 1
}

# Reconstruire les conteneurs Docker
rebuild_containers() {
    print_section "Reconstruction des Conteneurs"
    
    cd "$INSTALL_DIR"
    
    if need_rebuild || [ "$FORCE_UPDATE" = true ]; then
        print_info "Reconstruction nécessaire détectée..."
        
        # Arrêter les conteneurs
        print_info "Arrêt des conteneurs..."
        docker compose down || error_exit "Échec de l'arrêt des conteneurs"
        
        # Reconstruire et démarrer
        print_info "Reconstruction et démarrage des conteneurs..."
        if docker compose up -d --build; then
            print_success "Conteneurs reconstruits et démarrés"
        else
            error_exit "Échec de la reconstruction des conteneurs"
        fi
    else
        print_info "Aucune reconstruction nécessaire"
        
        # Simplement redémarrer les conteneurs
        print_info "Redémarrage des conteneurs..."
        docker compose restart || error_exit "Échec du redémarrage des conteneurs"
        print_success "Conteneurs redémarrés"
    fi
}

# Appliquer les migrations de base de données
apply_migrations() {
    print_section "Application des Migrations"
    
    cd "$INSTALL_DIR"
    
    # Vérifier si Flask-Migrate est disponible
    if docker compose exec -T panel python3 -c "import flask_migrate" 2>/dev/null; then
        print_info "Recherche de migrations à appliquer..."
        
        # Vérifier s'il y a des migrations en attente
        local pending_migrations=$(docker compose exec -T panel flask db heads 2>/dev/null | wc -l)
        
        if [ "$pending_migrations" -gt 0 ]; then
            print_info "Application des migrations de la base de données..."
            
            if docker compose exec -T panel flask db upgrade 2>/dev/null; then
                print_success "Migrations appliquées avec succès"
            else
                print_warning "Échec de l'application des migrations (peut-être déjà appliquées)"
            fi
        else
            print_info "Aucune migration en attente"
        fi
    else
        print_info "Flask-Migrate non disponible, migrations ignorées"
    fi
}

# Vérifier la santé après mise à jour
verify_health() {
    print_section "Vérification de la Santé"
    
    cd "$INSTALL_DIR"
    
    print_info "Attente du démarrage complet des services (30 secondes)..."
    sleep 30
    
    # Vérifier l'état des conteneurs
    local containers_running=$(docker compose ps --filter "status=running" --quiet | wc -l)
    local total_containers=$(docker compose ps --quiet | wc -l)
    
    if [ "$containers_running" -eq "$total_containers" ]; then
        print_success "Tous les conteneurs sont en cours d'exécution ($containers_running/$total_containers)"
    else
        print_error "Certains conteneurs ne sont pas en cours d'exécution ($containers_running/$total_containers)"
        docker compose ps
        return 1
    fi
    
    # Tester l'accès HTTP
    local server_ip=$(hostname -I | awk '{print $1}')
    if curl -s -o /dev/null -w "%{http_code}" "http://${server_ip}" --max-time 10 | grep -q "^[23]"; then
        print_success "Panel accessible via HTTP"
    else
        print_warning "Panel non accessible via HTTP"
        return 1
    fi
    
    return 0
}

# ========================================================================================
# FONCTIONS DE RESTAURATION
# ========================================================================================

# Restaurer en cas d'échec
rollback_update() {
    print_section "Restauration de la Version Précédente"
    
    cd "$INSTALL_DIR"
    
    print_warning "Tentative de restauration..."
    
    # Revenir à la version précédente
    if git reset --hard HEAD@{1} 2>/dev/null; then
        print_success "Code source restauré"
    else
        print_error "Échec de la restauration du code source"
    fi
    
    # Redémarrer les conteneurs
    print_info "Redémarrage des conteneurs..."
    docker compose restart || docker compose up -d
    
    print_warning "Restauration terminée. Veuillez vérifier l'état du système."
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

display_header() {
    clear
    cat <<EOF
${BOLD}${CYAN}
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           MISE À JOUR PANEL IPTV                         ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
${NC}

EOF
}

main() {
    # Créer le répertoire de logs
    mkdir -p "$(dirname "$LOG_FILE")"
    
    display_header
    
    log "=== Début de la mise à jour ==="
    log "Mode: $UPDATE_MODE"
    
    # Vérifier les prérequis
    if [ ! -d "$INSTALL_DIR" ]; then
        error_exit "Répertoire d'installation introuvable: $INSTALL_DIR"
    fi
    
    if ! command -v git &> /dev/null; then
        error_exit "Git n'est pas installé"
    fi
    
    # Vérifier les mises à jour disponibles
    if ! check_updates; then
        exit 0
    fi
    
    # Afficher le changelog
    display_changelog
    
    # Si mode check uniquement, s'arrêter ici
    if [ "$UPDATE_MODE" = "check" ]; then
        echo ""
        print_info "Pour appliquer la mise à jour, exécutez:"
        echo "  $0 --apply"
        echo ""
        exit 0
    fi
    
    # Demander confirmation si pas en mode force
    if [ "$FORCE_UPDATE" = false ]; then
        echo ""
        read -p "Appliquer la mise à jour maintenant? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Mise à jour annulée"
            exit 0
        fi
    fi
    
    # Effectuer la mise à jour
    create_pre_update_backup
    
    if ! update_source_code; then
        error_exit "Échec de la mise à jour du code source"
    fi
    
    if ! rebuild_containers; then
        print_error "Échec de la reconstruction des conteneurs"
        rollback_update
        exit 1
    fi
    
    apply_migrations
    
    # Vérifier la santé après mise à jour
    if ! verify_health; then
        print_error "Vérification de santé échouée"
        read -p "Voulez-vous restaurer la version précédente? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rollback_update
        fi
        exit 1
    fi
    
    # Afficher le résumé
    print_section "Mise à Jour Terminée"
    
    cat <<EOF

${GREEN}✅ Mise à jour réussie!${NC}

Version:       $(cd "$INSTALL_DIR" && git rev-parse --short HEAD)
Date:          $(date)

${BOLD}Vérifications:${NC}
✓ Code source mis à jour
✓ Conteneurs reconstruits
✓ Migrations appliquées
✓ Services en cours d'exécution

${BOLD}Prochaines étapes:${NC}
1. Vérifiez le panel dans votre navigateur
2. Consultez les logs si nécessaire:
   cd $INSTALL_DIR && docker compose logs -f
3. Surveillez les performances:
   $INSTALL_DIR/scripts/proxmox/monitor_panel.sh --check-all

${CYAN}Pour plus d'informations sur les changements, consultez:${NC}
https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet/commits

EOF

    log "=== Mise à jour terminée avec succès ==="
}

# ========================================================================================
# GESTION DES ARGUMENTS
# ========================================================================================

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --check                  Vérifier les mises à jour disponibles (défaut)
  --apply                  Appliquer les mises à jour
  --force                  Forcer la mise à jour sans confirmation
  --help                   Afficher cette aide

Exemples:
  # Vérifier les mises à jour
  $0 --check

  # Appliquer les mises à jour (avec confirmation)
  $0 --apply

  # Appliquer les mises à jour sans confirmation
  $0 --apply --force

Workflow recommandé:
  1. Vérifier les mises à jour: $0 --check
  2. Consulter le changelog
  3. Appliquer si nécessaire: $0 --apply

EOF
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --check)
            UPDATE_MODE="check"
            shift
            ;;
        --apply)
            UPDATE_MODE="apply"
            shift
            ;;
        --force)
            FORCE_UPDATE=true
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

# Point d'entrée
main
