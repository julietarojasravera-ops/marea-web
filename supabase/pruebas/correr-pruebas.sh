#!/bin/bash
# Prueba la base de Marea en un PostgreSQL local (NO en Supabase).
# Uso:  ./correr-pruebas.sh [clientes] [reservas]      (por defecto 1500 y 9000)
# Necesita psql y un PostgreSQL con btree_gist y pg_trgm (PGHOST/PGPORT/PGUSER como siempre).
set -e
CLIENTES=${1:-1500}; RESERVAS=${2:-9000}; DB=marea_prueba
AQUI=$(cd "$(dirname "$0")" && pwd)
psql -q -c "drop database if exists $DB" -c "create database $DB"
psql -q -d $DB -v ON_ERROR_STOP=1 -f "$AQUI/simulador-supabase.sql"
# pg_net no existe fuera de Supabase: el simulador lo reemplaza
sed 's/^create extension if not exists pg_net;/-- pg_net (simulado)/' "$AQUI/../instalacion/marea-instalacion-completa.sql" \
  | psql -q -d $DB -v ON_ERROR_STOP=1
psql -q -d $DB -v clientes=$CLIENTES -v reservas=$RESERVAS -f "$AQUI/carga-masiva.sql"
psql -q -d $DB -f "$AQUI/pruebas-sql13.sql" | sed -n '/RESULTADO/,$p'
psql -q -d $DB -f "$AQUI/medir-tiempos.sql" | tail -20
