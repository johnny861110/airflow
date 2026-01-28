from airflow import DAG
# Airflow 3.0 compatibility imports
try:
    from airflow.providers.standard.operators.python import PythonOperator
    from airflow.providers.standard.operators.bash import BashOperator
except ImportError:
    from airflow.operators.python import PythonOperator
    from airflow.operators.bash import BashOperator

from datetime import datetime, timedelta
import time

def sleep_task(seconds):
    print(f'Task is sleeping for {seconds} seconds...')
    time.sleep(seconds)
    print('Task finished sleeping.')
    return 'Sleep completed'

default_args = {
    'owner': 'ops_test',
    'depends_on_past': False,
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 0,
}

# Airflow 3.0 uses 'schedule' instead of 'schedule_interval'
with DAG(
    'ops_test_pipeline',
    default_args=default_args,
    description='A simple test DAG to verify Celery Worker and Scheduler',
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['ops', 'test'],
) as dag:

    t1 = BashOperator(
        task_id='print_date',
        bash_command='date',
    )

    t2 = PythonOperator(
        task_id='sleep_5_seconds',
        python_callable=sleep_task,
        op_kwargs={'seconds': 5},
    )

    t3 = BashOperator(
        task_id='echo_success',
        bash_command='echo "Airflow pipeline is working correctly!"',
    )

    t1 >> t2 >> t3
