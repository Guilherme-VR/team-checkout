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

## 3. Planejar (na mesma aba)

Rode em ordem; os comandos marcados como opcionais podem ser pulados.

| Comando | O que faz | Gera |
|---|---|---|
| `/speckit-clarify` | (opcional) Faz até 5 perguntas sobre pontos vagos da spec e grava as respostas nela. | `spec.md` atualizado |
| `/speckit-plan` | Faz a pesquisa, o modelo de dados e os contratos entre API e Checkout. | `plan.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md` |
| `/speckit-checklist` | (opcional) Gera um checklist de qualidade para um tema (ex.: "segurança"). | `checklists/` |
| `/speckit-tasks` | Quebra o plano em tasks por projeto. | `tasks.md` (índice e tasks `I` de integração), `tasks-api.md`, `tasks-checkout.md` |
| `/speckit-analyze` | (opcional) Confere a coerência entre spec, plano e tasks antes de implementar. | relatório no chat |

Revise os arquivos em `VRCheckout/specs/INP-2403/` antes de seguir. É mais barato corrigir a spec e o
plano agora do que o código depois.

## 4. Implementar

Em um terminal novo, na raiz do `team-checkout`:

```bash
./work.sh implementar INP-2403
```

O comando abre uma aba por projeto que tem tasks:

- **api**: `/speckit-implement INP-2403 --projeto api` executa `tasks-api.md`.
- **checkout**: `/speckit-implement INP-2403 --projeto checkout` executa `tasks-checkout.md`.

Regras do fluxo:

- As duas sessões rodam em paralelo. Cada uma marca `[X]` só no próprio arquivo de tasks.
- As tasks `I…` do `tasks.md` (integração) ficam para a sessão **checkout**, e ela só as executa depois que
  `tasks-api.md` e `tasks-checkout.md` estão todas concluídas. Se a API terminar depois, rode o implement do
  checkout de novo.
- O código segue `contracts/` à risca. Se o código divergir do contrato, a sessão para e pergunta.
- Ao terminar, o hook `vr-roteiro-teste` gera `specs/INP-2403/roteiro-de-teste.md`, com o passo a passo de
  teste manual nos modos Clássico, Touch e Self.

Se algo da spec ficou sem implementar, rode `/speckit-converge`. Ele compara spec, plano e tasks com o código
e acrescenta as tasks que faltam no arquivo do projeto certo. Depois disso, rode o implement de novo.

## 5. Testar e depurar

Abra a pasta `INP-2403/` no VS Code. O `.vscode/launch.json` tem estas configurações:

- `VRPdvAPI (Go)`
- `VRCheckout (debug mode)`, `(profile mode)`, `(release mode)` e `(driver)`
- `API + Checkout` e `API + Checkout (driver)`, que sobem os dois juntos

Use o `roteiro-de-teste.md` para validar no PDV.

## 6. Entregar

Em cada worktree que mudou (`INP-2403/VRPdvAPI` e `INP-2403/VRCheckout`), faça commit, push e abra o PR da
branch `INP-2403`, como em qualquer repo. A spec em `specs/INP-2403/` vai no PR do VRCheckout.

## 7. Limpar

```bash
./work.sh apagar INP-2403
```

O comando remove as worktrees, a branch local e a pasta da tarefa. A branch remota fica. Ele recusa se houver
alteração não commitada ou commit sem push em qualquer um dos projetos; `--forcar` descarta essas pendências.

## Outros comandos

| Comando | Uso |
|---|---|
| `./work.sh criar <branch>` | Só cria as worktrees, sem speckit nem aba (ex.: `./work.sh criar 8.6.0` para trabalhar numa branch existente). |
| `./work.sh ajuda` | Lista comandos e opções. |
