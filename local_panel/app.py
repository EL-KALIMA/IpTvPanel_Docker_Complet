"""
IPTV Panel - Main Application
Professional IPTV management system
"""
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, send_file, abort, has_request_context, current_app, session
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from flask_migrate import Migrate
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path
import secrets
import os
import re
import json
import subprocess
import redis
import hashlib
from dotenv import load_dotenv

from database.models import db, Admin, User, Connection, Channel, SystemLog, Settings, M3USource

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / '.env')

from services.streaming import StreamingService
from services.cloudflare import CloudflareService

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', secrets.token_hex(32))
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'postgresql://user:password@host/dbname')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {'pool_pre_ping': True, 'pool_recycle': 300}

ADMIN_API_TOKEN = os.environ.get('ADMIN_API_TOKEN', '').strip()

# Initialize Redis for temporary data storage (M3U import sessions)
try:
    redis_url = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
    redis_client = redis.from_url(redis_url, decode_responses=True)
    redis_client.ping()  # Test connection
    print(f"✓ Redis connected: {redis_url}")
except Exception as e:
    print(f"⚠ Redis not available: {e}. M3U import will use alternative storage.")
    redis_client = None

db.init_app(app)
migrate = Migrate(app, db)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

@login_manager.user_loader
def load_user(user_id):
    return Admin.query.get(int(user_id))

# Context processor for templates
@app.context_processor
def inject_globals():
    return {
        'now': datetime.utcnow(),
        'app_name': Settings.get('server_name', 'IPTV Panel'),
        'version': '1.0.0',
        'Settings': Settings
    }


def _external_ip():
    return request.remote_addr if has_request_context() else None


def _log_external(service: str, success: bool, message: str, detail: str = '') -> None:
    entry = message if success or not detail else f"{message} - {detail}"
    level = 'INFO' if success else 'ERROR'
    SystemLog.log(level, service, entry, _external_ip())


def sync_user_with_streaming(user, action: str, plain_password: str | None = None) -> tuple[bool, str]:
    success, detail = StreamingService.sync_user(user, action, plain_password)
    action_label = f"{action.capitalize()} user {user.username}"
    _log_external('STREAMING', success, action_label, str(detail))
    return success, str(detail)


def sync_channel_with_streaming(channel, action: str) -> tuple[bool, str]:
    success, detail = StreamingService.sync_channel(channel, action)
    action_label = f"{action.capitalize()} channel {channel.channel_id}"
    _log_external('STREAMING', success, action_label, str(detail))
    return success, str(detail)


def purge_playlist_cache(tokens: list[str], domain: str | None = None) -> tuple[bool, str]:
    domain = domain or Settings.get('stream_domain', request.host if has_request_context() else '')
    success, detail = CloudflareService.purge_urls(CloudflareService.playlist_urls(domain, tokens))
    _log_external('CLOUDFLARE', success, f"Purge playlist cache ({', '.join(tokens)})", str(detail))
    return success, str(detail)


def purge_channel_cache(channel_id: str, domain: str | None = None) -> tuple[bool, str]:
    domain = domain or Settings.get('stream_domain', request.host if has_request_context() else '')
    success, detail = CloudflareService.purge_urls(CloudflareService.channel_urls(domain, channel_id))
    _log_external('CLOUDFLARE', success, f"Purge channel cache ({channel_id})", str(detail))
    return success, str(detail)


def get_allowed_categories() -> list[str]:
    raw = Settings.get('m3u_allowed_categories')
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [str(item).strip() for item in data if str(item).strip()]
    except (TypeError, json.JSONDecodeError):
        pass
    return [part.strip() for part in raw.split(',') if part.strip()]


def set_allowed_categories(categories: list[str]) -> None:
    cleaned = []
    for item in categories:
        text = str(item).strip()
        if text and text not in cleaned:
            cleaned.append(text)
    Settings.set('m3u_allowed_categories', json.dumps(cleaned))


def channel_stream_template() -> str:
    default_domain = request.host if has_request_context() else 'stream.local'
    default = f"http://{default_domain}/live/stream/{{CHANNEL_ID}}.m3u8?token={{TOKEN}}"
    template = Settings.get('m3u_url_format', default) or default
    if '{CHANNEL_ID}' not in template and '{channel_id}' not in template:
        return default
    return template


def streaming_playlist_template() -> str:
    stream_domain = Settings.get('stream_domain', request.host if has_request_context() else 'stream.local')
    default = f"https://{stream_domain}/get_playlist.php?token={{TOKEN}}"
    template = Settings.get('stream_playlist_format', '')
    return template or default


def streaming_playlist_url(token: str) -> str:
    template = streaming_playlist_template()
    return template.replace('{TOKEN}', token)


def panel_playlist_url(token: str) -> str:
    if has_request_context():
        try:
            return url_for('generate_playlist', token=token, _external=True)
        except RuntimeError:
            pass
    panel_domain = Settings.get('panel_domain', '').strip()
    if panel_domain:
        if panel_domain.startswith('http://') or panel_domain.startswith('https://'):
            base = panel_domain.rstrip('/')
            return f"{base}/playlist/{token}.m3u8"
        return f"https://{panel_domain.rstrip('/')}/playlist/{token}.m3u8"
    return f"/playlist/{token}.m3u8"


def sync_channels_from_streaming(force: bool = False) -> None:
    """Pull the channel catalog from the streaming API and mirror it locally."""
    if not StreamingService.is_configured():
        return

    last_sync_raw = Settings.get('channel_sync_timestamp')
    if not force and last_sync_raw:
        try:
            last_sync = datetime.fromisoformat(last_sync_raw)
        except ValueError:
            last_sync = None
        if last_sync and datetime.utcnow() - last_sync < timedelta(minutes=5):
            return

    success, payload = StreamingService.fetch_channels()
    if not success:
        current_app.logger.warning("Channel sync failed: %s", payload)
        return

    records = []
    if isinstance(payload, dict):
        records = payload.get('channels') or []
    elif isinstance(payload, list):
        records = payload

    if not isinstance(records, list):
        current_app.logger.warning("Channel sync payload unexpected: %s", type(payload))
        return

    def _truncate(text: str | None, limit: int) -> str | None:
        if text is None:
            return None
        text = str(text)
        return text if len(text) <= limit else text[:limit]

    existing = {channel.channel_id: channel for channel in Channel.query.all()}
    seen = set()
    changed = False

    for item in records:
        if not isinstance(item, dict):
            continue
        channel_id = str(item.get('channel_id') or item.get('id') or '').strip()
        if not channel_id:
            continue
        channel_id = _truncate(channel_id, 50)
        seen.add(channel_id)
        channel = existing.get(channel_id)
        if not channel:
            channel = Channel(channel_id=channel_id)
            db.session.add(channel)
            existing[channel_id] = channel
            changed = True

        name = _truncate(item.get('name'), 100) or channel.name or channel_id
        if channel.name != name:
            channel.name = name
            changed = True

        source_url = item.get('source_url') or item.get('resolved_source_url')
        source_url = _truncate(source_url, 500) or channel.source_url
        if source_url and channel.source_url != source_url:
            channel.source_url = source_url
            changed = True

        category = _truncate(item.get('category') or 'General', 50)
        if category and channel.category != category:
            channel.category = category
            changed = True

        logo = _truncate(item.get('logo') or item.get('logo_url'), 500)
        if logo and channel.logo_url != logo:
            channel.logo_url = logo
            changed = True

        quality = _truncate(item.get('quality'), 20)
        if quality and channel.quality != quality:
            channel.quality = quality
            changed = True

        epg_id = _truncate(item.get('epg_id'), 100)
        if epg_id and channel.epg_id != epg_id:
            channel.epg_id = epg_id
            changed = True

        view_count = item.get('view_count')
        try:
            view_value = int(view_count) if view_count is not None else None
        except (TypeError, ValueError):
            view_value = None
        if view_value is not None and channel.view_count != view_value:
            channel.view_count = view_value
            changed = True

        is_active = item.get('is_active')
        if is_active is not None and channel.is_active != bool(is_active):
            channel.is_active = bool(is_active)
            changed = True

    if changed:
        db.session.commit()
    Settings.set('channel_sync_timestamp', datetime.utcnow().isoformat())


# DEPRECATED: This function is no longer used after migration to database-only system
# The user_manager.sh script now calls the Flask API, so calling it from here creates a circular dependency
# All user creation now goes directly to the database via User model
# Kept for reference only - can be removed in future cleanup
def create_stream_user_via_script(username: str, days: int) -> tuple[dict | None, str]:
    """
    DEPRECATED: Do not use. This creates a circular dependency.
    User creation should be done directly via the User model and database.
    """
    current_app.logger.warning("create_stream_user_via_script is deprecated and should not be called")
    return None, "This function is deprecated - use direct database operations instead"


def apply_m3u_template_from_url(m3u_url: str | None, token: str | None) -> None:
    if not m3u_url or not token or token not in m3u_url:
        return
    template = m3u_url.replace(token, '{TOKEN}')
    if Settings.get('m3u_url_format') != template:
        Settings.set('m3u_url_format', template)


def get_token_length() -> int:
    try:
        return max(16, int(Settings.get('token_length', '64') or 64))
    except (TypeError, ValueError):
        return 64


def get_active_source_id():
    """Get the ID of the currently active M3U source, or None if no source is active"""
    active_source = M3USource.query.filter_by(is_active=True).first()
    return active_source.id if active_source else None


@app.before_request
def enforce_setup_wizard():
    if not current_user.is_authenticated:
        return
    if Settings.get('setup_complete') == 'true':
        return
    # allow wizard and auth endpoints while incomplete
    allowed = {'static', 'setup_wizard', 'logout'}
    endpoint = request.endpoint
    if endpoint is None or endpoint in allowed:
        return
    return redirect(url_for('setup_wizard'))

# ============================================================================
# ADMIN ROUTES
# ============================================================================

@app.route('/')
@login_required
def dashboard():
    total_users = User.query.count()
    active_users = User.query.filter(User.is_active == True, User.expiry_date > datetime.utcnow()).count()
    expired_users = User.query.filter(User.expiry_date <= datetime.utcnow()).count()

    # Only count channels from active M3U source
    active_source_id = get_active_source_id()
    if active_source_id:
        total_channels = Channel.query.filter_by(is_active=True, source_id=active_source_id).count()
    else:
        total_channels = 0
    
    recent_users = User.query.order_by(User.created_at.desc()).limit(10).all()
    
    active_connections = Connection.query.filter(
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).count()
    
    recent_logs = SystemLog.query.order_by(SystemLog.timestamp.desc()).limit(10).all()
    
    expiring_soon = User.query.filter(
        User.is_active == True,
        User.expiry_date > datetime.utcnow(),
        User.expiry_date < datetime.utcnow() + timedelta(days=7)
    ).order_by(User.expiry_date).all()
    
    return render_template('dashboard.html',
        total_users=total_users,
        active_users=active_users,
        expired_users=expired_users,
        total_channels=total_channels,
        recent_users=recent_users,
        active_connections=active_connections,
        recent_logs=recent_logs,
        expiring_soon=expiring_soon
    )

@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        admin = Admin.query.filter_by(username=username).first()
        
        if admin and admin.check_password(password):
            login_user(admin)
            admin.last_login = datetime.utcnow()
            db.session.commit()
            SystemLog.log('INFO', 'AUTH', f'Admin {username} logged in', request.remote_addr)
            return redirect(url_for('dashboard'))
        else:
            flash('Invalid username or password', 'danger')
            SystemLog.log('WARNING', 'AUTH', f'Failed login for {username}', request.remote_addr)
    
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    SystemLog.log('INFO', 'AUTH', f'Admin {current_user.username} logged out', request.remote_addr)
    logout_user()
    return redirect(url_for('login'))


@app.route('/xui/')
def xui_root():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))


@app.route('/setup', methods=['GET', 'POST'])
@login_required
def setup_wizard():
    if Settings.get('setup_complete') == 'true':
        return redirect(url_for('dashboard'))

    step = request.args.get('step', '1')
    try:
        step = int(step)
    except ValueError:
        step = 1

    server_name = Settings.get('server_name', 'Main Panel')
    timezone = Settings.get('timezone', 'UTC')
    language = Settings.get('language', 'English')

    streaming_config = Settings.get('streaming_server_config', '{}')
    try:
        streaming_config = json.loads(streaming_config)
    except json.JSONDecodeError:
        streaming_config = {}

    m3u_url_format = Settings.get('m3u_url_format', f"http://{Settings.get('stream_domain', request.host)}/live/stream_{{CHANNEL_ID}}.m3u8?token={{TOKEN}}")
    token_type = Settings.get('token_type', 'user')
    token_length = Settings.get('token_length', '64')

    if request.method == 'POST':
        if step == 1:
            server_name = request.form.get('server_name', server_name)
            timezone = request.form.get('timezone', timezone)
            language = request.form.get('language', language)
            Settings.set('server_name', server_name)
            Settings.set('timezone', timezone)
            Settings.set('language', language)
            return redirect(url_for('setup_wizard', step=2))

        if step == 2:
            config = {
                'name': request.form.get('stream_server_name', streaming_config.get('name', 'Hetzner-Stream-01')),
                'ip': request.form.get('stream_server_ip', streaming_config.get('ip', '')),
                'port': request.form.get('stream_server_port', streaming_config.get('port', '80')),
                'type': request.form.get('stream_server_type', streaming_config.get('type', 'Load Balancer')),
                'protocol': request.form.get('stream_server_protocol', streaming_config.get('protocol', 'HTTP')),
                'status': request.form.get('stream_server_status', streaming_config.get('status', 'Active')),
            }
            Settings.set('streaming_server_config', json.dumps(config))
            return redirect(url_for('setup_wizard', step=3))

        if step == 3:
            m3u_url_format = request.form.get('m3u_url_format', m3u_url_format)
            token_type = request.form.get('token_type', token_type)
            token_length = request.form.get('token_length', token_length)
            Settings.set('m3u_url_format', m3u_url_format)
            Settings.set('token_type', token_type)
            Settings.set('token_length', token_length)
            Settings.set('setup_complete', 'true')
            flash('Initial setup complete!', 'success')
            return redirect(url_for('dashboard'))

    return render_template(
        'setup_wizard.html',
        step=step,
        server_name=server_name,
        timezone=timezone,
        language=language,
        streaming_config=streaming_config,
        m3u_url_format=m3u_url_format,
        token_type=token_type,
        token_length=token_length
    )

# ============================================================================
# USER MANAGEMENT
# ============================================================================

@app.route('/users')
@login_required
def users_list():
    page = request.args.get('page', 1, type=int)
    search = request.args.get('search', '')
    status = request.args.get('status', 'all')
    
    query = User.query
    
    if search:
        query = query.filter(
            (User.username.like(f'%{search}%')) | (User.email.like(f'%{search}%'))
        )
    
    if status == 'active':
        query = query.filter(User.is_active == True, User.expiry_date > datetime.utcnow())
    elif status == 'expired':
        query = query.filter(User.expiry_date <= datetime.utcnow())
    elif status == 'disabled':
        query = query.filter(User.is_active == False)
    
    users = query.order_by(User.created_at.desc()).paginate(page=page, per_page=20)
    
    return render_template('users_list.html', users=users, search=search, status=status)

@app.route('/users/add', methods=['GET', 'POST'])
@login_required
def users_add():
    if request.method == 'POST':
        username = request.form.get('username').strip()
        password = request.form.get('password') or secrets.token_urlsafe(12)
        email = request.form.get('email', '').strip()
        days = int(request.form.get('days', 30))
        max_connections = int(request.form.get('max_connections', 1))
        notes = request.form.get('notes', '').strip()
        
        if not username or len(username) < 3:
            flash('Username must be at least 3 characters', 'danger')
            return redirect(url_for('users_add'))
        
        if User.query.filter_by(username=username).first():
            flash('Username already exists', 'danger')
            return redirect(url_for('users_add'))
        
        user = User(
            username=username,
            email=email,
            expiry_date=datetime.utcnow() + timedelta(days=days),
            max_connections=max_connections,
            notes=notes
        )
        user.generate_token(get_token_length())
        user.set_password(password)

        db.session.add(user)
        db.session.commit()

        # Sync with streaming server (if configured) - pass plain password before it's hashed
        sync_success, sync_detail = sync_user_with_streaming(user, 'create', plain_password=password)
        if not sync_success:
            flash(f'Streaming server sync failed: {sync_detail}', 'warning')

        # Purge Cloudflare cache (if configured)
        purge_success, purge_detail = purge_playlist_cache([user.token])
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'USER', f'Created user: {username}', request.remote_addr)
        flash(f'User {username} created successfully!', 'success')
        return redirect(url_for('users_view', user_id=user.id))
    
    return render_template('users_add.html')

@app.route('/users/<int:user_id>')
@login_required
def users_view(user_id):
    user = User.query.get_or_404(user_id)

    active_conns = Connection.query.filter(
        Connection.user_id == user_id,
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).all()

    panel_url = panel_playlist_url(user.token)
    direct_stream_url = streaming_playlist_url(user.token)

    # Generate Xtream Codes format URL (password not stored in plaintext, user must provide it)
    xtream_url = url_for('get_php_playlist', username=user.username, password='<YOUR_PASSWORD>', type='m3u', _external=True)

    return render_template(
        'users_view.html',
        user=user,
        active_connections=active_conns,
        m3u_url=panel_url,
        streaming_m3u_url=direct_stream_url,
        xtream_m3u_url=xtream_url
    )

@app.route('/users/<int:user_id>/edit', methods=['GET', 'POST'])
@login_required
def users_edit(user_id):
    user = User.query.get_or_404(user_id)
    
    if request.method == 'POST':
        user.username = request.form.get('username')
        user.email = request.form.get('email', '')
        user.max_connections = int(request.form.get('max_connections'))
        user.is_active = request.form.get('is_active') == 'on'
        user.notes = request.form.get('notes', '')

        new_password = request.form.get('password')
        if new_password:
            user.set_password(new_password)

        db.session.commit()

        # Sync with streaming server - pass password only if it was changed
        sync_success, sync_detail = sync_user_with_streaming(user, 'update', plain_password=new_password if new_password else None)
        if not sync_success:
            flash(f'Streaming server sync failed: {sync_detail}', 'warning')

        purge_success, purge_detail = purge_playlist_cache([user.token])
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'USER', f'Updated user: {user.username}', request.remote_addr)
        flash('User updated successfully!', 'success')
        return redirect(url_for('users_view', user_id=user.id))
    
    return render_template('users_edit.html', user=user)

@app.route('/users/<int:user_id>/extend', methods=['POST'])
@login_required
def users_extend(user_id):
    user = User.query.get_or_404(user_id)
    days = int(request.form.get('days', 30))
    user.extend_subscription(days)
    db.session.commit()

    sync_success, sync_detail = sync_user_with_streaming(user, 'update')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    purge_success, purge_detail = purge_playlist_cache([user.token])
    if not purge_success:
        flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

    SystemLog.log('INFO', 'USER', f'Extended {user.username} by {days} days', request.remote_addr)
    flash(f'Subscription extended by {days} days', 'success')
    return redirect(url_for('users_view', user_id=user.id))

@app.route('/users/<int:user_id>/reset-token', methods=['POST'])
@login_required
def users_reset_token(user_id):
    user = User.query.get_or_404(user_id)
    old_token = user.token
    user.generate_token(get_token_length())
    db.session.commit()

    sync_success, sync_detail = sync_user_with_streaming(user, 'update')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    tokens_to_purge = [user.token]
    if old_token:
        tokens_to_purge.append(old_token)
    purge_success, purge_detail = purge_playlist_cache(tokens_to_purge)
    if not purge_success:
        flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

    SystemLog.log('INFO', 'USER', f'Reset token for {user.username}', request.remote_addr)
    flash('Token reset successfully!', 'warning')
    return redirect(url_for('users_view', user_id=user.id))

@app.route('/users/<int:user_id>/delete', methods=['POST'])
@login_required
def users_delete(user_id):
    user = User.query.get_or_404(user_id)
    username = user.username
    token = user.token

    sync_success, sync_detail = sync_user_with_streaming(user, 'delete')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    purge_playlist_cache([token])

    db.session.delete(user)
    db.session.commit()

    SystemLog.log('WARNING', 'USER', f'Deleted user: {username}', request.remote_addr)
    flash(f'User {username} deleted', 'info')
    return redirect(url_for('users_list'))

# ============================================================================
# CHANNEL MANAGEMENT
# ============================================================================

@app.route('/channels')
@login_required
def channels_list():
    try:
        sync_channels_from_streaming()
    except Exception as exc:  # noqa: BLE001
        current_app.logger.warning("Channel sync raised an exception: %s", exc)

    # Only show channels from active M3U source
    active_source_id = get_active_source_id()
    if not active_source_id:
        flash('No active M3U source. Please activate a source from M3U Sources page.', 'warning')
        return redirect(url_for('m3u_sources_list'))

    category = request.args.get('category', '')
    channels = Channel.query.filter_by(source_id=active_source_id)

    if category:
        channels = channels.filter_by(category=category)

    channels = channels.order_by(Channel.category, Channel.name).all()
    categories = db.session.query(Channel.category).filter(Channel.source_id == active_source_id).distinct().all()

    return render_template('channels_list.html', channels=channels, categories=[c[0] for c in categories], selected_category=category)

@app.route('/categories/manage', methods=['GET', 'POST'])
@login_required
def categories_manage():
    # Only show categories from active M3U source
    active_source_id = get_active_source_id()
    if not active_source_id:
        flash('No active M3U source. Please activate a source first.', 'warning')
        return redirect(url_for('m3u_sources_list'))

    raw_categories = db.session.query(Channel.category).filter(Channel.source_id == active_source_id).distinct().all()
    all_categories = sorted({(c[0] or '').strip() for c in raw_categories if (c[0] or '').strip()})
    selected = [cat for cat in get_allowed_categories() if cat in all_categories]
    available = [cat for cat in all_categories if cat not in selected]

    if request.method == 'POST':
        payload = request.form.get('selected_categories', '').strip()
        new_selected: list[str] = []
        if payload:
            parsed = None
            try:
                parsed = json.loads(payload)
            except json.JSONDecodeError:
                pass
            if isinstance(parsed, list):
                source = parsed
            else:
                source = [part.strip() for part in payload.split(',')]
            for cat in source:
                text = str(cat).strip()
                if text and text in all_categories and text not in new_selected:
                    new_selected.append(text)
        set_allowed_categories(new_selected)
        flash('Category selection updated. These categories will appear in generated playlists.', 'success')
        return redirect(url_for('categories_manage'))

    return render_template(
        'categories_manage.html',
        available_categories=available,
        selected_categories=selected,
        total_categories=len(all_categories)
    )

@app.route('/channels/add', methods=['GET', 'POST'])
@login_required
def channels_add():
    if request.method == 'POST':
        channel_id = request.form.get('channel_id')
        name = request.form.get('name')
        category = request.form.get('category', 'General')
        source_url = request.form.get('source_url')
        logo_url = request.form.get('logo_url', '')
        quality = request.form.get('quality', 'medium')
        
        if Channel.query.filter_by(channel_id=channel_id).first():
            flash('Channel ID already exists', 'danger')
            return redirect(url_for('channels_add'))
        
        channel = Channel(
            channel_id=channel_id,
            name=name,
            category=category,
            source_url=source_url,
            logo_url=logo_url,
            quality=quality
        )
        
        db.session.add(channel)
        db.session.commit()

        sync_success, sync_detail = sync_channel_with_streaming(channel, 'create')
        if not sync_success:
            flash(f'Streaming server channel sync failed: {sync_detail}', 'warning')

        purge_success, purge_detail = purge_channel_cache(channel.channel_id)
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'CHANNEL', f'Added channel: {name}', request.remote_addr)
        flash(f'Channel {name} added successfully!', 'success')
        return redirect(url_for('channels_list'))
    
    return render_template('channels_add.html')

@app.route('/channels/<int:channel_id>/delete', methods=['POST'])
@login_required
def channels_delete(channel_id):
    channel = Channel.query.get_or_404(channel_id)
    name = channel.name

    sync_success, sync_detail = sync_channel_with_streaming(channel, 'delete')
    if not sync_success:
        flash(f'Streaming server channel sync failed: {sync_detail}', 'warning')

    purge_channel_cache(channel.channel_id)

    db.session.delete(channel)
    db.session.commit()
    SystemLog.log('WARNING', 'CHANNEL', f'Deleted channel: {name}', request.remote_addr)
    flash(f'Channel {name} deleted', 'info')
    return redirect(url_for('channels_list'))

def parse_m3u_content(m3u_content):
    """
    Enhanced M3U parser that extracts all attributes and handles various formats.
    Returns: (channels_list, detected_attributes_set)
    """
    lines = m3u_content.split('\n')
    channels = []
    detected_attrs = set()

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # Skip empty lines and comments (but not EXTINF)
        if not line or (line.startswith('#') and not line.startswith('#EXTINF')):
            i += 1
            continue

        if line.startswith('#EXTINF'):
            # Extract all attributes using flexible regex (handles both single and double quotes)
            attrs = {}

            # Extract attributes with double quotes
            for match in re.finditer(r'([\w-]+)="([^"]*)"', line):
                attr_name = match.group(1)
                attr_value = match.group(2)
                attrs[attr_name] = attr_value
                detected_attrs.add(attr_name)

            # Extract attributes with single quotes
            for match in re.finditer(r"([\w-]+)='([^']*)'", line):
                attr_name = match.group(1)
                attr_value = match.group(2)
                if attr_name not in attrs:  # Don't override double-quoted values
                    attrs[attr_name] = attr_value
                    detected_attrs.add(attr_name)

            # Extract channel name (after the last comma)
            name_match = re.search(r',(.+)$', line)
            channel_name = name_match.group(1).strip() if name_match else ''

            # Find the URL (skip empty lines after EXTINF)
            url = None
            j = i + 1
            while j < len(lines):
                potential_url = lines[j].strip()
                if potential_url and not potential_url.startswith('#'):
                    url = potential_url
                    break
                j += 1

            if url and channel_name:  # Only add if we have both URL and name
                channels.append({
                    'name': channel_name,
                    'url': url,
                    'attributes': attrs
                })

            i = j + 1 if url else i + 1
        else:
            # Handle plain TXT format (just URLs)
            if line.startswith('http') or line.startswith('rtmp'):
                channels.append({
                    'name': f'Channel {len(channels) + 1}',
                    'url': line,
                    'attributes': {}
                })
            i += 1

    return channels, detected_attrs


@app.route('/channels/import', methods=['GET', 'POST'])
@login_required
def channels_import():
    """Step 1: Upload and analyze M3U content"""
    if request.method == 'POST':
        import_method = request.form.get('import_method', 'paste')
        m3u_content = ''

        if import_method == 'url':
            # Fetch from URL
            m3u_url = request.form.get('m3u_url', '').strip()
            if not m3u_url:
                flash('Please provide M3U URL', 'danger')
                return redirect(url_for('channels_import'))

            try:
                SystemLog.log('INFO', 'M3U_IMPORT', f'Fetching M3U from URL: {m3u_url}', request.remote_addr)
                response = requests.get(m3u_url, timeout=30)
                response.raise_for_status()
                m3u_content = response.text

                # Log fetch success
                SystemLog.log('INFO', 'M3U_IMPORT',
                    f'Successfully fetched {len(m3u_content)} characters from URL',
                    request.remote_addr)

            except requests.exceptions.RequestException as e:
                flash(f'Failed to fetch M3U from URL: {str(e)}', 'danger')
                SystemLog.log('ERROR', 'M3U_IMPORT', f'URL fetch failed: {str(e)}', request.remote_addr)
                return redirect(url_for('channels_import'))

        else:
            # Paste method
            m3u_content = request.form.get('m3u_content', '')

        if not m3u_content:
            flash('Please provide M3U content', 'danger')
            return redirect(url_for('channels_import'))

        # Parse the M3U content
        channels, detected_attrs = parse_m3u_content(m3u_content)

        if not channels:
            flash('No valid channels found in the provided content', 'danger')
            return redirect(url_for('channels_import'))

        # Generate a unique session key for this import
        import_id = secrets.token_urlsafe(16)

        # Store content in Redis (expires in 1 hour) or fallback to session
        if redis_client:
            try:
                redis_client.setex(f'import:{import_id}:content', 3600, m3u_content)
                redis_client.setex(f'import:{import_id}:total', 3600, str(len(channels)))
                session['import_id'] = import_id
            except Exception as e:
                current_app.logger.error(f"Redis storage failed: {e}")
                flash('Unable to store import data. Please try with a smaller file.', 'danger')
                return redirect(url_for('channels_import'))
        else:
            # Fallback: store in session (will fail for large files)
            try:
                session['m3u_content'] = m3u_content
                session['m3u_total_channels'] = len(channels)
            except Exception as e:
                current_app.logger.error(f"Session storage failed: {e}")
                flash('File too large for session storage. Please configure Redis.', 'danger')
                return redirect(url_for('channels_import'))

        # Define available database fields
        db_fields = {
            'channel_id': 'Channel ID (unique identifier)',
            'name': 'Channel Name',
            'category': 'Category/Group',
            'source_url': 'Source URL',
            'logo_url': 'Logo URL',
            'epg_id': 'EPG ID',
            'quality': 'Quality'
        }

        # Create default mapping suggestions
        default_mapping = {
            'tvg-id': 'epg_id',
            'tvg-name': 'name',
            'tvg-logo': 'logo_url',
            'group-title': 'category',
        }

        return render_template('channels_import_map.html',
            detected_attrs=sorted(detected_attrs),
            db_fields=db_fields,
            default_mapping=default_mapping,
            preview_channels=channels[:5],
            total_channels=len(channels)
        )

    return render_template('channels_import.html')


@app.route('/channels/import/confirm', methods=['POST'])
@login_required
def channels_import_confirm():
    """Step 2: Import channels with user-defined field mapping and save as M3U source"""

    # Retrieve M3U content from Redis or session
    m3u_content = None
    import_id = session.get('import_id')

    if import_id and redis_client:
        try:
            m3u_content = redis_client.get(f'import:{import_id}:content')
        except Exception as e:
            current_app.logger.error(f"Redis retrieval failed: {e}")

    if not m3u_content:
        # Fallback to session
        m3u_content = session.get('m3u_content')

    if not m3u_content:
        flash('Session expired. Please upload your M3U file again.', 'danger')
        return redirect(url_for('channels_import'))

    # Get source name and activation preference
    source_name = request.form.get('source_name', '').strip()
    activate_now = request.form.get('activate_now') == 'on'

    if not source_name:
        flash('Please provide a name for this M3U source. The name field is required.', 'danger')
        # Parse M3U to show the mapping page again
        channels, detected_attrs = parse_m3u_content(m3u_content)
        default_mapping = {
            'tvg-id': 'epg_id',
            'tvg-logo': 'logo_url',
            'group-title': 'category',
            'tvg-name': 'name'
        }
        db_fields = {
            'channel_id': 'Channel ID',
            'name': 'Channel Name',
            'category': 'Category',
            'logo_url': 'Logo URL',
            'epg_id': 'EPG ID',
            'quality': 'Quality'
        }
        return render_template('channels_import_map.html',
            detected_attrs=sorted(detected_attrs),
            db_fields=db_fields,
            default_mapping=default_mapping,
            preview_channels=channels[:5],
            total_channels=len(channels))

    # Check if source name already exists
    if M3USource.query.filter_by(name=source_name).first():
        flash(f'Source name "{source_name}" already exists. Please choose a different name.', 'danger')
        # Parse M3U to show the mapping page again
        channels, detected_attrs = parse_m3u_content(m3u_content)
        default_mapping = {
            'tvg-id': 'epg_id',
            'tvg-logo': 'logo_url',
            'group-title': 'category',
            'tvg-name': 'name'
        }
        db_fields = {
            'channel_id': 'Channel ID',
            'name': 'Channel Name',
            'category': 'Category',
            'logo_url': 'Logo URL',
            'epg_id': 'EPG ID',
            'quality': 'Quality'
        }
        return render_template('channels_import_map.html',
            detected_attrs=sorted(detected_attrs),
            db_fields=db_fields,
            default_mapping=default_mapping,
            preview_channels=channels[:5],
            total_channels=len(channels))

    # Get user-defined mapping from form
    mapping = {}
    for key in request.form:
        if key.startswith('map_'):
            m3u_attr = key.replace('map_', '')
            db_field = request.form[key]
            if db_field and db_field != 'ignore':
                mapping[m3u_attr] = db_field

    # Parse M3U content again
    channels, detected_attrs = parse_m3u_content(m3u_content)

    # Create M3U Source record
    m3u_source = M3USource(
        name=source_name,
        is_active=activate_now,
        total_channels=len(channels),
        detected_attributes=json.dumps(list(detected_attrs)),
        field_mapping=json.dumps(mapping)
    )
    db.session.add(m3u_source)
    db.session.flush()  # Get the source ID

    # If activating this source, deactivate all others
    if activate_now:
        M3USource.query.filter(M3USource.id != m3u_source.id).update({'is_active': False})

    imported = 0
    skipped = 0
    new_channels = []

    # Get the highest existing import ID to avoid collisions
    last_import_channel = Channel.query.filter(
        Channel.channel_id.like('imp%')
    ).order_by(Channel.channel_id.desc()).first()

    if last_import_channel:
        try:
            last_id = int(last_import_channel.channel_id.replace('imp', ''))
            next_id = last_id + 1
        except (ValueError, AttributeError):
            next_id = 1000
    else:
        next_id = 1000

    for channel_data in channels:
        attrs = channel_data['attributes']

        # Build channel object using mapping
        channel_values = {
            'name': channel_data['name'],
            'source_url': channel_data['url'],
            'category': 'Imported',
            'logo_url': '',
            'epg_id': '',
            'quality': 'medium'
        }

        # Apply user mapping
        for m3u_attr, db_field in mapping.items():
            if m3u_attr in attrs and db_field in channel_values:
                value = attrs[m3u_attr]
                if value:  # Only update if value is not empty
                    channel_values[db_field] = value

        # Generate unique channel_id
        # Check if user mapped an M3U attribute to channel_id
        channel_id_source = mapping.get('tvg-id', None)
        if channel_id_source == 'channel_id' and attrs.get('tvg-id'):
            # Use tvg-id as channel_id if mapped
            proposed_id = attrs['tvg-id']
            # Sanitize: remove special chars, limit length
            proposed_id = re.sub(r'[^a-zA-Z0-9_-]', '', proposed_id)[:50]
            if proposed_id and not Channel.query.filter_by(channel_id=proposed_id).first():
                channel_id = proposed_id
            else:
                channel_id = f'{next_id}'
                next_id += 1
        else:
            channel_id = f'{next_id}'
            next_id += 1

        # Check for duplicate
        if Channel.query.filter_by(channel_id=channel_id).first():
            skipped += 1
            continue

        # Create channel linked to this M3U source
        channel = Channel(
            channel_id=channel_id,
            name=channel_values['name'][:100],
            category=channel_values['category'][:50],
            source_url=channel_values['source_url'][:500],
            logo_url=channel_values['logo_url'][:500] if channel_values['logo_url'] else None,
            epg_id=channel_values['epg_id'][:100] if channel_values['epg_id'] else None,
            quality=channel_values['quality'][:20] if channel_values['quality'] else 'medium',
            source_id=m3u_source.id  # Link to M3U source
        )

        db.session.add(channel)
        new_channels.append(channel)
        imported += 1

    db.session.commit()

    # Sync with streaming server ONLY if this source is being activated
    sync_failures = []
    purge_failures = []
    if activate_now and new_channels:
        # Use parallel sync for faster bulk import
        SystemLog.log('INFO', 'M3U_IMPORT', f'Starting file-based sync of {len(new_channels)} channels...', request.remote_addr)

        success_count, failure_count, failed_ids = StreamingService.sync_channels_via_file(
            new_channels,
            app=current_app._get_current_object()
        )

        sync_failures = failed_ids

        SystemLog.log('INFO', 'M3U_IMPORT',
            f'Parallel sync complete: {success_count} succeeded, {failure_count} failed',
            request.remote_addr)

        # Note: Cloudflare purge still sequential (usually fast and less critical)
        for imported_channel in new_channels:
            purge_success, purge_detail = purge_channel_cache(imported_channel.channel_id)
            if not purge_success:
                purge_failures.append(f"{imported_channel.channel_id}")

    # Clear temporary data from Redis and session
    if import_id and redis_client:
        try:
            redis_client.delete(f'import:{import_id}:content')
            redis_client.delete(f'import:{import_id}:total')
        except Exception as e:
            current_app.logger.error(f"Redis cleanup failed: {e}")

    session.pop('import_id', None)
    session.pop('m3u_content', None)
    session.pop('m3u_total_channels', None)

    if sync_failures:
        flash(f'Streaming sync failed for channels: {", ".join(sync_failures[:5])}', 'warning')
    if purge_failures:
        flash(f'Cloudflare purge failed for channels: {", ".join(purge_failures[:5])}', 'warning')

    SystemLog.log('INFO', 'M3U_SOURCE', f'Created source "{source_name}" with {imported} channels ({skipped} skipped)', request.remote_addr)

    if activate_now:
        flash(f'M3U Source "{source_name}" created and activated with {imported} channels!', 'success')
    else:
        flash(f'M3U Source "{source_name}" created with {imported} channels. Activate it from M3U Sources page to use it.', 'success')

    return redirect(url_for('m3u_sources_list'))


# ============================================================================
# M3U SOURCES MANAGEMENT
# ============================================================================

@app.route('/m3u-sources')
@login_required
def m3u_sources_list():
    """List all M3U sources with their status"""
    sources = M3USource.query.order_by(M3USource.is_active.desc(), M3USource.uploaded_at.desc()).all()
    return render_template('m3u_sources_list.html', sources=sources)


@app.route('/m3u-sources/<int:source_id>/activate', methods=['POST'])
@login_required
def m3u_source_activate(source_id):
    """Activate a source and deactivate all others"""
    source = M3USource.query.get_or_404(source_id)

    if source.is_active:
        flash(f'Source "{source.name}" is already active.', 'info')
        return redirect(url_for('m3u_sources_list'))

    # Deactivate all sources
    M3USource.query.update({'is_active': False})

    # Activate this source
    source.is_active = True
    db.session.commit()

    # Sync all channels from this source to the streaming server using parallel sync
    channels = Channel.query.filter_by(source_id=source.id).all()

    if channels:
        SystemLog.log('INFO', 'M3U_SOURCE', f'Starting file-based sync of {len(channels)} channels for source "{source.name}"', request.remote_addr)

        success_count, failure_count, sync_failures = StreamingService.sync_channels_via_file(
            channels,
            app=current_app._get_current_object()
        )

        if sync_failures:
            flash(f'Source "{source.name}" activated, but {failure_count} channels failed to sync to streaming server.', 'warning')
        else:
            flash(f'Source "{source.name}" activated successfully! All {success_count} channels are now active.', 'success')

        SystemLog.log('INFO', 'M3U_SOURCE',
            f'Activated source "{source.name}": {success_count} synced, {failure_count} failed',
            request.remote_addr)
    else:
        flash(f'Source "{source.name}" activated (no channels to sync).', 'info')
        SystemLog.log('INFO', 'M3U_SOURCE', f'Activated source "{source.name}" (empty)', request.remote_addr)
    return redirect(url_for('m3u_sources_list'))


@app.route('/m3u-sources/<int:source_id>/deactivate', methods=['POST'])
@login_required
def m3u_source_deactivate(source_id):
    """Deactivate a source"""
    source = M3USource.query.get_or_404(source_id)

    if not source.is_active:
        flash(f'Source "{source.name}" is already inactive.', 'info')
        return redirect(url_for('m3u_sources_list'))

    source.is_active = False
    db.session.commit()

    flash(f'Source "{source.name}" deactivated. No channels are currently active.', 'warning')
    SystemLog.log('INFO', 'M3U_SOURCE', f'Deactivated source "{source.name}"', request.remote_addr)
    return redirect(url_for('m3u_sources_list'))


@app.route('/m3u-sources/<int:source_id>/delete', methods=['POST'])
@login_required
def m3u_source_delete(source_id):
    """Delete an M3U source and all its channels"""
    source = M3USource.query.get_or_404(source_id)

    if source.is_active:
        flash(f'Cannot delete active source "{source.name}". Please deactivate or activate another source first.', 'danger')
        return redirect(url_for('m3u_sources_list'))

    source_name = source.name
    channel_count = source.total_channels

    # Delete the source (channels will be cascade deleted)
    db.session.delete(source)
    db.session.commit()

    flash(f'Source "{source_name}" and its {channel_count} channels deleted successfully.', 'success')
    SystemLog.log('WARNING', 'M3U_SOURCE', f'Deleted source "{source_name}" with {channel_count} channels', request.remote_addr)
    return redirect(url_for('m3u_sources_list'))


@app.route('/m3u-sources/<int:source_id>')
@login_required
def m3u_source_view(source_id):
    """View details of an M3U source and its channels"""
    source = M3USource.query.get_or_404(source_id)
    page = request.args.get('page', 1, type=int)

    channels = Channel.query.filter_by(source_id=source.id).order_by(Channel.category, Channel.name).paginate(page=page, per_page=50)

    # Parse stored attributes and mapping
    detected_attrs = []
    if source.detected_attributes:
        try:
            detected_attrs = json.loads(source.detected_attributes)
        except json.JSONDecodeError:
            pass

    field_mapping = {}
    if source.field_mapping:
        try:
            field_mapping = json.loads(source.field_mapping)
        except json.JSONDecodeError:
            pass

    return render_template('m3u_source_view.html',
        source=source,
        channels=channels,
        detected_attrs=detected_attrs,
        field_mapping=field_mapping
    )


# ============================================================================
# PUBLIC API
# ============================================================================

def _extract_api_token():
    """Return API token from Authorization header, custom header, or query string."""
    auth_header = request.headers.get('Authorization', '')
    if auth_header and auth_header.lower().startswith('bearer '):
        return auth_header.split(' ', 1)[1].strip()
    header_token = request.headers.get('X-Api-Token') or request.headers.get('X-API-Token')
    if header_token:
        return header_token.strip()
    return request.args.get('api_token', '').strip()

@app.route('/api/users', methods=['POST'])
def api_create_user():
    if not ADMIN_API_TOKEN:
        return jsonify({'error': 'API token not configured'}), 503
    
    provided_token = _extract_api_token()
    if not provided_token or not secrets.compare_digest(provided_token, ADMIN_API_TOKEN):
        return jsonify({'error': 'Unauthorized'}), 401
    
    payload = request.get_json(silent=True)
    if not payload:
        return jsonify({'error': 'Invalid JSON payload'}), 400
    
    username = (payload.get('username') or '').strip()
    email = (payload.get('email') or '').strip()
    notes = (payload.get('notes') or '').strip()
    password = payload.get('password')
    plaintext_password = password or secrets.token_urlsafe(12)
    
    try:
        days_value = payload.get('days', payload.get('expiry_days', 30))
        days = int(days_value)
        if days <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify({'error': 'Invalid subscription days value'}), 400
    
    try:
        max_conn_value = payload.get('max_connections', 1)
        max_connections = int(max_conn_value)
        if max_connections <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify({'error': 'Invalid max_connections value'}), 400
    
    if len(username) < 3:
        return jsonify({'error': 'Username must be at least 3 characters'}), 400
    
    if User.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 409
    
    user = User(
        username=username,
        email=email,
        expiry_date=datetime.utcnow() + timedelta(days=days),
        max_connections=max_connections,
        notes=notes
    )
    user.generate_token(get_token_length())
    user.set_password(plaintext_password)
    
    db.session.add(user)
    db.session.commit()

    # Sync with streaming server (if configured)
    sync_success, sync_detail = sync_user_with_streaming(user, 'create', plain_password=plaintext_password)
    if not sync_success:
        current_app.logger.warning(f'Streaming server sync failed for {username}: {sync_detail}')
        # Don't fail the user creation - just log the issue

    # Purge Cloudflare cache (if configured)
    purge_success, purge_detail = purge_playlist_cache([user.token])
    if not purge_success:
        current_app.logger.warning(f'Cloudflare cache purge failed for {username}: {purge_detail}')

    playlist_url = panel_playlist_url(user.token)
    stream_playlist = streaming_playlist_url(user.token)

    SystemLog.log('INFO', 'API', f'Created user via API: {username}', request.remote_addr)

    return jsonify({
        'user_id': user.id,
        'username': user.username,
        'password': plaintext_password,
        'token': user.token,
        'expires_at': user.expiry_date.isoformat(),
        'max_connections': user.max_connections,
        'email': user.email,
        'm3u_url': playlist_url,
        'streaming_playlist_url': stream_playlist,
        'streaming_sync': {
            'success': sync_success,
            'detail': sync_detail
        },
        'cloudflare_purge': {
            'success': purge_success,
            'detail': purge_detail
        }
    }), 201

@app.route('/api/auth/<token>')
def api_auth(token):
    user = User.query.filter_by(token=token).first()
    
    if not user:
        return jsonify({'error': 'Invalid token', 'authorized': False}), 401
    
    if not user.is_active:
        return jsonify({'error': 'Account disabled', 'authorized': False}), 403
    
    if user.is_expired():
        return jsonify({'error': 'Subscription expired', 'authorized': False}), 403
    
    active_conns = Connection.query.filter(
        Connection.user_id == user.id,
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).count()
    
    if active_conns >= user.max_connections:
        return jsonify({'error': 'Connection limit reached', 'authorized': False}), 429
    
    user.last_access = datetime.utcnow()
    db.session.commit()
    
    return jsonify({
        'authorized': True,
        'username': user.username,
        'expiry': user.expiry_date.isoformat(),
        'max_connections': user.max_connections
    })

@app.route('/api/connection', methods=['POST'])
def api_connection():
    data = request.json or {}
    token = data.get('token')
    channel_id = data.get('channel_id')
    
    user = User.query.filter_by(token=token).first()
    if not user:
        return jsonify({'error': 'Invalid token'}), 401
    
    conn = Connection.query.filter_by(
        user_id=user.id,
        ip_address=request.remote_addr,
        channel_id=channel_id
    ).first()
    
    if not conn:
        conn = Connection(
            user_id=user.id,
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent', '')[:255],
            channel_id=channel_id
        )
        db.session.add(conn)
    else:
        conn.last_heartbeat = datetime.utcnow()
    
    db.session.commit()
    return jsonify({'status': 'ok'})

@app.route('/get.php')
def get_php_playlist():
    """
    Adapter endpoint to support legacy Xtream Codes-style playlist URLs.
    Authenticates via username and password query parameters and then
    serves the playlist using the internal token-based system.

    Supports query parameters:
    - username: User's username
    - password: User's password
    - type: m3u or m3u_plus
    - output: ts, m3u8, hls (optional, controls stream URL format)
    """
    username = request.args.get('username')
    password = request.args.get('password')
    m3u_type = request.args.get('type')
    output = request.args.get('output', 'm3u8')  # Default to m3u8 if not specified

    # Basic validation
    if not all([username, password, m3u_type]):
        return "Error: Missing username, password, or type parameter.", 400

    if m3u_type not in ['m3u_plus', 'm3u']:
        return "Error: Invalid type specified.", 400

    # Find and authenticate the user
    user = User.query.filter_by(username=username).first()

    if not user or not user.check_password(password):
        # Return an empty playlist for invalid credentials, as some apps expect this
        return "#EXTM3U\n", 200, {'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8'}

    # Check user status
    if not user.is_active or user.is_expired():
        return "Error: User account is inactive or expired.", 403

    # If valid, internally call the main playlist generator with the user's token
    # Pass the output format preference
    return generate_playlist(user.token, output_format=output)


@app.route('/playlist/<token>.m3u8')
def generate_playlist(token, output_format='m3u8'):
    """
    Generate M3U playlist for a user by token.

    Args:
        token: User's authentication token
        output_format: Stream URL extension format ('m3u8', 'ts', or 'hls')
    """
    user = User.query.filter_by(token=token).first()

    if not user or not user.is_active or user.is_expired():
        abort(403)

    # Only include channels from the active M3U source
    active_source_id = get_active_source_id()
    if not active_source_id:
        # No active source - return empty playlist
        return "#EXTM3U\n", 200, {'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8'}

    allowed_categories = get_allowed_categories()
    channels_query = Channel.query.filter_by(is_active=True, source_id=active_source_id)
    if allowed_categories:
        channels_query = channels_query.filter(Channel.category.in_(allowed_categories))
    channels = channels_query.order_by(Channel.category, Channel.name).all()
    stream_domain = Settings.get('stream_domain', request.host)
    format_template = channel_stream_template()

    # Normalize output format
    if output_format in ['ts', 'mpegts']:
        extension = '.ts'
    elif output_format in ['hls', 'm3u8']:
        extension = '.m3u8'
    else:
        extension = '.m3u8'  # Default

    m3u = "#EXTM3U\n"

    for channel in channels:
        m3u += f'#EXTINF:-1 tvg-id="{channel.channel_id}" tvg-name="{channel.name}" '
        if channel.logo_url:
            m3u += f'tvg-logo="{channel.logo_url}" '
        m3u += f'group-title="{channel.category}",{channel.name}\n'

        # Build stream URL with the requested output format
        stream_url = format_template.replace('{CHANNEL_ID}', channel.channel_id).replace('{TOKEN}', token)
        stream_url = stream_url.replace('{channel_id}', channel.channel_id).replace('{token}', token)

        # Replace extension if needed (e.g., change .m3u8 to .ts)
        if extension == '.ts' and '.m3u8' in stream_url:
            stream_url = stream_url.replace('.m3u8', extension)

        m3u += f'{stream_url}\n'

    user.last_access = datetime.utcnow()
    db.session.commit()

    return m3u, 200, {'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8'}


@app.route('/live/stream/<int:channel_id>.m3u8')
def live_stream(channel_id):
    """
    Stream a specific channel by ID with token authentication.
    Proxies the source stream URL.
    """
    token = request.args.get('token')
    if not token:
        abort(403, "Missing token")
    
    # Authenticate user by token
    user = User.query.filter_by(token=token).first()
    if not user or not user.is_active or user.is_expired():
        abort(403, "Invalid or expired token")
    
    # Get channel (convert to string to match VARCHAR type)
    channel = Channel.query.filter_by(channel_id=str(channel_id), is_active=True).first()
    if not channel:
        abort(404, "Channel not found")
    
    # Update user's last access
    user.last_access = datetime.utcnow()
    db.session.commit()
    
    # Redirect to the actual source URL
    return redirect(channel.source_url)

# ============================================================================
# SYSTEM
# ============================================================================

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    if request.method == 'POST':
        Settings.set('stream_domain', request.form.get('stream_domain', ''))
        Settings.set('stream_server_ip', request.form.get('stream_server_ip', ''))
        Settings.set('default_expiry_days', request.form.get('default_expiry_days', '30'))
        Settings.set('default_max_connections', request.form.get('default_max_connections', '2'))
        flash('Settings saved successfully!', 'success')
        return redirect(url_for('settings'))
    
    return render_template('settings.html')

@app.route('/logs')
@login_required
def logs():
    page = request.args.get('page', 1, type=int)
    level = request.args.get('level', '')
    category = request.args.get('category', '')
    
    query = SystemLog.query
    
    if level:
        query = query.filter_by(level=level)
    if category:
        query = query.filter_by(category=category)
    
    logs = query.order_by(SystemLog.timestamp.desc()).paginate(page=page, per_page=50)
    
    return render_template('logs.html', logs=logs, level=level, category=category)

@app.route('/api/stats')
@login_required
def api_stats():
    active_source_id = get_active_source_id()
    total_channels = 0
    if active_source_id:
        total_channels = Channel.query.filter_by(is_active=True, source_id=active_source_id).count()

    return jsonify({
        'total_users': User.query.count(),
        'active_users': User.query.filter(User.is_active == True, User.expiry_date > datetime.utcnow()).count(),
        'total_channels': total_channels,
        'active_connections': Connection.query.filter(
            Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
        ).count()
    })

# ============================================================================
# INITIALIZATION
# ============================================================================

def init_db():
    with app.app_context():
        db.create_all()
        
        if not Admin.query.filter_by(username='admin').first():
            admin = Admin(username='admin', email='admin@localhost')
            admin.set_password(os.environ.get('ADMIN_PASSWORD', 'GoldvisioN@1982'))
            db.session.add(admin)
            db.session.commit()
            print("✓ Created default admin")
        
        if not Settings.query.get('stream_domain'):
            Settings.set('stream_domain', os.environ.get('STREAM_DOMAIN', 'stream.yourdomain.com'))
            Settings.set('stream_server_ip', os.environ.get('STREAM_SERVER_IP', '0.0.0.0'))
            Settings.set('default_expiry_days', '30')
            Settings.set('default_max_connections', '2')
            Settings.set('token_length', Settings.get('token_length', '64'))
            Settings.set('setup_complete', Settings.get('setup_complete', 'false'))
            print("✓ Created default settings")

        if Settings.get('setup_complete') is None:
            Settings.set('setup_complete', 'false')

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000, debug=True)
