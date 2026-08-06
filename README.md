# grafana-migrator

Migra o banco do Grafana de **SQLite** para **MySQL/MariaDB** com segurança —
preservando dashboards byte a byte, validando antes e depois, e sem depender de gawk.

Baseado no [grafana/database-migrator](https://github.com/grafana/database-migrator)
(Apache-2.0), com correções para Grafana moderno (testado com Grafana 12):

| Problema no script oficial | Correção |
|---|---|
| JSON corrompido em dashboards com regex (`\d`), paths (`C:\`) ou aspas → "Dashboard not found" | Dump usa `NO_BACKSLASH_ESCAPES`; nenhum sed toca nos dados |
| `escape.awk` só funciona com gawk (quebra no Debian/mawk e no macOS) | awk 100% POSIX |
| `signing_key` (timestamps Go) aborta o import no meio | Excluída — o Grafana regenera as chaves |
| Timestamps Go em `folder`/`kv_store` rejeitados pelo `DATETIME` | Normalizados no dump |
| Import parcial em caso de erro | Transacional: ou tudo, ou nada |
| Nenhuma validação | Pré-checa versão do Grafana (`migration_log`), charset `utf8mb4` e `secret_key`; pós-checa `JSON_VALID` de todos os dashboards |

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/install.sh | bash
```

## Uso

1. Crie o banco de destino:
   ```sql
   CREATE DATABASE grafana CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   ```
2. Aponte o `grafana.ini` para o MySQL, **inicie o Grafana uma vez** (ele cria o
   schema — use a mesma versão do Grafana que gerou o `grafana.db`!) e pare o serviço.
3. Rode a migração:
   ```bash
   migrar-grafana -f /var/lib/grafana/grafana.db -d grafana -u grafana -H localhost \
                  -o /caminho/grafana.ini.antigo
   ```
   O `-o` compara o `secret_key` dos dois ambientes (sem ele as senhas dos
   datasources não descriptografam). Alternativas: `-k CHAVE` para informar a
   chave antiga direto, ou omita para receber apenas um aviso.
4. Inicie o Grafana e valide. Todos os usuários precisarão logar de novo.

Outras opções: `-n` só gera o dump (sem importar), `-O arquivo.sql` define o
destino do dump, `-i` aponta o grafana.ini local (padrão `/etc/grafana/grafana.ini`),
`-P` porta do MySQL.

## Requisitos

`sqlite3` (3.8+), cliente `mysql`/`mariadb` e qualquer `awk` (mawk, gawk ou BSD).

## Licença

Apache-2.0 — trabalho derivado do grafana/database-migrator.
