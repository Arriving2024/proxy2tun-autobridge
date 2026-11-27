using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Proxy2Tun.Desktop {
    internal sealed class PayloadManifest {
        public string version { get; set; }
        public PayloadFile[] files { get; set; }
    }
    internal sealed class PayloadFile {
        public string path { get; set; }
        public string sha256 { get; set; }
    }
    internal sealed class Candidate {
        public string Key { get; set; }
        public string DisplayName { get; set; }
        public string Endpoint { get; set; }
        public override string ToString() { return String.IsNullOrWhiteSpace(DisplayName) ? Endpoint : DisplayName; }
    }
    internal sealed class DesktopStatus {
        public string Status { get; set; }
        public string Message { get; set; }
        public Candidate[] Candidates { get; set; }
        public string SelectedKey { get; set; }
        public string SelectedDisplayName { get; set; }
        public string SelectedEndpoint { get; set; }
        public string UpdatedUtc { get; set; }
    }

    internal static class Program {
        internal const string Version = "0.3.1";
        internal const string PayloadResource = "Proxy2Tun.Payload.zip";
        internal static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };

        [STAThread]
        private static int Main(string[] args) {
            if (Array.IndexOf(args, "--self-test") >= 0) return SelfTest();
            bool render = Array.IndexOf(args, "--render-preview") >= 0;
            bool preview = render || Array.IndexOf(args, "--preview") >= 0;
            try {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                try { SetProcessDPIAware(); } catch { }
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Proxy2TUN-AutoBridge", "desktop-" + Version);
                if (render) {
                    string output = RenderOutput(args);
                    CheckNoReparse(output);
                    Directory.CreateDirectory(Path.GetDirectoryName(output));
                    using (MainForm form = new MainForm(root, true, true)) {
                        // Render our own preview component without touching an
                        // existing window or dispatching user input.
                        form.ShowInTaskbar = false; form.Opacity = 0;
                        form.Show(); Application.DoEvents(); form.PerformLayout();
                        Console.WriteLine("Preview layout: " + form.Size + "; system text height=" + form.Font.Height);
                        using (Bitmap bitmap = new Bitmap(form.Width, form.Height)) {
                            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                            bitmap.Save(output, System.Drawing.Imaging.ImageFormat.Png);
                        }
                        form.Hide();
                    }
                    Console.WriteLine("Rendered UI preview without elevation, backend or network changes: " + output);
                    return 0;
                }
                if (!preview) {
                    EnsurePayload(root);
                    string mutexName = MutexName(root);
                    try {
                        using (Mutex already = Mutex.OpenExisting(mutexName)) {
                            MessageBox.Show("全局代理助手已在运行，请在任务栏右下角的托盘中打开它。", "Proxy2TUN", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return 0;
                        }
                    } catch (WaitHandleCannotBeOpenedException) { }
                    catch (UnauthorizedAccessException) {
                        MessageBox.Show("全局代理助手已在此会话中运行，请在右下角托盘打开。", "Proxy2TUN", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return 0;
                    }
                    if (!IsAdministrator()) {
                        if (Array.IndexOf(args, "--elevated") >= 0) throw new InvalidOperationException("创建 TUN 需要 Windows 管理员权限。请允许 Windows 权限提示后再打开。");
                        try {
                            Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--elevated") { UseShellExecute = true, Verb = "runas", WorkingDirectory = Path.GetDirectoryName(Application.ExecutablePath) });
                            return 0;
                        } catch (Win32Exception ex) {
                            if (ex.NativeErrorCode == 1223) {
                                MessageBox.Show("已取消管理员权限，尚未启动全局代理。需要时再次双击程序即可。", "Proxy2TUN", MessageBoxButtons.OK, MessageBoxIcon.Information);
                                return 2;
                            }
                            throw;
                        }
                    }
                    bool created;
                    using (Mutex instance = new Mutex(true, mutexName, out created)) {
                        if (!created) {
                            MessageBox.Show("全局代理助手已在运行，请从任务栏右下角的托盘打开。", "Proxy2TUN");
                            return 0;
                        }
                        try { Application.Run(new MainForm(root, false)); }
                        finally { instance.ReleaseMutex(); }
                    }
                } else Application.Run(new MainForm(root, true));
                return 0;
            } catch (Exception ex) {
                if (render) { Console.Error.WriteLine("Could not render UI preview: " + ex.Message); return 1; }
                MessageBox.Show("无法启动全局代理助手。\r\n\r\n" + ex.Message, "Proxy2TUN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        internal static bool IsAdministrator() {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        internal static string RenderOutput(string[] args) {
            int index = Array.IndexOf(args, "--render-preview");
            if (index < 0 || index + 1 >= args.Length || String.IsNullOrWhiteSpace(args[index + 1]) || args[index + 1].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException("--render-preview requires a PNG output path.");
            string output = Path.GetFullPath(args[index + 1]);
            if (!String.Equals(Path.GetExtension(output), ".png", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("UI preview output must use the .png extension.");
            return output;
        }
        internal static string MutexName(string root) { return "Local\\Proxy2Tun.Desktop." + Hash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant())).Substring(0, 20); }
        internal static string Hash(byte[] bytes) {
            using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        internal static string HashFile(string path) {
            using (SHA256 sha = SHA256.Create()) using (FileStream input = File.OpenRead(path)) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
        }
        internal static string ReadSharedText(string path) {
            // Status is published with File.Replace. Permit replacement while
            // reading our open snapshot instead of blocking the controller.
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true)) return reader.ReadToEnd();
        }
        internal static string Quote(string argument) {
            StringBuilder text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in argument) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { text.Append('\\', slashes * 2 + 1); text.Append(c); slashes = 0; continue; }
                text.Append('\\', slashes); slashes = 0; text.Append(c);
            }
            text.Append('\\', slashes * 2); text.Append('"');
            return text.ToString();
        }
        internal static void CheckNoReparse(string path) {
            string current = Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current)) {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("程序目录不能经过符号链接或目录联接，请在普通本地目录中运行。");
                DirectoryInfo parent = Directory.GetParent(current);
                current = parent == null ? null : parent.FullName;
            }
        }
        internal static string SafeChild(string root, string relative) {
            if (String.IsNullOrWhiteSpace(relative) || relative.IndexOf(':') >= 0 || relative.IndexOf('\0') >= 0 || Path.IsPathRooted(relative)) throw new InvalidDataException("安装包路径无效。");
            string[] parts = relative.Replace('\\', '/').Split('/');
            foreach (string part in parts) if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" ")) throw new InvalidDataException("安装包包含不安全的路径。");
            string canonicalRoot = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            string result = Path.GetFullPath(Path.Combine(canonicalRoot, relative.Replace('/', '\\')));
            if (!result.StartsWith(canonicalRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包路径越界。");
            return result;
        }
        private static byte[] ReadEntry(ZipArchiveEntry entry, int maximum) {
            if (entry.Length < 0 || entry.Length > maximum) throw new InvalidDataException("安装包文件大小超出限制。");
            using (Stream source = entry.Open()) using (MemoryStream output = new MemoryStream()) {
                byte[] buffer = new byte[16384]; int count;
                while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
                    if (output.Length + count > maximum) throw new InvalidDataException("安装包文件大小超出限制。");
                    output.Write(buffer, 0, count);
                }
                return output.ToArray();
            }
        }
        internal static void EnsurePayload(string root) {
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResource)) {
                if (resource == null) throw new InvalidDataException("此程序缺少内嵌运行文件，请重新获取完整版本。");
                ExtractPayload(root, resource);
            }
        }
        internal static void ExtractPayload(string root, Stream resource) {
            CheckNoReparse(root);
            using (ZipArchive zip = new ZipArchive(resource, ZipArchiveMode.Read, true)) {
                ZipArchiveEntry manifestEntry = zip.GetEntry("desktop-payload.json");
                if (manifestEntry == null) throw new InvalidDataException("安装包缺少校验清单。");
                PayloadManifest manifest = Json.Deserialize<PayloadManifest>(Encoding.UTF8.GetString(ReadEntry(manifestEntry, 4 * 1024 * 1024)).TrimStart('\uFEFF'));
                if (manifest == null || manifest.version != Version || manifest.files == null || manifest.files.Length < 1 || manifest.files.Length > 256) throw new InvalidDataException("安装包版本或清单无效。");
                Dictionary<string, byte[]> verified = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
                HashSet<string> entryNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (ZipArchiveEntry entry in zip.Entries) {
                    if (entry.FullName.EndsWith("/")) { SafeChild(root, entry.FullName.TrimEnd('/')); continue; }
                    SafeChild(root, entry.FullName);
                    if (!entryNames.Add(entry.FullName.Replace('\\', '/'))) throw new InvalidDataException("安装包存在重复文件。");
                }
                foreach (PayloadFile file in manifest.files) {
                    if (file == null || file.sha256 == null || file.sha256.Length != 64) throw new InvalidDataException("文件校验信息无效。");
                    string destination = SafeChild(root, file.path);
                    string normalized = file.path.Replace('\\', '/');
                    if (verified.ContainsKey(normalized) || normalized.Equals("desktop-payload.json", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包清单存在重复文件。");
                    ZipArchiveEntry entry = zip.GetEntry(normalized);
                    if (entry == null) throw new InvalidDataException("安装包文件不完整。");
                    byte[] bytes = ReadEntry(entry, 8 * 1024 * 1024);
                    if (!String.Equals(Hash(bytes), file.sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包校验失败，请重新下载。");
                    CheckNoReparse(destination);
                    if (File.Exists(destination) && !String.Equals(HashFile(destination), file.sha256, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("已安装的程序文件被修改，已停止覆盖。请保留原文件并将新版本安装到独立目录。");
                    verified.Add(normalized, bytes);
                }
                if (entryNames.Count != verified.Count + 1) throw new InvalidDataException("安装包含有清单之外的文件。");
                // Validate every file before creating any source file. Never overwrite existing code.
                Directory.CreateDirectory(root);
                foreach (KeyValuePair<string, byte[]> item in verified) {
                    string destination = SafeChild(root, item.Key);
                    CheckNoReparse(destination);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    CheckNoReparse(destination);
                    if (File.Exists(destination)) continue;
                    using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(item.Value, 0, item.Value.Length);
                    if (HashFile(destination) != Hash(item.Value)) throw new IOException("写入运行文件后校验失败。");
                }
                string markerPath = SafeChild(root, ".proxy2tun-desktop-install.json");
                CheckNoReparse(markerPath);
                string marker = Json.Serialize(new Dictionary<string, object> {
                    { "project", "Proxy2TUN-AutoBridge-Desktop" }, { "schemaVersion", 1 },
                    { "version", Version }, { "installRoot", Path.GetFullPath(root).TrimEnd('\\') }, { "files", manifest.files }
                });
                if (File.Exists(markerPath)) {
                    Dictionary<string, object> previous = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(markerPath, Encoding.UTF8));
                    if (previous == null || !previous.ContainsKey("project") || !previous.ContainsKey("installRoot") ||
                        !String.Equals(Convert.ToString(previous["project"]), "Proxy2TUN-AutoBridge-Desktop", StringComparison.Ordinal) ||
                        !String.Equals(Convert.ToString(previous["installRoot"]), Path.GetFullPath(root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                        throw new IOException("已有安装记录不属于当前程序目录，已停止覆盖。");
                    if (!previous.ContainsKey("version") || Convert.ToString(previous["version"]) != Version || !previous.ContainsKey("schemaVersion") || Convert.ToInt32(previous["schemaVersion"]) != 1 ||
                        !previous.ContainsKey("files") || Json.Serialize(previous["files"]) != Json.Serialize(manifest.files))
                        throw new IOException("已有安装清单发生变化，已停止覆盖。");
                } else {
                    byte[] markerBytes = new UTF8Encoding(false).GetBytes(marker);
                    using (FileStream output = new FileStream(markerPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(markerBytes, 0, markerBytes.Length);
                }
            }
        }

        internal static string StateTitle(string state) {
            switch (state ?? "") {
                case "Preparing": return "正在准备运行组件";
                case "Scanning": return "正在识别代理软件";
                case "WaitingForProxy": return "等待代理软件连接";
                case "ChoiceRequired": return "请选择要绑定的代理软件";
                case "ExistingTun": return "检测到已有 TUN 正在运行";
                case "Starting": return "正在启动全局代理";
                case "Verifying": return "正在验证 DNS 和网络转发";
                case "Running": return "全局代理已连接，网络验证成功";
                case "Backoff": return "连接中断，正在有限重试";
                case "RecoveryPaused": return "自动恢复已暂停";
                case "Stopped": return "全局代理已停止";
                case "Error": return "暂时无法启动全局代理";
                default: return "正在读取运行状态";
            }
        }
        internal static bool IsFreshStatus(string timestamp, DateTime utcNow) {
            DateTime updated;
            if (String.IsNullOrWhiteSpace(timestamp) || !DateTime.TryParse(timestamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out updated)) return false;
            double age = (utcNow.ToUniversalTime() - updated).TotalSeconds;
            return age >= -30 && age <= 120;
        }
        internal static bool IsVerifiedRunning(string state, bool backendAlive, string updatedUtc, DateTime utcNow) {
            return state == "Running" && backendAlive && IsFreshStatus(updatedUtc, utcNow);
        }
        private static int SelfTest() {
            int assertions = 0;
            Action<bool, string> check = delegate(bool condition, string label) { if (!condition) throw new Exception(label); assertions++; };
            try {
                check(Quote("") == "\"\"", "empty argument");
                check(Quote("a b") == "\"a b\"", "space argument");
                check(Quote("a\"b") == "\"a\\\"b\"", "quote argument");
                check(Quote("C:\\a b\\") == "\"C:\\a b\\\\\"", "trailing slash");
                check(RenderOutput(new[] { "--render-preview", Path.Combine(Path.GetTempPath(), "preview layout.png") }).EndsWith("preview layout.png", StringComparison.Ordinal), "render path argument");
                bool missingRenderPath = false;
                try { RenderOutput(new[] { "--render-preview" }); } catch (ArgumentException) { missingRenderPath = true; }
                check(missingRenderPath, "render requires output path");
                check(StateTitle("Running").IndexOf("验证成功", StringComparison.Ordinal) >= 0, "running status");
                check(StateTitle("Verifying").IndexOf("成功", StringComparison.Ordinal) < 0, "verification not success");
                check(StateTitle("RecoveryPaused").IndexOf("暂停", StringComparison.Ordinal) >= 0, "paused status");
                DateTime now = new DateTime(2026, 11, 2, 12, 0, 0, DateTimeKind.Utc);
                check(IsVerifiedRunning("Running", true, now.ToString("o"), now), "running with live backend and fresh state");
                check(!IsVerifiedRunning("Running", false, now.ToString("o"), now), "dead backend is not success");
                check(!IsVerifiedRunning("Verifying", true, now.ToString("o"), now), "live backend is not verified network");
                check(!IsVerifiedRunning("Running", true, now.AddSeconds(-121).ToString("o"), now), "expired state is not success");
                check(!IsVerifiedRunning("Running", true, "not-a-timestamp", now), "malformed time is not success");
                check(!IsVerifiedRunning("Running", true, now.AddSeconds(31).ToString("o"), now), "future state is not success");
                check(IsVerifiedRunning("Running", true, now.AddSeconds(30).ToString("o"), now), "small clock skew tolerated");
                check(!IsVerifiedRunning("Running", true, null, now), "missing time is not success");
                DesktopStatus parsed = Json.Deserialize<DesktopStatus>("{\"Status\":\"ChoiceRequired\",\"Candidates\":[{\"Key\":\"fixture\",\"DisplayName\":\"Example\",\"Endpoint\":\"socks5://127.0.0.1:1\"}],\"SelectedEndpoint\":\"http://127.0.0.1:2\"}");
                check(parsed.Status == "ChoiceRequired" && parsed.Candidates.Length == 1 && parsed.Candidates[0].Key == "fixture", "backend selection contract");
                string root = Path.Combine(Path.GetTempPath(), "Proxy2TUN-self-test-" + Guid.NewGuid().ToString("N"));
                check(SafeChild(root, "desktop/Backend.ps1").StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase), "safe child");
                foreach (string invalid in new[] { "../escape.ps1", "a/../../escape", "C:\\escape.ps1", "a:stream", "a//b", "a./b", "a /b", "\\\\server\\share" }) {
                    bool rejected = false; try { SafeChild(root, invalid); } catch (InvalidDataException) { rejected = true; }
                    check(rejected, "reject " + invalid);
                }
                byte[] bytes = Encoding.UTF8.GetBytes("fixture");
                using (MemoryStream archive = new MemoryStream()) {
                    using (ZipArchive zip = new ZipArchive(archive, ZipArchiveMode.Create, true)) {
                        using (Stream output = zip.CreateEntry("desktop/Backend.ps1").Open()) output.Write(bytes, 0, bytes.Length);
                        string manifest = Json.Serialize(new PayloadManifest { version = Version, files = new[] { new PayloadFile { path = "desktop/Backend.ps1", sha256 = Hash(bytes) } } });
                        using (StreamWriter writer = new StreamWriter(zip.CreateEntry("desktop-payload.json").Open(), new UTF8Encoding(false))) writer.Write(manifest);
                    }
                    archive.Position = 0; ExtractPayload(root, archive);
                    check(HashFile(Path.Combine(root, "desktop", "Backend.ps1")) == Hash(bytes), "payload installed");
                check(File.Exists(Path.Combine(root, ".proxy2tun-desktop-install.json")), "desktop uninstall marker recorded");
                    archive.Position = 0; ExtractPayload(root, archive);
                    check(true, "unchanged install accepted");
                    File.WriteAllText(Path.Combine(root, "desktop", "Backend.ps1"), "locally modified");
                    archive.Position = 0; bool refused = false;
                    try { ExtractPayload(root, archive); } catch (IOException) { refused = true; }
                    check(refused, "modified file not overwritten");
                    check(File.ReadAllText(Path.Combine(root, "desktop", "Backend.ps1")) == "locally modified", "modified bytes retained");
                }
                // Remove only this test's known files and empty, random test directories.
                File.Delete(Path.Combine(root, "desktop", "Backend.ps1"));
                File.Delete(Path.Combine(root, ".proxy2tun-desktop-install.json"));
                Directory.Delete(Path.Combine(root, "desktop")); Directory.Delete(root);
                Console.WriteLine("PASS " + assertions + " desktop self-tests. No elevation, proxy, TUN or external requests.");
                return 0;
            } catch (Exception ex) { Console.Error.WriteLine("FAIL desktop self-test: " + ex.Message); return 1; }
        }
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    }

    internal sealed class MainForm : Form {
        readonly string root, runtime;
        readonly bool preview;
        readonly Label headline = new Label(), detail = new Label(), endpoint = new Label();
        readonly Button start = new Button(), stop = new Button(), choose = new Button(), diagnostics = new Button();
        readonly ComboBox choices = new ComboBox();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer();
        readonly object logLock = new object();
        Process backend;
        ProcessJob job;
        DateTime backendStartedUtc;
        DesktopStatus state;
        string choiceSignature = "";
        bool busy, exitRequested, trayNotified;

        internal MainForm(string appRoot, bool isPreview, bool staticRender = false) {
            root = appRoot; runtime = Path.Combine(root, "runtime"); preview = isPreview;
            Text = "Proxy2TUN 全局代理助手" + (preview ? " · 界面预览" : "");
            Icon = SystemIcons.Shield;
            Font = new Font("Microsoft YaHei UI", 10F);
            ClientSize = new Size(680, 412); MinimumSize = new Size(640, 440);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(247, 249, 252);
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(26, 20, 26, 20), ColumnCount = 1, RowCount = 7 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            foreach (int height in new[] { 34, 28, 62, 56, 52, 48 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            Label title = new Label { Text = "Proxy2TUN 全局代理助手", Font = new Font(Font.FontFamily, 17F, FontStyle.Bold), Dock = DockStyle.Fill };
            Label subtitle = new Label { Text = "全局 TCP 代理 · 局域网直连", ForeColor = Color.FromArgb(80, 94, 115), Dock = DockStyle.Fill };
            headline.Text = "正在准备"; headline.Font = new Font(Font.FontFamily, 15F, FontStyle.Bold); headline.Dock = DockStyle.Fill; headline.TextAlign = ContentAlignment.MiddleLeft;
            detail.Text = "自动识别本机已运行的代理软件，并验证 DNS 与 HTTPS 转发。"; detail.Dock = DockStyle.Fill;
            endpoint.Text = ""; endpoint.Dock = DockStyle.Fill; endpoint.ForeColor = Color.FromArgb(70, 84, 105);
            FlowLayoutPanel selection = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            choices.DropDownStyle = ComboBoxStyle.DropDownList; choices.Width = 430; choices.Visible = false;
            choose.Text = "绑定此代理"; choose.Width = 120; choose.Height = 32; choose.Visible = false; choose.Click += ChooseClick;
            selection.Controls.Add(choices); selection.Controls.Add(choose);
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            start.Text = "开始 / 重试"; stop.Text = "停止全局代理"; diagnostics.Text = "导出诊断";
            foreach (Button button in new[] { start, stop, diagnostics }) { button.Width = 145; button.Height = 36; button.Margin = new Padding(0, 0, 12, 0); buttons.Controls.Add(button); }
            start.Click += async delegate {
                if (BackendAlive && state != null && state.Status == "RecoveryPaused") await StopAsync(false);
                await StartAsync();
            };
            stop.Click += async delegate { await StopAsync(false); };
            diagnostics.Click += async delegate { await ExportDiagnosticsAsync(); };
            Label note = new Label { Text = preview ? "界面预览：不会启动代理、创建 TUN 或更改网络。" : "关闭窗口会收至托盘；在托盘中选择“退出并停止”可退出。\r\n一般 UDP / QUIC 不支持；程序不会设置开机常驻。", Dock = DockStyle.Bottom, Height = 50, ForeColor = Color.FromArgb(100, 110, 125), Font = new Font(Font.FontFamily, 9F) };
            Panel statusPanel = new Panel { Dock = DockStyle.Fill }; statusPanel.Controls.Add(detail);
            layout.Controls.Add(title, 0, 0); layout.Controls.Add(subtitle, 0, 1); layout.Controls.Add(headline, 0, 2); layout.Controls.Add(statusPanel, 0, 3); layout.Controls.Add(endpoint, 0, 4); layout.Controls.Add(selection, 0, 5);
            Panel bottom = new Panel { Dock = DockStyle.Fill }; buttons.Dock = DockStyle.Top; buttons.Height = 40; bottom.Controls.Add(note); bottom.Controls.Add(buttons); layout.Controls.Add(bottom, 0, 6);
            Controls.Add(layout);
            AutoScaleMode = AutoScaleMode.None;
            // This UI is built in code rather than by a designer. Scale its
            // logical pixel dimensions once; fonts already use system DPI.
            using (Graphics metrics = CreateGraphics()) {
                float scale = metrics.DpiX / 96F;
                if (Math.Abs(scale - 1F) > 0.01F) Scale(new SizeF(scale, scale));
            }
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("显示助手", null, delegate { RestoreWindow(); });
            menu.Items.Add("停止全局代理", null, async delegate { await StopAsync(false); });
            menu.Items.Add("退出并停止", null, async delegate { await StopAsync(true); });
            tray.Icon = Icon; tray.Text = "Proxy2TUN 全局代理助手"; tray.ContextMenuStrip = menu; tray.Visible = !staticRender;
            tray.DoubleClick += delegate { RestoreWindow(); };
            poll.Interval = 1000; poll.Tick += delegate { RefreshStatus(); }; if (!staticRender) poll.Start();
            FormClosing += OnFormClosingRequested;
            Shown += async delegate {
                if (preview) ShowState(new DesktopStatus { Status = "WaitingForProxy", Message = "请先打开代理软件并连接节点；检测到可用的本地代理后，助手会自动绑定。" });
                else await StartAsync();
            };
        }

        bool BackendAlive { get { try { return backend != null && !backend.HasExited; } catch { return false; } } }
        ProcessStartInfo BackendInfo(string action) {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            string script = Path.Combine(root, "desktop", "Backend.ps1");
            return new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Program.Quote(script) + " -Action " + action) {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = root,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
        }
        async Task StartAsync() {
            if (busy || BackendAlive) return;
            if (preview) { ShowState(new DesktopStatus { Status = "Running", Message = "预览状态：此界面没有启动真实代理或进行网络验证。", SelectedKey = "preview", UpdatedUtc = DateTime.UtcNow.ToString("o") }); return; }
            busy = true; RefreshButtons(); ShowState(new DesktopStatus { Status = "Preparing", Message = "首次运行会下载并校验官方运行组件，请稍候。" });
            try {
                await Task.Run(delegate {
                    Program.CheckNoReparse(runtime); Directory.CreateDirectory(runtime);
                    if (backend != null) { backend.Dispose(); backend = null; }
                    if (job != null) { job.Dispose(); job = null; }
                    Process process = new Process { StartInfo = BackendInfo("Run") };
                    process.StartInfo.EnvironmentVariables["PROXY2TUN_DESKTOP_SHA256"] = Program.HashFile(Application.ExecutablePath);
                    process.OutputDataReceived += CaptureOutput; process.ErrorDataReceived += CaptureOutput;
                    backendStartedUtc = DateTime.UtcNow;
                    if (!process.Start()) throw new IOException("无法启动后台控制器。");
                    backend = process;
                    try { job = new ProcessJob(process); }
                    catch { try { if (!process.HasExited) process.Kill(); } catch { } throw; }
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                });
                state = null; choiceSignature = "";
            } catch (Exception ex) { ShowState(new DesktopStatus { Status = "Error", Message = ex.Message }); }
            finally { busy = false; RefreshButtons(); }
        }
        void CaptureOutput(object sender, DataReceivedEventArgs args) {
            if (args.Data == null) return;
            try {
                lock (logLock) {
                    string log = Path.Combine(runtime, "desktop-shell.log");
                    if (File.Exists(log) && new FileInfo(log).Length > 1024 * 1024) {
                        string previous = log + ".previous";
                        if (File.Exists(previous)) File.Delete(previous);
                        File.Move(log, previous);
                    }
                    File.AppendAllText(log, DateTime.UtcNow.ToString("o") + " " + args.Data + Environment.NewLine, new UTF8Encoding(false));
                }
            } catch { }
        }
        async Task StopAsync(bool exit) {
            if (busy) return;
            if (preview) { if (exit) FinishExit(); else ShowState(new DesktopStatus { Status = "Stopped", Message = "预览状态，没有网络需要停止。" }); return; }
            busy = true; RefreshButtons();
            headline.Text = "正在安全停止"; headline.ForeColor = Color.FromArgb(104, 83, 18); detail.Text = "正在请求控制器释放自己的 TUN，请稍候。";
            bool success = false;
            try {
                success = await Task.Run(delegate {
                    using (Process helper = new Process { StartInfo = BackendInfo("Stop") }) {
                        helper.OutputDataReceived += CaptureOutput; helper.ErrorDataReceived += CaptureOutput;
                        if (!helper.Start()) throw new IOException("无法启动停止控制器。");
                        using (ProcessJob helperJob = new ProcessJob(helper)) {
                            helper.BeginOutputReadLine(); helper.BeginErrorReadLine();
                            if (!helper.WaitForExit(25000)) return false;
                            helper.WaitForExit();
                            if (helper.ExitCode != 0) return false;
                        }
                    }
                    if (backend != null && !backend.HasExited && !backend.WaitForExit(3000)) return false;
                    return true;
                });
                if (success) {
                    if (backend != null) { backend.Dispose(); backend = null; }
                    if (job != null) { job.Dispose(); job = null; }
                    ShowState(new DesktopStatus { Status = "Stopped", Message = "本程序的 TUN 已释放，原代理软件保持运行。" });
                    if (exit) FinishExit();
                } else {
                    ShowState(new DesktopStatus { Status = "Error", Message = "尚未确认安全停止。助手保持打开，请查看诊断后重试停止。" });
                    if (exit) RestoreWindow();
                }
            } catch (Exception ex) { ShowState(new DesktopStatus { Status = "Error", Message = "停止未完成：" + ex.Message }); if (exit) RestoreWindow(); }
            finally { busy = false; if (!IsDisposed) RefreshButtons(); }
        }
        void RefreshStatus() {
            if (preview || busy) return;
            if (backend != null) {
                try {
                    string statusPath = Path.Combine(runtime, "desktop-status.json");
                    if (File.Exists(statusPath) && File.GetLastWriteTimeUtc(statusPath) >= backendStartedUtc && new FileInfo(statusPath).Length < 1024 * 1024) {
                        DesktopStatus next = Program.Json.Deserialize<DesktopStatus>(Program.ReadSharedText(statusPath));
                        if (next != null && !String.IsNullOrEmpty(next.Status)) {
                            if (next.Status == "Running" && !BackendAlive) next = new DesktopStatus { Status = "Error", Message = "控制器已退出，请查看诊断后重试。" };
                            ShowState(next);
                        }
                    }
                } catch (IOException) { }
                catch (InvalidOperationException) { }
                catch (ArgumentException) { }
                catch (UnauthorizedAccessException) { }
                // Liveness and freshness also run after a failed status read.
                if (!BackendAlive && state != null && state.Status != "Stopped" && state.Status != "ExistingTun" && state.Status != "Error" && state.Status != "RecoveryPaused")
                    ShowState(new DesktopStatus { Status = "Error", Message = "后台控制器已退出，请导出诊断查看原因，再点击重试。" });
                else if (!BackendAlive && state == null)
                    ShowState(new DesktopStatus { Status = "Error", Message = "后台控制器未能启动，请导出诊断查看原因。" });
                else if (state != null && state.Status == "Running" && !Program.IsFreshStatus(state.UpdatedUtc, DateTime.UtcNow))
                    ShowState(new DesktopStatus { Status = "Verifying", Message = "运行状态尚未更新，正在重新核实连接；此时不会显示验证成功。" });
            }
            RefreshButtons();
        }
        void ShowState(DesktopStatus next) {
            state = next;
            bool verifiedRunning = Program.IsVerifiedRunning(next.Status, preview || BackendAlive, next.UpdatedUtc, DateTime.UtcNow);
            string titleState = next.Status == "Running" && !verifiedRunning ? "Verifying" : next.Status;
            headline.Text = Program.StateTitle(titleState) + (preview ? "（预览）" : "");
            headline.ForeColor = verifiedRunning ? Color.FromArgb(20, 125, 83) : next.Status == "Error" || next.Status == "RecoveryPaused" ? Color.FromArgb(174, 52, 56) : Color.FromArgb(43, 73, 113);
            detail.Text = next.Message ?? "";
            endpoint.Text = "";
            if (!String.IsNullOrWhiteSpace(next.SelectedDisplayName) || !String.IsNullOrWhiteSpace(next.SelectedEndpoint))
                endpoint.Text = (next.SelectedDisplayName ?? "") + "\r\n" + (next.SelectedEndpoint ?? "");
            if (next.Candidates != null) foreach (Candidate candidate in next.Candidates) if (candidate.Key == next.SelectedKey) { endpoint.Text = candidate.ToString() + "\r\n" + candidate.Endpoint; break; }
            bool select = next.Status == "ChoiceRequired" && next.Candidates != null && next.Candidates.Length > 0;
            choices.Visible = choose.Visible = select;
            if (select) {
                string signature = String.Join("|", Array.ConvertAll(next.Candidates, delegate(Candidate candidate) { return candidate.Key; }));
                if (signature != choiceSignature) {
                    choices.Items.Clear(); choices.Items.AddRange(next.Candidates); choices.SelectedIndex = 0; choiceSignature = signature;
                }
                choose.Enabled = BackendAlive;
            }
            tray.Text = verifiedRunning && !preview ? "Proxy2TUN · 已连接" : "Proxy2TUN · " + Program.StateTitle(titleState);
            RefreshButtons();
        }
        void RefreshButtons() {
            start.Enabled = !busy && (!BackendAlive || preview || (state != null && state.Status == "RecoveryPaused"));
            stop.Enabled = !busy;
            diagnostics.Enabled = !busy && !preview;
            if (busy) choose.Enabled = false;
        }
        void ChooseClick(object sender, EventArgs args) {
            Candidate selected = choices.SelectedItem as Candidate;
            if (selected == null || !BackendAlive || busy) return;
            try {
                string path = Path.Combine(runtime, "desktop-choice.json");
                Program.CheckNoReparse(path);
                string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllText(temporary, Program.Json.Serialize(new Dictionary<string, string> { { "Key", selected.Key } }), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
                choose.Enabled = false; detail.Text = "已选择代理，正在核实并绑定…";
            } catch (Exception ex) { MessageBox.Show("无法提交选择：" + ex.Message, "Proxy2TUN", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        }
        async Task ExportDiagnosticsAsync() {
            if (preview || busy) return;
            using (SaveFileDialog dialog = new SaveFileDialog()) {
                dialog.Title = "保存脱敏诊断";
                dialog.FileName = "Proxy2TUN-diagnostics.txt";
                dialog.Filter = "诊断文本 (*.txt)|*.txt";
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                await SaveDiagnosticsAsync(dialog.FileName);
            }
        }
        async Task SaveDiagnosticsAsync(string output) {
            busy = true; RefreshButtons();
            try {
                await Task.Run(delegate {
                    Program.CheckNoReparse(runtime);
                    Program.CheckNoReparse(output);
                    using (Process helper = Process.Start(BackendInfo("Diagnose"))) {
                        using (ProcessJob helperJob = new ProcessJob(helper)) {
                            Task<string> summary = helper.StandardOutput.ReadToEndAsync();
                            Task<string> errors = helper.StandardError.ReadToEndAsync();
                            if (!helper.WaitForExit(10000) || helper.ExitCode != 0 ||
                                !Task.WaitAll(new Task[] { summary, errors }, 1000))
                                throw new IOException("Diagnostic export failed.");
                            File.WriteAllText(output, summary.Result, new UTF8Encoding(true));
                        }
                    }
                });
                MessageBox.Show(this, "脱敏诊断已保存，可以把这个文本文件发给维护者。", "Proxy2TUN");
            } catch (Exception) { MessageBox.Show(this, "无法保存诊断，请换一个可写位置后重试。", "Proxy2TUN"); }
            finally { busy = false; RefreshButtons(); }
        }
        void RestoreWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
        void OnFormClosingRequested(object sender, FormClosingEventArgs args) {
            if (exitRequested) return;
            if (args.CloseReason == CloseReason.WindowsShutDown || args.CloseReason == CloseReason.TaskManagerClosing) {
                if (job != null) { job.Dispose(); job = null; }
                return;
            }
            args.Cancel = true; Hide();
            if (!trayNotified) { tray.ShowBalloonTip(3000, "Proxy2TUN 继续运行", "在右下角托盘中打开助手，或选择“退出并停止”。", ToolTipIcon.Info); trayNotified = true; }
        }
        void FinishExit() { exitRequested = true; poll.Stop(); tray.Visible = false; Close(); }
        protected override void Dispose(bool disposing) {
            if (disposing) { poll.Dispose(); tray.Dispose(); if (job != null) job.Dispose(); if (backend != null) backend.Dispose(); }
            base.Dispose(disposing);
        }
    }

    // The GUI owns only its backend process and descendants. Abrupt GUI exit
    // releases this job so an unattended hidden watcher cannot survive it.
    internal sealed class ProcessJob : IDisposable {
        IntPtr handle;
        internal ProcessJob(Process process) {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                ExtendedLimit info = new ExtendedLimit(); info.Basic.LimitFlags = 0x2000;
                int length = Marshal.SizeOf(typeof(ExtendedLimit)); IntPtr buffer = Marshal.AllocHGlobal(length);
                try { Marshal.StructureToPtr(info, buffer, false); if (!SetInformationJobObject(handle, 9, buffer, (uint)length)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
                finally { Marshal.FreeHGlobal(buffer); }
                if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } catch { Dispose(); throw; }
        }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    }
}
