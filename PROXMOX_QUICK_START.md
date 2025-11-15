# 🚀 Panel IPTV - Guide de Démarrage Rapide Proxmox

Guide de démarrage ultra-rapide pour installer le Panel IPTV sur Proxmox en 5 minutes.

## ⚡ Installation en 3 Étapes

### Étape 1: Créer le Conteneur/VM

**Option A: Conteneur LXC (Recommandé)**
```
Interface Proxmox → Create CT
- Hostname: iptv-panel
- Template: debian-12-standard
- Disk: 20 GB
- CPU: 2 cores
- RAM: 2048 MB
- Network: DHCP
```

**Option B: Machine Virtuelle**
```
Interface Proxmox → Create VM
- Name: iptv-panel
- ISO: debian-12 ou ubuntu-22.04
- Disk: 30 GB
- CPU: 2 cores
- RAM: 2048 MB
- Network: VirtIO
```

### Étape 2: Se Connecter et Installer

```bash
# Se connecter en SSH (remplacer IP_CONTENEUR)
ssh root@IP_CONTENEUR

# Lancer l'installation automatique
bash <(curl -s https://raw.githubusercontent.com/EL-KALIMA/IpTvPanel_Docker_Complet/main/scripts/proxmox/install_proxmox.sh)
```

Le script vous demandera:
- 🌐 **Nom de domaine**: panel.example.com
- 📧 **Email**: admin@example.com
- 🔑 **Mot de passe admin**: [votre mot de passe]
- 🔒 **Mot de passe DB**: [Entrée pour générer automatiquement]

⏱️ Temps d'installation: ~5-10 minutes

### Étape 3: Configurer l'Accès

**Option A: Accès Local (via /etc/hosts)**
```bash
# Sur votre machine locale (Linux/macOS)
sudo bash -c 'echo "192.168.1.100    panel.example.com" >> /etc/hosts'

# Sur Windows (PowerShell en Admin)
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "192.168.1.100    panel.example.com"
```

**Option B: DNS Public (pour accès Internet)**
```
1. Configurer votre domaine pour pointer vers votre IP publique
2. Configurer le port forwarding sur votre routeur (80, 443 → IP_CONTENEUR)
3. Le certificat Let's Encrypt sera généré automatiquement
```

## ✅ Vérification

Ouvrez votre navigateur: `https://panel.example.com`

**Connexion:**
- Username: `admin`
- Password: [le mot de passe que vous avez choisi]

## 🔧 Commandes Utiles

```bash
# Monitoring du système
/opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --check-all

# Créer une sauvegarde
sudo /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh

# Vérifier les mises à jour
/opt/IpTvPanel_Docker_Complet/scripts/proxmox/update_panel.sh --check

# Consulter les logs
cd /opt/IpTvPanel_Docker_Complet
docker compose logs -f

# Redémarrer les services
docker compose restart

# Arrêter les services
docker compose stop

# Démarrer les services
docker compose start
```

## 📚 Documentation Complète

Pour plus de détails, consultez:
- **Guide Proxmox Complet**: [docs/PROXMOX_GUIDE.md](docs/PROXMOX_GUIDE.md)
- **Guide des Scripts**: [scripts/proxmox/README.md](scripts/proxmox/README.md)
- **Guide des Configurations**: [configs/README.md](configs/README.md)
- **README Principal**: [README.md](README.md)

## 🆘 Problèmes Courants

### Le panel n'est pas accessible

```bash
# Vérifier que les conteneurs tournent
docker compose ps

# Vérifier les logs
docker compose logs nginx
docker compose logs panel

# Redémarrer les services
docker compose restart
```

### Certificat SSL invalide

C'est normal avec un certificat auto-signé. Acceptez l'exception dans votre navigateur.

Pour un certificat valide:
1. Votre domaine doit pointer vers votre IP publique
2. Les ports 80/443 doivent être accessibles depuis Internet
3. Let's Encrypt générera un certificat valide automatiquement

### Docker ne fonctionne pas dans LXC

```bash
# Sur l'hôte Proxmox, éditer la config du conteneur
nano /etc/pve/lxc/100.conf

# Ajouter ces lignes
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:

# Redémarrer le conteneur
pct stop 100 && pct start 100
```

## ⚙️ Configuration Automatique

### Sauvegardes Automatiques

```bash
# Éditer le crontab
sudo crontab -e

# Ajouter (sauvegarde quotidienne à 2h)
0 2 * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/backup_iptv.sh
```

### Monitoring Continu

```bash
# Éditer le crontab
sudo crontab -e

# Ajouter (vérification toutes les 5 minutes)
*/5 * * * * /opt/IpTvPanel_Docker_Complet/scripts/proxmox/monitor_panel.sh --alert --email admin@example.com
```

## 🎯 Prochaines Étapes

1. ✅ **Se connecter** au panel et changer le mot de passe admin
2. ✅ **Importer** vos playlists M3U via `/channels/import`
3. ✅ **Créer** des utilisateurs via `/users/add`
4. ✅ **Configurer** les sauvegardes automatiques (cron)
5. ✅ **Activer** le monitoring automatique (cron)

## 🔐 Sécurité

- ✅ Changez immédiatement le mot de passe admin
- ✅ Configurez le firewall (UFW)
- ✅ Utilisez HTTPS (Let's Encrypt)
- ✅ Activez les sauvegardes automatiques
- ✅ Surveillez les logs régulièrement

## 💡 Astuces

### Accès via VPN (Recommandé)

Pour un accès sécurisé sans exposition publique:

**Option 1: Tailscale (Plus Simple)**
```bash
# Sur le serveur Proxmox
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

**Option 2: WireGuard**
Voir le guide complet: [docs/PROXMOX_GUIDE.md#vpn-pour-accès-sécurisé](docs/PROXMOX_GUIDE.md#vpn-pour-accès-sécurisé)

### Utiliser Nginx Proxy Manager

Si vous utilisez déjà NPM sur Proxmox:
1. Consultez: [configs/nginx-proxy-manager.json](configs/nginx-proxy-manager.json)
2. Créez un Proxy Host pointant vers le conteneur IPTV
3. Configurez SSL via NPM

### Optimisations Performance

```bash
# Dans le conteneur
cd /opt/IpTvPanel_Docker_Complet

# Éditer docker-compose.yml pour ajuster les ressources
nano docker-compose.yml

# Augmenter les limites si nécessaire
# mem_limit: 2g  # Augmenter à 2GB ou plus
```

## 📞 Support

- **Issues GitHub**: [Issues](https://github.com/EL-KALIMA/IpTvPanel_Docker_Complet/issues)
- **Documentation**: [docs/](docs/)
- **Logs**: `/var/log/iptv-panel/`

---

**Version**: 1.0.0  
**Dernière mise à jour**: 2024-11-15

Bonne installation! 🎉
