#!/usr/bin/env bash
#
# install.sh — instala o grafana-migrator
#
#   curl -fsSL https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/install.sh | bash
#
# Variáveis (opcionais):
#   REPO=usuario/repo BRANCH=main DEST=/opt/grafana-migrator  curl ... | bash

set -euo pipefail

# >>>>>> EDITE AQUI depois de subir para o seu GitHub <<<<<<
REPO="${REPO:-SEU_USUARIO/SEU_REPO}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-/opt/grafana-migrator}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/$REPO/$BRANCH}"

ARQUIVOS=(migrar-grafana.sh sqlitedump-fixed.sh escape-fixed.awk)

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G="";R="";Y="";B="";N=""; fi

echo "${B}Instalando grafana-migrator em $DEST${N}"
[[ "$REPO" == "SEU_USUARIO/SEU_REPO" && "$BASE_URL" == https://raw.githubusercontent.com/* ]] \
    && { echo "${R}✘ Edite a variável REPO no install.sh (ou passe REPO=usuario/repo).${N}"; exit 1; }

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

# link no PATH
if [[ -d /usr/local/bin ]]; then
    $SUDO ln -sf "$DEST/migrar-grafana.sh" /usr/local/bin/migrar-grafana
    echo "${G}✔${N} comando ${B}migrar-grafana${N} disponível no PATH"
fi

# dependências (só avisa, não instala nada sem pedir)
FALTA=()
command -v sqlite3 >/dev/null || FALTA+=(sqlite3)
command -v mysql   >/dev/null || FALTA+=("mysql-client (ou mariadb-client)")
if (( ${#FALTA[@]} )); then
    echo "${Y}⚠ dependências faltando: ${FALTA[*]}${N}"
    echo "  Debian/Ubuntu:  sudo apt install sqlite3 default-mysql-client"
    echo "  macOS:          brew install sqlite mysql-client"
fi

echo
echo "${G}${B}✔ Instalado.${N} Exemplo de uso:"
echo "  migrar-grafana -f /var/lib/grafana/grafana.db -d grafana -u grafana -H localhost \\"
echo "                 -o /caminho/grafana.ini.antigo   # valida o secret_key"
