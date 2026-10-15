import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.database import SessionLocal, init_db
from app.routes import agent, auth, finance, mobile, system
from app.services import monitor
from app.services.risk.engine import load_bundle
from app.services.seed import seed

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    with SessionLocal() as db:
        seed(db)
    load_bundle()  # load the hybrid model once at startup
    task = asyncio.create_task(monitor.scheduler()) if settings.MONITOR_ENABLED else None
    yield
    if task:
        task.cancel()


app = FastAPI(title=settings.APP_NAME, version="1.0.0", lifespan=lifespan,
              description="AI agent that pays tuition and moves money for international students, "
                          "with a hybrid ML fraud guard and permission tiers.")

app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=False,
                   allow_methods=["GET", "POST"], allow_headers=["Authorization", "Content-Type"])

for r in (auth.router, finance.router, agent.router, mobile.router, system.router):
    app.include_router(r, prefix="/api")


@app.get("/api/health")
def health():
    return {"status": "ok", "llm": "gemini" if settings.GEMINI_API_KEY else "fallback-parser",
            "model": settings.GEMINI_MODEL if settings.GEMINI_API_KEY else None}
