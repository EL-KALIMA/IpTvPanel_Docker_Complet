#!/bin/bash
#
# ========================================================================================
# Script de Monitoring pour Panel IPTV
# ========================================================================================
# Ce script surveille l'état du panel IPTV et affiche un rapport détaillé:
# - État des conteneurs Docker
# - Utilisation CPU/RAM/Disque
# - Disponibilité HTTP/HTTPS
# - État de la base de données PostgreSQL
# - État de Redis
#
# USAGE:
#   ./monitor_panel.sh [--check-all] [--alert] [--json]
#
# CRON (alertes automatiques):
#   */5 * * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --alert
#
# ========================================================================================

set -euo pipefail

# ========================================================================================
# CONFIGURATION
# ========================================================================================

INSTALL_DIR="/opt/IpTvPanel_Docker_Complet"
LOG_FILE="/var/log/iptv-panel/monitor.log"
ALERT_EMAIL=""
CHECK_ALL=false
ALERT_MODE=false
JSON_OUTPUT=false

# Seuils d'alerte
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=85

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Variables globales pour les statuts
ISSUES_FOUND=0
WARNINGS_FOUND=0

# ========================================================================================
# FONCTIONS UTILITAIRES
# ========================================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "OK")
            echo -e "${GREEN}✅ ${message}${NC}"
            ;;
        "WARNING")
            echo -e "${YELLOW}⚠️  ${message}${NC}"
            WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
            ;;
        "ERROR")
            echo -e "${RED}❌ ${message}${NC}"
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
            ;;
        "INFO")
            echo -e "${BLUE}ℹ️  ${message}${NC}"
            ;;
    esac
    
    log "$status: $message"
}

print_section() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${CYAN}$*${NC}"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
}

# ========================================================================================
# FONCTIONS DE VÉRIFICATION
# ========================================================================================

# Vérifier l'état des conteneurs Docker
check_containers() {
    print_section "État des Conteneurs Docker"
    
    cd "$INSTALL_DIR"
    
    local containers=(panel db redis nginx certbot)
    
    for container in "${containers[@]}"; do
        local full_name="iptv_${container}"
        
        if docker ps --format '{{.Names}}' | grep -q "^${full_name}$"; then
            local status=$(docker inspect --format='{{.State.Status}}' "$full_name" 2>/dev/null || echo "unknown")
            local health=$(docker inspect --format='{{.State.Health.Status}}' "$full_name" 2>/dev/null || echo "none")
            
            if [ "$status" = "running" ]; then
                if [ "$health" = "healthy" ] || [ "$health" = "none" ]; then
                    print_status "OK" "${container}: Running"
                elif [ "$health" = "starting" ]; then
                    print_status "WARNING" "${container}: Starting..."
                else
                    print_status "ERROR" "${container}: Unhealthy ($health)"
                fi
            else
                print_status "ERROR" "${container}: Not running ($status)"
            fi
        else
            print_status "ERROR" "${container}: Container not found"
        fi
    done
}

# Vérifier l'utilisation des ressources
check_resources() {
    print_section "Utilisation des Ressources Système"
    
    # CPU
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    cpu_usage=$(printf "%.0f" "$cpu_usage")
    
    if [ "$cpu_usage" -ge "$CPU_THRESHOLD" ]; then
        print_status "WARNING" "CPU: ${cpu_usage}% (seuil: ${CPU_THRESHOLD}%)"
    else
        print_status "OK" "CPU: ${cpu_usage}%"
    fi
    
    # Mémoire
    local mem_info=$(free | grep Mem)
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_percent=$(awk "BEGIN {printf \"%.0f\", ($mem_used/$mem_total)*100}")
    local mem_total_gb=$(awk "BEGIN {printf \"%.1f\", $mem_total/1024/1024}")
    local mem_used_gb=$(awk "BEGIN {printf \"%.1f\", $mem_used/1024/1024}")
    
    if [ "$mem_percent" -ge "$MEMORY_THRESHOLD" ]; then
        print_status "WARNING" "RAM: ${mem_used_gb}GB/${mem_total_gb}GB (${mem_percent}%, seuil: ${MEMORY_THRESHOLD}%)"
    else
        print_status "OK" "RAM: ${mem_used_gb}GB/${mem_total_gb}GB (${mem_percent}%)"
    fi
    
    # Disque
    local disk_info=$(df -h / | tail -1)
    local disk_usage=$(echo "$disk_info" | awk '{print $5}' | sed 's/%//')
    local disk_used=$(echo "$disk_info" | awk '{print $3}')
    local disk_total=$(echo "$disk_info" | awk '{print $2}')
    
    if [ "$disk_usage" -ge "$DISK_THRESHOLD" ]; then
        print_status "WARNING" "Disque: ${disk_used}/${disk_total} (${disk_usage}%, seuil: ${DISK_THRESHOLD}%)"
    else
        print_status "OK" "Disque: ${disk_used}/${disk_total} (${disk_usage}%)"
    fi
    
    # Utilisation par conteneur
    if [ "$CHECK_ALL" = true ]; then
        echo ""
        print_status "INFO" "Utilisation par conteneur:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep iptv_ | while read line; do
            echo "    $line"
        done
    fi
}

# Vérifier la disponibilité HTTP/HTTPS
check_http_availability() {
    print_section "Disponibilité HTTP/HTTPS"
    
    local server_ip=$(hostname -I | awk '{print $1}')
    
    # Test HTTP
    if curl -s -o /dev/null -w "%{http_code}" "http://${server_ip}" --max-time 5 | grep -q "^[23]"; then
        print_status "OK" "HTTP: Accessible (http://${server_ip})"
    else
        print_status "ERROR" "HTTP: Non accessible (http://${server_ip})"
    fi
    
    # Test HTTPS
    if curl -k -s -o /dev/null -w "%{http_code}" "https://${server_ip}" --max-time 5 | grep -q "^[23]"; then
        print_status "OK" "HTTPS: Accessible (https://${server_ip})"
    else
        print_status "WARNING" "HTTPS: Non accessible (https://${server_ip})"
    fi
    
    # Test du domaine si configuré
    if [ -f "$INSTALL_DIR/.env" ]; then
        source "$INSTALL_DIR/.env"
        if [ -n "${PANEL_DOMAIN:-}" ]; then
            if curl -k -s -o /dev/null -w "%{http_code}" "https://${PANEL_DOMAIN}" --max-time 5 | grep -q "^[23]"; then
                print_status "OK" "Domaine: Accessible (https://${PANEL_DOMAIN})"
            else
                print_status "WARNING" "Domaine: Non accessible (https://${PANEL_DOMAIN})"
            fi
        fi
    fi
}

# Vérifier l'état de PostgreSQL
check_database() {
    print_section "État de la Base de Données PostgreSQL"
    
    cd "$INSTALL_DIR"
    
    # Vérifier la connexion
    if docker compose exec -T db pg_isready -U iptv_admin -d iptv_panel &>/dev/null; then
        print_status "OK" "PostgreSQL: Connexion réussie"
    else
        print_status "ERROR" "PostgreSQL: Connexion échouée"
        return
    fi
    
    if [ "$CHECK_ALL" = true ]; then
        # Statistiques de la base de données
        source "$INSTALL_DIR/.env"
        
        local db_stats=$(docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -t -c "
            SELECT 
                pg_database.datname,
                pg_size_pretty(pg_database_size(pg_database.datname)) AS size,
                (SELECT count(*) FROM pg_stat_activity WHERE datname = pg_database.datname) AS connections
            FROM pg_database
            WHERE datname = '$DB_NAME';
        " 2>/dev/null)
        
        if [ -n "$db_stats" ]; then
            echo "    Database: $(echo "$db_stats" | awk '{print $1}')"
            echo "    Size: $(echo "$db_stats" | awk '{print $3}')"
            echo "    Connections: $(echo "$db_stats" | awk '{print $5}')"
        fi
        
        # Nombre de tables
        local table_count=$(docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -t -c "
            SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';
        " 2>/dev/null | tr -d ' ')
        
        print_status "INFO" "Tables: $table_count"
    fi
}

# Vérifier l'état de Redis
check_redis() {
    print_section "État du Cache Redis"
    
    cd "$INSTALL_DIR"
    
    # Vérifier la connexion
    if docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        print_status "OK" "Redis: Connexion réussie"
    else
        print_status "ERROR" "Redis: Connexion échouée"
        return
    fi
    
    if [ "$CHECK_ALL" = true ]; then
        # Statistiques Redis
        local redis_info=$(docker compose exec -T redis redis-cli info stats 2>/dev/null)
        
        local total_commands=$(echo "$redis_info" | grep "total_commands_processed" | cut -d':' -f2 | tr -d '\r')
        local used_memory=$(docker compose exec -T redis redis-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d':' -f2 | tr -d '\r')
        local connected_clients=$(docker compose exec -T redis redis-cli info clients 2>/dev/null | grep "connected_clients" | cut -d':' -f2 | tr -d '\r')
        
        echo "    Commandes traitées: $total_commands"
        echo "    Mémoire utilisée: $used_memory"
        echo "    Clients connectés: $connected_clients"
    fi
}

# Vérifier les logs récents
check_recent_logs() {
    print_section "Logs Récents (Dernières 5 minutes)"
    
    cd "$INSTALL_DIR"
    
    # Vérifier les erreurs dans les logs
    local error_count=$(docker compose logs --since=5m 2>/dev/null | grep -i "error" | wc -l)
    local warning_count=$(docker compose logs --since=5m 2>/dev/null | grep -i "warning" | wc -l)
    
    if [ "$error_count" -gt 0 ]; then
        print_status "WARNING" "Erreurs trouvées dans les logs: $error_count"
    else
        print_status "OK" "Aucune erreur dans les logs récents"
    fi
    
    if [ "$warning_count" -gt 0 ]; then
        print_status "INFO" "Avertissements trouvés: $warning_count"
    fi
    
    if [ "$CHECK_ALL" = true ] && [ "$error_count" -gt 0 ]; then
        echo ""
        echo "Dernières erreurs:"
        docker compose logs --since=5m 2>/dev/null | grep -i "error" | tail -5 | while read line; do
            echo "    $line"
        done
    fi
}

# Vérifier l'espace disque des volumes Docker
check_docker_volumes() {
    print_section "Espace Disque des Volumes Docker"
    
    cd "$INSTALL_DIR"
    
    local volumes=$(docker volume ls --format '{{.Name}}' | grep iptv)
    
    for volume in $volumes; do
        local volume_size=$(docker run --rm -v "${volume}:/data:ro" alpine:latest du -sh /data 2>/dev/null | awk '{print $1}')
        print_status "INFO" "${volume}: ${volume_size}"
    done
}

# ========================================================================================
# FONCTIONS D'ALERTE
# ========================================================================================

send_alert() {
    local subject=$1
    local message=$2
    
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "[ALERTE] Panel IPTV - $subject" "$ALERT_EMAIL" 2>/dev/null || true
    fi
    
    # Logger l'alerte
    log "ALERTE: $subject"
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

display_header() {
    if [ "$JSON_OUTPUT" = false ]; then
        clear
        cat <<EOF
${BOLD}${CYAN}
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           MONITORING PANEL IPTV                          ║
║           $(date +'%Y-%m-%d %H:%M:%S')                          ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
${NC}

EOF
    fi
}

display_summary() {
    print_section "Résumé du Monitoring"
    
    if [ "$ISSUES_FOUND" -eq 0 ] && [ "$WARNINGS_FOUND" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✅ Tous les systèmes fonctionnent correctement${NC}"
    else
        if [ "$ISSUES_FOUND" -gt 0 ]; then
            echo -e "${RED}${BOLD}❌ Problèmes critiques trouvés: $ISSUES_FOUND${NC}"
        fi
        if [ "$WARNINGS_FOUND" -gt 0 ]; then
            echo -e "${YELLOW}${BOLD}⚠️  Avertissements: $WARNINGS_FOUND${NC}"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}Pour plus de détails, utilisez: $0 --check-all${NC}"
    echo ""
    
    # Envoyer une alerte si nécessaire
    if [ "$ALERT_MODE" = true ] && [ "$ISSUES_FOUND" -gt 0 ]; then
        send_alert "Problèmes détectés" "Le monitoring a détecté $ISSUES_FOUND problème(s) critique(s)."
    fi
}

main() {
    # Créer le répertoire de logs si nécessaire
    mkdir -p "$(dirname "$LOG_FILE")"
    
    display_header
    
    log "=== Début du monitoring ==="
    
    # Vérifier que l'installation existe
    if [ ! -d "$INSTALL_DIR" ]; then
        print_status "ERROR" "Répertoire d'installation introuvable: $INSTALL_DIR"
        exit 1
    fi
    
    # Effectuer les vérifications
    check_containers
    check_resources
    check_http_availability
    check_database
    check_redis
    
    if [ "$CHECK_ALL" = true ]; then
        check_recent_logs
        check_docker_volumes
    fi
    
    # Afficher le résumé
    display_summary
    
    log "=== Fin du monitoring ==="
    log "Issues: $ISSUES_FOUND, Warnings: $WARNINGS_FOUND"
    
    # Code de sortie basé sur les problèmes trouvés
    if [ "$ISSUES_FOUND" -gt 0 ]; then
        exit 1
    elif [ "$WARNINGS_FOUND" -gt 0 ]; then
        exit 2
    else
        exit 0
    fi
}

# ========================================================================================
# GESTION DES ARGUMENTS
# ========================================================================================

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --check-all              Effectuer toutes les vérifications (détaillé)
  --alert                  Mode alerte (pour cron, exit code basé sur les erreurs)
  --email ADDRESS          Email pour les alertes
  --json                   Sortie en format JSON
  --help                   Afficher cette aide

Exemples:
  # Vérification rapide
  $0

  # Vérification détaillée
  $0 --check-all

  # Mode alerte avec email
  $0 --alert --email admin@example.com

Configuration cron (monitoring toutes les 5 minutes):
  */5 * * * * $0 --alert --email admin@example.com >> /var/log/iptv-panel/monitor-cron.log 2>&1

Codes de sortie:
  0 - Tout fonctionne correctement
  1 - Problèmes critiques détectés
  2 - Avertissements détectés

EOF
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --check-all)
            CHECK_ALL=true
            shift
            ;;
        --alert)
            ALERT_MODE=true
            shift
            ;;
        --email)
            ALERT_EMAIL="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
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
