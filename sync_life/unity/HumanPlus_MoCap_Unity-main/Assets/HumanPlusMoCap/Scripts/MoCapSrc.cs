using System.Collections.Generic;
using UnityEngine;

namespace HumanPlusMoCap.Scripts
{
	/// <summary>
	/// 此脚本挂载在目标模型上，将动作捕捉标准SMPL模型（标准SMPL模型）的姿态应用到目标模型上
	/// 最终控制的是目标模型各关节的相对旋转
	/// 支持全局权重、半身权重和每个关节的单独权重控制，如果权重为0，则关节由动画状态机控制
	/// </summary>
	public class MoCapSrc : MonoBehaviour
	{
		[Tooltip("Bind this Script to your target character")]
		public GameObject src;

		[Header("MoCap Global Weight")]
		[Range(0f, 1f)]
		public float globalWeight = 1f;

		[Header("Half Body Weight")]
		[Range(0f, 1f)]
		[SerializeField]
		private float upperBodyWeight = 1f;

		[Range(0f, 1f)]
		[SerializeField]
		private float lowerBodyWeight = 1f;

		[Header("Affect Root Position")]
		[Tooltip("是否让动捕影响角色整体位置")]
		public bool affectRootPosition = true;
		
		[Header("Affect Root Rotation")]
		[Tooltip("是否让动捕影响角色整体旋转")]
		public bool affectRootRotation = true;
		
		[Header("Force Upper Body Upright")]
		[Tooltip("是否强制挺直上半身")]
		public bool forceUpperBodyUpright = false;
		
		/// <summary>
		/// 下半身关节索引数组，这些索引对应SmplToHuman中的下半身骨骼
		/// 包括：左/右大腿、左/右小腿、左/右脚、左/右脚趾
		/// </summary>
		private static readonly int[] LowerBodyIndices = { 1, 2, 4, 5, 7, 8, 10, 11 };
		
		/// <summary>
		/// 上半身关节索引数组，这些索引对应SmplToHuman中的上半身骨骼
		/// 包括：脊柱、胸部、上胸部、颈部、头部、左/右肩部、左/右大臂、左/右小臂、左/右手
		/// </summary>
		private static readonly int[] UpperBodyIndices = { 3, 6, 9, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };

		[Header("Per-joint MoCap Weight")]
		[SerializeField]
		public JointInfo[] jointsInfo = new JointInfo[SmplToHuman.Length];

		/// <summary>
		/// SMPL模型骨骼到Unity HumanBodyBones的映射数组
		/// 定义了SMPL模型骨骼与Unity角色骨骼的对应关系，其中Unity没有手心的骨骼，所以这里只有22个骨骼
		/// </summary>
		private static readonly HumanBodyBones[] SmplToHuman =
		{
			HumanBodyBones.Hips,
			HumanBodyBones.LeftUpperLeg,
			HumanBodyBones.RightUpperLeg,
			HumanBodyBones.Spine,
			HumanBodyBones.LeftLowerLeg,
			HumanBodyBones.RightLowerLeg,
			HumanBodyBones.Chest,
			HumanBodyBones.LeftFoot,
			HumanBodyBones.RightFoot,
			HumanBodyBones.UpperChest,
			HumanBodyBones.LeftToes,
			HumanBodyBones.RightToes,
			HumanBodyBones.Neck,
			HumanBodyBones.LeftShoulder,
			HumanBodyBones.RightShoulder,
			HumanBodyBones.Head,
			HumanBodyBones.LeftUpperArm,
			HumanBodyBones.RightUpperArm,
			HumanBodyBones.LeftLowerArm,
			HumanBodyBones.RightLowerArm,
			HumanBodyBones.LeftHand,
			HumanBodyBones.RightHand,
		};

		/// <summary>
		/// SMPL模型各关节对应的父节点索引数组
		/// 定义了骨骼层级结构，每个索引对应SmplToHuman数组中骨骼的父骨骼索引
		/// -1表示根节点（没有父节点）
		/// </summary>
		private static readonly int[] ParentIndex =
			{ -1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19 };
		
		[System.Serializable]
		public class JointInfo
		{
			public string jointName;
			
			[Range(0f, 1f)]
			public float weight = 1f;
		}

		/// <summary>
		/// 中间关节姿势，用于缓存目标关节的世界旋转，后续转为局部旋转
		/// 在动作捕捉旋转应用过程中作为中间存储
		/// </summary>
		private class MidJointPose
		{
			public Quaternion worldRotation;
			public Quaternion localRotation;
		}
		
		private Transform srcModel;
		
		private Animator srcAnimator;
		private Animator selfAnimator;
		
		private List<Transform> srcJoints;
		private List<Transform> selfJoints;
		
		// 中间关节姿势列表，用来缓存一份目标模型各关节的世界旋转，用于计算局部旋转
		private List<MidJointPose> midJoints;
		
		private Quaternion srcInitRotation;
		private Quaternion selfInitRotation;

		private List<Quaternion> srcJointsInitRotation;
		private List<Quaternion> selfJointsInitRotation;
		
		private Transform srcRoot;
		private Transform selfRoot;

		private Vector3 srcInitPosition;
		private Vector3 selfInitPosition;

		/// <summary>
		/// 标准SMPL模型到目标角色的缩放比例
		/// </summary>
		private float scale = 1f;
		
		/// <summary>
		/// 是否已完成初始化
		/// </summary>
		private bool hasInit;

		/// <summary>
		/// 在编辑器中验证和初始化jointsInfo数组
		/// 当脚本属性在Inspector中被修改时调用
		/// </summary>
		private void OnValidate()
		{
			// 确保jointsInfo数组的长度与SmplToHuman数组一致
			if (jointsInfo == null || jointsInfo.Length != SmplToHuman.Length)
			{
				jointsInfo = new JointInfo[SmplToHuman.Length];
			}

			// 初始化每个关节的信息
			for (int i = 0; i < SmplToHuman.Length; i++)
			{
				if (jointsInfo[i] == null)
					jointsInfo[i] = new JointInfo();

				// 设置关节名称为对应的HumanBodyBones枚举值
				jointsInfo[i].jointName = SmplToHuman[i].ToString();
			}
		}

		/// <summary>
		/// 脚本启动时的初始化方法
		/// 负责查找标准SMPL模型、获取Animator组件、初始化关节列表和初始姿势
		/// </summary>
		private void Start()
		{
			if (src == null)
			{
				Debug.LogError("[MoCapSrc] Src GameObject is null.");
				return;
			}
			
			Debug.Assert(ParentIndex.Length == SmplToHuman.Length);

			srcModel = src.transform.Find("StandardBody");
			if (srcModel == null)
			{
				Debug.LogWarning("[MoCapSrc] StandardBody not found, fallback to src root.");
				srcModel = src.transform;
			}

			// 获取标准SMPL模型和自身（目标角色）的Animator组件
			srcAnimator = srcModel.GetComponent<Animator>();
			selfAnimator = GetComponent<Animator>();

			if (srcAnimator == null || selfAnimator == null)
			{
				Debug.LogError("[MoCapSrc] Animator missing on source or target.");
				return;
			}

			if (jointsInfo == null || jointsInfo.Length != SmplToHuman.Length)
			{
				jointsInfo = new JointInfo[SmplToHuman.Length];
				for (int i = 0; i < jointsInfo.Length; i++)
					jointsInfo[i] = new JointInfo { jointName = SmplToHuman[i].ToString() };
			}

			// 初始化关节列表
			srcJoints = new List<Transform>(SmplToHuman.Length);
			selfJoints = new List<Transform>(SmplToHuman.Length);
			midJoints = new List<MidJointPose>(SmplToHuman.Length);

			// 获取标准SMPL模型和自身（目标角色）的关节Transform
			foreach (var bone in SmplToHuman)
			{
				srcJoints.Add(srcAnimator.GetBoneTransform(bone));
				selfJoints.Add(selfAnimator.GetBoneTransform(bone));
			}
			
			// 初始化中间关节姿势列表
			for (var i = 0; i < SmplToHuman.Length; i++)
			{
				midJoints.Add(new MidJointPose{worldRotation = selfJoints[i].rotation, localRotation = selfJoints[i].localRotation});
			}
			
			SetJointsInitRotation();
			SetInitPosition();

			hasInit = true;
		}

		/// <summary>
		/// 每帧更新时调用的方法，在动画更新之后执行
		/// 负责应用动作捕捉的关节旋转和位置
		/// </summary>
		private void LateUpdate()
		{
			if (!hasInit) return;
			if (srcRoot == null || selfRoot == null) return;

			SetJointsRotation();
			SetPosition();
		}

		/// <summary>
		/// 设置标准SMPL模型和目标角色关节的初始旋转
		/// 存储T-Pose时模型的初始旋转，用于后续的旋转计算
		/// </summary>
		private void SetJointsInitRotation()
		{
			// 记录标准SMPL模型和自身（目标角色）的初始旋转
			srcInitRotation = srcModel.rotation;
			selfInitRotation = transform.rotation;

			srcJointsInitRotation = new List<Quaternion>(SmplToHuman.Length);
			selfJointsInitRotation = new List<Quaternion>(SmplToHuman.Length);

			// 遍历所有关节，存储相对于根节点的初始旋转
			for (int i = 0; i < SmplToHuman.Length; i++)
			{
				if (srcJoints[i] == null || selfJoints[i] == null)
				{
					// 如果关节不存在，使用单位旋转
					srcJointsInitRotation.Add(Quaternion.identity);
					selfJointsInitRotation.Add(Quaternion.identity);
				}
				else
				{
					// 存储SMPL在T-Pose时关节的世界旋转
					srcJointsInitRotation.Add(
						srcJoints[i].rotation * Quaternion.Inverse(srcInitRotation)
					);
					// 存储目标在T-Pose时关节的世界旋转
					selfJointsInitRotation.Add(
						selfJoints[i].rotation * Quaternion.Inverse(selfInitRotation)
					);
				}
			}
		}

		/// <summary>
		/// 设置关节旋转，将标准SMPL模型的动作捕捉旋转应用到目标角色
		/// 包含两个主要阶段：根据SMPL的世界旋转计算目标模型的世界旋转，再将目标世界旋转转换为带权重的局部旋转
		/// </summary>
		private void SetJointsRotation()
		{
			// 第一阶段：计算所有关节的目标世界旋转
			for (int i = 0; i < SmplToHuman.Length; i++)
			{
				if (srcJoints[i] == null || selfJoints[i] == null)
					continue;
				
				// 计算动作捕捉旋转：
				// 1. 计算SMPL关节相对于标准SMPL模型根节点的旋转变化
				// 2. 从SMPL骨骼的T-Pose空间，转换到目标骨骼的T-Pose空间，进而消除Bind-Pose的影响
				// 3. 结合目标关节的初始旋转，得到目标世界旋转
				Quaternion mocapRot =
					selfInitRotation *
					(srcJoints[i].rotation * Quaternion.Inverse(srcJointsInitRotation[i])) *
					selfJointsInitRotation[i];
				
				// 存储计算得到的世界旋转到中间关节姿势中
				midJoints[i].worldRotation = mocapRot;
			}
			
			// 计算中间关节的局部旋转
			ComputeMidLocalRotations();
			
			// 第二阶段：将带权重的局部旋转应用到目标角色的关节上
			for (int i = 0; i < SmplToHuman.Length; i++)
			{
				if (srcJoints[i] == null || selfJoints[i] == null)
					continue;
				
				if (!affectRootRotation && i is 0) continue;

				// 根据关节索引获取对应半身的权重
				float bodyPartWeight = 1f;
				if (System.Array.IndexOf(UpperBodyIndices, i) >= 0)
				{
					bodyPartWeight = upperBodyWeight;
				}
				else if (System.Array.IndexOf(LowerBodyIndices, i) >= 0)
				{
					bodyPartWeight = lowerBodyWeight;
				}
				// 计算最终权重：关节权重 * 全局权重 * 半身权重
				float w = jointsInfo[i].weight * globalWeight * bodyPartWeight;
				if (w <= 0f) continue;

				// 获取目标关节当前的局部旋转（动画控制器控制的旋转）
				Quaternion animatorRot = selfJoints[i].localRotation;
				
				// 根据权重应用旋转：
				// - 如果权重为1，直接使用动作捕捉的局部旋转
				// - 否则，在动画控制器旋转和动作捕捉旋转之间进行插值
				selfJoints[i].localRotation = (w >= 1f)
					? midJoints[i].localRotation
					: Quaternion.Slerp(animatorRot, midJoints[i].localRotation, w);
			}

			// 如果启用了强制上半身挺直且全局权重大于0
			if (forceUpperBodyUpright && globalWeight > 0)
			{
				// 获取脊柱关节（索引3）
				var joint = selfJoints[3];
				Quaternion rot = joint.rotation;
				rot.x = -midJoints[3].worldRotation.x;
				joint.rotation = rot;
				selfJoints[3] = joint;
			}
		}
		
		/// <summary>
		/// 计算中间关节的局部旋转
		/// 根据关节的世界旋转和其父关节的世界旋转计算得到
		/// </summary>
		private void ComputeMidLocalRotations()
		{
			// 遍历所有中间关节
			for (int i = 0; i < midJoints.Count; i++)
			{
				// 获取当前关节的父关节索引
				int parent = ParentIndex[i];

				if (parent < 0)
				{
					// 根关节（Hips）的局部旋转等于其世界旋转
					midJoints[i].localRotation = midJoints[i].worldRotation;
				}
				else
				{
					// 子关节的局部旋转 = 父关节世界旋转的逆 * 子关节的世界旋转
					midJoints[i].localRotation =
						Quaternion.Inverse(midJoints[parent].worldRotation) *
						midJoints[i].worldRotation;
				}
			}
		}

		/// <summary>
		/// 设置初始位置和缩放比例
		/// 获取标准SMPL模型和目标角色的根节点（臀部）位置，并计算它们之间的缩放比例
		/// </summary>
		private void SetInitPosition()
		{
			// 获取标准SMPL模型和自身（目标角色）的臀部骨骼
			srcRoot = srcAnimator.GetBoneTransform(HumanBodyBones.Hips);
			selfRoot = selfAnimator.GetBoneTransform(HumanBodyBones.Hips);

			if (srcRoot == null || selfRoot == null)
			{
				Debug.LogError("[MoCapSrc] Hips bone missing.");
				return;
			}

			// 记录标准SMPL模型和自身（目标角色）臀部的初始位置
			srcInitPosition = srcRoot.position;
			selfInitPosition = selfRoot.position;

			// 计算标准SMPL模型和自身（目标角色）的高度（从根节点到臀部的Y轴距离）
			float srcHeight = srcRoot.position.y - srcRoot.root.position.y;
			float selfHeight = selfRoot.position.y - selfRoot.root.position.y;

			if (Mathf.Abs(srcHeight) < 1e-4f)
			{
				Debug.LogWarning("[MoCapSrc] Invalid source height, scale fallback to 1.");
				scale = 1f;
			}
			else
			{
				// 缩放比例 = 目标角色高度 / 标准SMPL模型高度
				scale = selfHeight / srcHeight;
			}
		}

		/// <summary>
		/// 应用根节点位置，将标准SMPL模型的位置变化应用到目标角色
		/// </summary>
		private void SetPosition()
		{
			if (!affectRootPosition) return;

			// 计算目标角色的新位置：
			// 1. 计算标准SMPL模型根节点的位置变化
			// 2. 根据缩放比例调整位置变化
			// 3. 将调整后的位置变化应用到目标角色的初始位置上
			selfRoot.position =
				(srcRoot.position - srcInitPosition) * scale + selfInitPosition;
		}
	}
}
