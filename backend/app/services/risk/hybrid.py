"""
Hybrid ML + DL fusion scorer, shared by training (ml/train_hybrid.py) and the live engine.

Base learners -> per-model fraud probability -> logistic-regression meta-learner (stacking).
The autoencoder is trained on legitimate payments only; its reconstruction error is turned
into an anomaly score by ranking it against the errors seen on legitimate training data.
"""

import numpy as np

BASE_MODELS = ["logistic_regression", "random_forest", "xgboost", "hist_gradient_boosting", "fnn", "autoencoder"]


def autoencoder_score(ae, X: np.ndarray, legit_errors_sorted: np.ndarray) -> np.ndarray:
    recon = ae.predict(X)
    err = np.mean((recon - X) ** 2, axis=1)
    return np.searchsorted(legit_errors_sorted, err) / len(legit_errors_sorted)


def base_scores(models: dict, X: np.ndarray, legit_errors_sorted: np.ndarray) -> np.ndarray:
    """Return an (n, len(BASE_MODELS)) matrix of base-model scores."""
    cols = []
    for name in BASE_MODELS:
        if name == "autoencoder":
            cols.append(autoencoder_score(models[name], models["ae_scaler"].transform(X), legit_errors_sorted))
        else:
            cols.append(models[name].predict_proba(X)[:, 1])
    return np.column_stack(cols)
