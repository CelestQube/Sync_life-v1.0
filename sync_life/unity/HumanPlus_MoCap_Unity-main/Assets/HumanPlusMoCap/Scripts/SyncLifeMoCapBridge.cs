using System;
using FlutterUnityIntegration;
using HumanPlusMoCap.Scripts;
using UnityEngine;
using UnityEngine.Scripting;

/// <summary>Flutter UnitySendMessage receiver; installed without changing scene/prefab references.</summary>
[Preserve]
public sealed class SyncLifeMoCapBridge : MonoBehaviour
{
    [Serializable] private class PoseMessage { public float[] pose; }
    private MoCapManager manager;
    private int frames;
    private float lastAck;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Install()
    {
        if (Application.platform != RuntimePlatform.Android) return;
        if (FindObjectOfType<SyncLifeMoCapBridge>() != null) return;
        var host = new GameObject("SyncLifeMoCapBridge");
        DontDestroyOnLoad(host);
        host.AddComponent<SyncLifeMoCapBridge>();
    }

    private void Start() { InvokeRepeating(nameof(Announce), 0.1f, 1f); }
    private bool Ready()
    {
        if (manager == null) manager = FindObjectOfType<MoCapManager>();
        if (manager == null || !manager.PhonePoseReady) return false;
        manager.UsePhoneInput();
        return true;
    }
    private void Announce()
    {
        if (Ready()) NativeAPI.SendMessageToFlutter("{\"type\":\"mocap_ready\",\"protocol\":1,\"jointCount\":24}");
    }
    [Preserve] public void Ping(string unused) { Announce(); }

    [Preserve]
    public void ReceivePose(string json)
    {
        try
        {
            if (!Ready()) { Error("骨骼映射尚未就绪"); return; }
            if (string.IsNullOrEmpty(json) || json.Length > 6000) { Error("姿态消息长度无效"); return; }
            var message = JsonUtility.FromJson<PoseMessage>(json);
            if (message == null || !manager.ApplyPhonePose(message.pose)) { Error("姿态需要 72 个有限数值"); return; }
            frames++;
            if (frames == 1 || Time.realtimeSinceStartup - lastAck > 0.5f)
            {
                lastAck = Time.realtimeSinceStartup;
                NativeAPI.SendMessageToFlutter("{\"type\":\"mocap_applied\",\"frames\":" + frames + "}");
            }
        }
        catch (Exception exception)
        {
            Debug.LogWarning("Phone mocap: " + exception.Message);
            Error("姿态消息解析失败");
        }
    }
    private static void Error(string message)
    {
        NativeAPI.SendMessageToFlutter("{\"type\":\"mocap_error\",\"message\":\"" + message + "\"}");
    }
}
