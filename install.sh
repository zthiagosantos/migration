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
 
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else G="";R="";Y="";B="";D="";N=""; fi
 
if [[ -t 1 ]]; then C=$'\e[36m'; else C=""; fi
echo "${C}${B}"
echo "  ╭─────────────────────────────────────────╮"
echo "  │   FLOWBIX · GRAFANA DATABASE MIGRATOR   │"
echo "  ╰─────────────────────────────────────────╯${N}"
echo "  ${D}Destino: $DEST${N}"
[[ "$REPO" == "SEU_USUARIO/SEU_REPO" && "$BASE_URL" == https://raw.githubusercontent.com/* ]] \
    && { echo "${R}✘ Edite REPO ou BASE_URL no install.sh antes de publicar.${N}"; exit 1; }
command -v curl >/dev/null || { echo "${R}✘ curl não instalado${N}"; exit 1; }
 
SUDO=""
if [[ ! -w "$(dirname "$DEST")" && $EUID -ne 0 ]]; then
    command -v sudo >/dev/null && SUDO="sudo" || { echo "${R}✘ sem permissão para criar $DEST${N}"; exit 1; }
fi
 
$SUDO mkdir -p "$DEST"
for f in "${ARQUIVOS[@]}"; do
    echo "  ↓ $f"
    $SUDO curl -fsSL "$BASE_URL/$f" -o "$DEST/$f" \
        || { echo "${R}✘ falha ao baixar $BASE_URL/$f${N}"; exit 1; }
done
$SUDO chmod +x "$DEST/migrar-grafana.sh" "$DEST/sqlitedump-fixed.sh"
[[ -d /usr/local/bin ]] && $SUDO ln -sf "$DEST/migrar-grafana.sh" /usr/local/bin/migrar-grafana
 
# terminal interativo (fd 3): usado pelas dependências e pelo assistente
HAVE_TTY=0
if [[ "${NO_WIZARD:-0}" != "1" && -e "$TTY" ]]; then
    { exec 3< "$TTY"; } 2>/dev/null && HAVE_TTY=1
fi
 
perguntar() {  # perguntar "texto" "padrão" -> resposta em $RESP
    local texto="$1" padrao="${2:-}"
    if [[ -n "$padrao" ]]; then
        printf "  ${Y}?${N} %s ${D}[%s]${N}: " "$texto" "$padrao" >&2
    else
        printf "  ${Y}?${N} %s: " "$texto" >&2
    fi
    read -r -u 3 RESP || RESP=""
    [[ -z "$RESP" ]] && RESP="$padrao"
    echo >&2
}
 
# ------------------------------------------------------------- dependências
FALTA_CMD=()
command -v sqlite3 >/dev/null || FALTA_CMD+=(sqlite3)
command -v mysql   >/dev/null || FALTA_CMD+=(mysql)
 
if (( ${#FALTA_CMD[@]} )) && [[ "${NO_DEPS:-0}" != "1" ]]; then
    # mapeia comando -> pacote conforme o gerenciador disponível
    PKGS=() GERENCIADOR="" INSTALAR=""
    if command -v apt-get >/dev/null; then
        GERENCIADOR="apt"; INSTALAR="apt-get install -y"
        for c in "${FALTA_CMD[@]}"; do
            [[ "$c" == sqlite3 ]] && PKGS+=(sqlite3) || PKGS+=(default-mysql-client)
        done
    elif command -v dnf >/dev/null || command -v yum >/dev/null; then
        GERENCIADOR="dnf/yum"; INSTALAR="$(command -v dnf || command -v yum) install -y"
        for c in "${FALTA_CMD[@]}"; do
            [[ "$c" == sqlite3 ]] && PKGS+=(sqlite) || PKGS+=(mariadb)
        done
    fi
 
    if [[ -n "$GERENCIADOR" ]]; then
        echo "${Y}⚠ pacotes necessários não encontrados:${N} ${PKGS[*]}"
        if [[ "${AUTO_DEPS:-0}" == "1" ]]; then
            RESP="s"
        elif (( HAVE_TTY )); then
            perguntar "Instalar agora? (s/n)" "s"
        else
            RESP="n"
        fi
        if [[ "${RESP,,}" == "s" ]]; then
            echo "  ${D}· $SUDO $INSTALAR ${PKGS[*]}${N}"
            if [[ "$GERENCIADOR" == "apt" ]]; then
                $SUDO apt-get update -qq >/dev/null 2>&1 || true
            fi
            $SUDO $INSTALAR "${PKGS[@]}" >/dev/null                 && echo "  ${G}✔ dependências instaladas${N}"                 || { echo "  ${R}✘ falha ao instalar; instale manualmente: $SUDO $INSTALAR ${PKGS[*]}${N}"; exit 1; }
        else
            echo "  ${D}instale manualmente: $SUDO $INSTALAR ${PKGS[*]}${N}"
        fi
    else
        echo "${Y}⚠ instale antes de migrar: ${FALTA_CMD[*]}${N}"
        echo "  ${D}macOS: brew install sqlite mysql-client${N}"
    fi
fi
 
echo "${G}✔ Instalado.${N} Comando disponível: ${B}migrar-grafana${N}"
 
# ---------------------------------------------------------------- assistente
(( HAVE_TTY )) || exit 0
 
echo >&2
echo "${B}${C}▸ Assistente de migração${N}  ${D}(Enter aceita o valor entre colchetes)${N}" >&2
perguntar "Executar a migração agora? (s/n)" "s"
[[ "${RESP,,}" != "s" ]] && { echo "  ${D}Ok — rode depois com: migrar-grafana -h${N}" >&2; exit 0; }
 
DB_PADRAO="/var/lib/grafana/grafana.db"
while :; do
    perguntar "Caminho do grafana.db (origem)" "$DB_PADRAO"
    SQLITE_FILE="$RESP"
    [[ -f "$SQLITE_FILE" ]] && break
    echo "  ${R}✘ não encontrei $SQLITE_FILE${N}" >&2
done
perguntar "Banco MySQL de destino" "grafana";   DB_NAME="$RESP"
perguntar "Usuário MySQL" "grafana";   DB_USER="$RESP"
perguntar "Host MySQL" "localhost"; DB_HOST="$RESP"
perguntar "Porta MySQL" "3306";      DB_PORT="$RESP"
perguntar "grafana.ini ANTIGO para validar secret_key (Enter pula)" ""
OLD_INI="$RESP"
[[ -n "$OLD_INI" && ! -f "$OLD_INI" ]] && { echo "  ${Y}⚠ arquivo não existe; a validação de secret_key será pulada${N}" >&2; OLD_INI=""; }
 
echo >&2
echo "  ${D}·${N} ${B}Resumo:${N} $SQLITE_FILE → $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME${OLD_INI:+  (secret_key: $OLD_INI)}" >&2
perguntar "Confirmar e executar? (s/n)" "s"
[[ "${RESP,,}" != "s" ]] && { echo "  ${D}Abortado.${N}" >&2; exit 0; }
 
ARGS=(-f "$SQLITE_FILE" -d "$DB_NAME" -u "$DB_USER" -H "$DB_HOST" -P "$DB_PORT" -m "$DEST")
[[ -n "$OLD_INI" ]] && ARGS+=(-o "$OLD_INI")
 
exec bash "$DEST/migrar-grafana.sh" "${ARGS[@]}"
