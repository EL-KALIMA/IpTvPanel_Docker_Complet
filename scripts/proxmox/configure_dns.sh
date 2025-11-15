#!/bin/bash
#
# ========================================================================================
# Script de Configuration DNS Local pour Panel IPTV
# ========================================================================================
# Ce script aide à configurer le DNS local pour accéder au panel IPTV
# via un nom de domaine personnalisé.
#
# USAGE:
#   ./configure_dns.sh
#
# ========================================================================================

set -euo pipefail

# Couleurs pour l'affichage
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

print_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

print_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$*${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ========================================================================================
# FONCTIONS DE DÉTECTION
# ========================================================================================

# Détecter l'IP locale
detect_local_ip() {
    local ip=""
    
    # Essayer différentes méthodes
    if command -v hostname &> /dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -z "$ip" ]; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi
    
    if [ -z "$ip" ]; then
        ip=$(ip addr show | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d'/' -f1)
    fi
    
    echo "$ip"
}

# Lire le domaine depuis .env
get_domain_from_env() {
    local env_file="/opt/IpTvPanel_Docker_Complet/.env"
    
    if [ -f "$env_file" ]; then
        grep "^PANEL_DOMAIN=" "$env_file" | cut -d'=' -f2
    else
        echo ""
    fi
}

# ========================================================================================
# FONCTIONS DE CONFIGURATION
# ========================================================================================

# Configurer /etc/hosts sur la machine locale
configure_local_hosts() {
    local domain=$1
    local ip=$2
    
    print_section "Configuration de /etc/hosts"
    
    # Vérifier si l'entrée existe déjà
    if grep -q "$domain" /etc/hosts 2>/dev/null; then
        print_warning "Une entrée pour $domain existe déjà dans /etc/hosts"
        
        read -p "Voulez-vous la remplacer? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Configuration annulée"
            return 1
        fi
        
        # Supprimer l'ancienne entrée
        if [ "$EUID" -eq 0 ]; then
            sed -i.backup "/$domain/d" /etc/hosts
            print_success "Ancienne entrée supprimée"
        else
            print_error "Droits root nécessaires pour modifier /etc/hosts"
            print_info "Exécutez: sudo sed -i.backup '/$domain/d' /etc/hosts"
            return 1
        fi
    fi
    
    # Ajouter la nouvelle entrée
    if [ "$EUID" -eq 0 ]; then
        echo "$ip    $domain" >> /etc/hosts
        print_success "Entrée ajoutée à /etc/hosts: $ip -> $domain"
    else
        print_warning "Droits root nécessaires pour modifier /etc/hosts"
        print_info ""
        print_info "Exécutez la commande suivante:"
        echo ""
        echo -e "${BOLD}  sudo bash -c 'echo \"$ip    $domain\" >> /etc/hosts'${NC}"
        echo ""
    fi
}

# Afficher les instructions pour différents systèmes
display_dns_instructions() {
    local domain=$1
    local ip=$2
    
    print_section "Instructions de Configuration DNS"
    
    cat <<EOF

${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}
${BOLD}${CYAN}║           Configuration DNS pour $domain${NC}
${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}

${BOLD}📍 Adresse IP du serveur:${NC} $ip
${BOLD}🌐 Nom de domaine:${NC} $domain

${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}${YELLOW}Option 1: Configuration Locale (/etc/hosts)${NC}
${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BOLD}Linux / macOS:${NC}
  sudo bash -c 'echo "$ip    $domain" >> /etc/hosts'

${BOLD}Windows (PowerShell en Admin):${NC}
  Add-Content -Path C:\\Windows\\System32\\drivers\\etc\\hosts -Value "$ip    $domain"

${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}${YELLOW}Option 2: Configuration DNS Routeur${NC}
${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

Si vous avez accès à votre routeur:
1. Connectez-vous à l'interface admin de votre routeur
2. Cherchez la section "DNS" ou "Hosts statiques"
3. Ajoutez une entrée:
   - Nom: $domain
   - Adresse IP: $ip

${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}${YELLOW}Option 3: DNS Serveur (Pi-hole, AdGuard, etc.)${NC}
${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BOLD}Pi-hole:${NC}
1. Interface Web -> Local DNS -> DNS Records
2. Ajoutez:
   - Domain: $domain
   - IP Address: $ip

${BOLD}AdGuard Home:${NC}
1. Filters -> DNS rewrites
2. Ajoutez:
   - Domain: $domain
   - IP: $ip

${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}${YELLOW}Option 4: DNS Public (Pour domaine réel)${NC}
${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

Si vous possédez le domaine et voulez un accès externe:
1. Connectez-vous à votre registrar/DNS provider
2. Créez un enregistrement A:
   - Type: A
   - Nom: ${domain%%.*}
   - Valeur: $ip (votre IP publique)
   - TTL: 300

${BOLD}Note:${NC} Assurez-vous d'avoir configuré le port forwarding sur votre routeur:
  - Port 80 (HTTP) -> $ip:80
  - Port 443 (HTTPS) -> $ip:443

${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${BOLD}${CYAN}Vérification${NC}
${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

Après la configuration, vérifiez:

${BOLD}1. Test de résolution DNS:${NC}
   ping $domain
   nslookup $domain
   dig $domain

${BOLD}2. Test d'accès HTTP:${NC}
   curl -I http://$domain
   curl -I http://$ip

${BOLD}3. Test d'accès HTTPS:${NC}
   curl -k -I https://$domain
   curl -k -I https://$ip

${BOLD}4. Navigateur:${NC}
   Ouvrez https://$domain dans votre navigateur
   Acceptez le certificat auto-signé si nécessaire

EOF
}

# Générer un script de configuration pour Windows
generate_windows_script() {
    local domain=$1
    local ip=$2
    
    local script_file="/tmp/configure_dns_windows.ps1"
    
    cat > "$script_file" <<'EOF'
# Script PowerShell de Configuration DNS pour Panel IPTV
# Exécutez ce script en tant qu'Administrateur

$domain = "DOMAIN_PLACEHOLDER"
$ip = "IP_PLACEHOLDER"

# Vérifier les privilèges admin
If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "Ce script nécessite les droits administrateur!"
    Write-Host "Faites un clic droit et sélectionnez 'Exécuter en tant qu'administrateur'"
    Exit
}

# Chemin du fichier hosts
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

# Vérifier si l'entrée existe déjà
$content = Get-Content $hostsFile
$entry = "$ip    $domain"

if ($content -match $domain) {
    Write-Host "Une entrée pour $domain existe déjà" -ForegroundColor Yellow
    $response = Read-Host "Voulez-vous la remplacer? (O/N)"
    if ($response -ne "O" -and $response -ne "o") {
        Write-Host "Configuration annulée" -ForegroundColor Yellow
        Exit
    }
    # Supprimer l'ancienne entrée
    $content = $content | Where-Object { $_ -notmatch $domain }
    $content | Set-Content $hostsFile
}

# Ajouter la nouvelle entrée
Add-Content -Path $hostsFile -Value $entry
Write-Host "✅ Configuration réussie!" -ForegroundColor Green
Write-Host "Entrée ajoutée: $entry" -ForegroundColor Cyan

# Test de résolution
Write-Host "`nTest de résolution DNS..." -ForegroundColor Yellow
try {
    $result = Resolve-DnsName -Name $domain -ErrorAction Stop
    Write-Host "✅ DNS résolu avec succès!" -ForegroundColor Green
    Write-Host "Adresse IP: $($result.IPAddress)" -ForegroundColor Cyan
} catch {
    Write-Host "⚠️  Attention: La résolution DNS a échoué" -ForegroundColor Yellow
    Write-Host "Videz le cache DNS avec: ipconfig /flushdns" -ForegroundColor Cyan
}

Write-Host "`nPour vider le cache DNS:" -ForegroundColor Yellow
Write-Host "  ipconfig /flushdns" -ForegroundColor Cyan

Pause
EOF
    
    # Remplacer les placeholders
    sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" "$script_file"
    sed -i "s/IP_PLACEHOLDER/$ip/g" "$script_file"
    
    print_success "Script Windows généré: $script_file"
    print_info "Copiez ce fichier sur votre machine Windows et exécutez-le en tant qu'Administrateur"
}

# ========================================================================================
# FONCTION PRINCIPALE
# ========================================================================================

main() {
    clear
    cat <<EOF
${BOLD}${CYAN}
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           CONFIGURATION DNS PANEL IPTV                   ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
${NC}

EOF

    # Détecter l'IP locale
    print_section "Détection de la configuration"
    
    local local_ip=$(detect_local_ip)
    if [ -z "$local_ip" ]; then
        print_error "Impossible de détecter l'adresse IP locale"
        exit 1
    fi
    print_success "IP locale détectée: $local_ip"
    
    # Récupérer le domaine
    local domain=$(get_domain_from_env)
    if [ -z "$domain" ]; then
        read -p "Entrez le nom de domaine du panel: " domain
    else
        print_success "Domaine détecté: $domain"
    fi
    
    # Menu de configuration
    print_section "Options de Configuration"
    
    cat <<EOF
${BOLD}Que souhaitez-vous faire?${NC}

  1) Configurer /etc/hosts sur cette machine
  2) Afficher les instructions de configuration DNS
  3) Générer un script de configuration pour Windows
  4) Tout afficher

EOF
    
    read -p "Votre choix (1-4): " choice
    
    case $choice in
        1)
            configure_local_hosts "$domain" "$local_ip"
            ;;
        2)
            display_dns_instructions "$domain" "$local_ip"
            ;;
        3)
            generate_windows_script "$domain" "$local_ip"
            ;;
        4)
            configure_local_hosts "$domain" "$local_ip"
            echo ""
            display_dns_instructions "$domain" "$local_ip"
            generate_windows_script "$domain" "$local_ip"
            ;;
        *)
            print_error "Choix invalide"
            exit 1
            ;;
    esac
    
    print_section "Configuration DNS Terminée"
    print_success "Vous pouvez maintenant accéder au panel via: https://$domain"
}

# Point d'entrée
main "$@"
