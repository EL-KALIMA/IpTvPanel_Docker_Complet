"""
IPTV Panel Database Models
Complete schema for IPTV management system
"""
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from datetime import datetime, timedelta
import secrets
import bcrypt

db = SQLAlchemy()

class Admin(UserMixin, db.Model):
    """Admin users for panel access"""
    __tablename__ = 'admins'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(100))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    
    def set_password(self, password):
        self.password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    def check_password(self, password):
        return bcrypt.checkpw(password.encode('utf-8'), self.password_hash.encode('utf-8'))


class User(db.Model):
    """IPTV subscribers"""
    __tablename__ = 'users'

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(100))
    token = db.Column(db.String(64), unique=True, nullable=False, index=True)
    
    is_active = db.Column(db.Boolean, default=True, index=True)
    expiry_date = db.Column(db.DateTime, nullable=False, index=True)
    max_connections = db.Column(db.Integer, default=1)
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_access = db.Column(db.DateTime)
    total_bandwidth_mb = db.Column(db.Integer, default=0)
    notes = db.Column(db.Text)
    
    connections = db.relationship('Connection', backref='user', lazy=True, cascade='all, delete-orphan')

    def set_password(self, password):
        self.password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    def check_password(self, password):
        if not self.password_hash:
            return False
        return bcrypt.checkpw(password.encode('utf-8'), self.password_hash.encode('utf-8'))
    
    def generate_token(self, char_length=64):
        try:
            char_length = int(char_length)
        except (TypeError, ValueError):
            char_length = 64
        self.token = secrets.token_hex(max(16, char_length) // 2)
    
    def is_expired(self):
        return datetime.utcnow() > self.expiry_date
    
    def days_remaining(self):
        if self.is_expired():
            return 0
        return (self.expiry_date - datetime.utcnow()).days
    
    def extend_subscription(self, days):
        if self.is_expired():
            self.expiry_date = datetime.utcnow() + timedelta(days=days)
        else:
            self.expiry_date += timedelta(days=days)


class Connection(db.Model):
    """Active connections tracking"""
    __tablename__ = 'connections'
    
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False, index=True)
    ip_address = db.Column(db.String(45))
    user_agent = db.Column(db.String(255))
    channel_id = db.Column(db.String(50))
    connected_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_heartbeat = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    
    def is_active(self):
        if not self.last_heartbeat:
            return False
        return (datetime.utcnow() - self.last_heartbeat).seconds < 120


class M3USource(db.Model):
    """M3U source providers - each uploaded M3U list becomes a source"""
    __tablename__ = 'm3u_sources'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)
    is_active = db.Column(db.Boolean, default=False, index=True)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
    total_channels = db.Column(db.Integer, default=0)
    detected_attributes = db.Column(db.Text)  # JSON string of detected M3U attributes
    field_mapping = db.Column(db.Text)  # JSON string of user's field mapping
    description = db.Column(db.String(255))

    # Relationship to channels
    channels = db.relationship('Channel', backref='m3u_source', lazy=True, cascade='all, delete-orphan')

    @staticmethod
    def get_active():
        """Get the currently active M3U source"""
        return M3USource.query.filter_by(is_active=True).first()

    @staticmethod
    def activate(source_id):
        """Activate a source and deactivate all others"""
        # Deactivate all sources
        M3USource.query.update({'is_active': False})
        # Activate the specified source
        source = M3USource.query.get(source_id)
        if source:
            source.is_active = True
            db.session.commit()
            return True
        return False


class Channel(db.Model):
    """Available channels"""
    __tablename__ = 'channels'

    id = db.Column(db.Integer, primary_key=True)
    channel_id = db.Column(db.String(50), unique=True, nullable=False, index=True)
    name = db.Column(db.String(100), nullable=False)
    category = db.Column(db.String(50), default='General', index=True)
    source_url = db.Column(db.String(500), nullable=False)
    logo_url = db.Column(db.String(500))
    is_active = db.Column(db.Boolean, default=True, index=True)
    quality = db.Column(db.String(20), default='medium')
    epg_id = db.Column(db.String(100))
    view_count = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # Foreign key to M3U source
    source_id = db.Column(db.Integer, db.ForeignKey('m3u_sources.id'), nullable=True, index=True)

    def increment_views(self):
        self.view_count += 1
        db.session.commit()


class SystemLog(db.Model):
    """System logs"""
    __tablename__ = 'logs'
    
    id = db.Column(db.Integer, primary_key=True)
    timestamp = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    level = db.Column(db.String(20), index=True)
    category = db.Column(db.String(50), index=True)
    message = db.Column(db.Text)
    ip_address = db.Column(db.String(45))
    
    @staticmethod
    def log(level, category, message, ip=None):
        log = SystemLog(level=level, category=category, message=message, ip_address=ip)
        db.session.add(log)
        db.session.commit()


class Settings(db.Model):
    """System settings"""
    __tablename__ = 'settings'
    
    key = db.Column(db.String(100), primary_key=True)
    value = db.Column(db.Text)
    description = db.Column(db.String(255))
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    @staticmethod
    def get(key, default=None):
        setting = Settings.query.get(key)
        return setting.value if setting else default
    
    @staticmethod
    def set(key, value, description=None):
        setting = Settings.query.get(key)
        if setting:
            setting.value = value
            if description:
                setting.description = description
        else:
            setting = Settings(key=key, value=value, description=description)
            db.session.add(setting)
        db.session.commit()
