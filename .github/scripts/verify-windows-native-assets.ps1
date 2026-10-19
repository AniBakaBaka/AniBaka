param(
    [string]$BundleDirectory = 'build/windows/x64/runner/Release'
)

$ErrorActionPreference = 'Stop'
$libraryPath = Join-Path $BundleDirectory 'ech_http.dll'
if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
    throw "Missing native ECH library in Windows bundle: $libraryPath"
}
$libraryPath = (Resolve-Path -LiteralPath $libraryPath).Path

if (-not ('AniBaka.NativeAssetsVerifier' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AniBaka {
    public static class NativeAssetsVerifier {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr library, string name);
        [DllImport("kernel32.dll")]
        private static extern bool FreeLibrary(IntPtr library);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate IntPtr CreateClient();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void DestroyClient(IntPtr client);

        public static void Verify(string path) {
            // Resolve dependencies only from the bundle and Windows default
            // directories, so a developer's PATH cannot mask a missing DLL.
            IntPtr library = LoadLibraryExW(path, IntPtr.Zero, 0x100 | 0x1000);
            if (library == IntPtr.Zero) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load " + path);
            }
            try {
                foreach (string symbol in new[] {
                    "eh_version", "eh_client_create", "eh_client_destroy",
                    "eh_request_start", "eh_request_acknowledge", "eh_request_destroy"
                }) {
                    if (GetProcAddress(library, symbol) == IntPtr.Zero) {
                        throw new InvalidOperationException("Missing native ECH symbol: " + symbol);
                    }
                }
                var create = (CreateClient)Marshal.GetDelegateForFunctionPointer(
                    GetProcAddress(library, "eh_client_create"), typeof(CreateClient));
                var destroy = (DestroyClient)Marshal.GetDelegateForFunctionPointer(
                    GetProcAddress(library, "eh_client_destroy"), typeof(DestroyClient));
                IntPtr client = create();
                if (client == IntPtr.Zero) {
                    throw new InvalidOperationException("Native ECH client initialization failed.");
                }
                destroy(client);
            } finally {
                FreeLibrary(library);
            }
        }
    }
}
'@
}

[AniBaka.NativeAssetsVerifier]::Verify($libraryPath)
Write-Host 'Windows ECH library loaded and native client initialized successfully.'
