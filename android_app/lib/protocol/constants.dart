/// 酷态科 BLE 协议常量（Dart 移植）
///
/// 参考: kairui1108/cuktech-ble-ha/src/cuktech_ble/protocol.py
library cuktech.protocol.constants;

// ---- GATT Service UUID ----
const String uuidFe95 = '0000fe95-0000-1000-8000-00805f9b34fb';

// ---- GATT Characteristic UUIDs ----
const String charDeviceInfo = '0000001c-0000-1000-8000-00805f9b34fb';
const String charAuthCtrl   = '00000010-0000-1000-8000-00805f9b34fb';
const String charAuthData   = '00000019-0000-1000-8000-00805f9b34fb';
const String charCmdSend    = '0000001a-0000-1000-8000-00805f9b34fb';
const String charCmdRecv    = '0000001b-0000-1000-8000-00805f9b34fb';
const String charFwVersion  = '00000004-0000-1000-8000-00805f9b34fb';

// ---- GATT Handles ----
const int handleDeviceInfo = 0x001f;
const int handleAuthCtrl   = 0x000d;
const int handleAuthData   = 0x0010;
const int handleCmdSend    = 0x0019;
const int handleCmdRecv    = 0x001c;
const int handleFwVersion  = 0x0008;

// ---- MiOT ----
const int siidCharger = 2;
const int productId   = 0x660e;

// ---- PIID 名称映射 ----
const Map<int, String> piidNames = <int, String>{
  1: 'C1口数据', 2: 'C2口数据', 3: 'C3口数据', 4: 'A口数据',
  5: '场景模式', 6: '息屏时间', 7: '协议控制', 8: '倒计时设置',
  9: 'C1口倒计时', 10: 'C2口倒计时', 11: 'C3口倒计时', 12: 'A口倒计时',
  13: '语言', 14: '进入界面', 15: 'USB-A小电流', 16: '端口控制',
  17: '未知-17', 18: '未知-18', 19: '空闲息屏', 20: '屏幕方向锁',
};

// ---- PIID 显示映射 ----
const Map<int, Map<int, String>> piidDisplay = <int, Map<int, String>>{
  5:  <int, String>{1: 'AI模式', 2: '数码生态', 3: '单口模式', 4: '均衡模式'},
  6:  <int, String>{1: '5分钟', 2: '10分钟', 3: '30分钟', 4: '常亮', 5: '1分钟'},
  13: <int, String>{0: 'English', 1: '中文'},
  15: <int, String>{0: '关闭', 1: '开启'},
  19: <int, String>{0: '关闭', 1: '开启'},
  20: <int, String>{0: '关闭', 1: '开启'},
};

// ---- 端口位掩码 (PIID 16) ----
const Map<String, int> portBits = <String, int>{
  'c1': 0, 'c2': 1, 'c3': 2, 'a': 3,
};

// ---- 端口 → 倒计时 PIID 映射 ----
const Map<String, int> timerPorts = <String, int>{
  'c1': 9, 'c2': 10, 'c3': 11, 'a': 12,
};

// ---- 协议开关位 (PIID 21) ----
// c1Flags: bit0=PD, bit1=PPS, bit2=UFCS, bit3=reserved(1)
// c2Flags: 同上
// c3Flags: bit0=UFCS, bit1=SCP
// aFlags:  bit0=UFCS, bit1=SCP
const Map<String, Map<String, int>> protocolSwitchBits = <String, Map<String, int>>{
  'c1': <String, int>{'pd': 0, 'pps': 1, 'ufcs': 2, '_reserved': 3},
  'c2': <String, int>{'pd': 8, 'pps': 9, 'ufcs': 10, '_reserved': 11},
  'c3': <String, int>{'ufcs': 16, 'scp': 17},
  'a':  <String, int>{'ufcs': 24, 'scp': 25},
};

// ---- 协议名称 ----
const Map<int, String> protocolNames = <int, String>{
  0x01: 'PD', 0x03: 'PD', 0x04: 'PD', 0x05: 'PD', 0x06: 'PD',
  0x07: 'PD Fixed', 0x08: 'PD PPS', 0x0a: 'PD', 0x0b: 'PD',
  0x30: 'PD', 0x60: 'USB-A', 0x70: 'QC', 0x80: 'PD',
};

// ---- PD 固定电压 ----
const Set<double> pdFixedVoltages = <double>{5.0, 9.0, 12.0, 15.0, 20.0};

// ---- PDO 类型（按高字节） ----
const Map<int, String> pdoKindByHighByte = <int, String>{
  0x07: 'PD Fixed',
  0x08: 'PD PPS',
};

// ---- 可读 PIID ----
const List<int> readableSettingsPiids = <int>[
  5, 6, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 21,
];

// ---- 超时与重试 ----
const Duration bleTimeout = Duration(seconds: 5);
const int bleMaxRetries = 3;