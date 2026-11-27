FROM python:3.12-slim
WORKDIR /app
ENV BIND_HOST=0.0.0.0 PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN groupadd --gid 10001 ecoruta && useradd --uid 10001 --gid 10001 --create-home ecoruta \
    && install -d -o ecoruta -g ecoruta -m 0700 /app/backend/data
COPY ecoruta/ ecoruta/
COPY streamlit_app.py .
COPY .streamlit/config.toml .streamlit/config.toml
COPY backend/schema.sql backend/schema.sql
COPY frontend/img/V*.jpg frontend/img/
USER ecoruta
EXPOSE 8080
HEALTHCHECK --interval=20s --timeout=8s --start-period=20s CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:'+os.environ['PORT']+'/_stcore/health', timeout=7).close()"]
ENTRYPOINT ["python", "-m", "ecoruta"]
