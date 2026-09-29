#!/usr/bin/env python3
"""部署前核对：确认翻译后的 config 可用、且 api_key 与原配置一致。

为什么必须核对 api_key：manager 与所有客户端都依赖它；若被改成别的值，
网关会拒绝全部既有客户端，而**服务本身仍显示 healthy**（故障很难第一时间定位）。

用法（在群晖上，需 sudo 读生产配置）：
    sudo python3 /tmp/verify-config.py

退出码：0 = 通过；1 = api_key 不一致，**不要部署**
"""
import json, sys

LIVE = '/volume1/docker/workbuddy2api/config.json'
NEW = '/tmp/cfg.new'

live = json.load(open(LIVE))
new = json.load(open(NEW))

same = live.get('api_key') == new.get('api_key')
sch = new.get('schedule', {})

print(f'api_key 一致   : {same}')
print(f'blackcat_hours : {sch.get("blackcat_hours")}   (期望 [1])')
print(f'growth_hours   : {sch.get("growth_hours")}   (期望 [1])')
print(f'school_hours   : {sch.get("school_hours", "(已删除)")}')
print(f'cat_hours 残留 : {sch.get("cat_hours", "(已删除)")}')

ok = same and sch.get('blackcat_hours') == [1] and 'school_hours' not in sch
if not ok:
    print()
    print('✗ 核对未通过 —— 不要部署。检查 /tmp/cfg.new 是否翻译正确。')
sys.exit(0 if ok else 1)
