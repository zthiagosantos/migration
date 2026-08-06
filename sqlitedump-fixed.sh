#!/bin/bash
# sqlitedump-fixed.sh — versão corrigida do sqlitedump.sh do grafana/database-migrator
#
# Correções em relação ao original:
#   1. NO_BACKSLASH_ESCAPES no cabeçalho do dump: o MySQL/MariaDB passa a
#      tratar '\' como caractere literal, igual ao SQLite. Isso elimina o
#      sed lossy do original (que corrompia JSON com regex \\d, paths C:\\,
#      etc. — a causa dos "Dashboard not found" pós-migração).
#   2. Não depende de gawk: usa escape-fixed.awk, 100%% POSIX.
#   3. Pula signing_key (timestamps Go incompatíveis; o Grafana regenera
#      as chaves na primeira inicialização).
#   4. Normaliza timestamps no formato Go (frações de ns + fuso) que o
#      DATETIME do MySQL rejeita: '...11:05:49.380208062-04:00' -> '...11:05:49'.
#   5. Lista tabelas via sqlite_master (o parsing de .tables do original
#      quebrava com nomes longos) e emite TRUNCATE/INSERT com crases.
#   6. FOREIGN_KEY_CHECKS=0 durante o import e tudo numa transação:
#      ou entra tudo, ou nada (sem imports pela metade).
#
# Uso (idêntico ao original):
#   ./sqlitedump-fixed.sh /caminho/grafana.db > grafana.sql
#   mysql --default-character-set=utf8mb4 -u USER -p BANCO < grafana.sql

set -euo pipefail

DB="${1:?uso: $0 /caminho/grafana.db}"
SKIP_TABLES="migration_log signing_key"

AWK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/escape-fixed.awk"
[ -f "$AWK_SCRIPT" ] || { echo "ERRO: escape-fixed.awk não encontrado ao lado deste script" >&2; exit 1; }

TABLES=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

skip() {
    case " $SKIP_TABLES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- cabeçalho
echo "-- gerado por sqlitedump-fixed.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "SET NAMES utf8mb4;"
echo "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES');"
echo "SET FOREIGN_KEY_CHECKS = 0;"
echo "START TRANSACTION;"

# ---------------------------------------------------------------- truncates
for t in $TABLES; do
    skip "$t" && continue
    echo "TRUNCATE TABLE \`$t\`;"
done

# ------------------------------------------------------------------ inserts
for t in $TABLES; do
    skip "$t" && continue
    printf '.headers on\n.mode insert %s\nSELECT * FROM "%s";\n' "$t" "$t"
done \
    | sqlite3 "$DB" \
    | awk -f "$AWK_SCRIPT" \
    | sed -E 's/([0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{6,9}[+-][0-9]{2}:[0-9]{2}/\1/g'

# -------------------------------------------------------------------- final
echo "COMMIT;"
echo "SET FOREIGN_KEY_CHECKS = 1;"
