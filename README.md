# ELT Pipeline using dbt, Snowflake, and Airflow

This project demonstrates how to build a simple ELT pipeline using [dbt (Data Build Tool)](https://www.getdbt.com/) to transform data in [Snowflake](https://www.snowflake.com/en/), with orchestration managed by [Apache Airflow](https://airflow.apache.org/). This setup showcases a modern data engineering workflow, essential for handling large-scale data transformations efficiently.


## 1. Setting up Snowflake
We will use Snowflake as our data warehouse, leveraging the sample dataset TPCH_SF1.

### Configuring Access Control
Snowflake’s RBAC (Role-based Access Control) is utilized to manage permissions. A dedicated `dbt_role` is created and assigned to the user.

```sql
USE ROLE accountadmin;
CREATE ROLE IF NOT EXISTS dbt_role;
GRANT ROLE dbt_role TO USER <Snowflake username>;
```

### Creating the Warehouse and Database
We create the required warehouse and database for our dbt transformations.

```sql
CREATE WAREHOUSE dbt_wh WITH WAREHOUSE_SIZE='X-SMALL';
CREATE DATABASE IF NOT EXISTS dbt_db;
GRANT USAGE ON WAREHOUSE dbt_wh TO ROLE dbt_role;
GRANT ALL ON DATABASE dbt_db TO ROLE dbt_role;
USE ROLE dbt_role;
CREATE SCHEMA IF NOT EXISTS dbt_db.dbt_schema;
```



## 2. Setting up dbt Project
To integrate dbt with Apache Airflow, we use [astronomer-cosmos](https://github.com/astronomer/astronomer-cosmos). The setup involves initializing an Astro project and configuring dbt.

### Initializing the Astro Project
```bash
curl -sSL install.astronomer.io | sudo bash -s  # Install Astro CLI
mkdir elt_project && cd elt_project
astro dev init
```

This generates a directory structure including DAGs, plugins, and dependencies.

### Creating the dbt Project
```bash
python -m venv dbt-env  # Create virtual environment
source dbt-env/bin/activate  # Activate environment
pip install dbt-core dbt-snowflake  # Install dbt
mkdir dags/dbt && cd dags/dbt
dbt init  # Initialize dbt project
```

During initialization, provide Snowflake credentials and database details.


## 3. Building the Data Model
We process the `orders` and `lineitem` tables from TPCH_SF1.

![Data Model](https://github.com/ndomah/ELT-Pipeline/blob/main/img/data-model.png)

### Configuring dbt Models
We define sources and transformations in dbt, specifying materialization strategies:

```yaml
models:
  data_pipeline:
    staging:
      +materialized: view
      snowflake_warehouse: dbt_wh
    marts:
      +materialized: table
      snowflake_warehouse: dbt_wh
```

The `models/staging/stg_tpch_orders.sql` transformation extracts required fields from `orders`:

```sql
SELECT
    o_orderkey AS order_key,
    o_custkey AS customer_key,
    o_orderstatus AS status_code,
    o_totalprice AS total_price,
    o_orderdate AS order_date
FROM {{ source('tpch', 'orders') }}
```

Similarly, `models/staging/stg_tpch_line_item.sql` processes `lineitem` and creates a surrogate key:

```sql
SELECT
    {{ dbt_utils.generate_surrogate_key(['l_orderkey', 'l_linenumber']) }} AS order_item_key,
    l_orderkey AS order_key,
    l_partkey AS part_key,
    l_linenumber AS line_number,
    l_quantity AS quantity,
    l_extendedprice AS extended_price,
    l_discount AS discount_percentage,
    l_tax AS tax_rate
FROM {{ source('tpch', 'lineitem') }}
```

The fact table `fct_orders.sql` integrates orders and order summaries:

```sql
SELECT
    orders.*,
    order_item_summary.gross_item_sales_amount,
    order_item_summary.item_discount_amount
FROM {{ ref('stg_tpch_orders') }} AS orders
JOIN {{ ref('dim_order_items_summary') }} AS order_item_summary
    ON orders.order_key = order_item_summary.order_key
ORDER BY order_date
```

Tests ensure data integrity, checking constraints such as unique `order_key` values.

```yaml
models:
  - name: fct_orders
    columns:
      - name: order_key
        tests:
          - unique
          - not_null
          - relationships:
              to: ref('stg_tpch_orders')
              field: order_key
```

Running dbt:
```bash
dbt test  # Run tests
dbt run  # Execute transformations
dbt build  # Execute and test
```


## 4. Orchestrating with Airflow
We configure Airflow to run dbt models using the [astronomer-cosmos](https://github.com/astronomer/astronomer-cosmos) package.

### Configuring Airflow
Modify `Dockerfile` to install dbt inside a virtual environment:

```dockerfile
FROM quay.io/astronomer/astro-runtime:11.4.0
RUN python -m venv dbt_venv && source dbt_venv/bin/activate && \
    pip install --no-cache-dir dbt-snowflake && deactivate
```

Add necessary dependencies in `requirements.txt`:

```
astronomer-cosmos
apache-airflow-providers-snowflake
```

### Creating the DAG
Define `dags/dbt/dbt_dag.py` to run dbt models:

```python
import os
from datetime import datetime
from cosmos import DbtDag, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig
from cosmos.profiles import SnowflakeUserPasswordProfileMapping
from cosmos.constants import TestBehavior

profile_config = ProfileConfig(
    profile_name='default',
    target_name='dev',
    profile_mapping=SnowflakeUserPasswordProfileMapping(
        conn_id='snowflake_conn',
        profile_args={'database': 'dbt_db', 'schema': 'dbt_schema'}
    )
)

dbt_snowflake_dag = DbtDag(
    project_config=ProjectConfig('/usr/local/airflow/dags/dbt/data_pipeline'),
    operator_args={'install_deps': True},
    profile_config=profile_config,
    execution_config=ExecutionConfig(dbt_executable_path=f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"),
    render_config=RenderConfig(test_behavior=TestBehavior.AFTER_ALL),
    schedule_interval='@daily',
    start_date=datetime(2024, 6, 1),
    catchup=False,
    dag_id='dbt_dag'
)
```

### Running Airflow
Start Airflow locally:

```bash
astro dev start
```

Once running, access the Airflow UI at [http://localhost:8080](http://localhost:8080).

### DAG Execution
![DAG Execution](https://github.com/ndomah/ELT-Pipeline/blob/main/img/dbt_dag_success.png)

After setting up the Snowflake connection in Airflow, trigger the DAG to orchestrate the ELT pipeline successfully.

## Conclusion
This project showcases a modern ELT pipeline with dbt, Snowflake, and Airflow, demonstrating efficient data transformation and orchestration workflows—ideal for building scalable and maintainable data pipelines.
