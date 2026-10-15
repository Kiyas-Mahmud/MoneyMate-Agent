import secrets
import warnings
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=BACKEND_DIR / ".env", case_sensitive=True, extra="ignore")

    APP_NAME: str = "MoneyMate Agent"
    ENVIRONMENT: str = "development"

    # SQLite by default so the project runs with zero setup; set a MySQL/Postgres URL in production.
    DATABASE_URL: str = f"sqlite:///{BACKEND_DIR / 'moneymate.db'}"

    JWT_SECRET_KEY: str = Field(default="")
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 120

    CORS_ORIGINS: str = "http://localhost:3000"

    GEMINI_API_KEY: str = ""
    GEMINI_MODEL: str = "gemini-2.5-flash"

    FX_LIVE: bool = True
    FX_API_URL: str = "https://open.er-api.com/v6/latest/USD"
    FX_CACHE_SECONDS: int = 3600

    MODEL_BUNDLE_PATH: str = str(BACKEND_DIR / "ml" / "artifacts" / "hybrid_risk_model.joblib")

    # Verification: no money ever moves without the student's verification.
    # "device": the phone signs a one-time challenge with a key unlocked by Face ID / fingerprint.
    # "sandbox": accepts {"sandbox": true} instead of a signature (demos through the API docs only).
    VERIFICATION_MODE: str = "device"
    CONFIRMATION_TTL_MINUTES: int = 15          # payments the student starts
    SCHEDULED_TTL_HOURS: int = 24               # payments prepared by the daily monitor

    # Daily monitor (deadlines, standing instructions, incoming money, low balance)
    MONITOR_ENABLED: bool = True
    MONITOR_HOUR: int = 8                       # local server time
    # Push notifications through the Expo push service (mobile app); off by default
    PUSH_ENABLED: bool = False
    EXPO_PUSH_URL: str = "https://exp.host/--/api/v2/push/send"

    DEMO_USER_PASSWORD: str = "Demo@2026"

    # Receipts: HMAC key for verification codes (defaults to a key derived from JWT_SECRET_KEY)
    RECEIPT_SIGNING_KEY: str = ""
    PUBLIC_BASE_URL: str = "http://localhost:8000"

    @property
    def cors_origins(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]


settings = Settings()

if settings.ENVIRONMENT == "production" and settings.VERIFICATION_MODE != "device":
    raise RuntimeError("VERIFICATION_MODE must be 'device' in production: payments need a phone signature.")

if not settings.JWT_SECRET_KEY:
    warnings.warn("JWT_SECRET_KEY is not set; using a random key (tokens reset on restart).")
    settings.JWT_SECRET_KEY = secrets.token_urlsafe(48)
