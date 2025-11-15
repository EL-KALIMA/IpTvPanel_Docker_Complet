# Scripts Proxmox pour Panel IPTV

Ce répertoire contient une collection de scripts automatisés pour faciliter le déploiement, la maintenance et la surveillance du Panel IPTV sur Proxmox.

## 📋 Table des Matières

- [Scripts Disponibles](#scripts-disponibles)
- [Installation Rapide](#installation-rapide)
- [Utilisation Détaillée](#utilisation-détaillée)
- [Configuration Cron](#configuration-cron)
- [Dépannage](#dépannage)

## 🚀 Scripts Disponibles

### 1. `install_proxmox.sh` - Installation Automatique

Script d'installation complet qui automatise le déploiement du Panel IPTV sur Proxmox.

**Fonctionnalités:**
- ✅ Détection automatique de l'environnement (VM/LXC)
- ✅ Installation de Docker et Docker Compose
- ✅ Configuration interactive ou silencieuse
- ✅ Génération automatique de mots de passe sécurisés
- ✅ Déploiement des conteneurs
- ✅ Création du compte administrateur
- ✅ Génération de certificat SSL auto-signé
- ✅ Rapport d'installation détaillé

**Usage:**
```bash
# Installation interactive (recommandé)
bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)

# Installation silencieuse
sudo ./install_proxmox.sh --silent \
  --domain panel.example.com \
  --admin-password "SecurePass123!" \
  --db-password "DBPass456!" \
  --email admin@example.com
```

**Options:**
- `--silent` - Mode non-interactif
- `--domain` - Nom de domaine du panel
- `--admin-password` - Mot de passe administrateur
- `--db-password` - Mot de passe base de données
- `--email` - Email pour notifications
- `--help` - Afficher l'aide

---

### 2. `configure_dns.sh` - Configuration DNS

Script assistant pour configurer l'accès au panel via un nom de domaine.

**Fonctionnalités:**
- ✅ Détection automatique de l'IP locale
- ✅ Configuration de /etc/hosts
- ✅ Instructions pour différents systèmes (Linux, macOS, Windows)
- ✅ Guide pour Pi-hole, AdGuard, routeurs
- ✅ Génération de script PowerShell pour Windows

**Usage:**
```bash
sudo ./configure_dns.sh
```

Le script propose plusieurs options:
1. Configurer /etc/hosts localement
2. Afficher les instructions DNS complètes
3. Générer un script pour Windows
4. Tout afficher

---

### 3. `backup_iptv.sh` - Sauvegarde Automatique

Script de sauvegarde complète avec rotation automatique.

**Fonctionnalités:**
- ✅ Sauvegarde de la base de données PostgreSQL
- ✅ Sauvegarde des fichiers de configuration
- ✅ Sauvegarde des volumes Docker
- ✅ Compression et archivage
- ✅ Rotation automatique (7 jours par défaut)
- ✅ Vérification d'intégrité
- ✅ Logging détaillé
- ✅ Notifications par email (optionnel)

**Usage:**
```bash
# Sauvegarde standard
sudo ./backup_iptv.sh

# Sauvegarde dans un répertoire personnalisé
sudo ./backup_iptv.sh --destination /mnt/nas/backups

# Sauvegarde avec 14 jours de rétention
sudo ./backup_iptv.sh --retention 14

# Sauvegarde avec notification email
sudo ./backup_iptv.sh --email admin@example.com
```

**Options:**
- `--destination DIR` - Répertoire de destination (défaut: /opt/backups/iptv)
- `--retention DAYS` - Jours de rétention (défaut: 7)
- `--email ADDRESS` - Email pour notifications
- `--help` - Afficher l'aide

**Structure de sauvegarde:**
```
/opt/backups/iptv/
├── iptv_panel_backup_20240115_020000.tar.gz
├── iptv_panel_backup_20240115_020000_manifest.txt
└── temp_20240115_020000/
    ├── database_20240115_020000.sql.gz
    ├── config/
    │   ├── .env
    │   ├── docker-compose.yml
    │   └── docker/
    └── volumes/
        ├── postgres_data_20240115_020000.tar.gz
        └── certbot_certs_20240115_020000.tar.gz
```

---

### 4. `monitor_panel.sh` - Surveillance Système

Script de monitoring complet avec alertes.

**Fonctionnalités:**
- ✅ État des conteneurs Docker
- ✅ Utilisation CPU/RAM/Disque
- ✅ Tests de disponibilité HTTP/HTTPS
- ✅ État de PostgreSQL et Redis
- ✅ Analyse des logs récents
- ✅ Alertes par email
- ✅ Rapport coloré et formaté
- ✅ Mode cron pour automatisation

**Usage:**
```bash
# Vérification rapide
./monitor_panel.sh

# Vérification complète
./monitor_panel.sh --check-all

# Mode alerte (pour cron)
./monitor_panel.sh --alert --email admin@example.com

# Sortie JSON
./monitor_panel.sh --json
```

**Options:**
- `--check-all` - Vérifications détaillées
- `--alert` - Mode alerte (codes de sortie)
- `--email ADDRESS` - Email pour alertes
- `--json` - Format JSON
- `--help` - Afficher l'aide

**Codes de sortie:**
- `0` - Tout fonctionne correctement
- `1` - Problèmes critiques détectés
- `2` - Avertissements détectés

**Exemple de sortie:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
État des Conteneurs Docker
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ panel: Running
✅ db: Running
✅ redis: Running
✅ nginx: Running

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Utilisation des Ressources Système
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ CPU: 25%
✅ RAM: 2.1GB/4.0GB (52%)
✅ Disque: 15GB/50GB (30%)
```

---

### 5. `update_panel.sh` - Mise à Jour

Script de mise à jour automatique avec sauvegarde et rollback.

**Fonctionnalités:**
- ✅ Vérification des mises à jour disponibles
- ✅ Affichage du changelog
- ✅ Sauvegarde automatique avant mise à jour
- ✅ Reconstruction des conteneurs si nécessaire
- ✅ Application des migrations de base de données
- ✅ Vérification de santé post-mise à jour
- ✅ Rollback automatique en cas d'échec

**Usage:**
```bash
# Vérifier les mises à jour
./update_panel.sh --check

# Appliquer les mises à jour (avec confirmation)
./update_panel.sh --apply

# Appliquer sans confirmation
sudo ./update_panel.sh --apply --force
```

**Options:**
- `--check` - Vérifier les mises à jour (défaut)
- `--apply` - Appliquer les mises à jour
- `--force` - Pas de confirmation
- `--help` - Afficher l'aide

**Workflow recommandé:**
```bash
# 1. Vérifier les mises à jour disponibles
./update_panel.sh --check

# 2. Consulter le changelog affiché

# 3. Appliquer la mise à jour
sudo ./update_panel.sh --apply
```

---

### 6. `uninstall.sh` - Désinstallation

Script de désinstallation propre avec options de préservation.

**Fonctionnalités:**
- ✅ Arrêt des conteneurs
- ✅ Suppression des conteneurs et images
- ✅ Suppression des volumes (optionnel)
- ✅ Nettoyage des fichiers
- ✅ Gestion des sauvegardes
- ✅ Nettoyage des logs et cron
- ✅ Mode interactif sécurisé

**Usage:**
```bash
# Désinstallation complète (interactive)
sudo ./uninstall.sh

# Désinstaller en gardant les données
sudo ./uninstall.sh --keep-data

# Désinstaller en gardant les sauvegardes
sudo ./uninstall.sh --keep-backups

# Garder données et sauvegardes
sudo ./uninstall.sh --keep-data --keep-backups
```

**Options:**
- `--keep-data` - Préserver les volumes de données
- `--keep-backups` - Préserver les sauvegardes
- `--keep-config` - Sauvegarder la configuration
- `--help` - Afficher l'aide

---

## 📦 Installation Rapide

### Méthode 1: Installation directe (recommandé)

```bash
# Télécharger et exécuter le script d'installation
bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)
```

### Méthode 2: Cloner le dépôt

```bash
# Cloner le dépôt
git clone https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet.git
cd IpTvPanel_Docker_Complet

# Rendre les scripts exécutables
chmod +x scripts/proxmox/*.sh

# Lancer l'installation
sudo ./scripts/proxmox/install_proxmox.sh
```

---

## ⚙️ Configuration Cron

### Sauvegardes Automatiques

Sauvegardes quotidiennes à 2h du matin:

```bash
# Éditer le crontab
sudo crontab -e

# Ajouter cette ligne
0 2 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh --email admin@example.com >> /var/log/iptv-panel/backup-cron.log 2>&1
```

### Monitoring Continu

Vérification toutes les 5 minutes:

```bash
# Éditer le crontab
sudo crontab -e

# Ajouter cette ligne
*/5 * * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --alert --email admin@example.com >> /var/log/iptv-panel/monitor-cron.log 2>&1
```

### Vérification des Mises à Jour

Vérification quotidienne à minuit:

```bash
# Éditer le crontab
sudo crontab -e

# Ajouter cette ligne
0 0 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/update_panel.sh --check >> /var/log/iptv-panel/update-check.log 2>&1
```

---

## 🔧 Utilisation Détaillée

### Workflow Complet d'Installation

```bash
# 1. Installation du panel
sudo bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)

# 2. Configuration DNS
sudo /opt/IpTvPanel_Docker_Complet/scripts/proxmox/configure_dns.sh

# 3. Vérifier l'installation
/opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --check-all

# 4. Créer une sauvegarde initiale
sudo /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh

# 5. Configurer les sauvegardes automatiques
sudo crontab -e
# Ajouter: 0 2 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh
```

### Maintenance Régulière

```bash
# Vérifier l'état du système
./monitor_panel.sh --check-all

# Consulter les logs
cd /opt/IpTvPanel_Docker_Complet
docker compose logs -f

# Vérifier les mises à jour
./update_panel.sh --check

# Créer une sauvegarde manuelle
sudo ./backup_iptv.sh
```

### Mise à Jour du Panel

```bash
# 1. Vérifier les mises à jour disponibles
./update_panel.sh --check

# 2. Créer une sauvegarde de précaution
sudo ./backup_iptv.sh

# 3. Appliquer la mise à jour
sudo ./update_panel.sh --apply

# 4. Vérifier le fonctionnement
./monitor_panel.sh --check-all
```

---

## 🐛 Dépannage

### Problème: Les conteneurs ne démarrent pas

```bash
# Vérifier les logs
cd /opt/IpTvPanel_Docker_Complet
docker compose logs

# Vérifier l'état des conteneurs
docker compose ps

# Redémarrer les conteneurs
docker compose restart
```

### Problème: Le panel n'est pas accessible

```bash
# Vérifier la disponibilité HTTP/HTTPS
./monitor_panel.sh

# Vérifier la configuration DNS
sudo ./configure_dns.sh

# Vérifier Nginx
docker compose logs nginx

# Vérifier les ports
sudo netstat -tulpn | grep -E ':(80|443)'
```

### Problème: Erreur de base de données

```bash
# Vérifier PostgreSQL
docker compose exec db pg_isready -U iptv_admin -d iptv_panel

# Consulter les logs
docker compose logs db

# Redémarrer la base de données
docker compose restart db
```

### Problème: Espace disque insuffisant

```bash
# Vérifier l'espace disque
df -h

# Nettoyer les anciennes sauvegardes
sudo ./backup_iptv.sh --retention 3

# Nettoyer Docker
docker system prune -a --volumes
```

### Restauration depuis une Sauvegarde

```bash
# 1. Arrêter les conteneurs
cd /opt/IpTvPanel_Docker_Complet
docker compose down

# 2. Extraire la sauvegarde
cd /opt/backups/iptv
tar xzf iptv_panel_backup_YYYYMMDD_HHMMSS.tar.gz

# 3. Restaurer la base de données
gunzip < temp_YYYYMMDD_HHMMSS/database_YYYYMMDD_HHMMSS.sql.gz | \
  docker compose exec -T db psql -U iptv_admin -d iptv_panel

# 4. Redémarrer les conteneurs
docker compose up -d
```

---

## 📊 Logs et Fichiers Importants

### Emplacements des Logs

```
/var/log/iptv-panel/
├── install.log          # Log d'installation
├── backup.log           # Log des sauvegardes
├── monitor.log          # Log du monitoring
├── update.log           # Log des mises à jour
└── uninstall.log        # Log de désinstallation
```

### Emplacements des Fichiers

```
/opt/IpTvPanel_Docker_Complet/
├── .env                 # Configuration environnement
├── docker-compose.yml   # Configuration Docker
├── INSTALLATION_INFO.txt # Infos d'installation
└── scripts/proxmox/     # Scripts de gestion

/opt/backups/iptv/
└── iptv_panel_backup_*.tar.gz  # Sauvegardes
```

---

## 🔒 Sécurité

### Bonnes Pratiques

1. **Mots de passe forts**: Utilisez des mots de passe complexes
2. **Sauvegardes régulières**: Configurez les sauvegardes automatiques
3. **Mises à jour**: Vérifiez régulièrement les mises à jour
4. **Monitoring**: Activez les alertes email
5. **Logs**: Surveillez les logs régulièrement
6. **Permissions**: Protégez les fichiers sensibles (chmod 600 .env)

### Commandes de Sécurité

```bash
# Vérifier les permissions du fichier .env
ls -la /opt/IpTvPanel_Docker_Complet/.env

# Corriger les permissions si nécessaire
sudo chmod 600 /opt/IpTvPanel_Docker_Complet/.env

# Vérifier les conteneurs en cours d'exécution
docker ps

# Consulter les tentatives de connexion
docker compose logs panel | grep -i "login\|auth"
```

---

## 📞 Support

- **Documentation**: [PROXMOX_GUIDE.md](../../docs/PROXMOX_GUIDE.md)
- **Issues**: [GitHub Issues](https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet/issues)
- **Logs**: `/var/log/iptv-panel/`

---

## 📝 License

Ces scripts font partie du projet IpTvPanel_Docker_Complet et sont distribués sous licence MIT.

---

**Dernière mise à jour**: 2024-11-15
