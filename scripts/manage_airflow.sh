#!/bin/bash
set -e

ACTION=$1

if [ -z "$ACTION" ]; then
    echo "Usage: $0 {start|stop|restart|status|enable|disable}"
    exit 1
fi

SERVICES=(
    airflow-scheduler.service
    airflow-webserver.service
    airflow-celery-worker@1.service
    airflow-celery-worker@2.service # Added second worker instance as per user request
    airflow-flower.service
)

case "$ACTION" in
    start|stop|restart|status|enable|disable)
        for SERVICE in "${SERVICES[@]}"; do
            echo "--- $ACTIONING $SERVICE ---"
            sudo systemctl "$ACTION" "$SERVICE"
        done
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|enable|disable}"
        exit 1
        ;;
esac
