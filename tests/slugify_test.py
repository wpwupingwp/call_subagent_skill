"""父代理冻结的验收测试：slugify(text) 的行为与边界。"""
import sys

from slugify import slugify


def check(expr, want, label):
    if expr != want:
        print(f"FAIL {label}: got {expr!r}, want {want!r}")
        sys.exit(1)


# 基本转换
check(slugify("Hello World"), "hello-world", "基本转换")
check(slugify("  A--B!! C  "), "a-b-c", "连续分隔符合并并去首尾")
# 空与纯符号
check(slugify(""), "", "空串")
check(slugify("!!!"), "", "纯符号")
# 非 ASCII 视为分隔符
check(slugify("Café au lait"), "caf-au-lait", "非 ASCII 字符")
# 下划线也是分隔符（只保留 ASCII 字母与数字）
check(slugify("a_b"), "a-b", "下划线")
# 长度上限 32，截断后不留尾随 '-'
check(slugify("a" * 40), "a" * 32, "超长截断")
check(slugify("a" * 31 + " b"), "a" * 31, "截断后去尾随分隔符")
check(len(slugify("word " * 20)) <= 32, True, "长度上限")

print("ok")
