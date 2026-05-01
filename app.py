#!/usr/bin/env python3
"""
app.py — Cloud server for Project U
---------------------------------------------
1. Serves PowerShell/Mac daemon scripts to authenticated users
2. Receives screenshots from daemons
3. Sends to Gemini for analysis
4. Pushes answer to phone via ntfy

Deploy on Render.com:
    1. Push this folder to a GitHub repo
    2. Create new Web Service on Render.com from the repo
    3. Set environment variables: GEMINI_API_KEY, NTFY_TOPIC
    4. Render auto-detects requirements.txt and starts the server
"""

import os
import logging
import hashlib
import time
from flask import Flask, request, jsonify, Response, abort
from google import genai
from google.genai import types
import requests as http_requests

# --- CONFIG (from environment variables for security) ---
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
# --- ntfy config ---
# Change this to your self-hosted ntfy URL (Railway, etc.)
# Default: https://ntfy.sh (public, has rate limits)
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "your-secret-topic-here")
PORT = int(os.environ.get("PORT", 5050))

PROMPT = (
    "Answer this question. Rules: "
    "(1) Multiple choice → respond with ONLY the letter (A, B, C, D, E, or F) "
    "based on position from top to bottom. "
    "(2) Calculation/numeric question → respond with ONLY the final numeric answer "
    "including units if needed. "
    "(3) Never show work, steps, or explanation. "
    "(4) Maximum 50 characters total. Just the answer, nothing else."
)

# --- LOGGING ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("server")

# --- GEMINI CLIENT ---
if not GEMINI_API_KEY:
    logger.warning("GEMINI_API_KEY not set! Add it as an environment variable.")
client = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None

# --- FLASK ---
app = Flask(__name__)


# ==============================================================
# USER VALIDATION
# ==============================================================
# TODO: Replace with real database (SQLite, PostgreSQL, etc.)
# For now, using an in-memory dict. This resets on server restart.
# In production, use a real database.

user_machines = {}  # {"user_code": "machine_id"}


def validate_user(code):
    """Check if user code is valid and paid."""
    if not code or len(code) < 5:
        return False
    # TODO: Check against Stripe/database if user has paid
    return True


def validate_machine(user_code, machine_id):
    """Lock a user code to one machine.

    First use: registers the machine. All subsequent uses must
    come from the same machine or they get rejected.
    """
    if not user_code or not machine_id:
        return False

    if user_code not in user_machines:
        # First time this code is used — register this machine
        user_machines[user_code] = machine_id
        logger.info(f"User {user_code[:6]} registered to machine {machine_id[:8]}...")
        return True

    if user_machines[user_code] == machine_id:
        # Same machine — allowed
        return True

    # Different machine — blocked
    logger.warning(
        f"User {user_code[:6]} tried from different machine. "
        f"Expected {user_machines[user_code][:8]}, got {machine_id[:8]}"
    )
    return False


def get_user_ntfy_topic(code):
    """Get the ntfy topic for a specific user."""
    return f"projectu_{code}"


# ==============================================================
# DAEMON SCRIPT SERVING (OBFUSCATED)
# ==============================================================

# Upload URL that the daemon will POST screenshots to
UPLOAD_URL = os.environ.get("UPLOAD_URL", "")

def get_upload_url():
    """Get the upload URL, falling back to constructing from request."""
    if UPLOAD_URL:
        return UPLOAD_URL
    return f"{request.scheme}://{request.host}/upload"


@app.route("/s/<user_code>")
def serve_windows_daemon(user_code):
    """Serve PowerShell daemon for Windows users.

    The setup/keybind picker is plain text (needs interactive console).
    The background daemon is Base64 encoded (hides server URLs and logic).
    """
    import base64

    if not validate_user(user_code):
        logger.warning(f"Invalid user code attempted: {user_code[:10]}")
        abort(403)

    logger.info(f"Serving Windows daemon for user: {user_code[:6]}...")

    try:
        with open("projectu_daemon.ps1", "r") as f:
            script = f.read()
    except FileNotFoundError:
        logger.error("projectu_daemon.ps1 not found!")
        abort(500)

    # Inject user-specific config
    upload_url = get_upload_url()
    script = script.replace("{{SERVER_URL}}", upload_url)
    script = script.replace("{{USER_CODE}}", user_code)

    return Response(script, mimetype="text/plain")


@app.route("/m/<user_code>")
def serve_mac_daemon(user_code):
    """Serve bash/Swift daemon for Mac users.

    User runs:
        curl -s https://yourserver.com/m/USERCODE | bash
    """
    if not validate_user(user_code):
        logger.warning(f"Invalid user code attempted: {user_code[:10]}")
        abort(403)

    logger.info(f"Serving Mac daemon for user: {user_code[:6]}...")

    try:
        with open("projectu_daemon_mac.sh", "r") as f:
            script = f.read()
    except FileNotFoundError:
        logger.error("projectu_daemon_mac.sh not found!")
        abort(500)

    # Inject user-specific config
    upload_url = get_upload_url()
    script = script.replace("{{SERVER_URL}}", upload_url)
    script = script.replace("{{USER_CODE}}", user_code)

    return Response(script, mimetype="text/plain")


# ==============================================================
# SCREENSHOT UPLOAD + LLM + NOTIFICATION
# ==============================================================

def push_to_phone(message, topic=None):
    """Send answer to user's phone via ntfy."""
    ntfy_topic = topic or NTFY_TOPIC
    try:
        resp = http_requests.post(
            f"{NTFY_SERVER}/{ntfy_topic}",
            data=message.encode("utf-8"),
            headers={"Title": "Project U", "Priority": "high"},
            timeout=10,
        )
        if resp.ok:
            logger.info(f"Notification sent to phone (topic: {ntfy_topic})")
        else:
            logger.error(f"ntfy error: {resp.status_code}")
    except Exception as e:
        logger.error(f"ntfy failed: {e}")


def push_buzz_answer(answer_letter, topic=None):
    """Send multiple notifications for stealth buzz mode.

    A=1 buzz, B=2 buzzes, C=3 buzzes, D=4 buzzes
    """
    ntfy_topic = topic or NTFY_TOPIC
    letter_map = {"A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6}
    buzz_count = letter_map.get(answer_letter.upper().strip(), 0)

    if buzz_count == 0:
        # Not a simple letter answer, send as text instead
        push_to_phone(answer_letter, topic)
        return

    for i in range(buzz_count):
        try:
            http_requests.post(
                f"{NTFY_SERVER}/{ntfy_topic}",
                data=".",
                headers={
                    "Title": "Project U",
                    "Priority": "max",
                    "Tags": "zap",
                },
                timeout=10,
            )
        except Exception:
            pass
        if i < buzz_count - 1:
            time.sleep(0.7)  # Gap between buzzes

    logger.info(f"Sent {buzz_count} buzzes for answer: {answer_letter}")


@app.route("/upload", methods=["POST"])
def upload():
    """Receive screenshot, send to Gemini, push answer to phone."""

    # Check user auth
    user_code = request.headers.get("X-User-Code", "")
    machine_id = request.headers.get("X-Machine-ID", "")

    if user_code and not validate_user(user_code):
        return jsonify({"error": "Invalid user code"}), 403

    if user_code and machine_id and not validate_machine(user_code, machine_id):
        return jsonify({"error": "This code is already registered to another machine"}), 403

    if "file" not in request.files:
        return jsonify({"error": "No file"}), 400

    file = request.files["file"]
    image_data = file.read()

    if not client:
        return jsonify({"error": "Server not configured (missing API key)"}), 500

    try:
        logger.info(f"Received {len(image_data) // 1024} KB image, sending to Gemini...")

        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=[
                types.Part.from_bytes(data=image_data, mime_type="image/jpeg"),
                PROMPT,
            ],
        )

        answer = response.text.strip()
        logger.info(f"Answer: {answer}")

        # Get user-specific ntfy topic
        user_topic = get_user_ntfy_topic(user_code) if user_code else NTFY_TOPIC

        # Check if answer is a single letter (multiple choice)
        # If so, and buzz mode is requested, send buzzes
        buzz_mode = request.headers.get("X-Buzz-Mode", "false").lower() == "true"

        if buzz_mode and len(answer) == 1 and answer.upper() in "ABCDEF":
            push_buzz_answer(answer, user_topic)
        else:
            push_to_phone(answer, user_topic)

        return jsonify({"status": "ok", "answer": answer}), 200

    except Exception as e:
        logger.error(f"Error: {e}")
        user_topic = get_user_ntfy_topic(user_code) if user_code else NTFY_TOPIC
        push_to_phone(f"Error: {str(e)[:80]}", user_topic)
        return jsonify({"error": str(e)}), 500


# ==============================================================
# HEALTH + INDEX
# ==============================================================

@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "running",
        "gemini_configured": bool(GEMINI_API_KEY),
        "ntfy_topic_set": NTFY_TOPIC != "your-secret-topic-here",
    }), 200


@app.route("/", methods=["GET"])
def index():
    return "Project U server is running. POST to /upload"


if __name__ == "__main__":
    logger.info(f"Server starting on port {PORT}")
    logger.info(f"ntfy topic: {NTFY_TOPIC}")
    app.run(host="0.0.0.0", port=PORT)
