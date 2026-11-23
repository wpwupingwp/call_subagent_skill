#!/usr/bin/env bash
# git-task-bus 自检。用法: bash tests/run.sh [--keep]
# 依赖: git >= 2.0、python3、（可选）zstd —— 没有 zstd 时跳过用量记录相关断言。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SK="$(cd "$HERE/../git-task-bus" && pwd)"
B="${TMPDIR:-/tmp}/gtb-test.$$"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$B"; }
trap cleanup EXIT

rm -rf "$B"; mkdir -p "$B/fix"
printf 'def add(a, b):\n    return a + b\n' > "$B/fix/calc.py"
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ✅ $1 (= $3)"; pass=$((pass+1));
        else echo "  ❌ $1 期望=$2 实际=$3"; fail=$((fail+1)); fi; }
sess() { export DSH_SESSION_ID="$1"; R="$B/$1/repo"; }
mkbrief() { printf '# 简报：%s\n## 范围\n白名单：只允许改动约定路径\n## 验收\n```bash\n%s\n```\n## 交付\n1. 提交（工作树干净）\n' "$1" "$2" > "$B/fix/brief-$1.md"; }
pf() { local t="" tests=""; local a=("$@"); for ((i=0;i<${#a[@]};i++)); do case "${a[i]}" in --task) t="${a[i+1]}";; --tests) tests="${a[i+1]}";; esac; done
       [ -n "$t" ] && mkbrief "$t" "$tests"; bash "$SK/scripts/preflight.sh" --root "$B" "$@" >/dev/null 2>&1; echo $?; }
po() { bash "$SK/scripts/postflight.sh" --root "$B" --task "$1" --stop "${2:-completed}" >"$B/$1.out" 2>&1; echo $?; }
b() { echo "--brief $B/fix/brief-$1.md"; }
cd "$B/fix"

echo "── A 通过 ──"
sess gA
chk "A/preflight" 0 "$(pf --task t-a --import calc.py --allow calc.py $(b t-a) --tests true)"
printf '\ndef mul(a,b):\n    return a*b\n' >> "$R/calc.py"; git -C "$R" commit -qam "add mul"
chk "A/postflight" 0 "$(po t-a)"
chk "A/历史四段" 4 "$(git -C "$R" rev-list --count HEAD)"
chk "A/任务产物入仓" "yes" "$([ -f "$R/tasks/t-a/MANIFEST.json" ] && echo yes || echo no)"

echo "── B 越界 ──"
sess gB
chk "B/preflight" 0 "$(pf --task t-b --import calc.py --allow calc.py $(b t-b) --tests true)"
echo n > "$R/notes.md"; git -C "$R" add -A; git -C "$R" commit -qm n
chk "B/应拒" 2 "$(po t-b)"
chk "B/已清除" "no" "$([ -e "$R/notes.md" ] && echo yes || echo no)"

echo "── C 测试失败 ──"
sess gC
chk "C/preflight" 0 "$(pf --task t-c --import calc.py --allow calc.py $(b t-c) --tests 'false')"
git -C "$R" commit -qam bad --allow-empty
chk "C/应 1" 1 "$(po t-c)"
chk "C/已回滚" "yes" "$(git -C "$R" log --format=%s -3 | grep -q 'discarded' && echo yes || echo no)"

echo "── D 历史改写 ──"
sess gD
chk "D/preflight" 0 "$(pf --task t-d --import calc.py --allow calc.py $(b t-d) --tests true)"
git -C "$R" checkout -q --orphan rw && git -C "$R" add -A >/dev/null && git -C "$R" commit -qm rw
git -C "$R" branch -f main rw && git -C "$R" switch -q main
chk "D/应拒" 2 "$(po t-d)"

echo "── E 脏树 ──"
sess gE
chk "E/preflight" 0 "$(pf --task t-e --import calc.py --allow calc.py $(b t-e) --tests true)"
echo junk > "$R/junk.txt"
chk "E/应 3" 3 "$(pf --task t-e --allow calc.py $(b t-e) --tests true)"
rm -f "$R/junk.txt"

echo "── F max-tokens ──"
sess gF
chk "F/preflight" 0 "$(pf --task t-f --import calc.py --allow calc.py $(b t-f) --tests true)"
chk "F/应 1" 1 "$(po t-f max-tokens)"

echo "── J 漏提交 ──"
sess gJ
chk "J/preflight" 0 "$(pf --task t-j --import calc.py --allow calc.py $(b t-j) --tests true)"
printf '\ndef z(): return 1\n' >> "$R/calc.py"
chk "J/应 2" 2 "$(po t-j)"
chk "J/已还原" "yes" "$(git -C "$R" log -1 --format=%s | grep -q 'discarded\|plan' && echo yes || echo no)"
chk "J/归档存在" "yes" "$([ -s "$R/tasks/t-j/deliveries/t-j.abandoned.patch" ] && echo yes || echo no)"

echo "── S 简报校验 ──"
sess gS
chk "S1/无简报" 3 "$(bash $SK/scripts/preflight.sh --task s-1 --allow a.py --tests true --root "$B" >/dev/null 2>&1; echo $?)"
mkdir -p "$R/tasks/s-2"; printf '# 简报\n白名单：只允许改动 a.py\n提交\n' > "$R/tasks/s-2/brief.md"
chk "S2/缺验收命令" 3 "$(bash $SK/scripts/preflight.sh --task s-2 --allow a.py --tests 'python3 x.py' --root "$B" >/dev/null 2>&1; echo $?)"

echo "── T 模型与最小模式 ──"
sess gT
chk "T/preflight" 0 "$(pf --task t-t --import calc.py --allow calc.py $(b t-t) --tests 'test -f calc.py' --model llama/LLaMA --save-model --quiet)"
chk "T/model 在仓库" "yes" "$([ -f "$R/model" ] && echo yes || echo no)"
TX=$(bash $SK/scripts/postflight.sh --root "$B" --task t-t --stop completed --quiet 2>&1); TRC=$?
chk "T/postflight" 0 "$TRC"
chk "T/manifest 记录模型" "llama/LLaMA" "$(python3 -c "import json;print(json.load(open('$R/tasks/t-t/MANIFEST.json'))['model'])" 2>/dev/null)"
chk "T/单分支" "main" "$(git -C "$R" branch --format='%(refname:short)')"
mkbrief t-u "test -f calc.py"
OUT=$(bash $SK/scripts/preflight.sh --task t-u --allow calc.py --brief "$B/fix/brief-t-u.md" --tests 'test -f calc.py' --root "$B" --quiet 2>/dev/null)
chk "T/复用模型" "MODEL=llama/LLaMA" "$(printf '%s\n' "$OUT" | grep '^MODEL=')"

echo "── U 共享基线 ──"
sess gA
mkbrief t-u2 "true"
chk "U/preflight" 0 "$(bash $SK/scripts/preflight.sh --task t-u2 --allow calc.py --brief "$B/fix/brief-t-u2.md" --tests true --root "$B" >/dev/null 2>&1; echo $?)"
chk "U/BASE=HEAD" "$(git -C "$R" rev-parse HEAD)" "$(sed -n 's/^BASE=//p' "$R/tasks/t-u2/dispatch.env")"

echo "── V 重复导入不覆盖 ──"
python3 -c "print('def add(a,b):\n    return a+b')" > "$B/fix/calc.py"
sess gV
chk "V/首次" 0 "$(pf --task t-v1 --import calc.py --allow calc.py $(b t-v1) --tests true)"
printf 'CHANGED\n' > "$B/fix/calc.py"
chk "V/再次" 0 "$(pf --task t-v2 --import calc.py --allow calc.py $(b t-v2) --tests true)"
chk "V/未覆盖" "yes" "$(grep -q 'def add' "$R/calc.py" && echo yes || echo no)"

echo "── AC envcheck ──"
mkdir -p "$B/ec/tests"; printf 'print("ok")\n' > "$B/ec/tests/t.py"
chk "AC/环境变量前缀" 0 "$(bash "$SK/scripts/envcheck.sh" --cwd "$B/ec" --tests 'PYTHONPATH=. python3 tests/t.py' >/dev/null 2>&1; echo $?)"
chk "AC/命令缺失" 3 "$(bash "$SK/scripts/envcheck.sh" --cwd "$B/ec" --tests 'no_such_cmd_xyz' >/dev/null 2>&1; echo $?)"

echo "── AD 工作区在 git 仓库内 ──"
mkdir -p "$B/gw/site/fix"
( cd "$B/gw" && git init -q && git symbolic-ref HEAD refs/heads/main && git config user.name t && git config user.email t@t && git commit -q --allow-empty -m init )
cd "$B/gw/site/fix"
printf 'x=1\n' > a.py
printf '# 简报\n白名单：只允许改动 a.py\n验收 test -f a.py\n提交\n' > brief.md
OUT=$(DSH_SESSION_ID=session-ad1 bash "$SK/scripts/preflight.sh" --task ad-1 --import a.py --allow a.py --brief brief.md --tests 'test -f a.py' --root "$B/gw/site" --quiet 2>&1)
chk "AD/本地忽略已追加" "yes" "$(grep -qxF '/site/session-*/' "$B/gw/.git/info/exclude" && echo yes || echo no)"
chk "AD/外层 status 干净" "" "$(git -C "$B/gw" status --porcelain --untracked-files=all -- site/session-ad1)"
chk "AD/不建 .gitignore" "no" "$([ -f "$B/gw/.gitignore" ] && echo yes || echo no)"
chk "AD/不建嵌套忽略" "no" "$([ -f "$B/gw/site/session-ad1/.gitignore" ] && echo yes || echo no)"

echo "── AD2 工作区已有 .gitignore ──"
mkdir -p "$B/gw2/site/fix"
( cd "$B/gw2" && git init -q && git symbolic-ref HEAD refs/heads/main && git config user.name t && git config user.email t@t
  printf 'keepme/\n*.log\n' > .gitignore && git add .gitignore && git commit -qm init )
cd "$B/gw2/site/fix"
printf 'x=1\n' > a.py
printf '# 简报\n白名单：只允许改动 a.py\n验收 test -f a.py\n提交\n' > brief.md
DSH_SESSION_ID=session-ed1 bash "$SK/scripts/preflight.sh" --task ed-1 --import a.py --allow a.py --brief brief.md --tests 'test -f a.py' --root "$B/gw2/site" >/dev/null 2>&1
chk "AD2/保留原规则" "yes" "$(grep -qxF 'keepme/' "$B/gw2/.gitignore" && echo yes || echo no)"
chk "AD2/未改 .gitignore" "no" "$(grep -q 'git-task-bus' "$B/gw2/.gitignore" && echo yes || echo no)"
chk "AD2/本地忽略已追加" "yes" "$(grep -qxF '/site/session-*/' "$B/gw2/.git/info/exclude" && echo yes || echo no)"
chk "AD2/会话目录不可见" "" "$(git -C "$B/gw2" status --porcelain --untracked-files=all -- site/session-ed1)"
chk "AD2/不重复追加" "1" "$(grep -cF '/site/session-*/' "$B/gw2/.git/info/exclude")"
cd "$B/fix"

echo "── AE 导入源变更 ──"
sess gAE
printf 'x=1\n' > "$B/fix/ae.py"
mkbrief t-ae1 true
chk "AE/preflight1" 0 "$(bash "$SK/scripts/preflight.sh" --root "$B" --task t-ae1 --import ae.py --allow ae.py --brief "$B/fix/brief-t-ae1.md" --tests true >/dev/null 2>&1; echo $?)"
printf 'x=2\n' > "$B/fix/ae.py"
mkbrief t-ae2 true
OUT_AE=$(bash "$SK/scripts/preflight.sh" --root "$B" --task t-ae2 --import ae.py --allow ae.py --brief "$B/fix/brief-t-ae2.md" --tests true 2>&1 >/dev/null)
chk "AE/源变更时警告" "yes" "$(printf '%s' "$OUT_AE" | grep -q '已变' && echo yes || echo no)"
chk "AE/索引已记录" "yes" "$([ -f "$R/tasks/imports.tsv" ] && echo yes || echo no)"
chk "AE/审查目录在仓库外" "yes" "$([ -d "$B/gAE/reviews" ] && echo yes || echo no)"
chk "AE/仓库内无 reviews" "no" "$([ -d "$R/tasks/t-ae1/reviews" ] && echo yes || echo no)"

echo "── AH 仓库锁 ──"
sess gAH
chk "AH/preflight" 0 "$(pf --task t-ah --import calc.py --allow calc.py $(b t-ah) --tests true)"
git -C "$R" commit -qam child --allow-empty
touch "$R/.git/index.lock"
OUT_AH=$(bash "$SK/scripts/postflight.sh" --root "$B" --task t-ah --quiet 2>&1); RC_AH=$?
chk "AH/锁存在时拒绝" 3 "$RC_AH"
chk "AH/提示删除锁" "yes" "$(printf '%s' "$OUT_AH" | grep -q 'index.lock' && echo yes || echo no)"
rm -f "$R/.git/index.lock"
chk "AH/解锁后可判定" 0 "$(bash "$SK/scripts/postflight.sh" --root "$B" --task t-ah --quiet >/dev/null 2>&1; echo $?)"

echo "── AI 合规审计 ──"
mkdir -p "$B/audit"
cat > "$B/audit/ok.jsonl" <<'EOF'
{"type":"assistant/message","data":{"turn":1,"message":{"content":[{"type":"tool-call","name":"read","arguments":"{\"file_path\":\"/p/code/a.py\"}"}]}}}
{"type":"assistant/message","data":{"turn":1,"message":{"content":[{"type":"tool-call","name":"subagent","arguments":"{}"}]}}}
EOF
cat > "$B/audit/bad.jsonl" <<'EOF'
{"type":"assistant/message","data":{"turn":1,"message":{"content":[{"type":"tool-call","name":"edit","arguments":"{\"file_path\":\"/p/code/a.py\"}"}]}}}
{"type":"assistant/message","data":{"turn":1,"message":{"content":[{"type":"tool-call","name":"subagent","arguments":"{}"}]}}}
EOF
cat > "$B/audit/none.jsonl" <<'EOF'
{"type":"assistant/message","data":{"turn":1,"message":{"content":[{"type":"tool-call","name":"read","arguments":"{}"}]}}}
EOF
chk "AI/合规会话" 0 "$(python3 "$HERE/audit_compliance.py" --session "$B/audit/ok.jsonl" --scope code >/dev/null 2>&1; echo $?)"
chk "AI/派发前改代码" 2 "$(python3 "$HERE/audit_compliance.py" --session "$B/audit/bad.jsonl" --scope code >/dev/null 2>&1; echo $?)"
chk "AI/无派发" 3 "$(python3 "$HERE/audit_compliance.py" --session "$B/audit/none.jsonl" --scope code >/dev/null 2>&1; echo $?)"

if [ "${SKIP_USAGE_TESTS:-0}" != 1 ] && command -v zstd >/dev/null 2>&1; then
echo "── AF 子会话结束原因校验 ──"
FH3="$B/fh3"
mkfake() {  # mkfake <sid> <kind>
  local d="$FH3/sessions/p/$1"
  mkdir -p "$d"
  { printf '{"type":"session","id":"%s","createdAt":%s,"parentSession":"%s","origin":"subagent"}\n' "$1" "$(date +%s)000" "$DSH_SESSION_ID"
    printf '{"type":"assistant/message","data":{"usage":{"inputTokens":1,"outputTokens":2,"cacheReadTokens":3}}}\n'
    printf '{"type":"turn/end","data":{"reason":{"kind":"%s"}}}\n' "$2"
  } | zstd -q -o "$d/session.v4.jsonl.zstd"
}
sess gAF
chk "AF/preflight" 0 "$(pf --task t-af --import calc.py --allow calc.py $(b t-af) --tests true)"
git -C "$R" commit -qam child --allow-empty
mkfake sid-stop aborted
OUT_AF=$(DSH_HOME="$FH3" bash "$SK/scripts/postflight.sh" --root "$B" --task t-af --child sid-stop --quiet 2>/dev/null); RC_AF=$?
chk "AF/日志 aborted 覆盖默认" 1 "$RC_AF"
chk "AF/输出含 stop=aborted" "yes" "$(printf '%s' "$OUT_AF" | grep -q 'stop=aborted' && echo yes || echo no)"
sess gAG
chk "AG/preflight" 0 "$(pf --task t-ag --import calc.py --allow calc.py $(b t-ag) --tests true)"
git -C "$R" commit -qam child --allow-empty
mkfake sid-ok completed
chk "AG/日志 completed 通过" 0 "$(DSH_HOME="$FH3" bash "$SK/scripts/postflight.sh" --root "$B" --task t-ag --child sid-ok --quiet >/dev/null 2>&1; echo $?)"
chk "AG/preflight2" 0 "$(pf --task t-ag2 --import calc.py --allow calc.py $(b t-ag2) --tests true)"
git -C "$R" commit -qam child2 --allow-empty
chk "AG/--stop 与日志不一致则失败" 1 "$(DSH_HOME="$FH3" bash "$SK/scripts/postflight.sh" --root "$B" --task t-ag2 --child sid-stop --stop completed --quiet >/dev/null 2>&1; echo $?)"

echo "── W 消耗记录 ──"
sess gW
chk "W/preflight" 0 "$(pf --task t-w --import calc.py --allow calc.py $(b t-w) --tests true)"
git -C "$R" commit -qam child --allow-empty
chk "W/postflight" 0 "$(bash $SK/scripts/postflight.sh --root "$B" --task t-w --stop completed --child child-123 --usage 'steps=7,in=100,out=200,cache=300' --quiet >/dev/null 2>&1; echo $?)"
chk "W/记录 childSession" "child-123" "$(python3 -c "import json;print(json.load(open('$R/tasks/t-w/MANIFEST.json'))['childSession'])" 2>/dev/null)"
chk "W/usage 有表头+一行" 2 "$(grep -c '' "$R/tasks/usage.tsv")"
chk "W/行内容" "t-w		pass	7	100	200	300" "$(tail -1 "$R/tasks/usage.tsv" | cut -f2-8)"
# 自动读取：伪造一个子代理会话日志
FH="$B/fakehome"; mkdir -p "$FH/sessions/p/sid-1"
printf '%s\n' '{"type":"assistant/message","data":{"usage":{"inputTokens":10,"outputTokens":20,"cacheReadTokens":30}}}' \
  '{"type":"assistant/message","data":{"usage":{"inputTokens":1,"outputTokens":2,"cacheReadTokens":3}}}' \
  | zstd -q -o "$FH/sessions/p/sid-1/session.v4.jsonl.zstd"
sess gX
chk "X/preflight" 0 "$(pf --task t-x --import calc.py --allow calc.py $(b t-x) --tests true)"
git -C "$R" commit -qam child --allow-empty
chk "X/postflight" 0 "$(DSH_HOME="$FH" bash $SK/scripts/postflight.sh --root "$B" --task t-x --stop completed --child sid-1 --quiet >/dev/null 2>&1; echo $?)"
chk "X/自动记录用量" "t-x		pass	2	11	22	33" "$(tail -1 "$R/tasks/usage.tsv" | cut -f2-8)"
sess gY
chk "Y/preflight" 0 "$(pf --task t-y --import calc.py --allow calc.py $(b t-y) --tests true)"
git -C "$R" commit -qam child --allow-empty
chk "Y/日志缺失仍通过" 0 "$(DSH_HOME="$B/nohome" bash $SK/scripts/postflight.sh --root "$B" --task t-y --stop completed --child nope --quiet >/dev/null 2>&1; echo $?)"
chk "Y/不写 usage" "no" "$([ -f "$R/tasks/usage.tsv" ] && echo yes || echo no)"
# --child auto：用伪造 home 验证按 parentSession 匹配
sess gZ
chk "Z/preflight" 0 "$(pf --task t-z --import calc.py --allow calc.py $(b t-z) --tests true)"
FH2="$B/fh2"; D2="$FH2/sessions/p/sid-auto"; mkdir -p "$D2"
NOW=$(date +%s)000
{ printf '{"type":"session","id":"sid-auto","createdAt":%s,"parentSession":"%s","origin":"subagent"}\n' "$NOW" "$DSH_SESSION_ID"
  printf '{"type":"assistant/message","data":{"usage":{"inputTokens":5,"outputTokens":6,"cacheReadTokens":7}}}\n'
} | zstd -q -o "$D2/session.v4.jsonl.zstd"
git -C "$R" commit -qam child --allow-empty
chk "Z/auto 应通过" 0 "$(DSH_HOME="$FH2" bash $SK/scripts/postflight.sh --root "$B" --task t-z --stop completed --child auto --quiet >/dev/null 2>&1; echo $?)"
chk "Z/匹配到 sid-auto" "sid-auto" "$(python3 -c "import json;print(json.load(open('$R/tasks/t-z/MANIFEST.json'))['childSession'])" 2>/dev/null)"
chk "Z/用量已记录" "t-z		pass	1	5	6	7" "$(tail -1 "$R/tasks/usage.tsv" | cut -f2-8)"
# AA：不传 --stop 默认 completed
sess gAA
chk "AA/preflight" 0 "$(pf --task t-aa --import calc.py --allow calc.py $(b t-aa) --tests true)"
git -C "$R" commit -qam child --allow-empty
chk "AA/默认 stop 通过" 0 "$(bash $SK/scripts/postflight.sh --root "$B" --task t-aa --quiet >/dev/null 2>&1; echo $?)"
chk "AA/重跑被拒" 3 "$(bash $SK/scripts/postflight.sh --root "$B" --task t-aa --quiet >/dev/null 2>&1; echo $?)"
chk "AA/归档未被覆盖" "t-aa.patch" "$(ls "$R/tasks/t-aa/deliveries/")"
# AB：越界 → reject，MANIFEST 指向 abandoned patch
sess gAB
chk "AB/preflight" 0 "$(pf --task t-ab --import calc.py --allow calc.py $(b t-ab) --tests true)"
printf 'oob\n' > "$R/oob.txt"; git -C "$R" add -A; git -C "$R" commit -qm oob
chk "AB/越界拒绝" 2 "$(bash $SK/scripts/postflight.sh --root "$B" --task t-ab --quiet >/dev/null 2>&1; echo $?)"
chk "AB/MANIFEST 指向 abandoned" "t-ab.abandoned.patch" "$(python3 -c "import json,os;print(os.path.basename(json.load(open('$R/tasks/t-ab/MANIFEST.json'))['patch']['file']))" 2>/dev/null)"
chk "W/无 usage 时不建文件" "no" "$([ -f "$R/tasks/usage.tsv.bak" ] && echo yes || echo no)"

else
  echo "  (跳过消耗记录相关断言：未安装 zstd，或 SKIP_USAGE_TESTS=1)"
fi

echo
echo "结果: $pass 通过 / $fail 失败"
exit $((fail>0))
