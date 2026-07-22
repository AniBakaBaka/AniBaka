#include "flutter_window.h"

#include <optional>

#include <windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  WriteStartupLog("FlutterWindow::OnCreate entered");
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  WriteStartupLog("Flutter view controller constructed");
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  WriteStartupLog("Flutter plugins registered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  shown_ = false;

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->OnFirstFrame();
  });

  // If Flutter fails to produce a first frame, expose the native host instead
  // of leaving an invisible background process.
  SetTimer(GetHandle(), kFallbackShowTimerId, 15000, nullptr);

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnFirstFrame() {
  KillTimer(GetHandle(), kFallbackShowTimerId);
  WriteStartupLog("First Flutter frame rendered");
  EnsureVisible();
}

void FlutterWindow::EnsureVisible() {
  if (shown_) return;
  shown_ = true;
  Show();
  WriteStartupLog("Native window shown");
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle the recovery timer before plugins can consume WM_TIMER.
  if (message == WM_TIMER && wparam == kFallbackShowTimerId) {
    KillTimer(GetHandle(), kFallbackShowTimerId);
    WriteStartupLog("First-frame timeout; showing native host window");
    EnsureVisible();

    const std::wstring warning =
        L"Baka 启动超时。请关闭应用，并将以下日志文件提供给开发者：\n\n" +
        GetStartupLogPath();
    ::MessageBoxW(hwnd, warning.c_str(), L"Baka 启动超时",
                  MB_OK | MB_ICONWARNING);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
