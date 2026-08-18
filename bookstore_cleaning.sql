drop table if exists bookstore;
create table bookstore(
date text,
from_code varchar(100),
to_code varchar(100),
sku varchar(100),
qty numeric,
unit_cost numeric,
unit_price numeric,
extended_cost numeric,
extended_retail numeric,
dataset varchar(100)

);
--add an id column
alter table bookstore
add column row_id integer generated always as identity primary key;
--counting if all the data was imported or not
select count(*) as row_count
from bookstore;
--preview all the rows --
select * from 
bookstore
order by random() limit 10;
--check all columns and datatypes 
select column_name,data_type
from information_schema.columns
where table_name='bookstore'
order by ordinal_position;
--checking text data--
select 'from_code'as column_name,
from_code as value ,count(*) as row_count
from bookstore group by from_code
union all
select 'to_code',to_code,count(*)
from bookstore group by to_code
union all
select 'sku',sku,count(*)
from bookstore group by sku
union all
select 'dataset',dataset,count(*)
from bookstore group by dataset;
--checking numeric data--
select 
 min(qty) as min_quantity,max(qty)as max_quantity,
 min(unit_cost) as min_cost,max(unit_cost)as max_cost,
 min(unit_price) as min_price,max(unit_price)as max_price,
 min(extended_cost) as min_extended_cost,max(extended_cost)as max_extended_cost,
 min(extended_retail) as min_extended_retail,max(extended_retail)as max_extended_retail
from bookstore;
