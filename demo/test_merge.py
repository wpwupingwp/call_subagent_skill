"""merge_ranges 的验收测试。父代理在派发前冻结，子代理不得修改。"""
import sys
from ranges import merge_ranges

CASES = [
    ([], []),
    ([(1, 3)], [(1, 3)]),
    ([(1, 3), (2, 6)], [(1, 6)]),
    ([(1, 2), (3, 5)], [(1, 5)]),                 # 相邻也合并
    ([(5, 7), (1, 3), (2, 4)], [(1, 7)]),         # 乱序输入
    ([(1, 10), (2, 3)], [(1, 10)]),               # 被包含
    ([(1, 2), (5, 6)], [(1, 2), (5, 6)]),         # 不相邻不合并
    ([(0, 0)], [(0, 0)]),
    ([(-5, -3), (-2, 0)], [(-5, 0)]),
    ([(1, 4), (5, 8), (9, 9)], [(1, 9)]),         # 链式相邻
]

fails = 0
for inp, want in CASES:
    try:
        got = merge_ranges(inp)
    except Exception as exc:                       # noqa: BLE001
        print(f"FAIL {inp}: 抛出 {type(exc).__name__}: {exc}")
        fails += 1
        continue
    if got != want:
        print(f"FAIL {inp}: 期望 {want}，实得 {got}")
        fails += 1

# 返回值必须是 list，元素为 tuple
try:
    out = merge_ranges([(1, 2), (2, 3)])
    if not isinstance(out, list) or not all(isinstance(x, tuple) for x in out):
        print(f"FAIL 返回类型: {type(out).__name__} {out}")
        fails += 1
except Exception as exc:                           # noqa: BLE001
    print(f"FAIL 类型测试抛出 {type(exc).__name__}: {exc}")
    fails += 1

for bad in [(3, 1), [(1, 5), (7, 6)]]:
    try:
        merge_ranges(bad)
    except ValueError:
        pass
    except Exception as exc:                       # noqa: BLE001
        print(f"FAIL {bad}: 期望 ValueError，实得 {type(exc).__name__}")
        fails += 1
    else:
        print(f"FAIL {bad}: 期望 ValueError，却正常返回")
        fails += 1

total = len(CASES) + 3
print(f"{total - fails}/{total} 通过")
sys.exit(1 if fails else 0)
