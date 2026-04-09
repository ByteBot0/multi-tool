#!/usr/bin/env bash
set -euo pipefail

# Meta-driven multi-tool launcher
# - Tools: *.sh in current directory (excluding this script)
# - Optional meta: <tool>.meta.json (e.g., ping-tool.meta.json)
# - UI supports option types: bool, string, int, enum
#
# Meta schema example:
# {
#   "title": "Ping Tool",
#   "options": [
#     {"key":"target","label":"Target domain or IP","type":"string","default":"google.com","flags":["-d"]},
#     {"key":"interval","label":"Ping interval (seconds)","type":"int","default":1,"flags":["-i"]},
#     {"key":"color","label":"Enable colored graph","type":"bool","default":false,"flags":["--color"]},
#     {"key":"mode","label":"Mode","type":"enum","default":"fast","choices":["fast","normal","slow"],"flags":["--mode"]}
#   ]
# }

SCRIPT_NAME="$(basename "$0")"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
  echo "Error: tmux not found."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found (needed to parse .meta.json)."
  exit 1
fi

# --- Discover tools ---
mapfile -t APPS_RAW < <(find "$DIR" -maxdepth 1 -type f -name "*.sh" -printf "%f\n" | sort)
APPS=()
for a in "${APPS_RAW[@]}"; do
  [[ -n "$a" && "$a" != "$SCRIPT_NAME" ]] && APPS+=("$a")
done

if (( ${#APPS[@]} == 0 )); then
  echo "No .sh apps found in: $DIR"
  exit 1
fi

# --- State ---
CUR=0
START_LABEL="Start ▶"
TOTAL=$(( ${#APPS[@]} + 1 ))

declare -a SEL
declare -a ARGS
for ((i=0;i<${#APPS[@]};i++)); do
  SEL[$i]=0
  ARGS[$i]=""
done

# --- Terminal cleanup ---
cleanup() {
  tput cnorm 2>/dev/null || true
  stty echo 2>/dev/null || true
}
trap cleanup EXIT

# --- UI input ---
read_key() {
  local key
  IFS= read -rsn1 key || return
  if [[ $key == $'\e' ]]; then
    read -rsn2 -t 0.01 key || return
    if [[ $key == "[A" ]]; then echo "UP"; return; fi
    if [[ $key == "[B" ]]; then echo "DOWN"; return; fi
    if [[ $key == "[C" ]]; then echo "RIGHT"; return; fi
    if [[ $key == "[D" ]]; then echo "LEFT"; return; fi
  fi
  if [[ $key == "" ]]; then echo "ENTER"; return; fi
  if [[ $key == " " ]]; then echo "SPACE"; return; fi
  if [[ $key == "q" ]]; then echo "QUIT"; return; fi
}

sanitize_session_name() {
  echo "${1%.sh}" | tr -c '[:alnum:]' '_'
}

# --- Main menu drawing ---
draw_menu() {
  tput clear
  echo "Multi-tool launcher"
  echo "Arrows: Move | Enter: Toggle/Options/Start | 'q': Quit"
  echo "--------------------------------------------------"
  for ((i=0;i<${#APPS[@]};i++)); do
    local mark="[ ]"
    [[ ${SEL[$i]} -eq 1 ]] && mark="[X]"

    local arg_preview=""
    if [[ -n "${ARGS[$i]}" ]]; then
      arg_preview="  (args: ${ARGS[$i]})"
      if (( ${#arg_preview} > 70 )); then
        arg_preview="${arg_preview:0:67}..."
      fi
    fi

    if [[ $i -eq $CUR ]]; then
      printf "> %s %s%s\n" "$mark" "${APPS[$i]}" "$arg_preview"
    else
      printf "  %s %s%s\n" "$mark" "${APPS[$i]}" "$arg_preview"
    fi
  done

  local start_idx=$((TOTAL-1))
  if [[ $CUR -eq $start_idx ]]; then
    printf "> %s\n" "$START_LABEL"
  else
    printf "  %s\n" "$START_LABEL"
  fi
}

# --- JSON helpers (python3) ---
# Prints tab-separated rows:
# idx  key  type  label  default_json  flags_json  choices_json
meta_dump_tsv() {
  local meta="$1"
  python3 - "$meta" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

opts = data.get("options", [])
for i, o in enumerate(opts):
    key = o.get("key","")
    typ = o.get("type","string")
    label = o.get("label", key)
    default = o.get("default", None)
    flags = o.get("flags", [])
    choices = o.get("choices", [])
    # Use json.dumps for safe transport; tabs separate columns
    print(i, key, typ, label,
          json.dumps(default, ensure_ascii=False),
          json.dumps(flags, ensure_ascii=False),
          json.dumps(choices, ensure_ascii=False),
          sep="\t")
PY
}

meta_title() {
  local meta="$1"
  python3 - "$meta" <<'PY'
import json, sys
path = sys.argv[1]
with open(path,'r',encoding='utf-8') as f:
    data = json.load(f)
print(data.get("title","Options"))
PY
}

# Parse json list (flags/choices) into newline list
json_list_to_lines() {
  python3 - "$1" <<'PY'
import json, sys
arr = json.loads(sys.argv[1])
for x in arr:
    print(x)
PY
}

# Parse default json into a printable scalar (no quotes for strings)
json_scalar_to_str() {
  python3 - "$1" <<'PY'
import json, sys
v = json.loads(sys.argv[1])
if v is None:
    print("")
elif isinstance(v, bool):
    print("true" if v else "false")
else:
    print(str(v))
PY
}

# --- Generic options UI (driven by meta) ---
# Stores built args into ARGS[idx]
configure_from_meta() {
  local tool_idx="$1"
  local tool="${APPS[$tool_idx]}"
  local meta="${DIR}/${tool%.sh}.meta.json"

  if [[ ! -f "$meta" ]]; then
    # no meta: fallback to manual entry (optional)
    stty echo; tput cnorm
    echo
    echo "Args for: $tool (no meta file found)"
    printf "Args [%s]: " "${ARGS[$tool_idx]}"
    local line=""
    IFS= read -r line || line=""
    [[ -n "$line" ]] && ARGS[$tool_idx]="$line"
    stty -echo; tput civis
    return 0
  fi

  local title
  title="$(meta_title "$meta")"

  # Load option rows
  mapfile -t ROWS < <(meta_dump_tsv "$meta" || true)
  if (( ${#ROWS[@]} == 0 )); then
    return 0
  fi

  local opt_cur=0
  local opt_total=$(( ${#ROWS[@]} + 1 ))  # + Done

  # Per-option current values
  # value as string for string/int/enum, "0/1" for bool
  declare -a O_KEY O_TYPE O_LABEL O_DEF_JSON O_FLAGS_JSON O_CHOICES_JSON O_VAL

  for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r idx key typ label def_json flags_json choices_json <<<"$r"
    O_KEY[$idx]="$key"
    O_TYPE[$idx]="$typ"
    O_LABEL[$idx]="$label"
    O_DEF_JSON[$idx]="$def_json"
    O_FLAGS_JSON[$idx]="$flags_json"
    O_CHOICES_JSON[$idx]="$choices_json"

    # Initialize from default
    local def_str
    def_str="$(json_scalar_to_str "$def_json")"
    if [[ "$typ" == "bool" ]]; then
      [[ "$def_str" == "true" ]] && O_VAL[$idx]="1" || O_VAL[$idx]="0"
    else
      O_VAL[$idx]="$def_str"
    fi
  done

  # Draw options screen
  while true; do
    tput clear
    echo "$title: $tool"
    echo "Arrows: move | Enter: edit/toggle | Space: toggle bool | Left/Right: cycle enum | q: back"
    echo "--------------------------------------------------"

    for ((i=0;i<${#ROWS[@]};i++)); do
      local prefix="  "
      [[ $opt_cur -eq $i ]] && prefix="> "

      local typ="${O_TYPE[$i]}"
      local label="${O_LABEL[$i]}"
      local val="${O_VAL[$i]}"

      if [[ "$typ" == "bool" ]]; then
        local box="[  ]"
        [[ "$val" == "1" ]] && box="[X]"
        printf "%s%s %s\n" "$prefix" "$box" "$label"
      elif [[ "$typ" == "enum" ]]; then
        local shown="$val"
        [[ -z "$shown" ]] && shown="<none>"
        printf "%s%s: %s\n" "$prefix" "$label" "$shown"
      else
        local shown="$val"
        local def_shown
        def_shown="$(json_scalar_to_str "${O_DEF_JSON[$i]}")"
        if [[ -z "$shown" ]]; then
          [[ -n "$def_shown" ]] && shown="<default: $def_shown>" || shown="<empty>"
        fi
        printf "%s%s\n" "$prefix" "$label"
        printf "    %s\n" "$shown"
      fi
    done

    echo
    if [[ $opt_cur -eq $((opt_total-1)) ]]; then
      echo "> Done ✔"
    else
      echo "  Done ✔"
    fi

    local action
    action=$(read_key) || continue
    case "$action" in
      UP)
        ((opt_cur==0)) && opt_cur=$((opt_total-1)) || opt_cur=$((opt_cur-1))
        ;;
      DOWN)
        ((opt_cur==opt_total-1)) && opt_cur=0 || opt_cur=$((opt_cur+1))
        ;;
      LEFT|RIGHT)
        # cycle enum if on enum row
        if (( opt_cur < ${#ROWS[@]} )); then
          if [[ "${O_TYPE[$opt_cur]}" == "enum" ]]; then
            local choices_json="${O_CHOICES_JSON[$opt_cur]}"
            mapfile -t CHOICES < <(json_list_to_lines "$choices_json")
            if (( ${#CHOICES[@]} > 0 )); then
              local current="${O_VAL[$opt_cur]}"
              local pos=-1
              for ((c=0;c<${#CHOICES[@]};c++)); do
                [[ "${CHOICES[$c]}" == "$current" ]] && pos=$c && break
              done
              if [[ "$action" == "RIGHT" ]]; then
                ((pos<0)) && pos=0 || pos=$(( (pos+1) % ${#CHOICES[@]} ))
              else
                ((pos<0)) && pos=0 || pos=$(( (pos-1+${#CHOICES[@]}) % ${#CHOICES[@]} ))
              fi
              O_VAL[$opt_cur]="${CHOICES[$pos]}"
            fi
          fi
        fi
        ;;
      SPACE)
        if (( opt_cur < ${#ROWS[@]} )); then
          if [[ "${O_TYPE[$opt_cur]}" == "bool" ]]; then
            [[ "${O_VAL[$opt_cur]}" == "1" ]] && O_VAL[$opt_cur]="0" || O_VAL[$opt_cur]="1"
          fi
        fi
        ;;
      ENTER)
        if [[ $opt_cur -eq $((opt_total-1)) ]]; then
          # Done -> build args and store
          local args_out=()
          for ((i=0;i<${#ROWS[@]};i++)); do
            local typ="${O_TYPE[$i]}"
            local val="${O_VAL[$i]}"
            local flags_json="${O_FLAGS_JSON[$i]}"

            mapfile -t FLAGS < <(json_list_to_lines "$flags_json")

            if [[ "$typ" == "bool" ]]; then
              if [[ "$val" == "1" ]]; then
                for f in "${FLAGS[@]}"; do args_out+=("$f"); done
              fi
            elif [[ "$typ" == "string" || "$typ" == "int" || "$typ" == "enum" ]]; then
              # If user left blank, omit and let tool default (simpler, matches your preference)
              if [[ -n "$val" ]]; then
                for f in "${FLAGS[@]}"; do args_out+=("$f"); done
                # If flags empty, still allow bare value? Typically no. We'll require flags for non-bool.
                if (( ${#FLAGS[@]} > 0 )); then
                  args_out+=("$val")
                fi
              fi
            fi
          done

          # Join args
          local joined=""
          for tok in "${args_out[@]}"; do
            joined+="$tok "
          done
          ARGS[$tool_idx]="${joined%" "}"
          return 0
        fi

        # Editing/toggling a row
        if (( opt_cur < ${#ROWS[@]} )); then
          local typ="${O_TYPE[$opt_cur]}"
          if [[ "$typ" == "bool" ]]; then
            [[ "${O_VAL[$opt_cur]}" == "1" ]] && O_VAL[$opt_cur]="0" || O_VAL[$opt_cur]="1"
          elif [[ "$typ" == "enum" ]]; then
            # Enter cycles enum too (like Right)
            local choices_json="${O_CHOICES_JSON[$opt_cur]}"
            mapfile -t CHOICES < <(json_list_to_lines "$choices_json")
            if (( ${#CHOICES[@]} > 0 )); then
              local current="${O_VAL[$opt_cur]}"
              local pos=-1
              for ((c=0;c<${#CHOICES[@]};c++)); do
                [[ "${CHOICES[$c]}" == "$current" ]] && pos=$c && break
              done
              ((pos<0)) && pos=0 || pos=$(( (pos+1) % ${#CHOICES[@]} ))
              O_VAL[$opt_cur]="${CHOICES[$pos]}"
            fi
          else
            stty echo; tput cnorm
            echo
            printf "%s (blank = default): " "${O_LABEL[$opt_cur]}"
            local in=""
            IFS= read -r in || in=""
            stty -echo; tput civis
            O_VAL[$opt_cur]="$in"
          fi
        fi
        ;;
      QUIT)
        return 0
        ;;
    esac
  done
}

toggle_select_and_maybe_configure() {
  local idx="$1"
  if [[ ${SEL[$idx]} -eq 1 ]]; then
    SEL[$idx]=0
    return 0
  fi
  SEL[$idx]=1
  configure_from_meta "$idx"
}

launch_selected_and_attach_first_alive() {
  local launched=()

  for ((i=0;i<${#APPS[@]};i++)); do
    if [[ ${SEL[$i]} -eq 1 ]]; then
      local file="${APPS[$i]}"
      local sess
      sess="$(sanitize_session_name "$file")"

      # Restart fresh each time Start is pressed
      if tmux has-session -t "$sess" 2>/dev/null; then
        tmux kill-session -t "$sess" 2>/dev/null || true
      fi

      # Run via bash -lc so args behave like normal CLI (quotes work if user includes them)
      local cmd="bash \"$DIR/$file\" ${ARGS[$i]}"
      tmux new-session -d -s "$sess" "bash -lc $(printf '%q' "$cmd")"
      launched+=("$sess")
    fi
  done

  if [[ ${#launched[@]} -eq 0 ]]; then
    tput cup $((TOTAL + 5)) 0
    echo "No scripts selected! Select at least one with Enter."
    sleep 1
    return 0
  fi

  sleep 0.1
  cleanup

  for s in "${launched[@]}"; do
    if tmux has-session -t "$s" 2>/dev/null; then
      exec tmux attach -t "$s"
    fi
  done

  echo "All selected tools exited immediately (no tmux sessions remain)."
  return 1
}

# --- Main loop ---
main() {
  tput civis
  stty -echo
  while true; do
    draw_menu
    local action
    action=$(read_key) || continue
    case "$action" in
      UP)
        [[ $CUR -eq 0 ]] && CUR=$((TOTAL - 1)) || CUR=$((CUR - 1))
        ;;
      DOWN)
        [[ $CUR -eq $((TOTAL - 1)) ]] && CUR=0 || CUR=$((CUR + 1))
        ;;
      ENTER)
        if [[ $CUR -eq $((TOTAL - 1)) ]]; then
          launch_selected_and_attach_first_alive
        else
          toggle_select_and_maybe_configure "$CUR"
        fi
        ;;
      QUIT)
        break
        ;;
    esac
  done
}

main
