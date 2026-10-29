FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --no-create-home app \
    && mkdir /data && chown app:app /data
COPY app.py ./server/app.py
USER 10001:10001
EXPOSE 8080
CMD ["uvicorn", "server.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--workers", "1", "--limit-concurrency", "32", "--timeout-keep-alive", "5"]
