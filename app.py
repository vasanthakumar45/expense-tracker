import csv
import io
import os
from datetime import datetime, timezone

import boto3
import psycopg2
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

APP_ENV = os.getenv("APP_ENV", "local")
S3_BUCKET = os.getenv("S3_BUCKET", "")
CATEGORIES = ("food", "travel", "rent", "utilities", "other")


def get_conn():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        dbname=os.getenv("DB_NAME", "expenses"),
        user=os.getenv("DB_USER", "expuser"),
        password=os.getenv("DB_PASSWORD", "exppass"),
        sslmode=os.getenv("DB_SSLMODE", "prefer"),
        connect_timeout=3,
    )


def run_query(sql, params=None, fetch=False):
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "CREATE TABLE IF NOT EXISTS expenses ("
                "id SERIAL PRIMARY KEY, "
                "title TEXT NOT NULL, "
                "amount NUMERIC(10,2) NOT NULL, "
                "category TEXT NOT NULL, "
                "created_at TIMESTAMP DEFAULT NOW())"
            )
            cur.execute(sql, params)
            rows = cur.fetchall() if fetch else None
        conn.commit()
        return rows
    finally:
        conn.close()


def validate_expense(data):
    title = str(data.get("title", "")).strip()
    if not title:
        return None, "title is required"
    try:
        amount = round(float(data.get("amount")), 2)
    except (TypeError, ValueError):
        return None, "amount must be a number"
    if not (0 < amount <= 1_000_000):
        return None, "amount must be between 0 and 1000000"
    category = str(data.get("category", "other")).lower()
    if category not in CATEGORIES:
        return None, "category must be one of: " + ", ".join(CATEGORIES)
    return {"title": title, "amount": amount, "category": category}, None


@app.route("/health")
def health():
    return jsonify(status="UP")


@app.route("/version")
def version():
    return jsonify(env=APP_ENV, version=os.getenv("APP_VERSION", "v1"))


@app.route("/expenses", methods=["POST"])
def add_expense():
    data = request.get_json(silent=True) or {}
    cleaned, error = validate_expense(data)
    if error:
        return jsonify(error=error), 400
    try:
        rows = run_query(
            "INSERT INTO expenses (title, amount, category) VALUES (%s, %s, %s) RETURNING id",
            (cleaned["title"], cleaned["amount"], cleaned["category"]),
            fetch=True,
        )
        return jsonify(id=rows[0][0], **cleaned), 201
    except psycopg2.Error:
        return jsonify(error="Database not reachable"), 503


@app.route("/expenses", methods=["GET"])
def list_expenses():
    try:
        rows = run_query(
            "SELECT id, title, amount, category FROM expenses ORDER BY id DESC LIMIT 50",
            fetch=True,
        )
        return jsonify(
            [{"id": r[0], "title": r[1], "amount": float(r[2]), "category": r[3]} for r in rows]
        )
    except psycopg2.Error:
        return jsonify(error="Database not reachable"), 503


@app.route("/expenses/summary", methods=["GET"])
def summary():
    try:
        rows = run_query(
            "SELECT category, COUNT(*), SUM(amount) FROM expenses GROUP BY category ORDER BY category",
            fetch=True,
        )
        return jsonify(
            [{"category": r[0], "count": r[1], "total": float(r[2])} for r in rows]
        )
    except psycopg2.Error:
        return jsonify(error="Database not reachable"), 503


@app.route("/reports", methods=["POST"])
def create_report():
    if not S3_BUCKET:
        return jsonify(error="S3 is not configured"), 501
    try:
        rows = run_query(
            "SELECT id, title, amount, category, created_at FROM expenses ORDER BY id",
            fetch=True,
        )
    except psycopg2.Error:
        return jsonify(error="Database not reachable"), 503

    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["id", "title", "amount", "category", "created_at"])
    writer.writerows(rows)
    key = "reports/expenses-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + ".csv"
    try:
        boto3.client("s3").put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=buffer.getvalue().encode("utf-8"),
            ContentType="text/csv",
        )
    except (BotoCoreError, ClientError):
        return jsonify(error="Could not write the report to S3"), 502
    return jsonify(bucket=S3_BUCKET, key=key, rows=len(rows)), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
