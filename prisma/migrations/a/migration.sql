-- it's a migration (with parens
ALTER TABLE "x" ADD COLUMN "y" TEXT;
EOF""",
"sed_ellipsis": f"""cd {W} && sed -i 's/A\\[p\\] !== undefined || g(p) !== null,/A[p] !== undefined,/' apps/server/package.json && grep -c "length > 0," apps/server/package.json""",
"sed_with_dq_paren": f"""cd {W} && sed -i "s/foo(/bar(/" apps/server/package.json""",
"dollar_paren_before": f"""cd {W} && X=$(git rev-parse HEAD) && sed -i 's/a/b/' apps/server/package.json""",
"subshell_before": f"""cd {W} && (git status) && sed -i 's/a/b/' apps/server/package.json""",
"backtick_in_sq": f"""cd {W} && sed -i 's/`a`/b/' apps/server/package.json""",
"python_in_dq_paren": f"""cd {W} && python3 -c "print(1)" && sed -i 's/a/b/' apps/server/package.json""",
"ansi": f"""cd {W} && sed -i $'s/a\\'/b/' apps/server/package.json""",
"arith": f"""cd {W} && echo $((1+2)) && sed -i 's/a/b/' apps/server/package.json""",
"case_paren": f"""cd {W} && case x in a) echo;; esac; sed -i 's/a/b/' apps/server/package.json""",
"brace": f"""cd {W} && {{ echo a; }} && sed -i 's/a/b/' apps/server/package.json""",
"dq_escaped_quote": f"""cd {W} && sed -i "s/\\"a\\"/b/" apps/server/package.json""",
"heredoc_unq_paren": f"""cd {W} && cat > a.txt <<EOF
(unbalanced
