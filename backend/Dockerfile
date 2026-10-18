# MoneyMate backend (FastAPI). Build from the backend/ folder:
#   docker build -t moneymate-backend .
#   docker run -d --name moneymate -p 8000:8000 --env-file .env -v moneymate-data:/data moneymate-backend
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    DATABASE_URL=sqlite:////data/moneymate.db

# libgomp: OpenMP runtime used by XGBoost
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
# The trained model (ml/artifacts) was saved with these library versions; keep them pinned so it loads.
# xgboost-cpu is the same library without the CUDA dependencies (about 300 MB smaller).
RUN grep -v '^xgboost' requirements.txt > /tmp/requirements.txt \
 && pip install -r /tmp/requirements.txt "xgboost-cpu==3.4.1" "scikit-learn==1.9.1" "numpy==2.5.4" \
    "pandas==3.0.6" "joblib==1.6.0" \
 && rm /tmp/requirements.txt

COPY app ./app
COPY ml ./ml
COPY scripts ./scripts

RUN useradd --create-home moneymate && mkdir -p /data && chown moneymate /data
USER moneymate
VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/anchors', timeout=4)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
