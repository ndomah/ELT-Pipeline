# ELT Pipeline with dbt, Snowflake, and Airflow

This project showcases an end-to-end **ELT (Extract, Load, Transform)** pipeline I built using **dbt**, **Snowflake**, and **Airflow**. The goal was to demonstrate how to orchestrate data transformations in Snowflake using dbt, and then automate the entire workflow in Airflow. Below is a walkthrough of the architecture, code, and workflow steps.

---

## Overview

1. **Snowflake** serves as the cloud data warehouse.
2. **dbt (data build tool)** handles the transformations (SQL-based data models, tests, and documentation).
3. **Airflow** orchestrates the entire pipeline, scheduling and running dbt commands automatically.

### DAG in Airflow

Below is a screenshot of the final Airflow DAG. You can see the tasks for staging, transforming, and testing the data. 

![Airflow DAG](./path_to_your_dag_image.png)

Each box in the DAG represents a dbt model or test that runs in sequence. Once the tasks complete successfully, the pipeline is considered done.

---

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
