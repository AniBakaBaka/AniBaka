#include <bitsdojo_window_windows/bitsdojo_window_plugin.h>
auto bdw = bitsdojo_window_configure(BDW_CUSTOM_FRAME);

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kAniBakaRegistryKey[] = L"Software\\AniBaka";
constexpr wchar_t kAniBakaInstanceMutex[] =
    L"Local\\AniBakaBaka.AniBaka.SingleInstance";
constexpr wchar_t kFlutterWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr DWORD kGpuMigrationVersion = 1;

static void ActivateExistingWindow() {
  HWND window = ::FindWindowW(kFlutterWindowClass, L"Baka");
  if (window == nullptr || !::IsWindowVisible(window)) {
    return;
  }

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
}

// AniBaka 5.0.1/5.0.2 wrote GpuPreference=2 on every launch. Remove that
// legacy value once, then leave all future user GPU choices untouched.
static bool MigrateLegacyGpuPreference() {
  wchar_t exe_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return false;
  }

  HKEY app_key;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kAniBakaRegistryKey, 0, nullptr, 0,
                        KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &app_key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }

  const std::wstring migration_value =
      std::wstring(L"LegacyGpuPreferenceMigration:") + exe_path;
  DWORD migration_version = 0;
  DWORD version_size = sizeof(migration_version);
  if (::RegGetValueW(app_key, nullptr, migration_value.c_str(),
                     RRF_RT_REG_DWORD, nullptr, &migration_version,
                     &version_size) == ERROR_SUCCESS &&
      migration_version >= kGpuMigrationVersion) {
    ::RegCloseKey(app_key);
    return false;
  }

  bool removed = false;
  HKEY gpu_key;
  if (::RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\DirectX\\UserGpuPreferences", 0,
          KEY_QUERY_VALUE | KEY_SET_VALUE, &gpu_key) == ERROR_SUCCESS) {
    wchar_t preference[64] = {};
    DWORD preference_size = sizeof(preference);
    if (::RegGetValueW(gpu_key, nullptr, exe_path, RRF_RT_REG_SZ, nullptr,
                       preference, &preference_size) == ERROR_SUCCESS) {
      std::wstring value(preference);
      while (!value.empty() &&
             (value.back() == L';' || value.back() == L' ')) {
        value.pop_back();
      }
      if (value == L"GpuPreference=2") {
        removed = ::RegDeleteValueW(gpu_key, exe_path) == ERROR_SUCCESS;
      }
    }
    ::RegCloseKey(gpu_key);
  }

  ::RegSetValueExW(app_key, migration_value.c_str(), 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&kGpuMigrationVersion),
                   sizeof(kGpuMigrationVersion));
  ::RegCloseKey(app_key);
  return removed;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kAniBakaInstanceMutex);
  if (instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    WriteStartupLog("Existing AniBaka instance detected; exiting duplicate");
    ActivateExistingWindow();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  InitializeStartupLog();
  WriteStartupLog("Process started");
  if (instance_mutex == nullptr) {
    WriteStartupLog("Single-instance guard unavailable; continuing startup");
  }

  if (MigrateLegacyGpuPreference()) {
    WriteStartupLog("Removed legacy forced high-performance GPU preference");
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WriteStartupLog("COM initialized");

  flutter::DartProject project(L"data");
  project.set_gpu_preference(flutter::GpuPreference::NoPreference);
  WriteStartupLog("Flutter engine using the Windows system GPU preference");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  WriteStartupLog("Creating Flutter window");
  if (!window.Create(L"Baka", origin, size)) {
    WriteStartupLog("Flutter window creation failed");
    const std::wstring error_message =
        L"应用启动失败。请将以下日志文件提供给开发者：\n\n" +
        GetStartupLogPath();
    ::MessageBoxW(
        nullptr, error_message.c_str(), L"Baka 启动错误",
        MB_OK | MB_ICONERROR | MB_TOPMOST);
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  WriteStartupLog("Flutter window created");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  WriteStartupLog("Process exiting normally");
  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
