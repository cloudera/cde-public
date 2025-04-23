from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.dummy_operator import DummyOperator
from cloudera.cdp.airflow.operators.cde_operator import CDEJobRunOperator

default_args = {
    'start_date': datetime(2021,1,1,1),
    'owner': 'demotest',
    'retry_delay': timedelta(seconds=5),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 0
}
dag = DAG(
    'run_penv_udf_test_dag',
    default_args=default_args,
    catchup=False,
    is_paused_upon_creation=False
)
start = DummyOperator(task_id='start', dag=dag)
end = DummyOperator(task_id='end', dag=dag)

penv_udf_test = CDEJobRunOperator(
    task_id='penv_udf_test_task',
    dag=dag,
    job_name='penv-udf-test',
    execution_timeout=timedelta(seconds=1800)
)

start >> penv_udf_test >> end
