using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using UnityEngine;

namespace HumanPlusMoCap.Scripts
{
    /// <summary>
    /// 动作捕捉管理器，负责网络连接、骨骼映射、动作数据接收与应用
    /// </summary>
    public class MoCapManager : MonoBehaviour
    {
        #region 枚举定义

        /// <summary>
        /// 网络连接状态
        /// </summary>
        public enum ConnectionState
        {
            /// <summary>未连接</summary>
            Disconnected,
            /// <summary>连接中</summary>
            Connecting,
            /// <summary>已连接</summary>
            Connected
        }

        /// <summary>
        /// 骨骼语义类型，用于自动映射
        /// </summary>
        private enum JointSemantic
        {
            Pelvis,
            LeftHip,
            RightHip,
            Spine1,
            LeftKnee,
            RightKnee,
            Spine2,
            LeftAnkle,
            RightAnkle,
            Spine3,
            LeftFoot,
            RightFoot,
            Neck,
            LeftCollar,
            RightCollar,
            Head,
            LeftShoulder,
            RightShoulder,
            LeftElbow,
            RightElbow,
            LeftWrist,
            RightWrist,
            LeftHand,
            RightHand
        }

        #endregion

        #region 常量定义

        /// <summary>
        /// 预期的骨骼关节数量
        /// </summary>
        private const int ExpectedJointCount = 24;

        #endregion

        #region 字段声明

        [Header("网络设置")]
        [Tooltip("服务器IP地址")]
        [SerializeField] private string serverIp = "127.0.0.1";

        [Tooltip("服务器端口号")]
        [SerializeField] private int port = 8888;

        [Tooltip("启动时自动连接")]
        [SerializeField] private bool connectOnLoad = true;

        [Tooltip("重连间隔时间（秒）")]
        [SerializeField] private float reconnectInterval = 3f;

        [Tooltip("首次连接失败后的重试延迟（秒）")]
        [SerializeField] private float initialRetryDelay = 2f;

        [Header("动作设置")]
        [Tooltip("所有旋转关节，按根到叶顺序排列。第一个关节的父对象被假定为平移关节。")]
        [SerializeField] private Transform[] joints;

        #endregion

        #region 私有字段

        private Socket clientSocket;
        private int dataSize = 4096;
        private byte[] data = new byte[4096];
        private string receiveBuffer = "";
        private readonly List<Quaternion> mocapRotations = new List<Quaternion>();

        private ConnectionState connectionState = ConnectionState.Disconnected;
        private float reconnectTimer;
        private float initialRetryTimer;
        private bool initialConnectionAttempted;
        private bool asyncConnecting;
        private bool phoneInput;
        private float connectTimeout = 3f;

        private Transform translationJoint;
        private Quaternion[] tPose;
        private Vector3 beginPosition;
        private Quaternion baseRotation;

        #endregion

        #region 属性

        /// <summary>
        /// 获取当前连接状态
        /// </summary>
        public ConnectionState CurrentConnectionState => connectionState;

        /// <summary>
        /// 获取是否已连接
        /// </summary>
        public bool IsConnected => connectionState == ConnectionState.Connected;

        #endregion

        #region 骨骼名称映射

        /// <summary>
        /// SMPL/SMPL-X 风格的骨骼名称映射表
        /// </summary>
        private static readonly Dictionary<JointSemantic, string[]> SmplNameMap = new Dictionary<JointSemantic, string[]>
        {
            { JointSemantic.Pelvis,        new[] { "m_avg_Pelvis" } },
            { JointSemantic.LeftHip,       new[] { "m_avg_L_Hip" } },
            { JointSemantic.RightHip,      new[] { "m_avg_R_Hip" } },
            { JointSemantic.Spine1,        new[] { "m_avg_Spine1" } },
            { JointSemantic.Spine2,        new[] { "m_avg_Spine2" } },
            { JointSemantic.Spine3,        new[] { "m_avg_Spine3" } },
            { JointSemantic.Neck,          new[] { "m_avg_Neck" } },
            { JointSemantic.Head,          new[] { "m_avg_Head" } },
            { JointSemantic.LeftCollar,    new[] { "m_avg_L_Collar" } },
            { JointSemantic.RightCollar,   new[] { "m_avg_R_Collar" } },
            { JointSemantic.LeftShoulder,  new[] { "m_avg_L_Shoulder" } },
            { JointSemantic.RightShoulder, new[] { "m_avg_R_Shoulder" } },
            { JointSemantic.LeftElbow,     new[] { "m_avg_L_Elbow" } },
            { JointSemantic.RightElbow,    new[] { "m_avg_R_Elbow" } },
            { JointSemantic.LeftWrist,     new[] { "m_avg_L_Wrist" } },
            { JointSemantic.RightWrist,    new[] { "m_avg_R_Wrist" } },
            { JointSemantic.LeftHand,      new[] { "m_avg_L_Hand", "m_avg_L_Index1" } },
            { JointSemantic.RightHand,     new[] { "m_avg_R_Hand", "m_avg_R_Index1" } },
            { JointSemantic.LeftKnee,      new[] { "m_avg_L_Knee" } },
            { JointSemantic.RightKnee,     new[] { "m_avg_R_Knee" } },
            { JointSemantic.LeftAnkle,     new[] { "m_avg_L_Ankle" } },
            { JointSemantic.RightAnkle,    new[] { "m_avg_R_Ankle" } },
            { JointSemantic.LeftFoot,      new[] { "m_avg_L_Foot" } },
            { JointSemantic.RightFoot,     new[] { "m_avg_R_Foot" } },
        };

        #endregion

        #region 生命周期方法

        /// <summary>
        /// 初始化，在游戏对象加载时调用
        /// </summary>
        private void Awake()
        {
            // Disable the legacy blocking PC socket before the first Android Update.
            if (Application.platform == RuntimePlatform.Android) UsePhoneInput();
            if (joints == null || joints.Length == 0)
            {
                Debug.LogWarning("Awake: joints 为空，尝试自动映射...");
                AutoMapJoints();
            }

            if (joints == null || joints.Length == 0)
            {
                Debug.LogError("Awake: 关节映射失败，joints 为空");
                return;
            }

            if (joints[0] == null)
            {
                Debug.LogError("Awake: joints[0] 为空");
                return;
            }

            translationJoint = joints[0].parent;

            if (translationJoint == null)
            {
                Debug.LogError("Awake: translationJoint 为空");
                return;
            }

            tPose = new Quaternion[joints.Length];
            for (int i = 0; i < joints.Length; i++)
            {
                if (joints[i] != null)
                {
                    tPose[i] = joints[i].localRotation;
                }
                else
                {
                    Debug.LogError($"Awake: joints[{i}] 为空");
                }
            }

            beginPosition = translationJoint.localPosition;
            baseRotation = translationJoint.rotation;

            Debug.Log($"Awake: 初始化完成，检测到 {joints.Length} 个关节");
        }

        /// <summary>
        /// 启动，在Awake之后调用
        /// </summary>
        private void Start()
        {
            if (connectOnLoad)
            {
                initialConnectionAttempted = false;
                initialRetryTimer = initialRetryDelay;
            }
        }

        /// <summary>
        /// 每帧更新
        /// </summary>
        private void Update()
        {
            if (!phoneInput && connectOnLoad) HandleConnection();
        }

        /// <summary>
        /// 晚于所有Update执行，用于应用动作数据
        /// </summary>
        private void LateUpdate()
        {
            if (!phoneInput && connectionState == ConnectionState.Connected)
            {
                ProcessMotionData();
            }

            if (joints == null || joints.Length == 0)
            {
                return;
            }

            if (mocapRotations.Count != joints.Length)
            {
                return;
            }

            for (int i = 0; i < joints.Length; i++)
            {
                if (joints[i] != null)
                {
                    joints[i].localRotation = mocapRotations[i];
                }
            }
        }

        /// <summary>
        /// 销毁时断开连接
        /// </summary>
        private void OnDestroy()
        {
            Disconnect();
        }

        #endregion

        #region 连接状态管理

        /// <summary>
        /// 处理连接状态管理，包括初始连接和断线重连
        /// </summary>
        private void HandleConnection()
        {
            if (asyncConnecting)
            {
                return;
            }

            if (connectionState == ConnectionState.Connected)
            {
                if (!IsSocketConnected())
                {
                    Debug.LogWarning("HandleConnection: 检测到连接已断开");
                    OnDisconnected();
                }
                return;
            }

            if (!initialConnectionAttempted)
            {
                initialRetryTimer -= Time.deltaTime;
                if (initialRetryTimer <= 0f)
                {
                    Debug.Log("HandleConnection: 尝试首次连接...");
                    initialConnectionAttempted = true;
                    Connect();
                }
                return;
            }

            reconnectTimer -= Time.deltaTime;
            if (reconnectTimer <= 0f)
            {
                Debug.Log($"HandleConnection: 尝试重新连接 (间隔 {reconnectInterval} 秒)...");
                reconnectTimer = reconnectInterval;
                Connect();
            }
        }

        /// <summary>
        /// 检查Socket是否仍处于连接状态
        /// </summary>
        /// <returns>是否已连接</returns>
        private bool IsSocketConnected()
        {
            try
            {
                if (clientSocket == null || !clientSocket.Connected)
                {
                    return false;
                }

                bool readable = clientSocket.Poll(0, SelectMode.SelectRead);
                bool writable = clientSocket.Poll(0, SelectMode.SelectWrite);

                if (readable && !writable)
                {
                    return false;
                }

                if (readable)
                {
                    byte[] buffer = new byte[1];
                    int received = clientSocket.Receive(buffer, SocketFlags.Peek);
                    return received > 0;
                }

                return true;
            }
            catch (SocketException)
            {
                return false;
            }
            catch (ObjectDisposedException)
            {
                return false;
            }
        }

        /// <summary>
        /// 断开连接时的回调处理
        /// </summary>
        private void OnDisconnected()
        {
            connectionState = ConnectionState.Disconnected;
            Debug.Log("OnDisconnected: 连接已断开，标记为未连接状态");
            reconnectTimer = reconnectInterval;
        }

        /// <summary>
        /// 成功连接时的回调处理
        /// </summary>
        private void OnConnected()
        {
            connectionState = ConnectionState.Connected;
            Debug.Log($"OnConnected: 连接成功 {serverIp}:{port}");
        }

        #endregion

        #region 网络通信

        /// <summary>
        /// 连接到服务器
        /// </summary>
        public void Connect()
        {
            if (asyncConnecting)
            {
                Debug.Log("Connect: 异步连接进行中，跳过");
                return;
            }

            if (clientSocket != null && clientSocket.Connected)
            {
                Debug.LogWarning("Connect: 已连接，跳过");
                return;
            }

            connectionState = ConnectionState.Connecting;
            asyncConnecting = true;

            try
            {
                if (clientSocket != null)
                {
                    try { clientSocket.Close(); }
                    catch
                    {
                    }

                    clientSocket = null;
                }

                clientSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                clientSocket.Blocking = false;

                IAsyncResult result = clientSocket.BeginConnect(
                    new IPEndPoint(IPAddress.Parse(serverIp), port),
                    ConnectCallback,
                    null);

                float timeoutTimer = 0f;
                while (!result.IsCompleted && timeoutTimer < connectTimeout)
                {
                    timeoutTimer += Time.deltaTime;
                }

                if (!result.IsCompleted)
                {
                    Debug.LogWarning($"Connect: 连接超时 ({connectTimeout}秒)");
                    try { clientSocket.Close(); }
                    catch
                    {
                    }

                    clientSocket = null;
                    asyncConnecting = false;
                    OnDisconnected();
                }
            }
            catch (SocketException ex)
            {
                Debug.LogError($"Connect: Socket错误 - {ex.Message} (错误码: {ex.ErrorCode})");
                asyncConnecting = false;
                OnDisconnected();
            }
            catch (ArgumentException ex)
            {
                Debug.LogError($"Connect: 参数错误 - {ex.Message}");
                asyncConnecting = false;
                OnDisconnected();
            }
            catch (ObjectDisposedException ex)
            {
                Debug.LogError($"Connect: Socket已释放 - {ex.Message}");
                asyncConnecting = false;
                OnDisconnected();
            }
            catch (Exception ex)
            {
                Debug.LogError($"Connect: 未知错误 - {ex.Message}");
                asyncConnecting = false;
                OnDisconnected();
            }
        }

        /// <summary>
        /// 异步连接完成的回调函数
        /// </summary>
        /// <param name="result">异步操作结果</param>
        private void ConnectCallback(IAsyncResult result)
        {
            try
            {
                if (clientSocket == null)
                {
                    asyncConnecting = false;
                    return;
                }

                clientSocket.EndConnect(result);
                clientSocket.Blocking = true;
                asyncConnecting = false;
                OnConnected();
            }
            catch (SocketException ex)
            {
                Debug.LogError($"ConnectCallback: 连接失败 - {ex.Message}");
                asyncConnecting = false;
                OnDisconnected();
            }
            catch (ObjectDisposedException)
            {
                Debug.LogWarning("ConnectCallback: Socket已关闭");
                asyncConnecting = false;
                OnDisconnected();
            }
            catch (Exception ex)
            {
                Debug.LogError($"ConnectCallback: 未知错误 - {ex.Message}");
                asyncConnecting = false;
                OnDisconnected();
            }
        }

        /// <summary>
        /// 断开与服务器的连接
        /// </summary>
        public void Disconnect()
        {
            if (clientSocket != null)
            {
                try
                {
                    if (clientSocket.Connected)
                    {
                        clientSocket.Shutdown(SocketShutdown.Both);
                    }
                    clientSocket.Close();
                }
                catch (SocketException ex)
                {
                    Debug.LogError($"Disconnect: Socket 错误 - {ex.Message}");
                }
                catch (ObjectDisposedException)
                {
                }
                catch (Exception ex)
                {
                    Debug.LogError($"Disconnect: 未知错误 - {ex.Message}");
                }
                clientSocket = null;
            }

            connectionState = ConnectionState.Disconnected;
            Debug.Log("Disconnect: 已断开连接");
        }

        /// <summary>
        /// 接收数据直到遇到指定结束符
        /// </summary>
        /// <param name="end">结束符</param>
        /// <returns>接收到的字符串（不包含结束符）</returns>
        public string Receive(char end)
        {
            if (clientSocket == null || !clientSocket.Connected)
            {
                Debug.LogError("Receive: Socket 未连接");
                return "";
            }

            try
            {
                string message = "";
                do
                {
                    int length = clientSocket.Receive(data);
                    if (length == 0)
                    {
                        Debug.LogWarning("Receive: 连接已关闭");
                        OnDisconnected();
                        return "";
                    }
                    message += Encoding.UTF8.GetString(data, 0, length);
                } while (message.Length > 0 && message[message.Length - 1] != end);

                if (message.Length > 0)
                {
                    return message.Substring(0, message.Length - 1);
                }
            }
            catch (SocketException ex)
            {
                Debug.LogError($"Receive: Socket 错误 - {ex.Message}");
                OnDisconnected();
            }
            catch (ObjectDisposedException ex)
            {
                Debug.LogError($"Receive: Socket 已释放 - {ex.Message}");
                OnDisconnected();
            }
            catch (Exception ex)
            {
                Debug.LogError($"Receive: 未知错误 - {ex.Message}");
                OnDisconnected();
            }
            return "";
        }

        /// <summary>
        /// 接收指定大小的数据
        /// </summary>
        /// <param name="size">接收缓冲区大小</param>
        /// <returns>接收到的字符串</returns>
        public string Receive(int size = 4096)
        {
            if (clientSocket == null || !clientSocket.Connected)
            {
                Debug.LogError("Receive: Socket 未连接");
                return "";
            }

            try
            {
                if (dataSize != size)
                {
                    data = new byte[size];
                    dataSize = size;
                }
                int length = clientSocket.Receive(data);
                if (length == 0)
                {
                    Debug.LogWarning("Receive: 连接已关闭");
                    OnDisconnected();
                    return "";
                }
                return Encoding.UTF8.GetString(data, 0, length);
            }
            catch (SocketException ex)
            {
                Debug.LogError($"Receive: Socket 错误 - {ex.Message}");
                OnDisconnected();
                return "";
            }
            catch (ObjectDisposedException ex)
            {
                Debug.LogError($"Receive: Socket 已释放 - {ex.Message}");
                OnDisconnected();
                return "";
            }
            catch (Exception ex)
            {
                Debug.LogError($"Receive: 未知错误 - {ex.Message}");
                OnDisconnected();
                return "";
            }
        }

        /// <summary>
        /// 发送消息到服务器
        /// </summary>
        /// <param name="message">要发送的消息</param>
        public void Send(string message)
        {
            if (clientSocket == null || !clientSocket.Connected)
            {
                Debug.LogError("Send: Socket 未连接");
                return;
            }

            try
            {
                byte[] sendData = Encoding.UTF8.GetBytes(message);
                int sent = clientSocket.Send(sendData);
                if (sent != sendData.Length)
                {
                    Debug.LogWarning($"Send: 发送不完整 {sent}/{sendData.Length}");
                }
            }
            catch (SocketException ex)
            {
                Debug.LogError($"Send: Socket 错误 - {ex.Message}");
                OnDisconnected();
            }
            catch (ObjectDisposedException ex)
            {
                Debug.LogError($"Send: Socket 已释放 - {ex.Message}");
                OnDisconnected();
            }
            catch (Exception ex)
            {
                Debug.LogError($"Send: 未知错误 - {ex.Message}");
                OnDisconnected();
            }
        }

        #endregion

        #region 动作数据处理

        /// <summary>
        /// 处理接收到的动作数据
        /// </summary>
        public void ProcessMotionData()
        {
            if (connectionState != ConnectionState.Connected)
            {
                return;
            }

            try
            {
                string raw = Receive(256);
                if (string.IsNullOrEmpty(raw))
                {
                    return;
                }

                receiveBuffer += raw;
                string[] motions = receiveBuffer.Split(new[] { '$' }, StringSplitOptions.RemoveEmptyEntries);

                if (motions.Length < 2)
                {
                    return;
                }

                receiveBuffer = motions[motions.Length - 1];
                string poseAndTran = motions[0];

                string[] parts = poseAndTran.Split(new[] { '#' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 2)
                {
                    Debug.LogError($"ProcessMotionData: 格式错误 - {poseAndTran}");
                    return;
                }

                string poseStr = parts[0];
                string posStr = parts[1];

                ParsePoseAndApply(poseStr);
                SetRootPosition(posStr);
            }
            catch (Exception ex)
            {
                Debug.LogError($"ProcessMotionData: 处理失败 - {ex.Message}");
            }
        }

        /// <summary>
        /// 解析姿态字符串并应用到骨骼
        /// </summary>
        /// <param name="pose">姿态字符串，格式为逗号分隔的数值</param>
        public bool PhonePoseReady => joints != null && joints.Length == ExpectedJointCount &&
            Array.TrueForAll(joints, joint => joint != null) &&
            tPose != null && tPose.Length == ExpectedJointCount && translationJoint != null;

        public void UsePhoneInput()
        {
            if (phoneInput) return;
            phoneInput = true;
            connectOnLoad = false;
            Disconnect();
        }

        /// <summary>SMPL local axis-angle radians, in the same order as the PC inference model.</summary>
        public bool ApplyPhonePose(float[] values)
        {
            if (!PhonePoseReady || values == null || values.Length != ExpectedJointCount * 3)
                return false;
            float[,] pose = new float[ExpectedJointCount, 3];
            for (int i = 0; i < values.Length; i++)
            {
                if (float.IsNaN(values[i]) || float.IsInfinity(values[i])) return false;
                pose[i / 3, i % 3] = values[i];
            }
            UsePhoneInput();
            // Reuse the calibrated local bone rotation path, rather than SetPose's world-rotation path.
            ApplyPose(pose);
            return true;
        }

        private void ParsePoseAndApply(string pose)
        {
            if (string.IsNullOrEmpty(pose))
            {
                Debug.LogError("ParsePoseAndApply: pose 字符串为空");
                return;
            }

            if (joints == null || joints.Length == 0)
            {
                Debug.LogError("ParsePoseAndApply: joints 为空");
                return;
            }

            if (tPose == null || tPose.Length != joints.Length)
            {
                Debug.LogError("ParsePoseAndApply: tPose 未初始化或长度不匹配");
                return;
            }

            string[] ps = pose.Split(',');
            int expectedLength = joints.Length * 3;

            if (ps.Length != expectedLength)
            {
                Debug.LogError($"ParsePoseAndApply: 长度不匹配 期待 {expectedLength} 实际 {ps.Length}");
                return;
            }

            float[,] pf = new float[joints.Length, 3];
            for (int i = 0; i < joints.Length; ++i)
            {
                for (int j = 0; j < 3; ++j)
                {
                    int index = i * 3 + j;
                    if (!float.TryParse(ps[index], out pf[i, j]))
                    {
                        Debug.LogError($"ParsePoseAndApply: 解析失败 index={index} value={ps[index]}");
                        return;
                    }
                }
            }

            ApplyPose(pf);
        }

        /// <summary>
        /// 应用姿态数据到骨骼
        /// </summary>
        /// <param name="pose">姿态数据，二维数组</param>
        private void ApplyPose(float[,] pose)
        {
            if (translationJoint == null)
            {
                Debug.LogError("ApplyPose: translationJoint 为空");
                return;
            }

            if (joints == null || joints.Length == 0)
            {
                Debug.LogError("ApplyPose: joints 为空");
                return;
            }

            Quaternion save = translationJoint.rotation;
            translationJoint.rotation = baseRotation;

            try
            {
                int jointNum = joints.Length;
                if (pose.GetLength(0) != jointNum)
                {
                    Debug.LogError($"ApplyPose: pose 维度不匹配 {pose.GetLength(0)} vs {jointNum}");
                    return;
                }

                mocapRotations.Clear();

                for (int i = 0; i < jointNum; i++)
                {
                    if (joints[i] == null)
                    {
                        mocapRotations.Add(Quaternion.identity);
                        continue;
                    }

                    Vector3 aa = new Vector3(pose[i, 0], -pose[i, 1], -pose[i, 2]);
                    float angle = aa.magnitude;

                    if (angle > 1e-6f)
                    {
                        Quaternion delta = Quaternion.AngleAxis(Mathf.Rad2Deg * angle, aa.normalized);
                        Quaternion target = tPose[i] * delta;
                        mocapRotations.Add(target);
                    }
                    else
                    {
                        mocapRotations.Add(tPose[i]);
                    }
                }
            }
            finally
            {
                translationJoint.rotation = save;
            }
        }

        #endregion

        #region 骨骼自动映射

        /// <summary>
        /// 自动映射骨骼关节，在Unity编辑器的上下文菜单中调用
        /// </summary>
        [ContextMenu("Auto Map Joints")]
        public void AutoMapJoints()
        {
            if (transform == null)
            {
                Debug.LogError("AutoMapJoints: transform 为空");
                return;
            }

            Debug.Log("AutoMapJoints: 开始自动映射...");

            Dictionary<JointSemantic, string[]> nameMap = DetectNamingStyle(transform);
            if (nameMap == null)
            {
                Debug.LogError("AutoMapJoints: 无法检测到骨骼命名风格");
                return;
            }

            List<Transform> ordered = new List<Transform>();
            List<string> missing = new List<string>();

            foreach (JointSemantic semantic in Enum.GetValues(typeof(JointSemantic)))
            {
                Transform found = FindByCandidates(transform, nameMap[semantic]);
                if (found != null)
                {
                    ordered.Add(found);
                }
                else
                {
                    missing.Add(semantic.ToString());
                }
            }

            if (ordered.Count == ExpectedJointCount)
            {
                joints = ordered.ToArray();
                Debug.Log($"AutoMapJoints: 映射完成 {ordered.Count} / {ExpectedJointCount}");
            }
            else
            {
                joints = Array.Empty<Transform>();
                StringBuilder builder = new StringBuilder();
                builder.AppendLine($"AutoMapJoints: 映射失败 {ordered.Count} / {ExpectedJointCount}");
                if (missing.Count > 0)
                {
                    builder.AppendLine("无法解析的关节：");
                    foreach (string m in missing)
                    {
                        builder.AppendLine($"- {m}");
                    }
                }
                Debug.LogError(builder.ToString());
            }
        }

        /// <summary>
        /// 检测骨骼命名风格
        /// </summary>
        /// <param name="root">骨骼根节点</param>
        /// <returns>命名映射表</returns>
        private Dictionary<JointSemantic, string[]> DetectNamingStyle(Transform root)
        {
            if (FindChildRecursively(root, "m_avg_Pelvis") != null)
            {
                Debug.Log("检测到 SMPL / SMPL-X 骨骼命名风格");
                return SmplNameMap;
            }

            Debug.LogError("无法识别骨骼命名风格");
            return null;
        }

        /// <summary>
        /// 通过候选名称列表查找骨骼
        /// </summary>
        /// <param name="root">搜索起点</param>
        /// <param name="names">候选名称列表</param>
        /// <returns>找到的骨骼Transform，未找到返回null</returns>
        private Transform FindByCandidates(Transform root, string[] names)
        {
            if (names == null)
            {
                return null;
            }

            foreach (string n in names)
            {
                Transform t = FindChildRecursively(root, n);
                if (t != null)
                {
                    return t;
                }
            }
            return null;
        }

        /// <summary>
        /// 递归查找子骨骼
        /// </summary>
        /// <param name="parent">父节点</param>
        /// <param name="candidate">目标名称（包含匹配）</param>
        /// <returns>找到的Transform，未找到返回null</returns>
        private Transform FindChildRecursively(Transform parent, string candidate)
        {
            if (parent == null || string.IsNullOrEmpty(candidate))
            {
                return null;
            }

            string target = candidate.ToLowerInvariant();

            foreach (Transform child in parent)
            {
                if (child == null)
                {
                    continue;
                }

                string boneName = child.name.ToLowerInvariant();
                if (boneName.Contains(target))
                {
                    return child;
                }

                Transform found = FindChildRecursively(child, candidate);
                if (found != null)
                {
                    return found;
                }
            }
            return null;
        }

        #endregion

        #region 姿态控制

        /// <summary>
        /// 设置动作捕捉目标姿态
        /// </summary>
        /// <param name="pose">姿态数据，二维数组 [关节索引, 3个轴的值]</param>
        public void SetMoCapTarget(float[,] pose)
        {
            if (translationJoint == null)
            {
                Debug.LogError("SetMoCapTarget: translationJoint 为空");
                return;
            }

            if (joints == null || joints.Length == 0)
            {
                Debug.LogError("SetMoCapTarget: joints 为空");
                return;
            }

            if (tPose == null || tPose.Length != joints.Length)
            {
                Debug.LogError("SetMoCapTarget: tPose 未初始化或长度不匹配");
                return;
            }

            if (pose == null)
            {
                Debug.LogError("SetMoCapTarget: pose 为空");
                return;
            }

            Quaternion save = translationJoint.rotation;
            translationJoint.rotation = baseRotation;

            try
            {
                int jointNum = joints.Length;
                if (pose.GetLength(0) != jointNum)
                {
                    Debug.LogError($"SetMoCapTarget: pose 维度不匹配 {pose.GetLength(0)} vs {jointNum}");
                    return;
                }

                for (int i = jointNum - 1; i >= 0; --i)
                {
                    if (joints[i] == null)
                    {
                        continue;
                    }

                    Vector3 aa = new Vector3(pose[i, 0], -pose[i, 1], -pose[i, 2]);
                    float angle = aa.magnitude;

                    if (angle > 1e-6f)
                    {
                        Quaternion delta = Quaternion.AngleAxis(Mathf.Rad2Deg * angle, aa.normalized);
                        joints[i].rotation = delta * joints[i].rotation;
                    }
                }
            }
            finally
            {
                translationJoint.rotation = save;
            }
        }

        /// <summary>
        /// 设置姿态（从字符串解析）
        /// </summary>
        /// <param name="pose">姿态字符串</param>
        /// <param name="split">分隔符</param>
        public void SetPose(string pose, char split = ',')
        {
            if (string.IsNullOrEmpty(pose))
            {
                Debug.LogError("SetPose: pose 字符串为空");
                return;
            }

            if (joints == null || joints.Length == 0)
            {
                Debug.LogError("SetPose: joints 为空");
                return;
            }

            string[] ps = pose.Split(split);
            int expectedLength = joints.Length * 3;

            if (ps.Length != expectedLength)
            {
                Debug.LogError($"SetPose: 长度不匹配 期待 {expectedLength} 实际 {ps.Length}");
                return;
            }

            float[,] pf = new float[joints.Length, 3];
            for (int i = 0; i < joints.Length; ++i)
            {
                for (int j = 0; j < 3; ++j)
                {
                    int index = i * 3 + j;
                    if (!float.TryParse(ps[index], out pf[i, j]))
                    {
                        Debug.LogError($"SetPose: 解析失败 index={index} value={ps[index]}");
                        return;
                    }
                }
            }
            SetMoCapTarget(pf);
        }

        /// <summary>
        /// 清除姿态，恢复到T-Pose
        /// </summary>
        public void ClearPose()
        {
            if (joints == null || joints.Length == 0)
            {
                return;
            }

            if (tPose == null || tPose.Length != joints.Length)
            {
                return;
            }

            for (int i = 0; i < joints.Length; ++i)
            {
                if (joints[i] != null)
                {
                    joints[i].localRotation = tPose[i];
                }
            }
        }

        #endregion

        #region 根位置控制

        /// <summary>
        /// 设置根节点位置
        /// </summary>
        /// <param name="pos">位置字符串，格式为 x,y,z</param>
        /// <param name="split">分隔符</param>
        public void SetRootPosition(string pos, char split = ',')
        {
            if (translationJoint == null)
            {
                Debug.LogError("SetRootPosition: translationJoint 为空");
                return;
            }

            if (string.IsNullOrEmpty(pos))
            {
                Debug.LogError("SetRootPosition: pos 字符串为空");
                return;
            }

            string[] ps = pos.Split(split);
            if (ps.Length < 3)
            {
                Debug.LogError($"SetRootPosition: 数据长度不足 期待 3 实际 {ps.Length}");
                return;
            }

            if (!float.TryParse(ps[0], out float x) ||
                !float.TryParse(ps[1], out float y) ||
                !float.TryParse(ps[2], out float z))
            {
                Debug.LogError("SetRootPosition: 坐标解析失败");
                return;
            }

            Vector3 p = new Vector3(-x, y, z);
            translationJoint.localPosition = p;
        }

        /// <summary>
        /// 清除根位置，恢复到初始位置
        /// </summary>
        public void ClearRootPosition()
        {
            if (translationJoint == null)
            {
                Debug.LogError("ClearRootPosition: translationJoint 为空");
                return;
            }
            translationJoint.localPosition = beginPosition;
        }

        /// <summary>
        /// 获取当前根位置
        /// </summary>
        /// <returns>当前根节点局部位置</returns>
        public Vector3 GetRootPosition()
        {
            if (translationJoint == null)
            {
                return Vector3.zero;
            }
            return translationJoint.localPosition;
        }

        #endregion
    }
}
