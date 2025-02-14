-- warehouse clean up
use role accountadmin;
drop warehouse if exists dbt_wh;
drop database if exists dbt_db;