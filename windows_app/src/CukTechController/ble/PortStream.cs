using System;
using System.Collections.Generic;
using CukTechController.Models;

namespace CukTechController.Ble
{
    /// <summary>
    /// 端口广播流控制器
    /// 按 PIID 订阅/发布端口状态
    /// </summary>
    public class PortStreamController
    {
        public static readonly PortStreamController Instance = new PortStreamController();

        private readonly Dictionary<int, List<EventHandler<PortState>>> _subscribers = new();
        private readonly object _lock = new();

        /// <summary>
        /// 订阅指定 PIID 的状态变化
        /// </summary>
        public event EventHandler<PortState>? StateChanged;

        /// <summary>
        /// 监听端口状态（按 PIID 过滤）
        /// </summary>
        public IDisposable Watch(int piid)
        {
            var subscription = new PiidSubscription(this, piid);
            return subscription;
        }

        /// <summary>
        /// 发布端口状态
        /// </summary>
        public void Publish(PortState state)
        {
            StateChanged?.Invoke(this, state);
        }

        /// <summary>
        /// 释放所有资源
        /// </summary>
        public void Dispose()
        {
            lock (_lock)
            {
                _subscribers.Clear();
            }
        }

        private class PiidSubscription : IDisposable
        {
            private readonly PortStreamController _owner;
            private readonly int _piid;
            private bool _disposed;

            public PiidSubscription(PortStreamController owner, int piid)
            {
                _owner = owner;
                _piid = piid;
                _owner.StateChanged += OnStateChanged;
            }

            private void OnStateChanged(object? sender, PortState e)
            {
                if (e.Piid == _piid && !_disposed)
                {
                    DataReceived?.Invoke(this, e);
                }
            }

            public event EventHandler<PortState>? DataReceived;

            public void Dispose()
            {
                if (_disposed) return;
                _disposed = true;
                _owner.StateChanged -= OnStateChanged;
            }
        }
    }
}