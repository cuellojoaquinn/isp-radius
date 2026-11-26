# Agente de diagnóstico (ver agente.py). Solo depende del SDK de Anthropic.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agente.py servidor.py ./
USER nobody
EXPOSE 8080
CMD ["python", "-u", "servidor.py"]
