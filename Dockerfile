FROM python:3.13-alpine AS test
WORKDIR /app
COPY app/server.py app/test_server.py /app/
RUN python -m unittest test_server.py

FROM python:3.13-alpine
RUN pip uninstall -y msgpack urllib3 setuptools pip \
 && adduser -D -u 10001 -h /app app
WORKDIR /app
COPY --from=test /app/server.py /app/server.py
USER 10001
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
