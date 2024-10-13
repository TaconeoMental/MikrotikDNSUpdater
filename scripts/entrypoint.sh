#!/bin/bash

gunicorn -k gevent \
    --reload \
    --workers 10 \
    --worker-connections 10 \
    --access-logfile=- \
    --pythonpath /app \
    --bind :5000 \
    app:app
