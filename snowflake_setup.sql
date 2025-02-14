-- warehouse setup
use role accountadmin;
create warehouse dbt_wh with warehouse_size='x-small';
create database if not exists dbt_db;
create role if not exists  dbt_role;


-- show grants on warehouse dbt_wh;
grant usage on warehouse dbt_wh to role dbt_role;

-- select current_user();
grant role dbt_role to user <Snowflake username>;
grant all on database dbt_db to role dbt_role;

use role dbt_role;
create schema dbt_db.dbt_schema;