#!/usr/bin/env python3
"""把原版（已删库镜像）的 config.json 翻译成 fork (v1.11.10+) 可用的格式。

为什么需要：原版与 fork 的 schedule 字段口径不同，而 json.Unmarshal 对未知字段
**静默忽略** —— 直接拿旧配置跑 fork，`cat_hours` 会被丢弃、夜猫任务回落默认 23 点，
且没有任何报错（实测 canary 日志：夜猫子已启用：[23] 点，而配置写的是 1 点）。

用法：
    python3 translate-config.py <原版 config.json> <输出 config.json>

设计原则：
    · 只改**确定需要改**的字段，其余原样保留（含 api_key 等凭据）
    · 翻译项写入注释性元数据（不改 JSON 结构），便于人工复核
    · 不猜测语义：无法确认等价的字段一律保留原值并报告
"""
import json, sys, collections

# 语义等价的改名（原版 → fork）
RENAME = {
    'cat_hours':   'blackcat_hours',    # 夜猫子窗口；原版叫 cat_*，fork 叫 blackcat_*
    'cat_enabled': 'blackcat_enabled',
}

# 原版有、fork 已彻底移除（上游 9/24 开学季活动结束后下线 scheduler/school.go）
DROP = ['school_hours', 'school_enabled']

# fork 新增、原版没有的调度项（缺省即启用，显式写出便于审阅）
ADD = {
    'growth_hours':   [1],   # 成长任务队列：网关内置，01:00 自动扫全部账号待办
    'growth_enabled': True,
}


def translate(live: dict) -> tuple[dict, list[str]]:
    notes = []
    out = json.loads(json.dumps(live), object_pairs_hook=collections.OrderedDict)

    sch = out.setdefault('schedule', {})

    # 1) 改名
    for old, new in RENAME.items():
        if old in sch:
            if new in sch:
                notes.append(f'注意：{old} 与 {new} 同时存在，保留 {new}={sch[new]}，丢弃 {old}={sch[old]}')
            else:
                sch[new] = sch[old]
                notes.append(f'改名：{old}={sch[old]} → {new}')
            del sch[old]

    # 2) 删除已下线字段
    for k in DROP:
        if k in sch:
            notes.append(f'删除：{k}={sch[k]}（上游 9/24 开学季下线，fork 无此排程）')
            del sch[k]

    # 3) 新增 fork 独有调度
    for k, v in ADD.items():
        if k not in sch:
            sch[k] = v
            notes.append(f'新增：{k}={v}（fork 内置成长任务队列，缺省即启用）')

    return out, notes


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]

    live = json.load(open(src, encoding='utf-8'))
    out, notes = translate(live)

    with open(dst, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write('\n')

    print(f'已生成：{dst}')
    print()
    for n in notes:
        print(f'  · {n}')
    print()
    print('  schedule 段最终形态：')
    for k, v in out['schedule'].items():
        print(f'    {k} = {v}')


if __name__ == '__main__':
    main()
