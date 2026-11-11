#!/usr/bin/env bash
# 오방도감 바깥 감시 한 바퀴 (11/6 · 운영 매뉴얼 갭 G09 · 등록부 T029)
# 넷리파이 밖(GitHub Actions 또는 아무 컴퓨터)에서 실서버를 한 번 훑는다. 같은 스크립트를 Actions 와 손 점검이 같이 쓴다.
#   사용: bash watch.sh            → 줄마다 OK / WARN / FAIL. 하나라도 FAIL 이면 끝 코드 1
# 환경변수(전부 선택. 값은 화면에 찍지 않는다)
#   BASE              점검할 주소 (기본 https://obangdogam.com)
#   OB_GATE_COOKIE    오픈 전 비밀번호 문 열쇠(ob_gate 쿠키의 64자 값). 있으면 화면을 문 안쪽까지 200 으로 확인. 없으면 문 상태도 정상으로 친다
#   OB_WATCH_STRICT   1 이면 오픈 뒤 기준: 화면은 200 만 정상(비밀번호 문이 다시 나오면 실패)
#   OUT_DIR           결과 파일을 둘 폴더(fail_names · summary.md · lines.txt). 기본 ./.ob-out
#   OB_BACKUP_REQUIRED 1 이면 백업 기록이 아예 없을 때도 실패(첫 백업이 성공한 뒤 켠다)
#   OB_DRILL          1 이면 일부러 실패 하나를 만든다(알림 길 시험용)
set -u
BASE=${BASE:-https://obangdogam.com}; BASE=${BASE%/}
OUT_DIR=${OUT_DIR:-./.ob-out}; mkdir -p "$OUT_DIR"
STRICT=${OB_WATCH_STRICT:-0}; COOKIE=${OB_GATE_COOKIE:-}
UA="ob-watch/1"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: > "$OUT_DIR/lines.txt"; FAILS=(); WARNS=()
line() { printf '%-5s %-14s %s\n' "$1" "$2" "$3" | tee -a "$OUT_DIR/lines.txt"; case $1 in FAIL) FAILS+=("$2");; WARN) WARNS+=("$2");; esac; }

# get <경로> [쿠키 쓰기 0|1] → 전역 CODE · SEC · BODY(파일) · LOC. 연결 실패는 CODE=000. 한 번 실패하면 5초 뒤 한 번 더(잠깐 끊김 걸러내기)
get() {
  local path=$1 use=${2:-0} try hdr=() meta
  [ "$use" = 1 ] && [ -n "$COOKIE" ] && hdr=(-H "cookie: ob_gate=$COOKIE")
  BODY=$TMP/body
  for try in 1 2; do
    meta=$(curl -sS -o "$BODY" -w '%{http_code} %{time_total} %{redirect_url}' --max-time 20 --connect-timeout 10 \
      -A "$UA" -H 'cache-control: no-cache' "${hdr[@]}" "$BASE$path" 2>"$TMP/err") || true
    CODE=${meta%% *}; meta=${meta#* }; SEC=${meta%% *}; LOC=${meta#* }; [ "$LOC" = "$SEC" ] && LOC=""
    [ -z "$CODE" ] && CODE=000
    case $CODE in 000|5??) [ $try = 1 ] && sleep 5 && continue;; esac
    break
  done
  SEC=$(printf '%.1f' "${SEC:-0}" 2>/dev/null || echo 0)
}
gate_page() { grep -q '/__gate' "$BODY" 2>/dev/null; }

# 화면 하나: 200 이면 정상. 오픈 전(STRICT≠1 · 쿠키 없음)에는 401 비밀번호 문 · 문으로 넘기기(30x)도 정상
page() {
  local name=$1 path=$2 use=0; [ -n "$COOKIE" ] && use=1
  get "$path" $use
  if [ "$CODE" = 200 ]; then
    if gate_page && [ "$STRICT" = 1 ]; then line FAIL "$name" "$CODE 비밀번호 문이 다시 나옴 ${SEC}s"; return; fi
    [ "$(wc -c < "$BODY")" -lt 800 ] && { line FAIL "$name" "$CODE 내용이 너무 짧음 ${SEC}s"; return; }
    line OK "$name" "$CODE ${SEC}s"
  elif [ "$STRICT" != 1 ] && [ -z "$COOKIE" ] && { { [ "$CODE" = 401 ] && gate_page; } || { [[ $CODE == 30? ]] && [[ $LOC == *__gate* ]]; }; }; then
    line OK "$name" "$CODE 오픈 전 문 ${SEC}s"
  elif [ -n "$COOKIE" ] && [ "$CODE" = 401 ] && gate_page; then
    line FAIL "$name" "401 열쇠가 안 맞음(OB_GATE_COOKIE 확인)"
  else
    line FAIL "$name" "$CODE ${SEC}s"
  fi
  slow "$name"
}
slow() { awk "BEGIN{exit !($SEC > 8)}" && line WARN "$1" "느림 ${SEC}s"; return 0; }

# 1) 홈 · 문 밖에 열린 정적 화면(처리방침) · 사이트맵 — 넷리파이 정적 배포가 살아 있는지
page home /
get /policy;      { [ "$CODE" = 200 ] && ! gate_page && [ "$(wc -c < "$BODY")" -gt 2000 ]; } && line OK policy "$CODE ${SEC}s" || line FAIL policy "$CODE ${SEC}s"
get /sitemap.xml; { [ "$CODE" = 200 ] && grep -q '<urlset' "$BODY"; } && line OK sitemap "$CODE ${SEC}s" || line FAIL sitemap "$CODE ${SEC}s"

# 2) 넷리파이 안 5분 감시가 돌고 있는지(/api/status · 숫자 없이 신호등 · 마지막 확인 몇 분 전)
get /api/status
if [ "$CODE" = 200 ]; then
  read -r LV AGE STALE < <(python3 -c 'import json,sys
try: j=json.load(open(sys.argv[1]))
except Exception: j={}
a=j.get("ageMin"); ok=isinstance(a,(int,float)) and a<=15
print(j.get("level","?"), "none" if a is None else a, "0" if ok else "1")' "$BODY")
  if [ "$STALE" != 0 ]; then line FAIL watcher "안쪽 감시 마지막 확인 ${AGE}분 전(15분 넘음 · level=$LV)"
  else line OK watcher "level=$LV ${AGE}분 전"; fi
  [ "$LV" = red ] && line WARN status-red "안쪽 감시가 P1 사고를 열어 둠(어드민 /ops 확인)"
else line FAIL watcher "/api/status $CODE ${SEC}s"; fi

# 3) 가벼운 건강 확인(/api/health: 저장소 · Supabase · AI 멈춤 · 결제 준비). 아직 배포 전이면 404 → 알림만
get /api/health
case $CODE in
  200) line OK health "$(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(" ".join(f"{k}={j.get(k)}" for k in ("blobs","db","ai","pay")))' "$BODY" 2>/dev/null)"
       # 매일 Blobs 백업(04:13): 36시간 넘게 새 기록이 없거나 실패면 FAIL(backup). 기록이 아직 없으면 WARN(OB_BACKUP_REQUIRED=1 이면 FAIL)
       read -r BST BWARN BTXT < <(python3 -c 'import json,sys
b=(json.load(open(sys.argv[1])) or {}).get("backup") or {}
t="day={} {}h전 저장소 {}/{} 키 {}개 {}초".format(b.get("day"),b.get("ageH"),b.get("storesOk"),b.get("stores"),b.get("keys"),b.get("sec"))
print(b.get("state","unknown"), "1" if b.get("warn") else "0", t)' "$BODY" 2>/dev/null || echo "unknown 0 -")
       if [ "$BWARN" = 1 ]; then line FAIL backup "$BST $BTXT"
       elif [ "$BST" = ok ]; then line OK backup "$BTXT"
       elif [ "$BST" = none ] && [ "${OB_BACKUP_REQUIRED:-0}" = 1 ]; then line FAIL backup "백업 기록 없음"
       else line WARN backup "백업 기록 $BST(첫 백업 전이면 정상)"; fi;;
  404) line WARN health "/api/health 아직 없음(health.mjs 배포 전 · 백업 결과도 못 봄)";;
  *)   line FAIL health "$CODE $(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(" ".join(f"{k}={j.get(k)}" for k in ("blobs","db")))' "$BODY" 2>/dev/null)";;
esac

# 4) 결제 함수: GET 은 정상 거절(405 · 401 · 403)이 와야 산 것. 404 · 5xx · 끊김이면 함수가 없거나 죽음
for nm in pay-prepare:/api/pay/prepare pay-webhook:/api/pay-webhook; do
  n=${nm%%:*}; p=${nm#*:}
  get "$p"
  case $CODE in 405|401|403) line OK "$n" "$CODE 정상 거절 ${SEC}s";; *) line FAIL "$n" "$CODE ${SEC}s";; esac
done

# 5) 대표 메뉴 5곳
for m in myeongri sinnyeon gunghap lifetime red; do page "$m" "/$m"; done

[ "${OB_DRILL:-0}" = 1 ] && line FAIL drill "시험용 일부러 실패"

# 결과
printf '%s\n' "${FAILS[@]}" | sed '/^$/d' | sort -u > "$OUT_DIR/fail_names"
{ echo "### 오방도감 바깥 감시 $(TZ=Asia/Seoul date '+%m/%d %H:%M') KST"
  echo; echo "실패 ${#FAILS[@]} · 주의 ${#WARNS[@]} · 기준: $([ "$STRICT" = 1 ] && echo '오픈 뒤(200 만)' || echo '오픈 전(문 상태 정상)') · 열쇠 $([ -n "$COOKIE" ] && echo 씀 || echo 안 씀)"
  echo; echo '```'; cat "$OUT_DIR/lines.txt"; echo '```'; } > "$OUT_DIR/summary.md"
[ ${#FAILS[@]} -eq 0 ]
