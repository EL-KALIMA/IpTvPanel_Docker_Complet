# Guide Complet d'Installation sur Proxmox

Ce guide détaille l'installation et la configuration du Panel IPTV sur un serveur Proxmox VE, que ce soit dans une VM (Machine Virtuelle) ou un conteneur LXC.

## 📋 Table des Matières

- [Prérequis](#prérequis)
- [Installation Rapide](#installation-rapide)
- [Configuration Réseau](#configuration-réseau)
- [LXC vs VM: Quel Choix?](#lxc-vs-vm-quel-choix)
- [Installation Détaillée](#installation-détaillée)
- [Configuration Firewall](#configuration-firewall)
- [Accès Externe](#accès-externe)
- [VPN pour Accès Sécurisé](#vpn-pour-accès-sécurisé)
- [Optimisations](#optimisations)
- [Troubleshooting](#troubleshooting)

---

## 🎯 Prérequis

### Proxmox VE
- **Version**: Proxmox VE 7.x ou 8.x
- **Accès**: Root SSH ou interface web
- **Réseau**: Configuration réseau fonctionnelle avec accès Internet

### Ressources Minimales

#### Pour Conteneur LXC (Recommandé)
- **CPU**: 2 vCores
- **RAM**: 2 GB (4 GB recommandé)
- **Disque**: 10 GB minimum (20 GB recommandé)
- **Réseau**: 1 interface réseau
- **Template**: Debian 12 ou Ubuntu 22.04

#### Pour Machine Virtuelle
- **CPU**: 2 vCores
- **RAM**: 2 GB (4 GB recommandé)
- **Disque**: 15 GB minimum (30 GB recommandé)
- **Réseau**: 1 interface réseau (VirtIO)
- **ISO**: Debian 12 ou Ubuntu 22.04 Server

### Ports Nécessaires
- **80** (HTTP) - Accès web et certbot
- **443** (HTTPS) - Accès web sécurisé
- **5432** (PostgreSQL) - Base de données (interne)
- **6379** (Redis) - Cache (interne)

---

## 🚀 Installation Rapide

### Méthode 1: Installation en Une Ligne (Recommandée)

```bash
# Se connecter en SSH à votre VM/LXC
ssh root@IP_DE_VOTRE_CONTENEUR

# Lancer l'installation automatique
bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)
```

Le script vous demandera:
1. **Nom de domaine** (ex: panel.mondomaine.com)
2. **Email** pour les notifications
3. **Mot de passe administrateur**
4. **Mot de passe base de données** (optionnel, peut être généré automatiquement)

### Méthode 2: Installation Manuelle

Voir la section [Installation Détaillée](#installation-détaillée) ci-dessous.

---

## 🌐 Configuration Réseau

### Configuration Réseau Proxmox

#### 1. Accéder à l'Interface Proxmox

Connectez-vous à l'interface web de Proxmox:
```
https://PROXMOX_IP:8006
```

#### 2. Vérifier la Configuration Réseau

Dans Proxmox, allez à:
```
Datacenter → Noeud → System → Network
```

Configuration typique:
```
vmbr0 (Linux Bridge)
├── Bridge ports: enp0s3 (ou votre interface physique)
├── IP: 192.168.1.100/24 (IP du serveur Proxmox)
├── Gateway: 192.168.1.1
└── CIDR: 192.168.1.0/24
```

### Configuration pour Conteneur LXC

#### Créer le Conteneur LXC

1. **Cliquer sur "Create CT"** dans l'interface Proxmox

2. **General**:
   - Node: Sélectionner votre nœud
   - VM ID: 100 (ou auto)
   - Hostname: iptv-panel
   - Password: [mot de passe root]
   - ☑️ Unprivileged container

3. **Template**:
   - Storage: local
   - Template: debian-12-standard ou ubuntu-22.04-standard

4. **Disks**:
   - Storage: local-lvm
   - Disk size: 20 GB

5. **CPU**:
   - Cores: 2

6. **Memory**:
   - Memory: 2048 MB (2GB)
   - Swap: 512 MB

7. **Network**:
   - Bridge: vmbr0
   - IPv4: DHCP (ou Static)
   - IPv6: DHCP (ou désactivé)
   - Firewall: ☐ (désactivé pour le moment)

8. **DNS**:
   - Use host settings: ☑️

9. **Confirm** et **Finish**

#### Configuration Post-Création LXC

```bash
# Démarrer le conteneur
pct start 100

# Se connecter au conteneur
pct enter 100

# Mettre à jour le système
apt update && apt upgrade -y

# Installer les prérequis
apt install -y curl wget git sudo

# Procéder à l'installation du panel
bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)
```

### Configuration pour Machine Virtuelle

#### Créer la VM

1. **Cliquer sur "Create VM"**

2. **General**:
   - Node: Sélectionner votre nœud
   - VM ID: 100
   - Name: iptv-panel

3. **OS**:
   - ISO: debian-12 ou ubuntu-22.04-server
   - Type: Linux
   - Version: 6.x/2.6 Kernel

4. **System**:
   - SCSI Controller: VirtIO SCSI
   - Qemu Agent: ☑️

5. **Disks**:
   - Bus/Device: SCSI 0
   - Storage: local-lvm
   - Disk size: 30 GB
   - Cache: Write back
   - Discard: ☑️

6. **CPU**:
   - Sockets: 1
   - Cores: 2
   - Type: host

7. **Memory**:
   - Memory: 2048 MB (2GB)
   - Ballooning: ☑️

8. **Network**:
   - Bridge: vmbr0
   - Model: VirtIO
   - Firewall: ☐

9. **Confirm**

#### Installation OS dans la VM

1. **Démarrer la VM** et se connecter via console/VNC
2. **Installer Debian/Ubuntu** (mode minimal/server)
3. **Configurer le réseau** (DHCP ou IP statique)
4. **Installer SSH**: `apt install openssh-server`
5. **Se connecter en SSH** et procéder à l'installation du panel

---

## 🔍 LXC vs VM: Quel Choix?

### Conteneur LXC (Recommandé)

**Avantages:**
- ✅ Plus léger (moins de RAM utilisée)
- ✅ Démarrage instantané
- ✅ Meilleure performance réseau
- ✅ Partage de kernel avec l'hôte
- ✅ Snapshots rapides

**Inconvénients:**
- ❌ Moins d'isolation que les VMs
- ❌ Partage du kernel (limitations possibles)
- ❌ Nécessite des privilèges pour Docker (voir section dédiée)

**Utilisation recommandée:**
- Environnement de développement
- Installation sur serveur Proxmox de confiance
- Besoin de performance maximale

### Machine Virtuelle

**Avantages:**
- ✅ Isolation complète
- ✅ Kernel indépendant
- ✅ Support matériel complet
- ✅ Plus flexible pour certaines configurations

**Inconvénients:**
- ❌ Plus gourmande en ressources
- ❌ Démarrage plus lent
- ❌ Overhead de virtualisation

**Utilisation recommandée:**
- Environnement de production
- Besoin d'isolation stricte
- Environnement multi-tenant

### Configuration Docker dans LXC

Pour utiliser Docker dans un conteneur LXC unprivileged, quelques ajustements sont nécessaires:

#### Sur l'Hôte Proxmox

```bash
# Éditer la configuration du conteneur
nano /etc/pve/lxc/100.conf

# Ajouter ces lignes (remplacer 100 par votre CT ID)
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
```

Puis redémarrer le conteneur:
```bash
pct stop 100
pct start 100
```

#### Dans le Conteneur LXC

```bash
# Après ces modifications, Docker devrait fonctionner
docker --version
```

---

## 📝 Installation Détaillée

### Étape 1: Préparation du Système

```bash
# Se connecter en SSH
ssh root@IP_CONTENEUR

# Mettre à jour le système
apt update && apt upgrade -y

# Installer les outils de base
apt install -y curl wget git vim net-tools sudo
```

### Étape 2: Installation avec le Script

```bash
# Télécharger le script
curl -O https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh

# Rendre le script exécutable
chmod +x install_proxmox.sh

# Lancer l'installation
./install_proxmox.sh
```

### Étape 3: Configuration Interactive

Le script vous demandera:

1. **Nom de domaine**:
   ```
   Nom de domaine (ex: panel.mondomaine.com): panel.example.com
   ```

2. **Email**:
   ```
   Email pour les notifications: admin@example.com
   ```

3. **Mot de passe administrateur**:
   ```
   Mot de passe administrateur (min 8 caractères): ********
   Confirmez le mot de passe administrateur: ********
   ```

4. **Mot de passe base de données**:
   ```
   Mot de passe base de données (min 8 caractères, ou Entrée pour générer):
   ```
   *Appuyez sur Entrée pour génération automatique*

5. **Confirmation**:
   ```
   Configuration:
     Domaine: panel.example.com
     Email: admin@example.com
     Mot de passe admin: ********
     Mot de passe DB: ********
   
   Confirmer et continuer? (y/N) y
   ```

### Étape 4: Attendre l'Installation

L'installation prend environ 5-10 minutes et effectue:
- ✅ Installation de Docker et Docker Compose
- ✅ Clonage du dépôt GitHub
- ✅ Configuration de l'environnement
- ✅ Déploiement des conteneurs
- ✅ Création du compte admin
- ✅ Génération du certificat SSL

### Étape 5: Configuration DNS

Après l'installation, configurez l'accès au domaine:

```bash
# Exécuter le script de configuration DNS
/opt/IpTvPanel_Docker_Complet/scripts/proxmox/configure_dns.sh
```

Ou manuellement sur votre machine locale:

**Linux/macOS**:
```bash
sudo bash -c 'echo "192.168.1.100    panel.example.com" >> /etc/hosts'
```

**Windows (PowerShell en Admin)**:
```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "192.168.1.100    panel.example.com"
```

### Étape 6: Accéder au Panel

1. **Ouvrir le navigateur**: `https://panel.example.com`
2. **Accepter le certificat** auto-signé (avertissement normal)
3. **Se connecter**:
   - Username: `admin`
   - Password: [le mot de passe choisi]

---

## 🔥 Configuration Firewall

### Firewall Proxmox

#### Activer le Firewall

1. **Interface Proxmox** → **Datacenter** → **Firewall**
2. **Cliquer sur "Options"**
3. **Enable Firewall**: Yes

#### Règles pour le Nœud

1. **Datacenter** → **Nœud** → **Firewall** → **Add**

Règle SSH:
```
Direction: in
Action: ACCEPT
Protocol: tcp
Dest. port: 22
Comment: Allow SSH
```

Règle Proxmox Web:
```
Direction: in
Action: ACCEPT
Protocol: tcp
Dest. port: 8006
Comment: Allow Proxmox Web
```

#### Règles pour le Conteneur/VM IPTV

1. **CT/VM** → **Firewall** → **Add**

Règle HTTP:
```
Direction: in
Action: ACCEPT
Protocol: tcp
Dest. port: 80
Comment: Allow HTTP
```

Règle HTTPS:
```
Direction: in
Action: ACCEPT
Protocol: tcp
Dest. port: 443
Comment: Allow HTTPS
```

### Firewall UFW (dans le Conteneur/VM)

```bash
# Installer UFW
apt install -y ufw

# Autoriser SSH (important!)
ufw allow 22/tcp

# Autoriser HTTP/HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

# Activer le firewall
ufw enable

# Vérifier le statut
ufw status verbose
```

---

## 🌍 Accès Externe

### Port Forwarding sur le Routeur

Pour accéder au panel depuis Internet:

1. **Se connecter au routeur** (ex: 192.168.1.1)
2. **Aller dans Port Forwarding** / NAT
3. **Créer deux règles**:

**Règle HTTP**:
```
Service Name: IPTV-HTTP
External Port: 80
Internal IP: 192.168.1.100 (IP du conteneur)
Internal Port: 80
Protocol: TCP
```

**Règle HTTPS**:
```
Service Name: IPTV-HTTPS
External Port: 443
Internal IP: 192.168.1.100
Internal Port: 443
Protocol: TCP
```

### DNS Public

Si vous possédez un nom de domaine:

1. **Se connecter au registrar** (OVH, Cloudflare, etc.)
2. **Créer un enregistrement A**:
   ```
   Type: A
   Name: panel
   Value: VOTRE_IP_PUBLIQUE
   TTL: 300
   ```

3. **Vérifier** avec: `nslookup panel.example.com`

### Let's Encrypt (Certificat SSL Valide)

Une fois le domaine accessible depuis Internet:

```bash
cd /opt/IpTvPanel_Docker_Complet

# Arrêter nginx temporairement
docker compose stop nginx

# Obtenir le certificat
docker compose run --rm certbot certonly \
  --standalone \
  --email admin@example.com \
  --agree-tos \
  -d panel.example.com

# Redémarrer nginx
docker compose start nginx
```

### Renouvellement Automatique

Configurer un cron pour le renouvellement:

```bash
# Éditer le crontab
crontab -e

# Ajouter cette ligne (renouvellement à 3h tous les jours)
0 3 * * * cd /opt/IpTvPanel_Docker_Complet && docker compose run --rm certbot renew && docker compose restart nginx
```

---

## 🔐 VPN pour Accès Sécurisé

### Option 1: WireGuard sur Proxmox

#### Installation WireGuard

```bash
# Sur l'hôte Proxmox
apt update
apt install -y wireguard wireguard-tools

# Générer les clés
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
```

#### Configuration Serveur

```bash
# Créer le fichier de configuration
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $(cat privatekey)
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o vmbr0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o vmbr0 -j MASQUERADE

# Client 1
[Peer]
PublicKey = CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

# Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

#### Configuration Client

Sur votre ordinateur/téléphone, créer un fichier `wg0-client.conf`:

```ini
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = VOTRE_IP_PUBLIQUE:51820
AllowedIPs = 192.168.1.0/24, 10.0.0.0/24
PersistentKeepalive = 25
```

#### Accès au Panel via VPN

Une fois connecté au VPN:
```
https://192.168.1.100
ou
https://panel.example.com (si DNS configuré)
```

### Option 2: Tailscale (Plus Simple)

#### Installation sur Proxmox

```bash
# Installer Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Démarrer Tailscale
tailscale up

# Autoriser le routage de sous-réseau
tailscale up --advertise-routes=192.168.1.0/24
```

#### Installation sur le Client

1. **Télécharger Tailscale**: https://tailscale.com/download
2. **Installer** et **se connecter** avec le même compte
3. **Accéder au panel** via l'IP Tailscale du serveur

Avantages Tailscale:
- ✅ Configuration automatique
- ✅ Gestion centralisée via interface web
- ✅ Support multi-plateforme
- ✅ Gratuit jusqu'à 20 appareils

---

## ⚡ Optimisations

### Optimisations LXC

#### Augmenter les Limites de Fichiers Ouverts

```bash
# Sur l'hôte Proxmox, éditer la config du conteneur
nano /etc/pve/lxc/100.conf

# Ajouter
lxc.prlimit.nofile: 1048576
```

#### Désactiver le Swap pour Meilleures Performances

```bash
# Dans le conteneur
swapoff -a

# Éditer fstab
nano /etc/fstab
# Commenter la ligne swap
```

### Optimisations VM

#### Activer QEMU Agent

```bash
# Dans la VM
apt install -y qemu-guest-agent
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent
```

#### Activer le Trim/Discard

Dans Proxmox:
1. **VM** → **Hardware** → **Hard Disk**
2. **Cocher**: Discard

### Optimisations PostgreSQL

```bash
cd /opt/IpTvPanel_Docker_Complet

# Éditer docker-compose.yml
nano docker-compose.yml

# Ajouter dans la section db:
    command: |
      -c shared_buffers=256MB
      -c effective_cache_size=1GB
      -c maintenance_work_mem=128MB
      -c max_connections=100

# Redémarrer
docker compose restart db
```

### Optimisations Redis

```bash
# Éditer docker-compose.yml
nano docker-compose.yml

# Ajouter dans la section redis:
    command: |
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
      --save ""

# Redémarrer
docker compose restart redis
```

### Optimisations Nginx

```bash
# Éditer la configuration Nginx
nano docker/nginx/nginx.conf

# Ajuster worker_processes et worker_connections
worker_processes auto;
events {
    worker_connections 2048;
}

# Redémarrer nginx
docker compose restart nginx
```

### Dimensionnement selon le Nombre d'Utilisateurs

| Utilisateurs | CPU | RAM | Disque | Réseau |
|-------------|-----|-----|--------|--------|
| 1-50 | 2 cores | 2 GB | 20 GB | 100 Mbps |
| 51-200 | 4 cores | 4 GB | 40 GB | 500 Mbps |
| 201-500 | 6 cores | 8 GB | 80 GB | 1 Gbps |
| 501-1000 | 8 cores | 16 GB | 120 GB | 1 Gbps |
| 1000+ | 12+ cores | 32+ GB | 200+ GB | 10 Gbps |

---

## 🔧 Troubleshooting

### Problème: Docker ne démarre pas dans LXC

**Solution**:
```bash
# Sur l'hôte Proxmox
nano /etc/pve/lxc/100.conf

# Ajouter ces lignes
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw

# Redémarrer le conteneur
pct stop 100 && pct start 100
```

### Problème: Erreur "overlay2" storage driver

**Solution**:
```bash
# Dans le conteneur
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "storage-driver": "overlay2"
}
EOF

systemctl restart docker
```

### Problème: Impossible d'accéder au panel

**Vérifications**:
```bash
# Vérifier que les conteneurs tournent
docker compose ps

# Vérifier les logs
docker compose logs nginx
docker compose logs panel

# Vérifier les ports
netstat -tulpn | grep -E ':(80|443)'

# Tester localement
curl -I http://localhost
```

### Problème: Certificat SSL invalide

**Solution pour Let's Encrypt**:
```bash
# Vérifier que le domaine pointe vers votre IP
nslookup panel.example.com

# Vérifier que le port 80 est accessible depuis Internet
curl -I http://panel.example.com

# Forcer le renouvellement
docker compose run --rm certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  --email admin@example.com \
  --agree-tos --force-renewal \
  -d panel.example.com

# Redémarrer nginx
docker compose restart nginx
```

### Problème: Base de données corrompue

**Solution**:
```bash
# Restaurer depuis une sauvegarde
cd /opt/backups/iptv
tar xzf iptv_panel_backup_YYYYMMDD_HHMMSS.tar.gz

# Arrêter les conteneurs
cd /opt/IpTvPanel_Docker_Complet
docker compose down

# Restaurer la base de données
gunzip < /opt/backups/iptv/temp_*/database_*.sql.gz | \
  docker compose exec -T db psql -U iptv_admin -d iptv_panel

# Redémarrer
docker compose up -d
```

### Problème: Manque d'espace disque

**Solutions**:
```bash
# Nettoyer les images Docker inutilisées
docker system prune -a

# Nettoyer les anciennes sauvegardes
cd /opt/backups/iptv
find . -name "*.tar.gz" -mtime +7 -delete

# Augmenter la taille du disque (LXC)
# Sur l'hôte Proxmox:
pct resize 100 0 +10G

# Augmenter la taille du disque (VM)
# Interface Proxmox → VM → Hardware → Hard Disk → Resize
# Puis dans la VM:
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

### Problème: Performance réseau lente

**Solutions**:
```bash
# Pour VM: Changer le modèle réseau en VirtIO
# Interface Proxmox → VM → Hardware → Network Device → Edit
# Model: VirtIO (paravirtualized)

# Désactiver le checksum offloading
ethtool -K eth0 tx off rx off

# Augmenter les buffers réseau
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
```

---

## 📊 Monitoring et Maintenance

### Monitoring Automatique

```bash
# Configurer le monitoring toutes les 5 minutes
crontab -e

# Ajouter
*/5 * * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --alert --email admin@example.com
```

### Sauvegardes Automatiques

```bash
# Configurer la sauvegarde quotidienne à 2h
crontab -e

# Ajouter
0 2 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh
```

### Vérification des Mises à Jour

```bash
# Vérifier manuellement
/opt/IpTvPanel_Docker_Complet/scripts/proxmox/update_panel.sh --check

# Automatiser la vérification
crontab -e

# Ajouter (vérification quotidienne)
0 0 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/update_panel.sh --check
```

---

## 📚 Ressources Complémentaires

- **Documentation Proxmox**: https://pve.proxmox.com/wiki/Main_Page
- **Documentation Docker**: https://docs.docker.com/
- **Forum Proxmox**: https://forum.proxmox.com/
- **Panel IPTV GitHub**: https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet

---

## 💡 Conseils de Sécurité

1. **Changer les mots de passe par défaut** immédiatement après l'installation
2. **Activer le firewall** (UFW ou firewall Proxmox)
3. **Configurer fail2ban** pour protéger contre les attaques par force brute
4. **Utiliser un VPN** pour l'accès d'administration
5. **Faire des sauvegardes régulières** (automatiques avec cron)
6. **Surveiller les logs** régulièrement
7. **Garder le système à jour** avec `apt update && apt upgrade`
8. **Utiliser HTTPS** avec Let's Encrypt pour un certificat valide

---

**Dernière mise à jour**: 2024-11-15

**Version du guide**: 1.0.0

Pour toute question ou problème, ouvrez une issue sur GitHub ou consultez le README principal.
