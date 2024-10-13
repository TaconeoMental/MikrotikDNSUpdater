FROM python:3.12
WORKDIR /app

COPY app.py .

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY ./scripts/entrypoint.sh /entrypoint.sh
RUN chmod u+x /entrypoint.sh

CMD ["python", "app.py"]
