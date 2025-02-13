# ELT Pipeline with dbt, Snowflake, and Airflow

This project showcases an end-to-end **ELT (Extract, Load, Transform)** pipeline I built using **dbt**, **Snowflake**, and **Airflow**. The goal was to demonstrate how to orchestrate data transformations in Snowflake using dbt, and then automate the entire workflow in Airflow. Below is a walkthrough of the architecture, code, and workflow steps.

## Overview

1. **Snowflake** serves as the cloud data warehouse.
2. **dbt (data build tool)** handles the transformations (SQL-based data models, tests, and documentation).
3. **Airflow** orchestrates the entire pipeline, scheduling and running dbt commands automatically.

### DAG in Airflow

Below is a screenshot of the final Airflow DAG. You can see the tasks for staging, transforming, and testing the data. 

![Airflow DAG]()

Each box in the DAG represents a dbt model or test that runs in sequence. Once the tasks complete successfully, the pipeline is considered done.


## Project Steps

### Step 1: Set Up the Snowflake Environment

First, we create and configure the necessary Snowflake resources (warehouse, database, schema, and role). This snippet demonstrates how to set up and tear down everything quickly:

```sql
-- create accounts
use role accountadmin;

create warehouse dbt_wh with warehouse_size='x-small';
create database if not exists dbt_db;
create role if not exists dbt_role;

show grants on warehouse dbt_wh;

grant role dbt_role to user <YOUR_USERNAME>;
grant usage on warehouse dbt_wh to role dbt_role;
grant all on database dbt_db to role dbt_role;

use role dbt_role;

create schema if not exists dbt_db.dbt_schema;

-- clean up (for teardown)
use role accountadmin;

drop warehouse if exists dbt_wh;
drop database if exists dbt_db;
drop role if exists dbt_role;
```
*Tip: Make sure you replace `<YOUR_USERNAME>` with your actual Snowflake username.*

### Step 2: Configure `dbt_profile.yml`

Next, configure your dbt profile to connect to Snowflake. Here, we specify the warehouse and materialization settings:

```yaml
models:
  snowflake_workshop:
    staging:
      materialized: view
      snowflake_warehouse: dbt_wh
    marts:
      materialized: table
      snowflake_warehouse: dbt_wh
```
*Note: The `dbt_profile.yml` also needs your Snowflake credentials. Typically, you’ll store those securely in a profiles.yml file, not in your repo.*


### Step 3: Create Source and Staging Files

We declare data sources in dbt so that we can reference them later in our staging models.

`models/staging/tpch_sources.yml`

```yaml
version: 2

sources:
  - name: tpch
    database: snowflake_sample_data
    schema: tpch_sf1
    tables:
      - name: orders
        columns:
          - name: o_orderkey
            tests:
              - unique
              - not_null
      - name: lineitem
        columns:
          - name: l_orderkey
            tests:
              - relationships:
                  to: source('tpch', 'orders')
                  field: o_orderkey
```
Then we create staging models that simplify or rename the raw columns:

`models/staging/stg_tpch_orders.sql`

```sql
select
    o_orderkey as order_key,
    o_custkey as customer_key,
    o_orderstatus as status_code,
    o_totalprice as total_price,
    o_orderdate as order_date
from
    {{ source('tpch', 'orders') }}
```

`models/staging/stg_tpch_line_items.sql`

```sql
select
    {{
        dbt_utils.generate_surrogate_key([
            'l_orderkey',
            'l_linenumber'
        ])
    }} as order_item_key,
    l_orderkey as order_key,
    l_partkey as part_key,
    l_linenumber as line_number,
    l_quantity as quantity,
    l_extendedprice as extended_price,
    l_discount as discount_percentage,
    l_tax as tax_rate
from
    {{ source('tpch', 'lineitem') }}
```

### Step 4: Macros (D.R.Y. - Don’t Repeat Yourself)

In dbt, macros help us reuse code. Here’s a simple macro to calculate discounted amounts:

`macros/pricing.sql`

```sql
{% macro discounted_amount(extended_price, discount_percentage, scale=2) %}
    (-1 * {{extended_price}} * {{discount_percentage}})::decimal(16, {{ scale }})
{% endmacro %}
```

### Step 5: Transform Models (Fact Tables / Data Marts)

We build intermediate and final (fact) tables. The intermediate table `int_order_items` enriches data by joining orders and line items, and then we aggregate those results in `int_order_items_summary`.

`models/marts/int_order_items.sql`

```sql
select
    line_item.order_item_key,
    line_item.part_key,
    line_item.line_number,
    line_item.extended_price,
    orders.order_key,
    orders.customer_key,
    orders.order_date,
    {{ discounted_amount('line_item.extended_price', 'line_item.discount_percentage') }} as item_discount_amount
from
    {{ ref('stg_tpch_orders') }} as orders
join
    {{ ref('stg_tpch_line_items') }} as line_item
        on orders.order_key = line_item.order_key
order by
    orders.order_date
```

`models/marts/int_order_items_summary.sql`

```sql
select 
    order_key,
    sum(extended_price) as gross_item_sales_amount,
    sum(item_discount_amount) as item_discount_amount
from
    {{ ref('int_order_items') }}
group by
    order_key
```

Finally, we create our fact model to combine the summary with the orders:

`models/marts/fct_orders.sql`

```sql
select
    orders.*,
    order_item_summary.gross_item_sales_amount,
    order_item_summary.item_discount_amount
from
    {{ref('stg_tpch_orders')}} as orders
join
    {{ref('int_order_items_summary')}} as order_item_summary
    on orders.order_key = order_item_summary.order_key
order by order_date
```

### Step 6: Tests

dbt supports both generic and custom (singular) tests. Generic tests are defined in YAML and run automatically, while singular tests are SQL queries that return failing rows.

**Generic Tests:** `models/marts/generic_tests.yml`

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
              severity: warn
      - name: status_code
        tests:
          - accepted_values:
              values: ['P', 'O', 'F']
```

**Singular Tests**

- `tests/fct_orders_discount.sql` checks if there are any unexpected positive discounts:

```sql
select
    *
from
    {{ref('fct_orders')}}
where
    item_discount_amount > 0
```

- `tests/fct_orders_date_valid.sql` ensures order_date is in a sensible range:

```sql
select
    *
from
    {{ref('fct_orders')}}
where
    date(order_date) > CURRENT_DATE()
    or date(order_date) < date('1990-01-01')
```

### Step 7: Deploy on Airflow

Airflow coordinates the dbt runs. We install `dbt-snowflake` and relevant providers in the Airflow Docker container, then configure a Snowflake connection in the Airflow UI.

`dockerfile`

```dockerfile
RUN python -m venv dbt_venv && source dbt_venv/bin/activate && \
    pip install --no-cache-dir dbt-snowflake && deactivate
```

`requirements.txt`

```
astronomer-cosmos
apache-airflow-providers-snowflake
```

**Airflow Snowflake Connection**

```json
{
  "account": "<account_locator>-<account_name>",
  "warehouse": "dbt_wh",
  "database": "dbt_db",
  "role": "dbt_role",
  "insecure_mode": false
}
```

`dbt_dag.py`

```python
import os
from datetime import datetime

from cosmos import DbtDag, ProjectConfig, ProfileConfig, ExecutionConfig
from cosmos.profiles import SnowflakeUserPasswordProfileMapping

profile_config = ProfileConfig(
    profile_name="default",
    target_name="dev",
    profile_mapping=SnowflakeUserPasswordProfileMapping(
        conn_id="snowflake_conn", 
        profile_args={"database": "dbt_db", "schema": "dbt_schema"},
    )
)

dbt_snowflake_dag = DbtDag(
    project_config=ProjectConfig("/usr/local/airflow/dags/dbt/data_pipeline"),
    operator_args={"install_deps": True},
    profile_config=profile_config,
    execution_config=ExecutionConfig(
        dbt_executable_path=f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
    ),
    schedule_interval="@daily",
    start_date=datetime(2023, 9, 10),
    catchup=False,
    dag_id="dbt_dag",
)
```

Once deployed, this DAG will extract data from Snowflake’s sample data, load it into staging models, and transform it into analytics-ready tables—complete with dbt’s built-in testing.

## Conclusion

With this project, I demonstrated:
- **Data Warehousing**: Setting up Snowflake resources and working with sample TPCH data.
- **dbt for ELT**: Building modular SQL transformations, leveraging macros, and running automated tests.
- **Orchestration with Airflow**: Scheduling and running dbt commands via a DAG, ensuring tasks are performed in the correct order.

This end-to-end pipeline shows the typical workflow for a modern data stack: raw data → staging → transformations → analytics. By incorporating automated tests, you ensure data quality at each step.
