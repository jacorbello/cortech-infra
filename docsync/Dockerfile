FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY docsync.py .

ENTRYPOINT ["python", "docsync.py"]
CMD ["--daemon", "--interval", "300"]
