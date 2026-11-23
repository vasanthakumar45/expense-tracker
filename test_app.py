from app import app, validate_expense


def test_health():
    response = app.test_client().get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "UP"


def test_version():
    response = app.test_client().get("/version")
    assert response.status_code == 200
    assert response.get_json()["version"] == "v999"


def test_validate_accepts_and_cleans_input():
    cleaned, error = validate_expense({"title": " Lunch ", "amount": "12.5", "category": "FOOD"})
    assert error is None
    assert cleaned == {"title": "Lunch", "amount": 12.5, "category": "food"}


def test_validate_rejects_bad_amounts():
    for bad in (0, -5, "abc", None, float("nan"), 2_000_000):
        cleaned, error = validate_expense({"title": "x", "amount": bad})
        assert cleaned is None
        assert error


def test_validate_rejects_unknown_category():
    cleaned, error = validate_expense({"title": "x", "amount": 5, "category": "gold"})
    assert cleaned is None
    assert "category" in error


def test_add_expense_without_title_returns_400():
    response = app.test_client().post("/expenses", json={"amount": 10})
    assert response.status_code == 400


def test_report_without_bucket_returns_501():
    response = app.test_client().post("/reports")
    assert response.status_code == 501
