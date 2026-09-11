FROM python:3.12-slim

WORKDIR /app

# Nothing but FastAPI and uvicorn now - the fixture needs no quote library
# and no HTTP client, so the slim base has everything required.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
