"""
Train the hybrid risk model and write ml/artifacts/hybrid_risk_model.joblib.

Pipeline (same architecture as our IEEE-CIS research ensemble, see ml/research/):
  1. Five supervised base learners: Logistic Regression, Random Forest, XGBoost,
     HistGradientBoosting, and a feed-forward neural network (FNN).
  2. An autoencoder trained on legitimate payments only (anomaly score).
  3. Out-of-fold base predictions train a logistic-regression meta-learner (stacking).
  4. Risk thresholds are chosen on a validation split; metrics are reported on a held-out test split.

Usage:  python -m ml.train_hybrid
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, f1_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold, train_test_split
from sklearn.neural_network import MLPClassifier, MLPRegressor
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from xgboost import XGBClassifier

from app.services.risk.features import FEATURE_NAMES
from app.services.risk.hybrid import BASE_MODELS, base_scores
from ml.generate_data import OUT as DATA_PATH, generate

ARTIFACT = Path(__file__).resolve().parent / "artifacts" / "hybrid_risk_model.joblib"
METRICS = Path(__file__).resolve().parent / "artifacts" / "metrics.json"
SEED = 42


def make_supervised():
    return {
        "logistic_regression": make_pipeline(StandardScaler(), LogisticRegression(max_iter=2000, C=1.0)),
        "random_forest": RandomForestClassifier(n_estimators=200, max_depth=12, min_samples_leaf=3,
                                                n_jobs=-1, random_state=SEED),
        "xgboost": XGBClassifier(n_estimators=300, max_depth=5, learning_rate=0.08, subsample=0.9,
                                 colsample_bytree=0.9, eval_metric="logloss", random_state=SEED, n_jobs=-1),
        "hist_gradient_boosting": HistGradientBoostingClassifier(max_iter=250, learning_rate=0.08, random_state=SEED),
        "fnn": make_pipeline(StandardScaler(), MLPClassifier(hidden_layer_sizes=(64, 32), alpha=1e-3,
                                                             early_stopping=True, max_iter=300, random_state=SEED)),
    }


def fit_autoencoder(X_legit):
    scaler = StandardScaler().fit(X_legit)
    Z = scaler.transform(X_legit)
    ae = MLPRegressor(hidden_layer_sizes=(16, 6, 16), max_iter=300, early_stopping=True, random_state=SEED)
    ae.fit(Z, Z)
    errors = np.sort(np.mean((ae.predict(Z) - Z) ** 2, axis=1))
    return ae, scaler, errors


def fit_all(X, y):
    models = make_supervised()
    for m in models.values():
        m.fit(X, y)
    ae, ae_scaler, errors = fit_autoencoder(X[y == 0])
    models["autoencoder"], models["ae_scaler"] = ae, ae_scaler
    return models, errors


def evaluate(y, p, threshold):
    pred = (p >= threshold).astype(int)
    return {
        "roc_auc": round(float(roc_auc_score(y, p)), 4),
        "pr_auc": round(float(average_precision_score(y, p)), 4),
        "f1": round(float(f1_score(y, pred)), 4),
        "precision": round(float(precision_score(y, pred, zero_division=0)), 4),
        "recall": round(float(recall_score(y, pred)), 4),
    }


def main():
    if not DATA_PATH.exists():
        DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
        generate(80000).to_csv(DATA_PATH, index=False)
    df = pd.read_csv(DATA_PATH)
    X, y = df[FEATURE_NAMES].to_numpy(dtype=float), df["is_fraud"].to_numpy()

    X_train, X_tmp, y_train, y_tmp = train_test_split(X, y, test_size=0.3, stratify=y, random_state=SEED)
    X_val, X_test, y_val, y_test = train_test_split(X_tmp, y_tmp, test_size=0.5, stratify=y_tmp, random_state=SEED)

    # Out-of-fold base predictions so the meta-learner never sees scores from models trained on the same rows
    oof = np.zeros((len(X_train), len(BASE_MODELS)))
    for k, (tr, va) in enumerate(StratifiedKFold(5, shuffle=True, random_state=SEED).split(X_train, y_train)):
        fold_models, fold_errors = fit_all(X_train[tr], y_train[tr])
        oof[va] = base_scores(fold_models, X_train[va], fold_errors)
        print(f"  fold {k + 1}/5 done")

    meta = LogisticRegression(max_iter=1000, C=1.0).fit(oof, y_train)
    models, legit_errors = fit_all(X_train, y_train)

    p_val = meta.predict_proba(base_scores(models, X_val, legit_errors))[:, 1]
    S_test = base_scores(models, X_test, legit_errors)
    p_test = meta.predict_proba(S_test)[:, 1]

    # Scores are strongly bimodal. On validation, payments scoring 0.10-0.70 are ~25-65% fraud (worth asking
    # the student) and payments >= 0.70 are >80% fraud (block). The band table is saved in metrics.
    t_medium, t_high = 0.10, 0.70
    bands = []
    for lo, hi in [(0, .1), (.1, .3), (.3, .5), (.5, .7), (.7, .9), (.9, 1.01)]:
        m = (p_val >= lo) & (p_val < hi)
        bands.append({"band": f"{lo:.1f}-{min(hi, 1):.1f}", "payments": int(m.sum()),
                      "fraud_rate": round(float(y_val[m].mean()), 3) if m.sum() else None})

    per_model = {name: round(float(roc_auc_score(y_test, S_test[:, i])), 4) for i, name in enumerate(BASE_MODELS)}
    metrics = {
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "data": f"synthetic student cross-border payments ({len(df)} rows, {y.mean():.2%} fraud, 1% label noise)",
        "split": {"train": len(y_train), "val": len(y_val), "test": len(y_test)},
        "thresholds": {"medium": t_medium, "high": t_high},
        "validation_score_bands": bands,
        "hybrid_test_at_medium": evaluate(y_test, p_test, t_medium),
        "hybrid_test_at_high": evaluate(y_test, p_test, t_high),
        "base_model_test_roc_auc": per_model,
        "meta_weights": dict(zip(BASE_MODELS, [round(float(w), 3) for w in meta.coef_[0]])),
    }

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({
        "version": "1.0.0",
        "feature_names": FEATURE_NAMES,
        "base_model_names": BASE_MODELS,
        "models": models,
        "legit_errors": legit_errors,
        "meta": meta,
        "thresholds": metrics["thresholds"],
        "metrics": metrics,
    }, ARTIFACT, compress=3)
    METRICS.write_text(json.dumps(metrics, indent=2))
    print(json.dumps(metrics, indent=2))
    print(f"saved -> {ARTIFACT}")


if __name__ == "__main__":
    main()
