# Configurations Panel IPTV

Ce répertoire contient des fichiers de configuration exemple et templates pour différents scénarios d'installation du Panel IPTV.

## 📁 Fichiers Disponibles

### `.env.proxmox-example`

Template de configuration optimisé pour Proxmox VE (VM et LXC).

**Utilisation:**
```bash
# Copier le template
cp configs/.env.proxmox-example .env

# Éditer avec vos valeurs
nano .env

# Générer des valeurs sécurisées
openssl rand -hex 32  # Pour SECRET_KEY et ADMIN_API_TOKEN
openssl rand -hex 24  # Pour les mots de passe
```

**Caractéristiques:**
- ✅ Optimisé pour Proxmox VE 7.x et 8.x
- ✅ Support VM et conteneur LXC
- ✅ Configuration réseau adaptée
- ✅ Variables de monitoring et alertes
- ✅ Configuration sauvegardes automatiques
- ✅ Commentaires détaillés en français

### `nginx-proxy-manager.json`

Configuration exemple pour Nginx Proxy Manager.

**Utilisation:**

Ce fichier JSON contient:
- Configuration complète d'un Proxy Host pour le panel IPTV
- Configuration SSL avec Let's Encrypt
- Configuration avancée Nginx optimisée
- Règles de cache pour assets statiques
- Support WebSocket
- Headers de sécurité

**Scénarios d'utilisation:**
1. Vous avez déjà Nginx Proxy Manager installé sur Proxmox
2. Vous voulez exposer le panel via un reverse proxy
3. Vous gérez plusieurs services derrière NPM

**Guide d'application:**
```bash
# 1. Ouvrir NPM dans votre navigateur
http://PROXMOX_IP:81

# 2. Se connecter (défaut: admin@example.com / changeme)

# 3. Créer un nouveau Proxy Host
Hosts → Proxy Hosts → Add Proxy Host

# 4. Remplir selon la configuration dans le fichier JSON
   - Details: domaine, IP, port
   - SSL: Let's Encrypt
   - Advanced: copier la configuration personnalisée

# 5. Sauvegarder et tester
curl -I https://panel.example.com
```

## 🔧 Configurations Additionnelles

### Configuration Docker Compose Personnalisée

Si vous voulez personnaliser `docker-compose.yml`:

```bash
# Copier le fichier original
cp docker-compose.yml docker-compose.custom.yml

# Éditer
nano docker-compose.custom.yml

# Utiliser la version personnalisée
docker compose -f docker-compose.custom.yml up -d
```

### Configuration Nginx Personnalisée

Pour modifier la configuration Nginx interne:

```bash
# Éditer la configuration
nano docker/nginx/app.conf

# Redémarrer nginx
docker compose restart nginx
```

### Variables d'Environnement Avancées

Variables supplémentaires que vous pouvez ajouter dans `.env`:

```bash
# Optimisations PostgreSQL
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB
POSTGRES_MAX_CONNECTIONS=100

# Optimisations Redis
REDIS_MAXMEMORY=256mb
REDIS_MAXMEMORY_POLICY=allkeys-lru

# Nginx Workers
NGINX_WORKER_PROCESSES=auto
NGINX_WORKER_CONNECTIONS=2048

# Logging
LOG_LEVEL=INFO
LOG_FORMAT=json

# Timezone
TZ=Europe/Paris

# Limites de ressources
PANEL_MEMORY_LIMIT=1g
DB_MEMORY_LIMIT=512m
REDIS_MEMORY_LIMIT=256m
```

## 📊 Configurations par Scénario

### Scénario 1: Installation Simple (Local)

```bash
# Utiliser .env.proxmox-example
cp configs/.env.proxmox-example .env

# Configuration minimale
PANEL_DOMAIN=panel.local
CERTBOT_EMAIL=admin@example.com
DB_PASS=votre_mot_de_passe_db
ADMIN_PASSWORD=votre_mot_de_passe_admin
SECRET_KEY=$(openssl rand -hex 32)
ADMIN_API_TOKEN=$(openssl rand -hex 32)
```

### Scénario 2: Installation avec NPM

```bash
# 1. Configurer .env avec IP locale
PANEL_DOMAIN=panel.example.com
# ... autres variables

# 2. Installer le panel normalement
./scripts/proxmox/install_proxmox.sh

# 3. Configurer NPM selon nginx-proxy-manager.json
# Le panel sera accessible uniquement via l'IP locale
# NPM gérera l'accès externe et SSL
```

### Scénario 3: Installation Production (Accès Internet)

```bash
# 1. Configurer .env avec domaine public
PANEL_DOMAIN=panel.mondomaine.com
CERTBOT_EMAIL=admin@mondomaine.com
# ... autres variables

# 2. S'assurer que le domaine pointe vers IP publique
# 3. Configurer port forwarding 80/443
# 4. Installer avec SSL Let's Encrypt automatique
```

### Scénario 4: Serveur de Streaming Séparé

```bash
# Dans .env du panel
STREAM_DOMAIN=stream.mondomaine.com
STREAM_SERVER_IP=95.217.193.163
STREAMING_API_BASE_URL=http://95.217.193.163:5000
STREAMING_API_TOKEN=$(openssl rand -hex 32)

# Sur le serveur de streaming
# Installer et configurer avec le même token
```

## 🔐 Sécurité des Configurations

### Bonnes Pratiques

1. **Ne jamais commiter `.env`**
   ```bash
   # Vérifier que .env est dans .gitignore
   grep "^\.env$" .gitignore
   ```

2. **Permissions strictes**
   ```bash
   chmod 600 .env
   chown root:root .env
   ```

3. **Mots de passe forts**
   ```bash
   # Générer des mots de passe sécurisés
   openssl rand -base64 32  # 32 bytes = très fort
   openssl rand -hex 24     # 24 bytes = fort
   ```

4. **Rotation des secrets**
   ```bash
   # Changer les secrets régulièrement
   # 1. Générer nouvelles valeurs
   NEW_SECRET=$(openssl rand -hex 32)
   
   # 2. Mettre à jour .env
   sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$NEW_SECRET/" .env
   
   # 3. Redémarrer le panel
   docker compose restart panel
   ```

5. **Audit des configurations**
   ```bash
   # Vérifier qu'aucun secret n'est en clair dans les logs
   grep -r "DB_PASS\|SECRET_KEY\|API_TOKEN" /var/log/iptv-panel/
   
   # Ne devrait rien retourner
   ```

## 🛠️ Outils de Configuration

### Script de Validation

Créez un script pour valider votre configuration:

```bash
#!/bin/bash
# validate_config.sh

source .env

errors=0

# Vérifier les variables obligatoires
required_vars=(
    "PANEL_DOMAIN"
    "CERTBOT_EMAIL"
    "DB_PASS"
    "SECRET_KEY"
    "ADMIN_PASSWORD"
    "ADMIN_API_TOKEN"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Variable manquante: $var"
        errors=$((errors + 1))
    fi
done

# Vérifier les mots de passe faibles
if [ ${#DB_PASS} -lt 8 ]; then
    echo "⚠️  DB_PASS trop court (min 8 caractères)"
    errors=$((errors + 1))
fi

if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
    echo "⚠️  ADMIN_PASSWORD trop court (min 8 caractères)"
    errors=$((errors + 1))
fi

# Vérifier le format email
if [[ ! "$CERTBOT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "⚠️  Format email invalide"
    errors=$((errors + 1))
fi

if [ $errors -eq 0 ]; then
    echo "✅ Configuration valide!"
else
    echo "❌ $errors erreur(s) trouvée(s)"
    exit 1
fi
```

### Script de Génération

Générer automatiquement une configuration:

```bash
#!/bin/bash
# generate_config.sh

read -p "Nom de domaine: " domain
read -p "Email: " email
read -s -p "Mot de passe admin: " admin_pass
echo

# Générer les secrets
db_pass=$(openssl rand -hex 24)
secret_key=$(openssl rand -hex 32)
api_token=$(openssl rand -hex 32)

# Créer .env
cat > .env <<EOF
PANEL_DOMAIN=$domain
CERTBOT_EMAIL=$email
DB_NAME=iptv_panel
DB_USER=iptv_admin
DB_PASS=$db_pass
SECRET_KEY=$secret_key
ADMIN_PASSWORD=$admin_pass
ADMIN_API_TOKEN=$api_token
STREAM_DOMAIN=
STREAM_SERVER_IP=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=
STREAMING_API_BASE_URL=
STREAMING_API_TOKEN=
EOF

chmod 600 .env
echo "✅ Configuration générée dans .env"
```

## 📚 Ressources

- **Documentation Proxmox**: [docs/PROXMOX_GUIDE.md](../docs/PROXMOX_GUIDE.md)
- **Scripts d'installation**: [scripts/proxmox/](../scripts/proxmox/)
- **Docker Compose**: [docker-compose.yml](../docker-compose.yml)
- **README principal**: [README.md](../README.md)

## 💡 Conseils

1. **Toujours tester** les configurations dans un environnement de test avant la production
2. **Sauvegarder** vos configurations avant modification
3. **Documenter** toute personnalisation que vous faites
4. **Versionner** vos configurations personnalisées (sans les secrets)
5. **Auditer** régulièrement la sécurité de vos configurations

---

**Dernière mise à jour**: 2024-11-15

Pour toute question, consultez la documentation complète ou ouvrez une issue sur GitHub.
