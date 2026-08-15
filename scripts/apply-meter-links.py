#!/usr/bin/env python3
"""
套用最終確認過的對照表：修正標籤文字為 meters.description 的標準寫法，並加上 Show detail 連結。
E-ATS1 已經手動加過連結，跳過不動。

Usage: python3 apply-meter-links.py <input.json> <output.json>
"""
import json
import sys

# 已完全人工核對確認過的對照表：電表代碼 -> (元素名稱, 正確標籤文字)
MAPPING = {
    "E-WH":    ("Element 40",  "原料倉"),
    "E-EXH1":  ("Element 60",  "染整區抽風扇"),
    "E-EXH2":  ("Element 75",  "電站1抽風扇"),
    "E-ELV2":  ("Element 69",  "纖造電梯2"),
    "E-ELV3":  ("Element 134", "電梯3"),
    "E-QAHB":  ("Element 95",  "品保+熱縮"),
    "E-FIRE":  ("Element 135", "消防系統"),
    "E-WASTE": ("Element 94",  "廢水處理+食堂+軟水"),
    "E-CRANE": ("Element 50",  "天車"),
    "E-DYE3":  ("Element 18",  "連染"),
    "E-DYE1":  ("Element 115", "浸染+滴定"),
    "E-DYE2":  ("Element 84",  "浸染區+化料+染料"),
    "E-FIBAC": ("Element 29",  "織造冷氣"),
    "E-PRO1":  ("Element 13",  "加工+電梯1"),
    "E-FIB1":  ("Element 39",  "纖造"),
    "E-BOIL":  ("Element 85",  "鍋爐"),
    "E-PRINT": ("Element 59",  "網印"),
    "E-OFF":   ("Element 49",  "辦公室"),
    "E-RSV1":  ("Element 125", "預留迴路1"),
    "E-RSV2":  ("Element 104", "預留迴路2"),
    "E-RSV3":  ("Element 105", "預留迴路3"),
    "E-SEC":   ("Element 70",  "保衛室"),
    "E-ATS2":  ("Element 8",   "ATS-2"),  # 標籤本身格式跟 database 不同（ATS-2 vs ATS2市電進線），維持畫面既有寫法不改字
    "E-AIR":   ("Element 30",  "空壓機"),
    "E-SOC2":  ("Element 124", "電站2插座"),
}

def make_link(meter_code):
    return {
        "oneClick": True,
        "targetBlank": True,
        "title": "Show detail",
        "url": f"/grafana/d/power-meter-detail/power-meter-detail?orgId=1&from=now-1h&to=now&timezone=browser&var-meters={meter_code}&var-fields=$__all&refresh=10s&kiosk"
    }

def main():
    infile, outfile = sys.argv[1], sys.argv[2]
    with open(infile, encoding='utf-8') as f:
        data = json.load(f)

    elements = data['panels'][0]['options']['root']['elements']
    by_name = {el['name']: el for el in elements}

    text_changes = []
    links_added = []
    skipped = []

    for code, (elname, correct_text) in MAPPING.items():
        el = by_name.get(elname)
        if not el:
            print(f"⚠️ 找不到元素 {elname}（對應 {code}），略過")
            continue

        if el.get('links'):
            skipped.append((code, elname))
            continue

        old_text = el.get('config', {}).get('text', {}).get('fixed', '')
        if old_text != correct_text:
            el['config']['text']['fixed'] = correct_text
            text_changes.append((code, elname, old_text, correct_text))

        el['links'] = [make_link(code)]
        links_added.append((code, elname, correct_text))

    with open(outfile, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print("=== 文字修正（畫面標籤 → meters.description 標準寫法）===")
    if text_changes:
        for code, elname, old, new in text_changes:
            print(f"  {code:<10} {elname:<15} 「{old}」 → 「{new}」")
    else:
        print("  （無需修正的文字）")

    print(f"\n=== 新增連結（共 {len(links_added)} 筆）===")
    for code, elname, txt in links_added:
        print(f"  {code:<10} {elname:<15} 「{txt}」")

    if skipped:
        print(f"\n=== 已有連結，跳過不動（{len(skipped)} 筆）===")
        for code, elname in skipped:
            print(f"  {code:<10} {elname:<15}")

    print(f"\n輸出檔案：{outfile}")
    print("下一步：確認上面的變更清單無誤後，用這個檔案匯入 Grafana（Dashboard settings > JSON Model，貼上內容並 Save），")
    print("或直接透過 sync-dashboard.sh 走版控流程。")

if __name__ == '__main__':
    main()