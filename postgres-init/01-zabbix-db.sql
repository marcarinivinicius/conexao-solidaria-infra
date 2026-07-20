-- Banco/usuario dedicado do Zabbix, no mesmo servidor Postgres da app
-- (decisao pragmatica de MVP: um Postgres so, dois bancos, em vez de subir
-- um segundo motor de banco so pro Zabbix).
CREATE USER zabbix WITH PASSWORD 'zabbix';
CREATE DATABASE zabbix OWNER zabbix ENCODING 'UTF8' TEMPLATE template0;
