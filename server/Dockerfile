FROM python:3.12-slim
WORKDIR /app
COPY server/*.py /app/server/
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).read()"
CMD ["python", "-m", "server", "--host", "0.0.0.0", "--port", "8080", "--cache", "/data/context-cache.json"]
