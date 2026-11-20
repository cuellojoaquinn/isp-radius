FROM python:3.12.8-slim
RUN pip install --no-cache-dir librouteros==3.4.1 prometheus-client==0.21.1
COPY exporter.py /app/exporter.py
USER nobody
CMD ["python3", "-u", "/app/exporter.py"]
