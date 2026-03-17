import pytest
from app import app as flask_app


@pytest.fixture(autouse=True)
def reset_items():
    """Reset in-memory store between tests."""
    import app as m
    m._items = []
    yield
    m._items = []


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


# ── Index / Health ────────────────────────────────────────────────────────────

def test_index(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.get_json()["status"] == "running"


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "healthy"
    assert "timestamp" in data


# ── Items CRUD ────────────────────────────────────────────────────────────────

def test_get_items_empty(client):
    r = client.get("/api/items")
    assert r.status_code == 200
    data = r.get_json()
    assert data["items"] == []
    assert data["count"] == 0


def test_create_item(client):
    r = client.post("/api/items", json={"name": "widget", "description": "a test widget"})
    assert r.status_code == 201
    data = r.get_json()
    assert data["name"] == "widget"
    assert data["id"] == 1
    assert "created_at" in data


def test_create_item_missing_name(client):
    r = client.post("/api/items", json={"description": "no name"})
    assert r.status_code == 400


def test_create_item_no_body(client):
    r = client.post("/api/items", content_type="application/json", data="")
    assert r.status_code == 400


def test_get_item(client):
    client.post("/api/items", json={"name": "gadget"})
    r = client.get("/api/items/1")
    assert r.status_code == 200
    assert r.get_json()["name"] == "gadget"


def test_get_item_not_found(client):
    r = client.get("/api/items/9999")
    assert r.status_code == 404


def test_delete_item(client):
    client.post("/api/items", json={"name": "to-delete"})
    r = client.delete("/api/items/1")
    assert r.status_code == 204
    assert client.get("/api/items/1").status_code == 404


def test_delete_item_not_found(client):
    r = client.delete("/api/items/9999")
    assert r.status_code == 404


def test_items_count(client):
    for name in ("a", "b", "c"):
        client.post("/api/items", json={"name": name})
    data = client.get("/api/items").get_json()
    assert data["count"] == 3
