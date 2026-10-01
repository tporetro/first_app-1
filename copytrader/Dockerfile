FROM python:3.11-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 DATA_DIR=/data PORT=8080
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY copytrader ./copytrader
COPY config.server.json ./
RUN mkdir -p /data
EXPOSE 8080
# Dry-run unless config, --live AND COPYTRADER_LIVE_CONFIRM all say otherwise.
CMD ["python", "-m", "copytrader", "-c", "config.server.json", "serve"]
