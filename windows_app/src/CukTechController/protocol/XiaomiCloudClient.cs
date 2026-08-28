using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace CukTechController.Protocol;

/// <summary>
/// 米家云 API 客户端
/// 移植自 xiaomi_cloud.py，支持 WebView 登录后的 API 调用
/// </summary>
public class XiaomiCloudClient
{
    private readonly HttpClient _httpClient;
    private readonly string _userAgent;
    private string _ssecurity = "";
    private string _serviceToken = "";
    private string _userId = "";
    private string _location = "";
    private bool _isLoggedIn;

    public bool IsLoggedIn => _isLoggedIn;
    public string UserId => _userId;

    // 事件：登录成功
    public event EventHandler<LoginSuccessEventArgs>? LoginSuccess;
    // 事件：登录失败
    public event EventHandler<LoginErrorEventArgs>? LoginError;

    public XiaomiCloudClient()
    {
        _httpClient = new HttpClient();
        _userAgent = GenerateAgent();
    }

    private static string GenerateAgent()
    {
        var random = new Random();
        var suffix1 = new char[11];
        for (int i = 0; i < 11; i++)
            suffix1[i] = (char)('A' + random.Next(26));
        var suffix2 = new char[6];
        for (int i = 0; i < 6; i++)
            suffix2[i] = (char)('A' + random.Next(26));
        return $"Android-7.1.1-1.0.0-ONEPLUS A3010-136-{new string(suffix1)} MIIO/{new string(suffix2)}";
    }

    /// <summary>
    /// 从 WebView 登录结果设置凭据
    /// </summary>
    public void SetCredentials(string serviceToken, string ssecurity, string userId = "", string location = "")
    {
        _serviceToken = serviceToken;
        _ssecurity = ssecurity;
        _userId = userId;
        _location = location;
        _isLoggedIn = true;
        
        // 触发登录成功事件
        LoginSuccess?.Invoke(this, new LoginSuccessEventArgs(serviceToken, ssecurity));
    }

    /// <summary>
    /// 获取 beaconKey (BLE Token)
    /// POST /v2/device/blt_get_beaconkey
    /// </summary>
    public async Task<string?> GetBeaconKeyAsync(string did, string server = "cn")
    {
        if (!_isLoggedIn)
            throw new InvalidOperationException("Not logged in");

        var url = GetServerUrl(server);
        var result = await ApiCallAsync($"{url}/v2/device/blt_get_beaconkey",
            new Dictionary<string, string>
            {
                ["data"] = JsonConvert.SerializeObject(new { did, pdid = 1 })
            });

        if (result != null && result.code == 0)
            return result.result?.beaconkey;
        return null;
    }

    /// <summary>
    /// 获取设备列表
    /// </summary>
    public async Task<List<CloudDeviceInfo>> GetDeviceListAsync(string server = "cn")
    {
        if (!_isLoggedIn)
            throw new InvalidOperationException("Not logged in");

        var url = GetServerUrl(server);
        var homes = await ApiCallAsync($"{url}/v2/homeroom/gethome",
            new Dictionary<string, string>
            {
                ["data"] = JsonConvert.SerializeObject(new { fg = true, fetch_share = true, fetch_share_dev = true, limit = 300, app_ver = 7 })
            });

        var devices = new List<CloudDeviceInfo>();
        if (homes?.code == 0)
        {
            foreach (var home in homes.result?.homelist ?? new List<HomeInfo>())
            {
                var homeData = await ApiCallAsync($"{url}/v2/home/home_device_list",
                    new Dictionary<string, string>
                    {
                        ["data"] = JsonConvert.SerializeObject(new
                        {
                            home_owner = home.uid,
                            home_id = home.id,
                            limit = 200,
                            get_split_device = true,
                            support_smart_home = true
                        })
                    });

                if (homeData?.code == 0)
                {
                    foreach (var dev in homeData.result?.device_info ?? new List<DeviceInfo>())
                    {
                        if (!string.IsNullOrEmpty(dev.token))
                        {
                            devices.Add(new CloudDeviceInfo
                            {
                                Did = dev.did,
                                Name = dev.name,
                                Model = dev.model,
                                Token = dev.token,
                                Mac = dev.mac
                            });
                        }
                    }
                }
            }
        }
        return devices;
    }

    private static string GetServerUrl(string server) => server switch
    {
        "cn" => "https://api.io.mi.com/app",
        "de" => "https://de.api.io.mi.com/app",
        "us" => "https://us.api.io.mi.com/app",
        "ru" => "https://ru.api.io.mi.com/app",
        "tw" => "https://tw.api.io.mi.com/app",
        "sg" => "https://sg.api.io.mi.com/app",
        "in" => "https://in.api.io.mi.com/app",
        _ => "https://api.io.mi.com/app"
    };

    private async Task<ApiResponse?> ApiCallAsync(string url, Dictionary<string, string> @params)
    {
        var millis = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var nonce = XiaomiCloudCrypto.GenerateNonce(millis);
        var signedNonce = XiaomiCloudCrypto.SignedNonce(_ssecurity, nonce);
        var encParams = XiaomiCloudCrypto.GenerateEncParams(url, "POST", signedNonce, nonce, @params, _ssecurity);

        var headers = new Dictionary<string, string>
        {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = _userAgent,
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["x-xiaomi-protocal-flag-cli"] = "PROTOCAL-HTTP2",
            ["MIOT-ENCRYPT-ALGORITHM"] = "ENCRYPT-RC4"
        };

        var cookies = new Dictionary<string, string>
        {
            ["userId"] = _userId,
            ["yetAnotherServiceToken"] = _serviceToken,
            ["serviceToken"] = _serviceToken,
            ["locale"] = "en_GB",
            ["timezone"] = "GMT+08:00",
            ["channel"] = "MI_APP_STORE"
        };

        var cookieHeader = string.Join(";", cookies.Select(kv => $"{kv.Key}={kv.Value}"));

        for (int retry = 0; retry < 3; retry++)
        {
            try
            {
                // 每次重试创建新的请求（HttpRequestMessage 不可重用）
                using var content = new FormUrlEncodedContent(encParams);
                using var requestMessage = new HttpRequestMessage(HttpMethod.Post, url);

                foreach (var header in headers)
                    requestMessage.Headers.TryAddWithoutValidation(header.Key, header.Value);

                requestMessage.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
                requestMessage.Content = content;

                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var response = await _httpClient.SendAsync(requestMessage, cts.Token);

                if (response.IsSuccessStatusCode)
                {
                    var responseText = await response.Content.ReadAsStringAsync();
                    var decrypted = XiaomiCloudCrypto.Rc4Decrypt(
                        XiaomiCloudCrypto.SignedNonce(_ssecurity, encParams["_nonce"]!),
                        responseText);
                    return JsonConvert.DeserializeObject<ApiResponse>(decrypted);
                }
                else
                {
                    System.Diagnostics.Debug.WriteLine($"[XiaomiCloudClient] API {url} returned {(int)response.StatusCode} (retry {retry + 1})");
                }
            }
            catch (OperationCanceledException)
            {
                System.Diagnostics.Debug.WriteLine($"[XiaomiCloudClient] Timeout, retry {retry + 1}");
            }
            catch (Exception ex) when (retry < 2)
            {
                System.Diagnostics.Debug.WriteLine($"[XiaomiCloudClient] Error: {ex.Message}, Retry {retry + 1}");
            }
        }
        return null;
    }

    public void Logout()
    {
        _ssecurity = "";
        _serviceToken = "";
        _userId = "";
        _location = "";
        _isLoggedIn = false;
    }
}

// Helper classes for JSON deserialization
public class ApiResponse
{
    public int code { get; set; }
    public string? message { get; set; }
    public ApiResult? result { get; set; }
}

public class ApiResult
{
    public string? beaconkey { get; set; }
    public List<HomeInfo>? homelist { get; set; }
    public List<DeviceInfo>? device_info { get; set; }
}

public class HomeInfo
{
    public string id { get; set; } = "";
    public string uid { get; set; } = "";
}

public class DeviceInfo
{
    public string did { get; set; } = "";
    public string name { get; set; } = "";
    public string model { get; set; } = "";
    public string token { get; set; } = "";
    public string mac { get; set; } = "";
}

public class CloudDeviceInfo
{
    public string Did { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "";
    public string Token { get; set; } = "";
    public string Mac { get; set; } = "";
}

public class LoginSuccessEventArgs : EventArgs
{
    public string ServiceToken { get; }
    public string Ssecurity { get; }
    public LoginSuccessEventArgs(string serviceToken, string ssecurity)
    {
        ServiceToken = serviceToken;
        Ssecurity = ssecurity;
    }
}

public class LoginErrorEventArgs : EventArgs
{
    public string ErrorMessage { get; }
    public LoginErrorEventArgs(string errorMessage) => ErrorMessage = errorMessage;
}
