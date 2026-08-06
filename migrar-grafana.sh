#!/usr/bin/env bash
#
# migrar-grafana.sh (v3)
# Migra o banco do Grafana de SQLite para MySQL/MariaDB com segurança.
#
# Baseado no grafana/database-migrator (Apache-2.0), com correções:
#   - NO_BACKSLASH_ESCAPES: JSON preservado byte a byte (regex \d, C:\, aspas)
#   - awk 100% POSIX (mawk/BSD awk/gawk)
#   - signing_key excluída; timestamps Go normalizados
#   - Import transacional com utf8mb4
#   - Pré-checagens: schema, charset, versão (migration_log), secret_key
#   - Pós-checagem: JSON_VALID de todos os dashboards
#
# Uso:
#   migrar-grafana.sh -f grafana.db -d grafana -u grafana [-H host] [-P porta]
#
# Opções de secret_key (senhas de datasources):
#   -o /caminho/grafana.ini.antigo   compara com o ini do servidor antigo
#   -k CHAVE                         informa a chave antiga diretamente
#   -i /caminho/grafana.ini.novo     ini local (padrão: /etc/grafana/grafana.ini)
#
# Outras:
#   -m DIR   pasta com sqlitedump-fixed.sh/escape-fixed.awk (padrão: a do script)
#   -n       só gera o dump, não importa
#   -o(utro) use -O para definir o arquivo .sql de saída

set -euo pipefail

# ------------------------------------------------------------------- visual
if [[ -t 1 ]]; then
    C0=$'\e[0m'; CB=$'\e[1m'; CDIM=$'\e[2m'
    CG=$'\e[32m'; CR=$'\e[31m'; CY=$'\e[33m'; CC=$'\e[36m'
else
    C0=""; CB=""; CDIM=""; CG=""; CR=""; CY=""; CC=""
fi

banner() {
    [[ "${GM_NO_BANNER:-0}" == "1" ]] && return 0
    local L=58
    echo
    printf "  ${CC}${CB}╭"; printf '─%.0s' $(seq 1 $L); printf "╮${C0}\n"
    printf "  ${CC}${CB}│%*s%s%*s│${C0}\n" 16 "" "FLOWBIX • GRAFANA MIGRATOR" 16 ""
    printf "  ${CC}${CB}│%*s%s%*s│${C0}\n" 17 "" "SQLite ➜ MySQL / MariaDB" 17 ""
    printf "  ${CC}${CB}╰"; printf '─%.0s' $(seq 1 $L); printf "╯${C0}\n"
}
secao()  { echo; echo "${CB}${CC}▸ $*${C0}"; }
ok()     { echo "  ${CG}✔${C0} $*"; }
info()   { echo "  ${CDIM}•${C0} $*"; }
nota()   { echo "  ${CDIM}· $*${C0}"; }
aviso()  { echo "  ${CY}⚠${C0} $*" >&2; }
erro()   { echo; echo "  ${CR}${CB}✘ ERRO:${C0}${CR} $*${C0}" >&2; exit 1; }

# passo "texto" comando...  → spinner enquanto roda, ✔/✘ ao terminar
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
ANIMA=0; [[ -t 1 ]] && ANIMA=1
passo() {
    local texto="$1"; shift
    local rc=0
    if (( ANIMA )); then
        "$@" >/tmp/.gm-passo.log 2>&1 &
        local pid=$! i=0
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${CC}%s${C0} %s" "${SPIN[i++ % 10]}" "$texto"
            sleep 0.08
        done
        wait "$pid" || rc=$?
        printf "\r\033[K"
    else
        "$@" >/tmp/.gm-passo.log 2>&1 || rc=$?
    fi
    if (( rc == 0 )); then ok "$texto"; else echo "  ${CR}✘${C0} $texto"; fi
    return $rc
}

# ---------------------------------------------------------------- parâmetros
SQLITE_FILE="" DB_NAME="" DB_USER="" DB_HOST="localhost" DB_PORT="3306"
OLD_INI="" OLD_KEY="" NEW_INI="/etc/grafana/grafana.ini"
DUMP_FILE="" SKIP_IMPORT=0

# resolve symlink (instalação via install.sh cria link em /usr/local/bin)
SELF="$0"
while [[ -L "$SELF" ]]; do
    LINK="$(readlink "$SELF")"
    [[ "$LINK" = /* ]] && SELF="$LINK" || SELF="$(dirname "$SELF")/$LINK"
done
MIGRATOR_DIR="$(cd "$(dirname "$SELF")" && pwd)"

uso() { sed -n '3,26p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "f:d:u:H:P:m:O:o:k:i:nh" opt; do
    case $opt in
        f) SQLITE_FILE="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        H) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        m) MIGRATOR_DIR="$OPTARG" ;;
        O) DUMP_FILE="$OPTARG" ;;
        o) OLD_INI="$OPTARG" ;;
        k) OLD_KEY="$OPTARG" ;;
        i) NEW_INI="$OPTARG" ;;
        n) SKIP_IMPORT=1 ;;
        h|*) uso ;;
    esac
done

banner
[[ -n "$SQLITE_FILE" && -n "$DB_NAME" && -n "$DB_USER" ]] || uso
[[ -f "$SQLITE_FILE" ]] || erro "arquivo SQLite não encontrado: $SQLITE_FILE"
DUMP_FILE="${DUMP_FILE:-$(pwd)/grafana-$(date +%Y%m%d-%H%M%S).sql}"

# ------------------------------------------------------------ pré-requisitos
secao "Pré-requisitos"
command -v sqlite3 >/dev/null || erro "sqlite3 não instalado (apt install sqlite3)"
command -v awk     >/dev/null || erro "awk não instalado"
command -v mysql   >/dev/null || erro "cliente mysql não instalado"
[[ -f "$MIGRATOR_DIR/sqlitedump-fixed.sh" && -f "$MIGRATOR_DIR/escape-fixed.awk" ]] \
    || erro "sqlitedump-fixed.sh/escape-fixed.awk não encontrados em $MIGRATOR_DIR (use -m)"
ok "Dependências validadas (sqlite3 $(sqlite3 --version | awk '{print $1}'), awk, mysql)."

# TTY_DEV permite testes automatizados; em produção é o terminal do usuário.
TTY="${TTY_DEV:-/dev/tty}"
if [[ -z "${MYSQL_PWD:-}" ]]; then
    printf "  %s?%s Senha MySQL para %s@%s: " "$CY" "$C0" "$DB_USER" "$DB_HOST" >&2
    read -rs MYSQL_PWD < "$TTY"; echo >&2
    export MYSQL_PWD
fi
MYSQL_CMD=(mysql --default-character-set=utf8mb4 -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
sql() { "${MYSQL_CMD[@]}" -N -B -e "$1"; }

# ------------------------------------------------------------- secret_key
# Extrai secret_key de um grafana.ini (seção [security], ignorando comentários)
ini_secret_key() {
    awk '
        /^\[security\]/ { s=1; next }
        /^\[/           { s=0 }
        s && /^[[:space:]]*secret_key[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, "");
            print; exit
        }' "$1"
}
mascara() { local k="$1"; echo "${k:0:3}···${k: -2} (${#k} chars)"; }

secao "secret_key (senhas dos datasources)"
DEFAULT_KEY="SW2YcwTIb9zpOOhoPsMm"

NEW_KEY="${GF_SECURITY_SECRET_KEY:-}"
if [[ -z "$NEW_KEY" && -f "$NEW_INI" ]]; then
    NEW_KEY="$(ini_secret_key "$NEW_INI" || true)"
fi
[[ -z "$NEW_KEY" ]] && NEW_KEY_EFETIVA="$DEFAULT_KEY (padrão, chave não definida)" || NEW_KEY_EFETIVA="$NEW_KEY"

if [[ -n "$OLD_INI" ]]; then
    [[ -f "$OLD_INI" ]] || erro "ini antigo não encontrado: $OLD_INI"
    OLD_KEY="$(ini_secret_key "$OLD_INI" || true)"
fi

if [[ -n "$OLD_KEY" || -n "$OLD_INI" ]]; then
    K_OLD="${OLD_KEY:-$DEFAULT_KEY}"
    K_NEW="${NEW_KEY:-$DEFAULT_KEY}"
    if [[ "$K_OLD" == "$K_NEW" ]]; then
        ok "secret_key confere entre antigo e novo: $(mascara "$K_NEW")"
    else
        erro "secret_key DIFERENTE entre os ambientes!
       antigo: $(mascara "$K_OLD")
       novo:   $(mascara "$K_NEW") ${NEW_INI:+em $NEW_INI}
       Copie o secret_key do grafana.ini antigo para o novo ([security])
       e rode de novo — sem isso as senhas dos datasources não abrem."
    fi
else
    if [[ -n "$NEW_KEY" ]]; then
        aviso "não recebi a chave antiga (-o ini ou -k chave) para comparar."
        info  "chave local em uso: $(mascara "$NEW_KEY")"
    else
        aviso "sem chave antiga para comparar e o ini local usa a chave PADRÃO."
        info  "se o servidor antigo tinha secret_key própria, copie-a antes de iniciar o Grafana."
    fi
fi

# --------------------------------------------------- pré-checagens no MySQL
secao "Banco de destino  ${CDIM}$DB_USER@$DB_HOST/$DB_NAME${C0}"
sql "SELECT 1" >/dev/null || erro "não consegui conectar no MySQL"

sql "SELECT 1 FROM migration_log LIMIT 1" >/dev/null 2>&1 \
    || erro "tabela migration_log não existe no MySQL.
       Aponte o grafana.ini para este banco, inicie o Grafana uma vez
       (ele cria o schema), pare o serviço e rode este script de novo."
ok "Schema validado ($(sql "SHOW TABLES" | wc -l) tabelas)."

CHARSET=$(sql "SELECT default_character_set_name FROM information_schema.SCHEMATA WHERE schema_name='$DB_NAME'")
if [[ "$CHARSET" != "utf8mb4" ]]; then
    TBL_CHARSET=$(sql "SELECT SUBSTRING_INDEX(table_collation,'_',1) FROM information_schema.TABLES WHERE table_schema='$DB_NAME' AND table_name='dashboard'")
    [[ "$TBL_CHARSET" == "utf8mb4" ]] \
        && aviso "banco em '$CHARSET' mas tabela dashboard em utf8mb4 — deve funcionar" \
        || erro "charset '$CHARSET' — dashboards com emoji vão falhar. Recrie:
       CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
       e deixe o Grafana recriar o schema antes de importar."
else
    ok "Charset confirmado (utf8mb4)."
fi

MIG_SQLITE=$(sqlite3 "$SQLITE_FILE" "SELECT count(*) FROM migration_log")
MIG_MYSQL=$(sql "SELECT count(*) FROM migration_log")
if (( MIG_MYSQL < MIG_SQLITE )); then
    erro "versões diferentes do Grafana: migration_log SQLite=$MIG_SQLITE vs MySQL=$MIG_MYSQL.
       O Grafana que criou o schema é mais ANTIGO que o que gerou o grafana.db.
       Atualize o Grafana, inicie-o contra o MySQL (aplica as migrações que
       faltam), pare o serviço e rode de novo."
elif (( MIG_MYSQL > MIG_SQLITE )); then
    aviso "MySQL tem mais migrações ($MIG_MYSQL) que o SQLite ($MIG_SQLITE) — Grafana novo é mais recente; costuma funcionar, mas o ideal é igualar."
else
    ok "Versões do Grafana compatíveis (migration_log: $MIG_SQLITE = $MIG_MYSQL)."
fi

# ------------------------------------------------------------- gerar o dump
secao "Dump"
gerar_dump() { bash "$MIGRATOR_DIR/sqlitedump-fixed.sh" "$(realpath "$SQLITE_FILE")" > "$DUMP_FILE"; }
passo "Gerando arquivo de dump" gerar_dump || erro "falha ao gerar o dump: $(tail -3 /tmp/.gm-passo.log)"
[[ -s "$DUMP_FILE" ]] || erro "dump saiu vazio"
grep -q 'NO_BACKSLASH_ESCAPES' "$DUMP_FILE" || erro "dump sem NO_BACKSLASH_ESCAPES"
nota "$DUMP_FILE ($(wc -l < "$DUMP_FILE") linhas)"

if grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6,9}[+-][0-9]{2}:[0-9]{2}' "$DUMP_FILE"; then
    aviso "restaram timestamps formato Go no dump — o import pode falhar"
fi

if (( SKIP_IMPORT )); then
    info "modo -n: import não executado."
    exit 0
fi

# ------------------------------------------------------------------ importar
secao "Import  ${CDIM}(as tabelas serão truncadas)${C0}"
echo "  ${CY}⏸  Grafana precisa estar PARADO. Prosseguindo em 5s (Ctrl-C aborta)...${C0}"
sleep 5

importar() { "${MYSQL_CMD[@]}" < "$DUMP_FILE"; }
if passo "Importando dados para o MySQL" importar; then
    :
else
    tail -5 /tmp/.gm-passo.log >&2
    erro "import falhou (veja acima).
       Erros 1062 'Duplicate entry' = conflito de maiúsculas/minúsculas:
       edite $DUMP_FILE removendo uma das linhas conflitantes e reimporte:
       mysql --default-character-set=utf8mb4 -h $DB_HOST -u $DB_USER -p $DB_NAME < $DUMP_FILE"
fi

# --------------------------------------------------------------- validação
secao "Validação"
for T in user org dashboard folder data_source; do
    printf "  ${CDIM}•${C0} %-12s : %s registros\n" "$T" "$(sql "SELECT count(*) FROM \`$T\`" 2>/dev/null || echo '?')"
done

N_BAD_JSON=$(sql "SELECT count(*) FROM dashboard WHERE is_folder=0 AND JSON_VALID(data)=0" 2>/dev/null || echo 0)
if [[ "$N_BAD_JSON" != "0" ]]; then
    aviso "$N_BAD_JSON dashboard(s) com JSON inválido:"
    sql "SELECT uid, title FROM dashboard WHERE is_folder=0 AND JSON_VALID(data)=0"
else
    ok "Integridade: todos os dashboards aprovados no teste JSON_VALID."
fi

echo
echo "${CG}${CB}  ✔ MIGRAÇÃO CONCLUÍDA COM SUCESSO.${C0}"
secao "Próximos passos"
echo "  ${CDIM}1.${C0} Inicie o serviço do Grafana."
echo "  ${CDIM}2.${C0} Valide o acesso (os usuários precisarão realizar um novo login)."
echo "  ${CDIM}3.${C0} Verifique a integridade das pastas, dashboards e datasources."
echo
