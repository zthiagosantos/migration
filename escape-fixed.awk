# escape-fixed.awk — versão portável (POSIX) do escape.awk do grafana/database-migrator
#
# Correções em relação ao original:
#   1. Não usa match() de 3 argumentos (exclusivo do gawk) — funciona com
#      mawk (Debian/Ubuntu), BSD awk (macOS) e gawk.
#   2. Linhas que não são INSERT (ex.: continuação de valores com quebra de
#      linha real) são preservadas — o original as descartava silenciosamente.
#
# Função: colocar crases na tabela e nas colunas de cada INSERT gerado pelo
# sqlite3 (.headers on / .mode insert), para nomes reservados do MySQL.

/^INSERT INTO / {
    p1 = index($0, "(")
    if (p1 > 0) {
        head = substr($0, 1, p1 - 1)         # "INSERT INTO tabela"
        rest = substr($0, p1 + 1)
        p2 = index(rest, ") VALUES(")
        if (p2 > 0) {
            table = substr(head, 13)         # depois de "INSERT INTO "
            sub(/^ +/, "", table); sub(/ +$/, "", table)

            middle = substr(rest, 1, p2 - 1) # lista de colunas
            values = substr(rest, p2 + 9)    # tudo depois de ") VALUES(" (inclui ");" final)

            gsub(/"/, "", middle)
            n = split(middle, cols, ",")
            out = ""
            for (i = 1; i <= n; i++)
                out = out (i > 1 ? "," : "") "`" cols[i] "`"

            printf("INSERT INTO `%s` (%s) VALUES(%s\n", table, out, values)
            next
        }
    }
    print
    next
}
{ print }
