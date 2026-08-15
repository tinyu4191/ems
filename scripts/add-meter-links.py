#!/usr/bin/env python3
"""
自動比對 canvas 面板裡的電表數值方塊跟站名標籤，加上 Show detail 連結。
以文字比對為主（比對 meters.description），"備用" 這種重複文字才用座標消歧。

Usage: python3 add-meter-links.py <input.json>
輸出：印出對照表（不寫入任何檔案），核對無誤後再跑 apply 版本。
"""
import json
import sys
import re
import difflib

# 從 Terry 提供的 meters 清單整理，只保留 electricity 電表
METERS = {
    "E-WH":    "原料倉",
    "E-EXH1":  "染整區抽風扇",
    "E-EXH2":  "電站1抽風扇",
    "E-ELV2":  "纖造電梯2",
    "E-ELV3":  "電梯3",
    "E-QAHB":  "品保+熱縮",
    "E-FIRE":  "消防系統",
    "E-WASTE": "廢水處理+食堂+軟水",
    "E-CRANE": "天車",
    "E-DYE3":  "連染",
    "E-DYE1":  "浸染+滴定",
    "E-DYE2":  "浸染區+化料+染料",
    "E-FIBAC": "織造冷氣",
    "E-PRO1":  "加工+電梯1",
    "E-FIB1":  "纖造",
    "E-BOIL":  "鍋爐",
    "E-PRINT": "網印",
    "E-OFF":   "辦公室",
    "E-RSV1":  "預留迴路1",
    "E-RSV2":  "預留迴路2",
    "E-RSV3":  "預留迴路3",
    "E-SEC":   "保衛室",
    "E-ATS1":  "ATS1市電進線",
    "E-ATS2":  "ATS2市電進線",
    "E-AIR":   "空壓機",
    "E-SOC2":  "電站2插座",
}

def center(p):
    x = (p.get('left', 0) + (100 - p.get('right', 0))) / 2
    y = (p.get('top', 0) + (100 - p.get('bottom', 0))) / 2
    return x, y

def dist(a, b):
    return ((a[0]-b[0])**2 + (a[1]-b[1])**2) ** 0.5

def main():
    infile = sys.argv[1]
    with open(infile, encoding='utf-8') as f:
        data = json.load(f)

    panel = data['panels'][0] if 'panels' in data else data
    elements = panel['options']['root']['elements']

    # 每個電表代碼在畫面上的數值方塊中心點（kW + PF 平均）
    meter_points = {}
    for el in elements:
        if el.get('type') == 'metric-value':
            field = el.get('config', {}).get('text', {}).get('field', '')
            m = re.match(r'^([A-Z0-9]+)_(kW|PF)$', field)
            if m:
                code = 'E-' + m.group(1)  # canvas 的 field 沒有 E- 前綴，補上跟 METERS 對齊
                meter_points.setdefault(code, []).append(center(el['placement']))

    # 候選標籤：type=text，fixed text 不是 "Power"/"PF"，目前沒有 link
    candidates = []
    for el in elements:
        if el.get('type') == 'text':
            txt = el.get('config', {}).get('text', {}).get('fixed', '')
            if txt and txt not in ('Power', 'PF') and not el.get('links'):
                candidates.append(el)

    # 先用 ATS1/ATS2 這種畫面上是 "ATS-1"/"ATS-2" 格式的特殊比對
    special = {"E-ATS1": "ATS-1", "E-ATS2": "ATS-2"}

    results = []
    unmatched_meters = []
    used_names = set()

    # 找出重複文字的標籤（例如 "備用"）分組，稍後用座標消歧
    text_groups = {}
    for el in candidates:
        txt = el['config']['text']['fixed']
        text_groups.setdefault(txt, []).append(el)

    for code, desc in METERS.items():
        if code not in meter_points:
            continue  # 這支電表在這張 dashboard 上沒有數值方塊
        target_text = special.get(code, desc)
        best, best_score = None, 0
        for el in candidates:
            if el['name'] in used_names:
                continue
            txt = el['config']['text']['fixed']
            score = difflib.SequenceMatcher(None, target_text, txt).ratio()
            if score > best_score:
                best, best_score = el, score

        if best and best_score >= 0.5:
            used_names.add(best['name'])
            results.append((code, best['name'], best['config']['text']['fixed'], round(best_score, 2), "文字比對"))
        else:
            unmatched_meters.append((code, desc))

    # "備用" 這類重複文字，用座標離哪個電表數值方塊最近來分配
    for txt, els in text_groups.items():
        if len(els) <= 1:
            continue
        remaining_meters = [c for c, d in unmatched_meters]
        for el in els:
            if el['name'] in used_names:
                continue
            ec = center(el['placement'])
            best_code, best_d = None, 999
            for code in remaining_meters:
                if code not in meter_points:
                    continue
                pts = meter_points[code]
                mc = (sum(p[0] for p in pts)/len(pts), sum(p[1] for p in pts)/len(pts))
                d = dist(ec, mc)
                if d < best_d:
                    best_code, best_d = code, d
            if best_code:
                used_names.add(el['name'])
                results.append((best_code, el['name'], txt, round(best_d, 1), "座標消歧(⚠️人工核對)"))
                remaining_meters.remove(best_code)
                unmatched_meters = [(c, d) for c, d in unmatched_meters if c != best_code]

    print(f"{'電表代碼':<10}{'元素名稱':<20}{'標籤文字':<20}{'分數/距離':<12}{'比對方式'}")
    print("-" * 80)
    for code, name, txt, score, method in sorted(results, key=lambda r: r[0]):
        print(f"{code:<10}{name:<20}{txt:<20}{score:<12}{method}")

    if unmatched_meters:
        print(f"\n⚠️ 沒找到對應標籤的電表（可能畫面上沒有名稱標籤，或本次貼的 JSON 不完整）：")
        for code, desc in unmatched_meters:
            print(f"  {code} ({desc})")

    mapping_file = infile.replace('.json', '_mapping.json')
    with open(mapping_file, 'w', encoding='utf-8') as f:
        json.dump({code: name for code, name, _, _, _ in results}, f, ensure_ascii=False, indent=2)
    print(f"\n對照表存到 {mapping_file}")
    print("請核對上面的表格，尤其標記 ⚠️ 的部分，確認無誤後跟我說，我再給你寫入連結的 script。")

if __name__ == '__main__':
    main()