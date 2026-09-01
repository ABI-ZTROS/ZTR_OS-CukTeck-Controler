using System;
using System.Collections.Generic;
using CukTechController.Models;

namespace CukTechController.Ble
{
    /// <summary>
    /// 端口广播流控制器
    /// 单例模式：PortDecoder → Publish(this, state) → MainViewModel 订阅 StateChanged。
    ///
    /// 简化（2026-09 重构）：去掉了 Watch()/PiidSubscription 嵌套类等完全没人调用的死 API。
    /// 当前全局只有一条真通路：Publish → StateChanged event → OnPortStateChanged。
    /// </summary>
    public class PortStreamController
    {
        public static readonly PortStreamController Instance = new();

        private readonly object _lock = new();

        /// <summary>状态变化广播：供 MainViewModel 订阅以刷新 UI</summary>
        public event EventHandler<PortState>? StateChanged;

        /// <summary>
        /// 发布端口状态。
        /// PortDecoder.Decode() 内部在解析完新的 PIID 1-4 状态后会调用。
        /// </summary>
        public void Publish(PortState state)
        {
            EventHandler<PortState>? handler;
            lock (_lock)
            {
                handler = StateChanged;
            }
            handler?.Invoke(this, state);
        }
    }
}
