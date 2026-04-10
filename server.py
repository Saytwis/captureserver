#!/usr/bin/env python3
"""
server.py — Cloud server for capturewindows
---------------------------------------------
Receives screenshots from windows_daemon, sends to Gemini, pushes answer
to phone via ntfy.

Deploy on Render.com:
    1. Push this folder to a GitHub repo
    2. Create new Web Service on Render.com from the repo
    3. Set environment variables: GEMINI_API_KEY, NTFY_TOPIC
    4. Render auto-detects requirements.txt and starts the server
"""

import os
import logging
from flask import Flask, request, jsonify
from google import genai
from google.genai import types
import requests as http_requests

# --- CONFIG (from environment variables for security) ---
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "your-secret-topic-here")
PORT = int(os.environ.get("PORT", 5050))

PROMPT = "Look at this image. If it's a multiple choice question, identify the correct answer and respond with ONLY a single letter based on its position from top to bottom (or left to right): A for 1st, B for 2nd, C for 3rd, D for 4th, E for 5th, F for 6th. It doesn't matter if the choices are labeled with letters, numbers, or nothing at all. For any other question, give the shortest possible answer. No explanation."

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


def push_to_phone(message):
    try:
        resp = http_requests.post(
            f"https://ntfy.sh/{NTFY_TOPIC}",
            data=message.encode("utf-8"),
            headers={"Title": "Notification", "Priority": "high"},
            timeout=10,
        )
        if resp.ok:
            logger.info("Notification sent to phone")
        else:
            logger.error(f"ntfy error: {resp.status_code}")
    except Exception as e:
        logger.error(f"ntfy failed: {e}")


@app.route("/upload", methods=["POST"])
def upload():
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

        push_to_phone(answer)

        return jsonify({"status": "ok", "answer": answer}), 200

    except Exception as e:
        logger.error(f"Error: {e}")
        push_to_phone(f"Error: {str(e)[:80]}")
        return jsonify({"error": str(e)}), 500


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "running",
        "gemini_configured": bool(GEMINI_API_KEY),
        "ntfy_topic_set": NTFY_TOPIC != "your-secret-topic-here",
    }), 200


@app.route("/", methods=["GET"])
def index():
    return "capturewindows server is running. POST to /upload"


if __name__ == "__main__":
    logger.info(f"Server starting on port {PORT}")
    logger.info(f"ntfy topic: {NTFY_TOPIC}")
    app.run(host="0.0.0.0", port=PORT)
