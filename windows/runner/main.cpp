#include <bitsdojo_window_windows/bitsdojo_window_plugin.h>
auto bdw = bitsdojo_window_configure(BDW_CUSTOM_FRAME | BDW_HIDE_ON_STARTUP);

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include <filesystem>
#include <fstream>

#include "flutter_window.h"
#include "utils.h"

// Writes GpuPreference=2 (high-performance / discrete GPU) for this exe
// into HKCU\Software\Microsoft\DirectX\UserGpuPreferences so Windows
// routes the process to the discrete GPU on dual-GPU systems.
static void SetDiscreteGpuPreference() {
  wchar_t exe_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) return;

  HKEY hKey;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER,
                        L"Software\\Microsoft\\DirectX\\UserGpuPreferences",
                        0, nullptr, 0, KEY_SET_VALUE, nullptr, &hKey,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  ::RegSetValueExW(hKey, exe_path, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(L"GpuPreference=2"),
                   sizeof(L"GpuPreference=2"));
  ::RegCloseKey(hKey);
}

// Returns path to a sentinel file used to detect whether the previous
// launch failed to reach a visible state.  Stored in %TEMP% so that it
// survives uninstall/reinstall but is cleaned up by the OS over time.
static std::wstring GetStartupSentinelPath() {
  wchar_t temp_dir[MAX_PATH];
  if (::GetTempPathW(MAX_PATH, temp_dir) == 0) {
    return L"";
  }
  return std::wstring(temp_dir) + L"baka_startup.sentinel";
}

// If the sentinel file exists, the previous launch never reached a
// visible state (the file is deleted once the window is shown).
// In that case we append --purge-persistent-cache so the Flutter engine
// discards any corrupted shader / SkSL cache that may have been left
// behind by a GPU driver change.
static void CheckAndPurgeCache(std::vector<std::string>& args) {
  const auto sentinel = GetStartupSentinelPath();
  if (sentinel.empty()) return;

  if (std::filesystem::exists(sentinel)) {
    // Previous launch failed — request cache purge.
    bool has_purge = false;
    for (const auto& a : args) {
      if (a == "--purge-persistent-cache") {
        has_purge = true;
        break;
      }
    }
    if (!has_purge) {
      args.push_back("--purge-persistent-cache");
    }
  }

  // (Re)create the sentinel so we can detect failure on the next launch.
  std::ofstream(sentinel, std::ios::trunc).close();
}

// Delete the sentinel file — called once the window has been shown
// successfully, so the next launch knows everything is fine.
static void ClearStartupSentinel() {
  const auto sentinel = GetStartupSentinelPath();
  if (!sentinel.empty()) {
    std::error_code ec;
    std::filesystem::remove(sentinel, ec);
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  SetDiscreteGpuPreference();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // If the previous launch failed to show a window, purge the persistent
  // shader cache to recover from GPU-driver-change corruption.
  CheckAndPurgeCache(command_line_arguments);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Baka", origin, size)) {
    ::MessageBoxW(
        nullptr,
        L"应用启动失败。这可能是由于 GPU 驱动变更导致的着色器缓存损坏。请再次双击启动，应用会自动清理缓存并重试。如果问题仍然存在，请尝试更新显卡驱动。",
        L"Baka 启动错误",
        MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Window was shown and closed normally — clear the sentinel.
  ClearStartupSentinel();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
