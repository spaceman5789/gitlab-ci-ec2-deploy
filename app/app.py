from flask import Flask, jsonify, request
from datetime import datetime
import os

app = Flask(__name__)

# In-memory store (illustrative — swap for a real DB in production)
_items: list[dict] = []


@app.route("/", methods=["GET"])
def index():
    return jsonify(
        {
            "service": "Flask REST API",
            "version": "1.0.0",
            "status": "running",
            "docs": "/api/items",
        }
    )


@app.route("/health", methods=["GET"])
def health():
    return jsonify(
        {
            "status": "healthy",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "environment": os.getenv("FLASK_ENV", "production"),
        }
    )


@app.route("/api/items", methods=["GET"])
def get_items():
    return jsonify({"items": _items, "count": len(_items)})


@app.route("/api/items", methods=["POST"])
def create_item():
    data = request.get_json(silent=True)
    if not data or "name" not in data:
        return jsonify({"error": "'name' field is required"}), 400

    item = {
        "id": len(_items) + 1,
        "name": data["name"],
        "description": data.get("description", ""),
        "created_at": datetime.utcnow().isoformat() + "Z",
    }
    _items.append(item)
    return jsonify(item), 201


@app.route("/api/items/<int:item_id>", methods=["GET"])
def get_item(item_id: int):
    item = next((i for i in _items if i["id"] == item_id), None)
    if not item:
        return jsonify({"error": f"item {item_id} not found"}), 404
    return jsonify(item)


@app.route("/api/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id: int):
    global _items
    before = len(_items)
    _items = [i for i in _items if i["id"] != item_id]
    if len(_items) == before:
        return jsonify({"error": f"item {item_id} not found"}), 404
    return "", 204


if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    app.run(host="0.0.0.0", port=port)
