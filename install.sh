#!/usr/bin/env bash
#
# install.sh — instala o grafana-migrator e (opcionalmente) já executa a migração
#
#   Instalar e migrar em um comando só (o assistente pergunta tudo):
#     curl -fsSL https://SEU_SERVIDOR/install.sh | bash
#
#   Só instalar, sem assistente:
#     curl -fsSL https://SEU_SERVIDOR/install.sh | NO_WIZARD=1 bash
#
# Variáveis opcionais: REPO=usuario/repo BRANCH=main DEST=/opt/grafana-migrator
#                      BASE_URL=https://... (sobrepõe REPO/BRANCH)

set -euo pipefail

# >>>>>> EDITE AQUI depois de subir para o seu servidor/repositório <<<<<<
REPO="${REPO:-zthiagosantos/migration}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-/opt/grafana-migrator}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
TTY="${TTY_DEV:-/dev/tty}"

ARQUIVOS=(migrar-grafana.sh sqlitedump-fixed.sh escape-fixed.awk)
 
if [[ -t 2 ]]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
    ANIMA=1
else
    G="";R="";Y="";C="";B="";D="";N=""; ANIMA=0
fi
 
secao() { echo >&2; echo "${B}${C}▸${N} ${B}$*${N}" >&2; }
ok()    { echo "  ${G}✔${N} $*" >&2; }
falha() { echo "  ${R}✘${N} $*" >&2; }
aviso() { echo "  ${Y}⚠${N} $*" >&2; }
nota()  { echo "  ${D}· $*${N}" >&2; }
 
# passo "texto" comando...  → spinner enquanto roda, ✔/✘ ao terminar
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
passo() {
    local texto="$1"; shift
    local rc=0
    if (( ANIMA )); then
        "$@" >/tmp/.gm-passo.log 2>&1 &
        local pid=$! i=0
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${C}%s${N} %s" "${SPIN[i++ % 10]}" "$texto" >&2
            sleep 0.08
        done
        wait "$pid" || rc=$?
        printf "\r\033[K" >&2
    else
        "$@" >/tmp/.gm-passo.log 2>&1 || rc=$?
    fi
    if (( rc == 0 )); then ok "$texto"; else falha "$texto"; fi
    return $rc
}
 
# largura em COLUNAS (ignora bytes de continuação UTF-8; independe do locale)
larg() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c; }
 
caixa() {  # caixa "linha1" "linha2" ...
    local L=58 linha pad
    printf "  ${C}╭" >&2; printf '─%.0s' $(seq 1 $L) >&2; printf "╮${N}\n" >&2
    for linha in "$@"; do
        pad=$(( L - 2 - $(larg "$linha") ))
        (( pad < 0 )) && pad=0
        printf "  ${C}│${N} %s%*s ${C}│${N}\n" "$linha" "$pad" "" >&2
    done
    printf "  ${C}╰" >&2; printf '─%.0s' $(seq 1 $L) >&2; printf "╯${N}\n" >&2
}
 
banner() {
    local L=58
    echo >&2
    printf "  ${C}${B}╭" >&2; printf '─%.0s' $(seq 1 $L) >&2; printf "╮${N}\n" >&2
    printf "  ${C}${B}│%*s%s%*s│${N}\n" 16 "" "FLOWBIX • GRAFANA MIGRATOR" 16 "" >&2
    printf "  ${C}${B}│%*s%s%*s│${N}\n" 17 "" "SQLite ➜ MySQL / MariaDB" 17 "" >&2
    printf "  ${C}${B}╰" >&2; printf '─%.0s' $(seq 1 $L) >&2; printf "╯${N}\n" >&2
}
 
banner
 
if [[ "$REPO" == "SEU_USUARIO/SEU_REPO" && "$BASE_URL" == https://raw.githubusercontent.com/* ]]; then
    secao "Instalação"; falha "Edite REPO ou BASE_URL no install.sh antes de publicar."; exit 1
fi
command -v curl >/dev/null || { secao "Instalação"; falha "curl não instalado"; exit 1; }
 
SUDO=""
if [[ ! -w "$(dirname "$DEST")" && $EUID -ne 0 ]]; then
    command -v sudo >/dev/null && SUDO="sudo" || { falha "sem permissão para criar $DEST"; exit 1; }
fi
 
# ------------------------------------------------------------------ download
secao "Instalação"
 
baixar_tudo() {
    $SUDO mkdir -p "$DEST" || return 1
    local f
    for f in "${ARQUIVOS[@]}"; do
        $SUDO curl -fsSL "$BASE_URL/$f" -o "$DEST/$f" || return 1
    done
    $SUDO chmod +x "$DEST/migrar-grafana.sh" "$DEST/sqlitedump-fixed.sh" || return 1
    if [[ -d /usr/local/bin ]]; then $SUDO ln -sf "$DEST/migrar-grafana.sh" /usr/local/bin/migrar-grafana; fi
    return 0
}
 
passo "Baixando arquivos necessários" baixar_tudo \
    || { nota "verifique a URL: $BASE_URL"; exit 1; }
 
# terminal interativo (fd 3): usado pelas dependências e pelo assistente
HAVE_TTY=0
if [[ "${NO_WIZARD:-0}" != "1" && -e "$TTY" ]]; then
    { exec 3< "$TTY"; } 2>/dev/null && HAVE_TTY=1
fi
 
perguntar() {
    local texto="$1" padrao="${2:-}"
    if [[ -n "$padrao" ]]; then
        printf "  ${C}▸${N} %s ${D}[%s]${N}: " "$texto" "$padrao" >&2
    else
        printf "  ${C}▸${N} %s: " "$texto" >&2
    fi
    read -r -u 3 RESP || RESP=""
    [[ -z "$RESP" ]] && RESP="$padrao"
    return 0
}
 
# ------------------------------------------------------------- dependências
FALTA_CMD=()
command -v sqlite3 >/dev/null || FALTA_CMD+=(sqlite3)
command -v mysql   >/dev/null || FALTA_CMD+=(mysql)
 
if (( ${#FALTA_CMD[@]} == 0 )); then
    ok "Verificando dependências"
elif [[ "${NO_DEPS:-0}" == "1" ]]; then
    aviso "Dependências ausentes: ${FALTA_CMD[*]}"
else
    PKGS=() INSTALAR=""
    if command -v apt-get >/dev/null; then
        INSTALAR="apt-get install -y"
        for c in "${FALTA_CMD[@]}"; do
            [[ "$c" == sqlite3 ]] && PKGS+=(sqlite3) || PKGS+=(default-mysql-client)
        done
    elif command -v dnf >/dev/null || command -v yum >/dev/null; then
        INSTALAR="$(command -v dnf || command -v yum) install -y"
        for c in "${FALTA_CMD[@]}"; do
            [[ "$c" == sqlite3 ]] && PKGS+=(sqlite) || PKGS+=(mariadb)
        done
    fi
 
    if [[ -n "$INSTALAR" ]]; then
        aviso "Pacotes necessários não encontrados: ${PKGS[*]}"
        if [[ "${AUTO_DEPS:-0}" == "1" ]]; then RESP="s"
        elif (( HAVE_TTY )); then perguntar "Instalar agora? (s/n)" "s"
        else RESP="n"; fi
 
        if [[ "${RESP,,}" == "s" ]]; then
            instalar_deps() {
                command -v apt-get >/dev/null && { $SUDO apt-get update -qq >/dev/null 2>&1 || true; }
                $SUDO $INSTALAR "${PKGS[@]}"
            }
            passo "Instalando dependências (${PKGS[*]})" instalar_deps \
                || { nota "instale manualmente: $SUDO $INSTALAR ${PKGS[*]}"; exit 1; }
        else
            nota "instale manualmente: $SUDO $INSTALAR ${PKGS[*]}"
        fi
    else
        aviso "Dependências ausentes: ${FALTA_CMD[*]}"
        nota "macOS: brew install sqlite mysql-client"
    fi
fi
 
ok "Componentes instalados em $DEST"
 
# ---------------------------------------------------------------- assistente
(( HAVE_TTY )) || exit 0
 
secao "Assistente de migração ${D}(Pressione Enter para aceitar os valores padrão)${N}"
perguntar "Executar a migração agora? (s/n)" "s"
if [[ "${RESP,,}" != "s" ]]; then nota "Rode depois com: migrar-grafana -h"; exit 0; fi
echo >&2
 
while :; do
    perguntar "Caminho do banco de origem (SQLite)" "/var/lib/grafana/grafana.db"
    SQLITE_FILE="$RESP"
    [[ -f "$SQLITE_FILE" ]] && break
    falha "não encontrei $SQLITE_FILE"
done
perguntar "Banco de destino (MySQL)" "grafana";   DB_NAME="$RESP"
perguntar "Usuário do banco"         "grafana";   DB_USER="$RESP"
perguntar "Host do banco"            "localhost"; DB_HOST="$RESP"
perguntar "Porta"                    "3306";      DB_PORT="$RESP"
perguntar "Caminho do grafana.ini de origem (Enter para pular)" ""
OLD_INI="$RESP"
if [[ -n "$OLD_INI" && ! -f "$OLD_INI" ]]; then aviso "arquivo não existe; validação de secret_key será pulada"; OLD_INI=""; fi
 
secao "Resumo da operação"
if [[ -n "$OLD_INI" ]]; then
    caixa "• Origem:  $SQLITE_FILE" "• Destino: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME" "• Ini:     $OLD_INI"
else
    caixa "• Origem:  $SQLITE_FILE" "• Destino: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
fi
perguntar "Confirmar e iniciar a migração? (s/n)" "s"
if [[ "${RESP,,}" != "s" ]]; then nota "Abortado."; exit 0; fi
 
ARGS=(-f "$SQLITE_FILE" -d "$DB_NAME" -u "$DB_USER" -H "$DB_HOST" -P "$DB_PORT" -m "$DEST")
if [[ -n "$OLD_INI" ]]; then ARGS+=(-o "$OLD_INI"); fi
 
export GM_NO_BANNER=1
exec bash "$DEST/migrar-grafana.sh" "${ARGS[@]}"
