export AIRFLOW_HOME=/opt/airflow
export AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@localhost:5432/airflow
/opt/airflow/venv/bin/airflow db migrate
