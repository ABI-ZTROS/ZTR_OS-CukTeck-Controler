using System;
using System.Collections.Generic;
using CukTechController.Protocol;

namespace CukTechController.Models
{
    /// <summary>
    /// 端口状态模型
    /// </summary>
    public class PortState
    {
        /// <summary>端口 PIID (1-4)</summary>
        public int Piid { get; set; }

        /// <summary>端口索引 (0-3，兼容旧代码)</summary>
        public int PortIndex { get => Piid - 1; }

        /// <summary>输出电压 (V)</summary>
        public double Voltage { get; set; }

        /// <summary>输出电流 (A)</summary>
        public double Current { get; set; }

        /// <summary>输出功率 (W)</summary>
        public double Power { get; set; }

        /// <summary>是否正在充电 (与 Active 同义)</summary>
        public bool IsCharging { get => Active; set => Active = value; }

        /// <summary>是否活跃（有设备接入）</summary>
        public bool Active { get; set; }

        /// <summary>当前协议名</summary>
        public string Protocol { get; set; } = string.Empty;

        public PortState CopyWith(
            double? voltage = null,
            double? current = null,
            double? power = null,
            string? protocol = null,
            bool? active = null)
        {
            return new PortState
            {
                Piid = Piid,
                Voltage = voltage ?? Voltage,
                Current = current ?? Current,
                Power = power ?? Power,
                Protocol = protocol ?? Protocol,
                Active = active ?? Active,
            };
        }

        public override string ToString() =>
            $"PortState({Piid}: {Voltage:F1}V {Current:F1}A {Power:F1}W {(Active ? "ON" : "OFF")} {Protocol})";
    }

    /// <summary>
    /// 充电器整体状态
    /// </summary>
    public class ChargerState
    {
        /// <summary>输入电压 (V)</summary>
        public double InputVoltage { get; set; }

        /// <summary>输入电流 (A)</summary>
        public double InputCurrent { get; set; }

        /// <summary>输入功率 (W)</summary>
        public double InputPower { get; set; }

        /// <summary>温度 (°C)</summary>
        public int Temperature { get; set; }

        /// <summary>端口数量</summary>
        public int PortCount { get; set; } = 4;

        /// <summary>各端口状态</summary>
        public List<PortState> Ports { get; set; } = new List<PortState>();

        /// <summary>是否已连接</summary>
        public bool IsConnected { get; set; }
    }

    /// <summary>
    /// 设备信息
    /// </summary>
    public class DeviceInfo
    {
        /// <summary>型号</summary>
        public string Model { get; set; } = string.Empty;

        /// <summary>序列号</summary>
        public string SerialNumber { get; set; } = string.Empty;

        /// <summary>固件版本</summary>
        public string FirmwareVersion { get; set; } = string.Empty;

        /// <summary>产品 ID</summary>
        public int ProductId { get; set; } = Protocol.ProtocolConstants.ProductId;

        /// <summary>硬件版本</summary>
        public string HardwareVersion { get; set; } = string.Empty;
    }

    /// <summary>
    /// Token 配置
    /// </summary>
    public class TokenConfig
    {
        /// <summary>米家 Token</summary>
        public string Token { get; set; } = string.Empty;

        /// <summary>加密 Key</summary>
        public string Key { get; set; } = string.Empty;

        /// <summary>用户 ID</summary>
        public string UserId { get; set; } = string.Empty;

        /// <summary>设备 ID</summary>
        public string Did { get; set; } = string.Empty;

        /// <summary>Token 是否有效</summary>
        public bool IsValid =>
            !string.IsNullOrEmpty(Token) &&
            !string.IsNullOrEmpty(Key) &&
            !string.IsNullOrEmpty(UserId) &&
            !string.IsNullOrEmpty(Did);
    }
}
/// <summary>
/// 米家云凭证 —— 跨平台 JSON 导出/导入数据类
/// 与 Android CloudCredentials 格式一致
/// </summary>
public class CloudCredentials
{
    public string UserId { get; set; } = "";
    public string Ssecurity { get; set; } = "";
    public string ServiceToken { get; set; } = "";
    public string Did { get; set; } = "";
    public string BeaconKey { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public string DeviceModel { get; set; } = "";

    public bool IsValid =>
        !string.IsNullOrEmpty(Ssecurity) &&
        !string.IsNullOrEmpty(ServiceToken) &&
        !string.IsNullOrEmpty(UserId);
}

/// <summary>
/// 跨平台导出包装类
/// JSON 格式与 Android SecureTokenStore 导出一致
/// </summary>
public class CloudExportBundle
{
    public int Version { get; set; } = 1;
    public string ExportedAt { get; set; } = "";
    public CloudCredentials XiaomiCloud { get; set; } = new();
}
