# Checkout Team: fluxo de trabalho com speckit

Uma tarefa do Jira (ex.: `INP-2403`) vira uma pasta com duas worktrees, VRPdvAPI e VRCheckout,
ambas na branch `INP-2403`. O speckit vive no VRCheckout: uma única spec em
`VRCheckout/specs/INP-2403/` cobre os dois projetos, e cada requisito é marcado com o projeto a que pertence.

```
team-checkout/
├── work.sh
├── .vscode/              modelos de launch.json e settings.json
├── main/                 clones principais (branch main); as worktrees saem daqui
│   ├── VRPdvAPI/
│   └── VRCheckout/
└── INP-2403/             pasta da tarefa
    ├── .vscode/          debug de Go + Dart
    ├── VRPdvAPI/         worktree na branch INP-2403
    └── VRCheckout/       worktree na branch INP-2403
        └── specs/INP-2403/
```



## 1. Preparar o ambiente (uma vez)

```bash
./work.sh init
```

O comando clona VRPdvAPI e VRCheckout em `main/` e copia o `.vscode/` para `main/.vscode/`. Repos que já
estão clonados só recebem `fetch`.

## 2. Criar a tarefa e especificar

```bash
./work.sh INP-2403 -b speckit        # base origin/speckit
./work.sh INP-2403 -b speckit -l     # base speckit local (com commits sem push)
```

Esse comando:

1. Cria `INP-2403/` com as duas worktrees na branch `INP-2403`. Se a branch já existe localmente ou no
   `origin`, ela é reaproveitada e o `-b` é ignorado.
2. Se a base não existir em um dos projetos (por exemplo, `speckit` só existe no VRCheckout), pergunta se
   deve usar a `main` naquele projeto.
3. Para antes de criar qualquer coisa se a base do VRCheckout não tiver `.specify/`.
4. Abre uma aba do Claude no VRCheckout, com o VRPdvAPI como diretório adicional, já rodando
   `/speckit-specify INP-2403`.

O hook `vr-escopo-specify` lê a tarefa no Jira, levanta o que ela toca em cada projeto e grava
`specs/INP-2403/spec.md`.

Para usar uma branch com nome diferente da tarefa, passe `--branch` (ou `-n`). A pasta e a spec continuam
com o nome da tarefa; o `-b` segue sendo a base de onde a branch nova parte:

```bash
./work.sh INP-2403 -n feature/troco -b speckit   # pasta INP-2403/, branch feature/troco
```

Os comandos seguintes (`implementar`, `apagar`) não precisam repetir o `--branch`: eles usam a branch em que
as worktrees da tarefa já estão.

Texto extra depois da chave vai junto com o comando:

```bash
./work.sh INP-2403 -b speckit "considerar também o modo Self"
```