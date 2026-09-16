#!/bin/bash

# ==============================================================================
# MTTR Observability & Auto-Remediation Project Setup Script
# Target OS: Debian 13 (VMware, 3GB RAM, 30GB Storage, 2 Cores)
# ==============================================================================

set -e

PROJECT_DIR="$HOME/mttr-observability-project"
echo "🚀 Starting MTTR Observability Project Setup..."
echo "📁 Project directory: $PROJECT_DIR"

# 1. Install Docker and Docker Compose if not present
if ! command -v docker &> /dev/null; then
    echo "🐳 Docker not found. Installing Docker for Debian..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER
    echo "✅ Docker installed."
fi

# 2. Create project structure
mkdir -p "$PROJECT_DIR"/{prometheus,alertmanager,blackbox,grafana/provisioning/datasources,app,webhook}
cd "$PROJECT_DIR"

# 3. Generate Configuration Files
echo "📝 Generating configuration files..."

cat << 'EOF' > prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'app'
    static_configs:
      - targets: ['app:5000']

  - job_name: 'blackbox_http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://app:5000/health
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
EOF

cat << 'EOF' > prometheus/rules.yml
groups:
  - name: synthetic_monitoring
    rules:
      - alert: BlackboxProbeFailed
        expr: probe_success == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Synthetic monitor failed for {{ $labels.instance }}"
          description: "The blackbox probe for {{ $labels.instance }} has been failing for more than 1 minute."
EOF

cat << 'EOF' > alertmanager/alertmanager.yml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'webhook'

receivers:
  - name: 'webhook'
    webhook_configs:
      - url: 'http://webhook:9000/webhook'
        send_resolved: true
EOF

cat << 'EOF' > blackbox/blackbox.yml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: GET
      preferred_ip_protocol: "ip4"
EOF

cat << 'EOF' > grafana/provisioning/datasources/datasource.yml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

# 4. Generate Application Code
echo "🐍 Generating Sample Application..."

cat << 'EOF' > app/requirements.txt
Flask==3.0.0
prometheus-client==0.19.0
EOF

cat << 'EOF' > app/app.py
from flask import Flask, jsonify
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)
is_healthy = True

REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'status'])

@app.route('/health')
def health():
    if is_healthy:
        return jsonify({"status": "healthy"}), 200
    else:
        return jsonify({"status": "unhealthy"}), 500

@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}

@app.route('/')
def home():
    REQUEST_COUNT.labels(method='GET', endpoint='/', status='200').inc()
    return jsonify({"message": "MTTR Observability Demo App"})

@app.route('/simulate-failure')
def simulate_failure():
    global is_healthy
    is_healthy = False
    return jsonify({"message": "Simulating failure... /health will now return 500"})

@app.route('/recover')
def recover():
    global is_healthy
    is_healthy = True
    return jsonify({"message": "Recovered"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

cat << 'EOF' > app/Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
CMD ["python", "app.py"]
EOF

# 5. Generate Webhook Receiver Code
echo "🪝 Generating Webhook Receiver..."

cat << 'EOF' > webhook/requirements.txt
Flask==3.0.0
docker==7.0.0
EOF

cat << 'EOF' > webhook/webhook.py
from flask import Flask, request, jsonify
import docker
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

client = docker.from_env()

@app.route('/webhook', methods=['POST'])
def webhook():
    alert_data = request.json
    logging.info("Received Alert Payload")
    
    for alert in alert_data.get('alerts', []):
        if alert['status'] == 'firing':
            alertname = alert.get('labels', {}).get('alertname', 'Unknown')
            instance = alert.get('labels', {}).get('instance', 'Unknown')
            
            # Context-Aware Enrichment (Mock)
            runbook_url = f"https://wiki.internal/runbooks/{alertname.lower()}"
            owner = "platform-team@company.com"
            
            logging.info(f"🚨 ENRICHED ALERT: {alertname} on {instance}")
            logging.info(f"📖 Runbook: {runbook_url}")
            logging.info(f"👤 Owner: {owner}")
            
            # Auto-Remediation Logic
            if alertname == 'BlackboxProbeFailed' and 'app:5000' in instance:
                logging.info("🛠️ TRIGGERING AUTO-REMEDIATION: Restarting application container...")
                try:
                    container = client.containers.get('mttr-app')
                    container.restart()
                    logging.info("✅ Auto-remediation successful: Container restarted.")
                except Exception as e:
                    logging.error(f"❌ Auto-remediation failed: {e}")

    return jsonify({"status": "success"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=9000)
EOF

cat << 'EOF' > webhook/Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY webhook.py .
CMD ["python", "webhook.py"]
EOF

# 6. Generate Docker Compose File
echo "🐳 Generating Docker Compose file..."

cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: mttr-prometheus
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./prometheus/rules.yml:/etc/prometheus/rules.yml
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    ports:
      - "9090:9090"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    container_name: mttr-alertmanager
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
    ports:
      - "9093:9093"
    restart: unless-stopped

  blackbox:
    image: prom/blackbox-exporter:latest
    container_name: mttr-blackbox
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml
    command:
      - '--config.file=/etc/blackbox_exporter/config.yml'
    ports:
      - "9115:9115"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: mttr-grafana
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    ports:
      - "3000:3000"
    restart: unless-stopped

  app:
    build: ./app
    container_name: mttr-app
    ports:
      - "5000:5000"
    restart: unless-stopped

  webhook:
    build: ./webhook
    container_name: mttr-webhook
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "9000:9000"
    restart: unless-stopped
EOF

# 7. Build and Start the Stack
echo "🏗️ Building and starting the Docker Compose stack..."
sudo docker compose up -d --build

echo "✅ Setup Complete!"
echo "=========================================================="
echo "🌐 Access URLs (Use your VM's IP address):"
echo "   - Grafana:      http://<VM_IP>:3000 (admin/admin)"
echo "   - Prometheus:   http://<VM_IP>:9090"
echo "   - Alertmanager: http://<VM_IP>:9093"
echo "   - Sample App:   http://<VM_IP>:5000"
echo "=========================================================="
echo "🧪 How to test Auto-Remediation:"
echo "   1. Open a terminal and tail the webhook logs:"
echo "      sudo docker logs -f mttr-webhook"
echo "   2. In another terminal, simulate a failure:"
echo "      curl http://<VM_IP>:5000/simulate-failure"
echo "   3. Wait ~1.5 minutes for Blackbox to detect and Alertmanager to fire."
echo "   4. Watch the webhook logs trigger the auto-remediation!"
echo "=========================================================="