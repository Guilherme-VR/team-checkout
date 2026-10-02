#!/usr/bin/env bash
# Monta e desmonta a pasta <Checkout-Team>/INP-XXXX de uma tarefa: worktrees de VRPdvAPI e
# VRCheckout na branch INP-XXXX e debug do VS Code. Comandos em ajuda().
set -e

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
  ajuda        Mostra esta mensagem.

<tarefa>: nome exato da tarefa, que vira o nome da branch e da pasta (ex.: INP-2403).

Opções:
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
  ./work.sh implementar INP-2403            abre as abas do implement
  ./work.sh apagar INP-2403                 remove tudo da tarefa localmente
EOF
}

CMD=especificar
KEY=
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

# A primeira entrada é o próprio main/<repo>, que nunca é removido.
worktree_of() {
  git -C "$1" worktree list --porcelain |
    awk -v b="branch refs/heads/$KEY" '/^worktree /{n++; w=substr($0,10)} n>1 && $0==b{print w}'
}

# Confere os dois projetos antes de apagar qualquer coisa, para não deixar a tarefa pela metade.
delete_local() {
  local problems=() p repo wt n
  for p in "${PROJECTS[@]}"; do
    git -C "$TEAM/main/$p" worktree prune
  done
  for p in "${PROJECTS[@]}"; do
    repo="$TEAM/main/$p"
    has_ref "$repo" "refs/heads/$KEY" || continue
    if [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = "$KEY" ]; then
      echo "$p: main/$p está na branch $KEY; troque de branch antes." >&2
      exit 1
    fi
    wt=$(worktree_of "$repo")
    # A spec em specs/INP-XXXX não conta como pendência: vai embora junto com a worktree.
    if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain -- . ":(exclude)specs/$KEY")" ]; then
      problems+=("$p: alterações não commitadas em $wt")
    fi
    n=$(git -C "$repo" rev-list --count "refs/heads/$KEY" --not --remotes)
    if [ "$n" -gt 0 ]; then
      problems+=("$p: $n commit(s) só locais em $KEY")
    fi
  done
  if [ ${#problems[@]} -gt 0 ] && [ -z "$FORCE" ]; then
    printf '  - %s\n' "${problems[@]}" >&2
    echo "Nada apagado. Resolva, ou repita com --forcar para descartar." >&2
    exit 1
  fi

  for p in "${PROJECTS[@]}"; do
    repo="$TEAM/main/$p"
    if ! has_ref "$repo" "refs/heads/$KEY"; then
      echo "$p: sem branch local $KEY."
      continue
    fi
    wt=$(worktree_of "$repo")
    if [ -n "$wt" ]; then
      # .dart_tool e ephemeral/ passam de 260 caracteres; sem longpaths a remoção para no meio.
      # --force sempre: a checagem acima já barrou pendências, e a spec não commitada travaria o git.
      git -c core.longpaths=true -C "$repo" worktree remove --force "$wt"
      echo "$p: worktree $wt removida."
    fi
    git -C "$repo" branch -D "$KEY" >/dev/null
    echo "$p: branch local $KEY apagada."
  done

  # Bundles antigos têm junctions para shared/; só some a pasta quando sobrou apenas o CLAUDE.md (hardlink).
  if [ -d "$WORK" ]; then
    # Junction em bundle antigo: apagar os arquivos dentro dela apagaria os originais.
    if [ -d "$WORK/.vscode" ] && [ ! -L "$WORK/.vscode" ]; then
      rm -f "$WORK/.vscode/launch.json" "$WORK/.vscode/settings.json"
      rmdir "$WORK/.vscode" 2>/dev/null || true
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
}

# Branch da tarefa já existente (local ou no origin) é reaproveitada; a base só vale para branch nova.
# Sem --local, origin/<base> primeiro, para não partir de uma branch local desatualizada.
source_ref() {
  local repo="$TEAM/main/$1" first="origin/$BASE" second="$BASE"
  [ -n "$LOCAL" ] && { first="$BASE"; second="origin/$BASE"; }
  if has_ref "$repo" "refs/heads/$KEY"; then echo "$KEY"
  elif has_ref "$repo" "refs/remotes/origin/$KEY"; then echo "origin/$KEY"
  elif has_ref "$repo" "$first"; then echo "$first"
  elif has_ref "$repo" "$second"; then echo "$second"
  fi
}

add_worktree() {
  local repo="$TEAM/main/$1" path="$WORK/$1" ref
  if [ -e "$path" ]; then
    echo "$1: $path já existe; reaproveitando."
    return
  fi
  ref=$(source_ref "$1")
  case "$ref" in
    "") echo "$1: base $BASE não existe." >&2; exit 1 ;;
    "$KEY")
      echo "$1: usando a branch local $KEY."
      git -C "$repo" worktree add "$path" "$KEY" ;;
    "origin/$KEY")
      echo "$1: rastreando origin/$KEY."
      git -C "$repo" worktree add --track -b "$KEY" "$path" "origin/$KEY" ;;
    *)
      echo "$1: branch nova $KEY a partir de $ref."
      git -C "$repo" worktree add --no-track -b "$KEY" "$path" "$ref" ;;
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
  echo "Parta de uma base que tenha, ex.: ./work.sh $CMD $KEY -b speckit -l" >&2
  exit 1
}

# Debug de Go e Dart (e o compound API + Checkout) abrindo a raiz do bundle no VS Code.
# O settings.json aponta para o .fvm de speckit/VRCheckout: o bundle não tem .fvm próprio.
setup_debugger() {
  local vscode="$WORK/.vscode" f
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

# $1 = speckit: exige o fluxo speckit versionado na branch (especificar/implementar).
create_bundle() {
  local p branch
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
    [ "$branch" = "$KEY" ] || echo "Aviso: $p está na branch $branch, não em $KEY." >&2
  done
  setup_debugger
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
  # Sem MSYS_NO_PATHCONV o Git Bash converte "/speckit-..." em caminho do Windows.
  MSYS_NO_PATHCONV=1 wt.exe "${window[@]}" "${TABS[@]}"
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
