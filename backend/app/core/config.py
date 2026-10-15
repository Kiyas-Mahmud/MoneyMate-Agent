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

    MODEL_BUNDLE_PATH: str = str(BACKEND_DIR / "ml" / "artifacts" / "hybrid_risk_model.joblib")

    # Permission-tier limits (USD equivalent)
    AUTO_EXECUTE_LIMIT_USD: float = 200.0
    AUTO_EXECUTE_DAILY_LIMIT_USD: float = 500.0
    CONFIRMATION_TTL_MINUTES: int = 15

    DEMO_USER_PASSWORD: str = "Demo@2026"

    @property
    def cors_origins(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]


settings = Settings()

if not settings.JWT_SECRET_KEY:
    warnings.warn("JWT_SECRET_KEY is not set; using a random key (tokens reset on restart).")
    settings.JWT_SECRET_KEY = secrets.token_urlsafe(48)
