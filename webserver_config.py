import os
from airflow.configuration import conf

basedir = os.path.abspath(os.path.dirname(__file__))

# The SQLAlchemy connection string.
SQLALCHEMY_DATABASE_URI = conf.get('database', 'SQL_ALCHEMY_CONN')

# Flask-WTF flag for CSRF
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = None

# AUTHENTICATION CONFIG
AUTH_TYPE = 1  # Database Auth
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = 'Public'

# CSRF Config - RELAXED FOR TESTING
WTF_CSRF_CHECK_DEFAULT = False
