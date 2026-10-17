"""
Gemini calls with a model fallback chain. The primary model can be briefly overloaded (503) or retired for new
keys (404); the next model in GEMINI_FALLBACK_MODELS is tried before the caller falls back to the offline path.
"""

import logging
import time

import httpx

from app.core.config import settings

log = logging.getLogger(__name__)

# 5xx: overloaded or down. 404: model retired for this key. 429: quota for this model.
RETRYABLE = {404, 429, 500, 502, 503, 504}
COOLDOWN_SECONDS = 300  # busy or retired model
QUOTA_COOLDOWN_SECONDS = 60  # free-tier per-minute quota (Google asks to retry after about a minute)
_resting: dict[str, float] = {}  # model -> time it may be tried again


def models() -> list[str]:
    chain = [settings.GEMINI_MODEL, *[m.strip() for m in settings.GEMINI_FALLBACK_MODELS.split(",")]]
    return list(dict.fromkeys(m for m in chain if m))


def client():
    from google import genai
    from google.genai import types

    # No retry with back-off per model: the fallback chain handles a busy model, so the chat doesn't stall.
    # The timeout (milliseconds) stops a stalled call from holding the chat open.
    return genai.Client(api_key=settings.GEMINI_API_KEY,
                        http_options=types.HttpOptions(retry_options=types.HttpRetryOptions(attempts=1),
                                                       timeout=int(settings.GEMINI_TIMEOUT_SECONDS * 1000)))


def generate(api, *, contents, config, start: int = 0):
    """Returns (response, index of the model that answered). Raises the last error if every model fails."""
    from google.genai import errors

    chain = models()
    now = time.monotonic()
    # Skip models that failed a moment ago, unless that would leave nothing to try.
    order = [i for i in range(start, len(chain)) if _resting.get(chain[i], 0) <= now] or list(range(start, len(chain)))
    last = None
    for i in order:
        try:
            response = api.models.generate_content(model=chain[i], contents=contents, config=config)
            _resting.pop(chain[i], None)
            return response, i
        except errors.APIError as e:
            if e.code not in RETRYABLE:
                raise
            rest = QUOTA_COOLDOWN_SECONDS if e.code == 429 else COOLDOWN_SECONDS
            _resting[chain[i]] = time.monotonic() + rest
            log.warning("Gemini model %s unavailable (%s), resting it for %ss", chain[i], e.code, rest)
            last = e
        except httpx.TransportError as e:
            # Timed out or unreachable: the next model would likely wait as long, so rest this one and let the
            # caller answer offline.
            _resting[chain[i]] = time.monotonic() + COOLDOWN_SECONDS
            log.warning("Gemini model %s unreachable (%s), resting it", chain[i], type(e).__name__)
            raise
    raise last or RuntimeError("No Gemini model configured")
