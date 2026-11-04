import base64
import hmac
import logging
import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from openai import OpenAI

load_dotenv()

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("echosight")

app = FastAPI(title="EchoSight Vision Server")

# CORS locked to what this API uses. Set CORS_ORIGINS="https://..." in
# production; the default keeps local browser testing working (no cookies).
cors_origins = [
    origin.strip()
    for origin in os.getenv("CORS_ORIGINS", "*").split(",")
    if origin.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=False,
    allow_methods=["POST"],
    allow_headers=["Authorization", "Content-Type"],
)

# Connects to Groq using the official OpenAI client SDK
api_key = os.getenv("GROQ_API_KEY") or os.getenv("FIREWORKS_API_KEY")
if not api_key:
    raise RuntimeError(
        "Missing GROQ_API_KEY (or FIREWORKS_API_KEY); refusing to start."
    )
base_url = os.getenv("GROQ_BASE_URL", "https://api.groq.com/openai/v1")
model_name = os.getenv("VISION_MODEL", "meta-llama/llama-4-scout-17b-16e-instruct")

client = OpenAI(base_url=base_url, api_key=api_key)

# Optional shared secret for /assist. When ASSIST_API_KEY is set, callers must
# send `Authorization: Bearer <key>`; when unset, the endpoint stays open for
# local development.
ASSIST_API_KEY = os.getenv("ASSIST_API_KEY", "")

MAX_IMAGE_BYTES = int(os.getenv("MAX_IMAGE_BYTES", str(8 * 1024 * 1024)))
MAX_QUERY_CHARS = int(os.getenv("MAX_QUERY_CHARS", "2000"))
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp"}

SYSTEM_PROMPT = """You are an assistive spatial audio guide for a person with low vision.
Follow these strict output rules:
1. Keep responses under 2 concise sentences.
2. Always use clock-face directions (e.g., 'at 2 o'clock', 'straight ahead', 'arm's reach to your left').
3. Prioritize immediate hazards (drop-offs, low-hanging obstacles, trip points) first.
4. Do not include pleasantries, disclaimers, or descriptive fluff. Speak as if guiding their direct gaze."""


def _check_auth(request: Request) -> None:
    if not ASSIST_API_KEY:
        return
    auth = request.headers.get("authorization", "")
    if not hmac.compare_digest(auth, f"Bearer {ASSIST_API_KEY}"):
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.post("/assist")
async def assist(
    request: Request,
    query: str = Form("What is in front of me, and are there any hazards?"),
    image: UploadFile = File(...),
):
    _check_auth(request)

    if len(query) > MAX_QUERY_CHARS:
        raise HTTPException(status_code=422, detail="Query too long.")
    if image.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(
            status_code=415,
            detail="Unsupported image type; send JPEG, PNG, or WebP.",
        )
    image_bytes = await image.read(MAX_IMAGE_BYTES + 1)
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image too large.")
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image.")

    try:
        b64_image = base64.b64encode(image_bytes).decode("utf-8")

        response = client.chat.completions.create(
            model=model_name,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": query},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{b64_image}"
                            },
                        },
                    ],
                },
            ],
            max_tokens=150,
            temperature=0.2,
        )

        content = response.choices[0].message.content or ""
        return {"spoken_guidance": content.strip()}

    except HTTPException:
        raise
    except Exception:
        log.exception("assist request failed")
        raise HTTPException(status_code=502, detail="Vision request failed.")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
