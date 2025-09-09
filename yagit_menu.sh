#!/usr/bin/env bash
# -------------------------------------------------------------------
# YAGIT - "야매 깃허브" 콘솔 메뉴 (owner 자동멤버 + 멤버=rwx)
# - 프로젝트 생성 / 멤버 추가 / 멤버 제거 / 정보 보기
# - root 불필요, setfacl/getfacl 필요(acl 패키지)
#   sudo apt update && sudo apt install -y acl
# 권한 정책:
#   - 프로젝트 멤버(= .yagit_members의 모든 사용자): rwX (기본/상속)
#   - 비멤버: rX
#   - 실제 파일 소유자는 현재 실행 사용자(변경 안 함)
#   - owner는 자동으로 멤버에 포함되어 rwx를 부여받음
# -------------------------------------------------------------------
set -euo pipefail

BASE="${YAGIT_BASE:-$HOME/yagit}"

die(){ echo "[오류] $*" >&2; read -rp "Enter를 누르면 메뉴로..."; return 1; }
info(){ echo "[정보] $*"; }
ok(){ echo "[완료] $*"; }

need_acl(){
  command -v setfacl >/dev/null || die "setfacl 없음. apt install -y acl 후 재시도"
  command -v getfacl >/dev/null || die "getfacl 없음. apt install -y acl 후 재시도"
}

norm_csv(){ local s="${1:-}"; s="${s//,/ }"; awk '{$1=$1;print}' <<<"$s"; }   # "a,b, c" -> "a b c"
unique_lines(){ awk '!seen[$0]++'; }  # 중복 제거

proj_dir(){ echo "${BASE}/$1"; }
members_file(){ echo "$(proj_dir "$1")/.yagit_members"; }
meta_file(){ echo "$(proj_dir "$1")/.yagit_meta"; }

ensure_proj_exists(){
  [[ -d "$(proj_dir "$1")" ]] || die "프로젝트 없음: $1 (경로: $(proj_dir "$1"))"
}

# 패치 전 프로젝트 자동 보정: meta의 owner가 멤버 파일에 없으면 추가
ensure_owner_in_members(){
  local name="$1"
  local mfile; mfile="$(members_file "$name")"
  local mdir;  mdir="$(proj_dir "$name")"
  [[ -f "$mfile" ]] || : >"$mfile"
  local owner; owner="$(awk -F= '/^owner=/{print $2}' "$(meta_file "$name")" 2>/dev/null || echo "")"
  if [[ -n "$owner" ]] && ! grep -qx "$owner" "$mfile"; then
    { cat "$mfile"; echo "$owner"; } | unique_lines > "$mfile"
    info "owner(${owner})를 멤버 목록에 자동 추가했습니다. (${mdir})"
  fi
}

apply_acl(){
  # 멤버 = rwx, 비멤버 = r-x, 상속 포함
  local name="$1" target; target="$(proj_dir "$name")"
  local mfile; mfile="$(members_file "$name")"
  [[ -f "$mfile" ]] || : >"$mfile"

  # 과거 프로젝트 보정
  ensure_owner_in_members "$name"

  # 기본 ACL 초기화 및 owner/others 기본권한
  setfacl -Rb "$target" || true
  # u::rwx = 실제 파일 소유자(=현재 실행 사용자)
  setfacl -Rm u::rwx,g::r-x,o::r-x,m::rwx "$target"
  setfacl -Rdm u::rwx,g::r-x,o::r-x,m::rwx "$target"

  # 각 멤버에게 rwx 부여(기존 + 상속)
  while read -r u; do
    [[ -n "${u:-}" ]] || continue
    setfacl -Rm "u:${u}:rwx" "$target"
    setfacl -Rdm "u:${u}:rwx" "$target"
  done < <(grep -v '^\s*$' "$mfile" | sed 's/#.*$//')

  ok "ACL 적용: $target  (멤버=rwx / 비멤버=r-x)"
}

init_project(){
  need_acl
  mkdir -p "$BASE"

  read -rp "프로젝트명: " name
  [[ -n "${name:-}" ]] || { die "프로젝트명이 비었습니다."; return; }

  local dir; dir="$(proj_dir "$name")"
  if [[ -e "$dir" ]]; then die "이미 존재: $dir"; return; fi

  # owner는 '.yagit_members'에 자동 포함되어 rwx를 가짐(논리적 소유자)
  read -rp "프로젝트 owner(기본=$USER): " owner
  owner="${owner:-$USER}"

  read -rp "초기 멤버(쉼표로 여러 명, 예: user1,user3) [빈값 허용]: " members

  mkdir -p "$dir"/{docs,src,bin,logs,tmp}
  chmod 2775 "$dir"   # 관례상 setgid 유지

  # 멤버 파일 생성: owner 자동 포함 + 초기 멤버 추가, 중복 제거
  {
    echo "$owner"
    if [[ -n "${members:-}" ]]; then
      for u in $(norm_csv "$members"); do echo "$u"; done
    fi
  } | unique_lines >"$(members_file "$name")"

  # 메타 기록
  cat >"$(meta_file "$name")" <<META
name=${name}
base=${BASE}
owner=${owner}
created_at=$(date -Is)
META

  apply_acl "$name"
  ln -sfn "$dir" "${BASE}/${name}-latest"
  ok "프로젝트 생성 완료: ${dir}"
}

add_members(){
  need_acl
  read -rp "프로젝트명: " name
  ensure_proj_exists "$name"
  read -rp "추가 멤버(쉼표, 예: user5,user6): " users
  [[ -n "${users:-}" ]] || { die "추가할 멤버가 없습니다."; return; }

  local mfile; mfile="$(members_file "$name")"; touch "$mfile"
  { cat "$mfile"; for u in $(norm_csv "$users"); do echo "$u"; done; } | unique_lines >"$mfile"
  ensure_owner_in_members "$name"
  ok "멤버 추가 반영"
  apply_acl "$name"
}

remove_members(){
  need_acl
  read -rp "프로젝트명: " name
  ensure_proj_exists "$name"
  read -rp "제거 멤버(쉼표, 예: user3): " users
  [[ -n "${users:-}" ]] || { die "제거할 멤버가 없습니다."; return; }

  local mfile; mfile="$(members_file "$name")"
  [[ -f "$mfile" ]] || : >"$mfile"

  # owner는 제거 불가(항상 멤버로 유지)
  local owner; owner="$(awk -F= '/^owner=/{print $2}' "$(meta_file "$name")" 2>/dev/null || echo "")"

  tmp="$(mktemp)"; cp "$mfile" "$tmp"
  for u in $(norm_csv "$users"); do
    if [[ -n "$owner" && "$u" == "$owner" ]]; then
      info "owner(${owner})는 제거할 수 없습니다. 건너뜀."
      continue
    fi
    if grep -qx "$u" "$tmp"; then
      grep -vx "$u" "$tmp" > "$tmp.new" || true
      mv "$tmp.new" "$tmp"; ok "제거: $u"
    else
      info "목록에 없음: $u"
    fi
  done
  mv "$tmp" "$mfile"
  ensure_owner_in_members "$name"
  apply_acl "$name"
}

show_info(){
  read -rp "프로젝트명: " name
  ensure_proj_exists "$name"
  ensure_owner_in_members "$name"

  local dir; dir="$(proj_dir "$name")"

  echo "== META =="; [[ -f "$(meta_file "$name")" ]] && cat "$(meta_file "$name")" || echo "(없음)"; echo
  echo "== MEMBERS (owner 포함) =="; [[ -f "$(members_file "$name")" ]] && nl -ba "$(members_file "$name")" || echo "(없음)"; echo
  echo "== STAT =="; stat "$dir"; echo

  # ACL 요약: user::, user:<id>, group::, mask::, other:: 만 출력 (default:* 등은 숨김)
  echo "== ACL (요약) =="
  getfacl -p "$dir" \
    | awk 'BEGIN{hide=0}
           /^# file/ || /^# owner/ || /^# group/ {next}
           /^default:/ {next}
           /^user::/ || /^user:[^:]+:/ || /^group::/ || /^mask::/ || /^other::/ {print}
          '
  echo
  read -rp "Enter를 누르면 메뉴로..."
}

main_menu(){
  while true; do
    clear
    cat <<MENU
========================================
   YAGIT - 프로젝트 콘솔
   BASE: ${BASE}
========================================
  1) 프로젝트 생성 
  2) 멤버 추가
  3) 멤버 제거 (owner 제거 불가)
  4) 프로젝트 정보 보기
  q) 종료
----------------------------------------
MENU
    read -rp "선택: " sel
    case "$sel" in
      1) init_project ;;
      2) add_members ;;
      3) remove_members ;;
      4) show_info ;;
      q|Q) echo "bye!"; exit 0 ;;
      *) echo "잘못된 선택입니다."; sleep 1 ;;
    esac
  done
}

main_menu
