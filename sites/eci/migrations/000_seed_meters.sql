-- =============================================
-- sites/eci/migrations/000_seed_meters.sql
-- ECI 錶頭主檔（26 電 + 4 水 + 3 蒸氣 = 33 支）。
-- 過渡用：A7（site.json + 啟動同步 meters）完成後，改由 site.json 取代這支檔案。
-- =============================================
INSERT INTO meters (meter_id, meter_type, gateway, zone, is_main, description) VALUES
    -- ── 電錶 ──────────────────────────────────────────────
    ('E-WH',    'electricity', 'OTPanel_01.1', '倉庫',       FALSE, '原料倉'),
    ('E-EXH1',  'electricity', 'OTPanel_01.1', '抽風扇系統', FALSE, '染整區抽風扇'),
    ('E-EXH2',  'electricity', 'OTPanel_01.1', '抽風扇系統', FALSE, '電站1抽風扇'),
    ('E-ELV2',  'electricity', 'OTPanel_01.1', '電梯',       FALSE, '纖造電梯2'),
    ('E-ELV3',  'electricity', 'OTPanel_02.1', '電梯',       FALSE, '電梯3'),
    ('E-QAHB',  'electricity', 'OTPanel_02.1', '品保',       FALSE, '品保+熱縮'),
    ('E-FIRE',  'electricity', 'OTPanel_02.1', '消防系統',   FALSE, '消防系統'),
    ('E-WASTE', 'electricity', 'OTPanel_02.1', '廢水',       FALSE, '廢水處理+食堂+軟水'),
    ('E-CRANE', 'electricity', 'OTPanel_01.1', '浸染',       FALSE, '天車'),
    ('E-DYE3',  'electricity', 'OTPanel_01.2', '連染',       FALSE, '連染'),
    ('E-DYE1',  'electricity', 'OTPanel_02.2', '浸染',       FALSE, '浸染區+化料+染料'),
    ('E-DYE2',  'electricity', 'OTPanel_02.2', '浸染',       FALSE, '浸染+滴定'),
    ('E-FIBAC', 'electricity', 'OTPanel_01.1', '冷氣',       FALSE, '織造冷氣'),
    ('E-PRO1',  'electricity', 'OTPanel_01.2', '加工',       FALSE, '加工+電梯1'),
    ('E-FIB1',  'electricity', 'OTPanel_01.2', '織造',       FALSE, '纖造'),
    ('E-BOIL',  'electricity', 'OTPanel_02.2', '鍋爐',       FALSE, '鍋爐'),
    ('E-PRINT', 'electricity', 'OTPanel_01.1', '網印',       FALSE, '網印'),
    ('E-OFF',   'electricity', 'OTPanel_01.1', '其他',       FALSE, '辦公室'),
    ('E-RSV1',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '預留迴路1'),
    ('E-RSV2',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '預留迴路2'),
    ('E-RSV3',  'electricity', 'OTPanel_02.2', '其他',       FALSE, '預留迴路3'),
    ('E-SEC',   'electricity', 'OTPanel_01.1', '其他',       FALSE, '保衛室'),
    ('E-ATS1',  'electricity', 'OTPanel_01.2', 'ATS1配電站', TRUE,  'ATS1市電進線'),
    ('E-ATS2',  'electricity', 'OTPanel_02.2', 'ATS2配電站', TRUE,  'ATS2市電進線'),
    ('E-AIR',   'electricity', 'OTPanel_01.2', '空壓機',     FALSE, '空壓機'),
    ('E-SOC2',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '電站2插座'),
    -- ── 水錶 ──────────────────────────────────────────────
    ('W-DYE1',  'water', 'OTPanel_03.2', '染紗區', FALSE, '染紗區入水口'),
    ('W-DYE2',  'water', 'OTPanel_03.2', '連染區', FALSE, '連染區入水口'),
    ('W-IN2',   'water', 'OTPanel_04',   '進水',   TRUE,  '管水系統進水口2'),
    ('W-IN1',   'water', 'OTPanel_05',   '進水',   TRUE,  '管水系統進水口1'),
    -- ── 蒸氣錶 ────────────────────────────────────────────
    ('S-DYE1',  'steam', 'OTPanel_03.1', '染紗區', FALSE, '染紗區蒸氣'),
    ('S-BOIL',  'steam', 'OTPanel_03.1', '鍋爐',   FALSE, '鍋爐蒸氣'),
    ('S-DYE2',  'steam', 'OTPanel_03.1', '連染區', FALSE, '連染區蒸氣')
ON CONFLICT (meter_id) DO NOTHING;
