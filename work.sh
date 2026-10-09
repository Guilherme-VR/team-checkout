#!/usr/bin/env bash
# Monta e desmonta a pasta <Checkout-Team>/INP-XXXX de uma tarefa: worktrees de VRPdvAPI e
# VRCheckout na branch INP-XXXX e debug do VS Code. Comandos em ajuda().
set -e
# Abas abertas por versões antigas deste script herdaram MSYS_NO_PATHCONV; com ela, o git não
# acha os caminhos /c/... e todo "git -C" falha.
unset MSYS_NO_PATHCONV

ajuda() {
  cat <<'EOF'
Uso: ./work.sh <comando> <tarefa> [opções] [texto extra]

Comandos:
  init         Clona VRPdvAPI e VRCheckout em main/, na branch main. Rode uma vez,
               antes dos outros comandos; não pede <tarefa>. Repos já clonados ficam.
  criar        Só cria as worktrees (VRPdvAPI + VRCheckout) na pasta da tarefa.
  especificar  Cria as worktrees e abre uma aba com /speckit-specify. (padrão)
  implementar  Abre uma aba de /speckit-implement por projeto que tem tasks
               (tasks-api.md, tasks-checkout.md). Rode depois do /speckit-tasks.
  apagar       Remove as worktrees e a branch local da tarefa; o remoto fica.
               Recusa se houver alteração não commitada ou commit sem push.
               Antes, encerra o servidor do CodeGraph aberto na pasta da tarefa.
  ajuda        Mostra esta mensagem.

<tarefa>: nome exato da tarefa, que vira o nome da pasta e, sem --branch, o da branch
         (ex.: INP-2403).

Opções:
  --branch, -n <nome>  Nome da branch da tarefa (padrão: <tarefa>). No apagar, sem esta
                       opção, vale a branch em que a worktree da tarefa está.
  --base, -b <branch>  Branch de partida de uma branch nova (padrão: main).
  --local, -l          Parte da <branch> local, com commits sem push, em vez de origin/<branch>.
  --forcar, -f         No apagar, descarta alterações e commits sem push.
  --remoto, -r <url>   No init, URL base dos repos (padrão: https://github.com/vrsoftbr).

O texto extra vai junto do comando do Claude nas abas.

Exemplos:
  ./work.sh init                            clona os repos em main/
  ./work.sh INP-2403                        cria e abre o specify
  ./work.sh criar INP-2403                  só cria as worktrees
  ./work.sh criar INP-2403 -b release/6.10  branch nova a partir de release/6.10
  ./work.sh INP-2403 -n feature/troco       pasta INP-2403, branch feature/troco
  ./work.sh implementar INP-2403            abre as abas do implement
  ./work.sh apagar INP-2403                 remove tudo da tarefa localmente
EOF
}

CMD=especificar
KEY=
BRANCH=
BASE=main
LOCAL=
FORCE=
REMOTE=https://github.com/vrsoftbr
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    init|criar|especificar|implementar|apagar|ajuda) CMD="$1" ;;
    -h|--help|help) CMD=ajuda ;;
    --implementar|-i) CMD=implementar ;;
    --apagar) CMD=apagar ;;
    --branch|-n)
      [ -n "$2" ] || { echo "--branch precisa de um nome." >&2; exit 1; }
      BRANCH="$2"; shift ;;
    --base|-b)
      [ -n "$2" ] || { echo "--base precisa de uma branch." >&2; exit 1; }
      BASE="$2"; shift ;;
    --local|-l) LOCAL=1 ;;
    --forcar|-f) FORCE=1 ;;
    --remoto|-r)
      [ -n "$2" ] || { echo "--remoto precisa de uma URL." >&2; exit 1; }
      REMOTE="${2%/}"; shift ;;
    -*) echo "Opção desconhecida: $1. Veja ./work.sh ajuda" >&2; exit 1 ;;
    *)
      if [ -n "$KEY" ]; then EXTRA+=("$1"); else KEY="$1"; fi ;;
  esac
  shift
done

if [ "$CMD" = ajuda ]; then
  ajuda
  exit 0
fi
if [ -z "$KEY" ] && [ "$CMD" != init ]; then
  echo "Informe a tarefa: ./work.sh $CMD INP-XXXX (veja ./work.sh ajuda)" >&2
  exit 1
fi
if [ -n "$BRANCH" ] && ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "--branch: nome de branch inválido: $BRANCH" >&2
  exit 1
fi

DIR=$(dirname "$(realpath "$0")")
# Roda tanto de speckit/ quanto de uma cópia na raiz do Checkout-Team.
# Sem main/ em nenhum dos dois (antes do init), a raiz é a pasta do script.
if [ -d "$DIR/main" ]; then TEAM="$DIR"
elif [ -d "$(dirname "$DIR")/main" ]; then TEAM=$(dirname "$DIR")
else TEAM="$DIR"
fi
WORK="$TEAM/$KEY"
SPECS="$WORK/VRCheckout/specs/$KEY"
PROJECTS=(VRPdvAPI VRCheckout)

has_ref() { git -C "$1" rev-parse --verify --quiet "$2" >/dev/null; }

# Branch da tarefa no projeto $1: a do --branch; sem ele, a da worktree que já existe
# (criada antes com --branch); sem worktree, o nome da tarefa.
branch_of() {
  local b
  if [ -n "$BRANCH" ]; then echo "$BRANCH"; return; fi
  [ -e "$WORK/$1" ] && b=$(git -C "$WORK/$1" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$b" ] && [ "$b" != HEAD ]; then echo "$b"; else echo "$KEY"; fi
}

# $1 = repo, $2 = branch. A primeira entrada é o próprio main/<repo>, que nunca é removido.
worktree_of() {
  git -C "$1" worktree list --porcelain |
    awk -v b="branch refs/heads/$2" '/^worktree /{n++; w=substr($0,10)} n>1 && $0==b{print w}'
}

# Encerra os servidores do CodeGraph (`codegraph serve --path <pasta>`) da pasta da tarefa ou de
# uma subpasta dela, com os processos filhos. Um servidor órfão, de sessão do Claude já fechada,
# segura o índice em .codegraph/ e a remoção da worktree falha. Os de outras tarefas ficam.
stop_codegraph() {
  command -v powershell.exe >/dev/null || return 0
  CG_PATH=$(cygpath -w "$WORK") powershell.exe -NoProfile -NonInteractive -Command '
    $dir = [regex]::Escape($env:CG_PATH.TrimEnd("\"))
    $all = Get-CimInstance Win32_Process
    function Stop-Tree($id) {
      $all | Where-Object ParentProcessId -eq $id | ForEach-Object { Stop-Tree $_.ProcessId }
      Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    $all | Where-Object {
      $_.CommandLine -match "codegraph(\.js)?`"?\s+serve" -and
      $_.CommandLine -match "--path\s+`"?$dir(\\|`"|\s|$)"
    } | ForEach-Object {
      Stop-Tree $_.ProcessId
      "CodeGraph: servidor $($_.ProcessId) encerrado."
    }
  ' | tr -d '\r'
}

# Confere os dois projetos antes de apagar qualquer coisa, para não deixar a tarefa pela metade.
delete_local() {
  local problems=() p repo wt n b
  for p in "${PROJECTS[@]}"; do
    git -C "$TEAM/main/$p" worktree prune
  done
  for p in "${PROJECTS[@]}"; do
    repo="$TEAM/main/$p"
    b=$(branch_of "$p")
    has_ref "$repo" "refs/heads/$b" || continue
    if [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = "$b" ]; then
      echo "$p: main/$p está na branch $b; troque de branch antes." >&2
      exit 1
    fi
    wt=$(worktree_of "$repo" "$b")
    # A spec em specs/INP-XXXX não conta como pendência: vai embora junto com a worktree.
    if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain -- . ":(exclude)specs/$KEY")" ]; then
      problems+=("$p: alterações não commitadas em $wt")
    fi
    n=$(git -C "$repo" rev-list --count "refs/heads/$b" --not --remotes)
    if [ "$n" -gt 0 ]; then
      problems+=("$p: $n commit(s) só locais em $b")
    fi
  done
  if [ ${#problems[@]} -gt 0 ] && [ -z "$FORCE" ]; then
    printf '  - %s\n' "${problems[@]}" >&2
    echo "Nada apagado. Resolva, ou repita com --forcar para descartar." >&2
    exit 1
  fi

  stop_codegraph

  for p in "${PROJECTS[@]}"; do
    repo="$TEAM/main/$p"
    b=$(branch_of "$p")
    if ! has_ref "$repo" "refs/heads/$b"; then
      echo "$p: sem branch local $b."
      continue
    fi
    wt=$(worktree_of "$repo" "$b")
    if [ -n "$wt" ]; then
      # .dart_tool e ephemeral/ passam de 260 caracteres; sem longpaths a remoção para no meio.
      # --force sempre: a checagem acima já barrou pendências, e a spec não commitada travaria o git.
      git -c core.longpaths=true -C "$repo" worktree remove --force "$wt"
      echo "$p: worktree $wt removida."
    fi
    git -C "$repo" branch -D "$b" >/dev/null
    echo "$p: branch local $b apagada."
  done

  # Bundles antigos têm junctions para shared/; só some a pasta quando sobrou apenas o CLAUDE.md (hardlink).
  if [ -d "$WORK" ]; then
    # Junction em bundle antigo: apagar os arquivos dentro dela apagaria os originais.
    if [ -d "$WORK/.vscode" ] && [ ! -L "$WORK/.vscode" ]; then
      rm -f "$WORK/.vscode/launch.json" "$WORK/.vscode/settings.json"
      rmdir "$WORK/.vscode" 2>/dev/null || true
    fi
    # Índice do CodeGraph da tarefa (vr-codegraph.sh): derivado, o servidor já foi encerrado acima.
    if [ -d "$WORK/.codegraph" ] && [ ! -L "$WORK/.codegraph" ]; then
      # Banco aberto por um processo que o stop_codegraph não reconheceu: avisa em vez de abortar.
      rm -rf "$WORK/.codegraph" ||
        echo "Aviso: $WORK/.codegraph em uso; feche a sessão do Claude dessa pasta e apague à mão." >&2
    fi
    if [ "$(ls -A "$WORK")" = "CLAUDE.md" ]; then
      rm "$WORK/CLAUDE.md"
      rmdir "$WORK"
    elif [ -n "$(ls -A "$WORK")" ]; then
      echo "Aviso: $WORK ficou com conteúdo; confira e remova à mão." >&2
    else
      rmdir "$WORK"
    fi
  fi
}

# main/<repo> é o clone principal: as worktrees das tarefas saem dele.
init_main() {
  local p repo
  mkdir -p "$TEAM/main"
  for p in "${PROJECTS[@]}"; do
    repo="$TEAM/main/$p"
    if [ -d "$repo/.git" ]; then
      echo "$p: main/$p já existe; só atualizando."
      git -C "$repo" fetch origin --quiet || echo "$p: fetch falhou." >&2
      continue
    fi
    if [ -e "$repo" ]; then
      echo "$p: $repo existe e não é um repo git; remova antes." >&2
      exit 1
    fi
    echo "$p: clonando $REMOTE/$p.git em main/$p."
    # .dart_tool e ephemeral/ passam de 260 caracteres; longpaths fica gravado no repo.
    git -c core.longpaths=true clone --branch main "$REMOTE/$p.git" "$repo"
    git -C "$repo" config core.longpaths true
  done
  install_fvm "$TEAM/main/VRCheckout"
  setup_debugger "$TEAM/main"
}

# Branch da tarefa já existente (local ou no origin) é reaproveitada; a base só vale para branch nova.
# Sem --local, origin/<base> primeiro, para não partir de uma branch local desatualizada.
source_ref() {
  local repo="$TEAM/main/$1" b first="origin/$BASE" second="$BASE"
  b=$(branch_of "$1")
  [ -n "$LOCAL" ] && { first="$BASE"; second="origin/$BASE"; }
  if has_ref "$repo" "refs/heads/$b"; then echo "$b"
  elif has_ref "$repo" "refs/remotes/origin/$b"; then echo "origin/$b"
  elif has_ref "$repo" "$first"; then echo "$first"
  elif has_ref "$repo" "$second"; then echo "$second"
  fi
}

add_worktree() {
  local repo="$TEAM/main/$1" path="$WORK/$1" b ref answer
  if [ -e "$path" ]; then
    echo "$1: $path já existe; reaproveitando."
    return
  fi
  b=$(branch_of "$1")
  ref=$(source_ref "$1")
  # Base que só existe num dos projetos (ex.: speckit, só no VRCheckout): oferece a main no outro.
  if [ -z "$ref" ] && [ "$BASE" != main ] && [ -t 0 ]; then
    read -r -p "$1: base $BASE não existe. Usar a main? [s/N] " answer
    case "$answer" in
      s|S|sim|Sim) ref=$(BASE=main source_ref "$1") ;;
    esac
  fi
  case "$ref" in
    "") echo "$1: base $BASE não existe." >&2; exit 1 ;;
    "$b")
      echo "$1: usando a branch local $b."
      git -C "$repo" worktree add "$path" "$b" ;;
    "origin/$b")
      echo "$1: rastreando origin/$b."
      git -C "$repo" worktree add --track -b "$b" "$path" "origin/$b" ;;
    *)
      echo "$1: branch nova $b a partir de $ref."
      git -C "$repo" worktree add --no-track -b "$b" "$path" "$ref" ;;
  esac
}

# O speckit tem de vir versionado na branch da tarefa; checado antes de criar qualquer worktree.
require_speckit() {
  local path="$WORK/VRCheckout" repo="$TEAM/main/VRCheckout" ref files
  if [ -e "$path" ]; then
    ref=$(git -C "$path" rev-parse --abbrev-ref HEAD)
    files=$(git -C "$path" ls-files -- .specify)
  else
    ref=$(source_ref VRCheckout)
    [ -n "$ref" ] && files=$(git -C "$repo" ls-tree --name-only "$ref" -- .specify)
  fi
  [ -n "$files" ] && return
  echo "VRCheckout: ${ref:-$BASE} não tem o speckit (.specify/) versionado." >&2
  echo "Parta de uma base que tenha, ex.: ./work.sh $CMD $KEY${BRANCH:+ -n $BRANCH} -b speckit -l" >&2
  exit 1
}

# Debug de Go e Dart (e o compound API + Checkout) abrindo a raiz do bundle no VS Code.
# O settings.json aponta para o .fvm de speckit/VRCheckout: o bundle não tem .fvm próprio.
# $1 = pasta que recebe o .vscode (a da tarefa ou main/).
setup_debugger() {
  local vscode="$1/.vscode" f
  mkdir -p "$vscode"
  for f in launch.json settings.json; do
    [ -f "$vscode/$f" ] && continue
    if [ -f "$TEAM/.vscode/$f" ]; then
      cp "$TEAM/.vscode/$f" "$vscode/$f"
    else
      echo "Aviso: $TEAM/.vscode/$f não existe; .vscode/$f não criado." >&2
    fi
  done
}

# Libs nativas do ObjectBox, sem as quais o flutter test do VRCheckout não roda. Ficam em lib/
# (no .gitignore), uma cópia por worktree. Falha não impede a tarefa: só os testes ficam sem rodar.
install_objectbox() {
  local dir="$WORK/VRCheckout"
  [ -f "$dir/lib/objectbox.dll" ] && return
  echo "VRCheckout: instalando as libs do ObjectBox para os testes."
  (cd "$dir" && bash <(curl -fsSL https://raw.githubusercontent.com/objectbox/objectbox-dart/main/install.sh)) ||
    echo "Aviso: libs do ObjectBox não instaladas; rode o install.sh do README do VRCheckout." >&2
}

# Flutter do .fvmrc do VRCheckout, que também cria o .fvm/flutter_sdk usado pelo settings.json.
# Só nas branches com .fvmrc. Falha não impede a tarefa. $1 = pasta do VRCheckout.
install_fvm() {
  local dir="$1"
  [ -f "$dir/.fvmrc" ] || return 0
  if ! command -v fvm >/dev/null; then
    echo "Aviso: fvm não encontrado; rode fvm install em $dir." >&2
    return 0
  fi
  echo "VRCheckout: fvm install."
  (cd "$dir" && fvm install) ||
    echo "Aviso: fvm install falhou em $dir; rode à mão." >&2
}

# $1 = speckit: exige o fluxo speckit versionado na branch (especificar/implementar).
create_bundle() {
  local p branch expected
  # Offline não impede: a base pode existir localmente.
  for p in "${PROJECTS[@]}"; do
    git -C "$TEAM/main/$p" fetch origin --quiet || echo "$p: fetch falhou; seguindo com as refs locais." >&2
  done
  [ "$1" = speckit ] && require_speckit

  mkdir -p "$WORK"
  [ -f "$WORK/CLAUDE.md" ] || ln "$TEAM/shared/CLAUDE.md" "$WORK/CLAUDE.md" 2>/dev/null || true

  for p in "${PROJECTS[@]}"; do
    add_worktree "$p"
    branch=$(git -C "$WORK/$p" rev-parse --abbrev-ref HEAD)
    # Sem --branch, a worktree reaproveitada vale como está: pode ter sido criada com --branch.
    expected=$(branch_of "$p")
    [ "$branch" = "$expected" ] || echo "Aviso: $p está na branch $branch, não em $expected." >&2
  done
  install_fvm "$WORK/VRCheckout"
  install_objectbox
  setup_debugger "$WORK"
}

TABS=()
add_tab() {
  local project="$1" other="$2" title="$3" command="$4" root
  root=$(cygpath -w "$WORK")
  [ ${#TABS[@]} -gt 0 ] && TABS+=(\;)
  # --add-dir é variádico: sem o "--" ele engole o prompt como mais um diretório.
  TABS+=(new-tab -d "$root\\$project" --title "$KEY $title" \
    claude --add-dir "$root\\$other" -- "$command ${EXTRA[*]}")
}

open_tabs() {
  # Fora do Windows Terminal, "-w 0" joga as abas numa janela já aberta e escondida.
  local window=()
  [ -n "$WT_SESSION" ] && window=(-w 0)
  # Herdado de uma sessão do Claude, faz as abas abrirem como sub-sessão (sem transcript).
  unset CLAUDE_CODE_CHILD_SESSION
  # Sem a exclusão o Git Bash converte "/speckit-..." em caminho do Windows. Exclui só esse
  # prefixo: as abas herdam a variável, e MSYS_NO_PATHCONV quebraria todo "git -C /c/..." nelas.
  MSYS2_ARG_CONV_EXCL='/speckit' wt.exe "${window[@]}" "${TABS[@]}"
}

case "$CMD" in
  init)
    init_main
    echo "Pronto: $TEAM/main" ;;
  apagar)
    delete_local ;;
  criar)
    create_bundle
    echo "Pronto: $WORK" ;;
  especificar)
    create_bundle speckit
    add_tab VRCheckout VRPdvAPI specify "/speckit-specify $KEY"
    open_tabs ;;
  implementar)
    create_bundle speckit
    [ -f "$SPECS/tasks-api.md" ] && add_tab VRCheckout VRPdvAPI api "/speckit-implement $KEY --projeto api"
    [ -f "$SPECS/tasks-checkout.md" ] && add_tab VRCheckout VRPdvAPI checkout "/speckit-implement $KEY --projeto checkout"
    if [ ${#TABS[@]} -eq 0 ]; then
      echo "Nenhum tasks-api.md/tasks-checkout.md em $SPECS; rode o /speckit-tasks primeiro." >&2
      exit 1
    fi
    open_tabs ;;
esac
