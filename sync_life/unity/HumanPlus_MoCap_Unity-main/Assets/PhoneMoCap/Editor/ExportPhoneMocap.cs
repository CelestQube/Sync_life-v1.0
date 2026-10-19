using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using HumanPlusMoCap.Scripts;

public static class ExportPhoneMocap
{
    // Editor smoke check only; Android embedding must still be checked on the phone.
    public static void ValidateScene()
    {
        var scene = EditorBuildSettings.scenes.First(item => item.enabled);
        EditorSceneManager.OpenScene(scene.path);
        var manager = UnityEngine.Object.FindObjectOfType<MoCapManager>();
        if (manager == null) throw new InvalidOperationException("Scene has no active MoCapManager.");
        manager.SendMessage("Awake", SendMessageOptions.RequireReceiver);
        if (!manager.PhonePoseReady || !manager.ApplyPhonePose(new float[72]))
            throw new InvalidOperationException("Scene cannot accept the 24-joint phone pose.");
        var invalid = new float[72];
        invalid[71] = float.NaN;
        if (manager.ApplyPhonePose(invalid) || manager.ApplyPhonePose(new float[3]))
            throw new InvalidOperationException("Scene accepted an invalid phone pose.");
        var camera = Camera.main;
        if (camera == null || !camera.isActiveAndEnabled)
            throw new InvalidOperationException("Scene has no active main camera.");
        var renderers = UnityEngine.Object.FindObjectsOfType<SkinnedMeshRenderer>();
        var planes = GeometryUtility.CalculateFrustumPlanes(camera);
        if (!renderers.Any(item => item.enabled && item.sharedMesh != null && GeometryUtility.TestPlanesAABB(planes, item.bounds)))
            throw new InvalidOperationException("No character mesh is visible to the main camera.");

        var preview = Path.GetFullPath(Path.Combine(Application.dataPath, "../phone-scene-preview.png"));
        var previousTarget = camera.targetTexture;
        var previousActive = RenderTexture.active;
        var previousAspect = camera.aspect;
        var target = new RenderTexture(600, 800, 24);
        var pixels = new Texture2D(600, 800, TextureFormat.RGB24, false);
        try
        {
            camera.targetTexture = target;
            camera.aspect = 600f / 800f;
            camera.Render();
            RenderTexture.active = target;
            pixels.ReadPixels(new Rect(0, 0, 600, 800), 0, 0);
            pixels.Apply();
            File.WriteAllBytes(preview, pixels.EncodeToPNG());
        }
        finally
        {
            camera.targetTexture = previousTarget;
            camera.aspect = previousAspect;
            RenderTexture.active = previousActive;
            target.Release();
            UnityEngine.Object.DestroyImmediate(target);
            UnityEngine.Object.DestroyImmediate(pixels);
        }
        Debug.Log("PHONE_SCENE_VALIDATED: 24 joints, valid/invalid pose checks, visible character, editor preview " + preview);
    }

    // Calls the same entry point as Flutter > Export Android (Debug).
    // Run in a staging Flutter workspace: the plugin replaces android/unityLibrary.
    public static void ExportWithFlutterPlugin()
    {
        if (Application.unityVersion != "2022.3.22f1")
            throw new InvalidOperationException("Use official Unity 2022.3.22f1 for this export.");
        PlayerSettings.SetScriptingBackend(BuildTargetGroup.Android, ScriptingImplementation.IL2CPP);
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
        FlutterUnityIntegration.Editor.Build.DoBuildAndroidLibraryDebug();
    }

    // Export to staging first; the existing Android library remains available if export fails.
    public static void Export()
    {
        var root = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
        var staging = Path.Combine(root, "build/phone-unity-export");
        var arguments = Environment.GetCommandLineArgs();
        var pathArgument = Array.IndexOf(arguments, "-phoneMocapExportPath");
        if (pathArgument >= 0 && pathArgument + 1 < arguments.Length)
            staging = Path.GetFullPath(arguments[pathArgument + 1]);
        PlayerSettings.SetScriptingBackend(BuildTargetGroup.Android, ScriptingImplementation.IL2CPP);
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
        EditorUserBuildSettings.exportAsGoogleAndroidProject = true;
        var scenes = EditorBuildSettings.scenes.Where(scene => scene.enabled).Select(scene => scene.path).ToArray();
        if (scenes.Length == 0) throw new InvalidOperationException("No enabled Unity scene");
        var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions {
            scenes = scenes, target = BuildTarget.Android, locationPathName = staging,
            options = BuildOptions.AcceptExternalModificationsToPlayer
        });
        if (report.summary.result != BuildResult.Succeeded) throw new InvalidOperationException("Unity export failed");
        Debug.Log("PHONE_MOCAP_EXPORT_SUCCEEDED: " + staging);
    }
}
