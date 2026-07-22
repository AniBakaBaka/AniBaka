#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <shlobj.h>
#include <stdio.h>
#include <windows.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>

namespace {

std::wstring ResolveStartupLogPath() {
  PWSTR documents_path = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_Documents, KF_FLAG_DEFAULT,
                                       nullptr, &documents_path))) {
    std::filesystem::path log_path(documents_path);
    ::CoTaskMemFree(documents_path);
    return (log_path / L"baka" / L"logs" / L"startup.log").wstring();
  }

  wchar_t temp_path[MAX_PATH];
  if (::GetTempPathW(MAX_PATH, temp_path) != 0) {
    return (std::filesystem::path(temp_path) / L"baka_startup.log").wstring();
  }
  return L"baka_startup.log";
}

std::string StartupTimestamp() {
  const auto now = std::chrono::system_clock::now();
  const std::time_t time = std::chrono::system_clock::to_time_t(now);
  std::tm local_time = {};
  localtime_s(&local_time, &time);

  std::ostringstream stream;
  stream << std::put_time(&local_time, "%Y-%m-%d %H:%M:%S");
  return stream.str();
}

}  // namespace

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length <= 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::wstring GetStartupLogPath() {
  static const std::wstring path = ResolveStartupLogPath();
  return path;
}

void InitializeStartupLog() {
  const std::filesystem::path path(GetStartupLogPath());
  std::error_code error;
  std::filesystem::create_directories(path.parent_path(), error);
  std::ofstream(path, std::ios::trunc)
      << StartupTimestamp() << " [INFO] Native startup log initialized\n";
}

void WriteStartupLog(const std::string& message) {
  std::ofstream(GetStartupLogPath(), std::ios::app)
      << StartupTimestamp() << " [INFO] " << message << '\n';
}
