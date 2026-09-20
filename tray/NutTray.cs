// NutTray — taskbar battery icon for a NUT-monitored UPS (EcoFlow DELTA 3 Plus / RIVER 3 Plus on Windows).
// Talks to upsd directly over TCP (no upsc.exe spawn), redraws the icon as a large percentage with a
// status-coloured bar, pops notifications on power events, and exposes the useful settings in a dialog.
//
// Build (no SDK needed — uses the csc that ships with Windows):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:NutTray.exe NutTray.cs
//
// Usage: NutTray.exe [upsname] [host] [port]     defaults: ecoflow 127.0.0.1 3493
//        NutTray.exe --apply <lb%> <shutdownEnabled 0|1> <countdownSeconds>   (internal, elevated fallback)
//
// Layout assumption: this exe lives in <NUT>\tray\, config in <NUT>\etc\, nut.exe in <NUT>\bin\.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length >= 4 && args[0] == "--apply")
        {
            // Elevated helper mode: write NUT config + restart the service, then exit.
            try
            {
                NutConfig.Apply(int.Parse(args[1]), args[2] == "1", int.Parse(args[3]));
                NutConfig.RestartService(false);
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "NutTray", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            return;
        }
        string ups  = args.Length > 0 ? args[0] : "ecoflow";
        string host = args.Length > 1 ? args[1] : "127.0.0.1";
        int    port = args.Length > 2 ? int.Parse(args[2]) : 3493;
        using (var app = new TrayApp(ups, host, port)) Application.Run();
    }
}

// ---------------------------------------------------------------------------------------------- paths
static class Paths
{
    public static readonly string TrayDir = Path.GetDirectoryName(Application.ExecutablePath);
    public static readonly string NutDir  = Path.GetDirectoryName(TrayDir);
    public static readonly string Etc     = Path.Combine(NutDir, "etc");
    public static readonly string NutExe  = Path.Combine(NutDir, "bin\\nut.exe");
    public static readonly string UpsConf = Path.Combine(Etc, "ups.conf");
    public static readonly string MonConf = Path.Combine(Etc, "upsmon.conf");
    public static readonly string TrayIni = Path.Combine(TrayDir, "NutTray.ini");
}

// ---------------------------------------------------------------------------------------------- tray-local settings
sealed class TraySettings
{
    public int  PollSeconds = 5;
    public bool Notify = true;

    public static TraySettings Load()
    {
        var s = new TraySettings();
        try
        {
            if (File.Exists(Paths.TrayIni))
                foreach (var line in File.ReadAllLines(Paths.TrayIni))
                {
                    var kv = line.Split(new[] { '=' }, 2);
                    if (kv.Length != 2) continue;
                    switch (kv[0].Trim())
                    {
                        case "PollSeconds": int p; if (int.TryParse(kv[1], out p)) s.PollSeconds = Math.Max(2, Math.Min(60, p)); break;
                        case "Notify": s.Notify = kv[1].Trim() != "0"; break;
                    }
                }
        }
        catch { }
        return s;
    }

    public void Save()
    {
        File.WriteAllText(Paths.TrayIni, "PollSeconds=" + PollSeconds + "\r\nNotify=" + (Notify ? 1 : 0) + "\r\n");
    }
}

// ---------------------------------------------------------------------------------------------- NUT config (ups.conf / upsmon.conf)
static class NutConfig
{
    static readonly Regex RxLow  = new Regex(@"^(\s*override\.battery\.charge\.low\s*=\s*)(\d+)", RegexOptions.Multiline);
    static readonly Regex RxShut = new Regex(@"^(\s*SHUTDOWNCMD\s+)(.*)$", RegexOptions.Multiline);
    static readonly Regex RxT    = new Regex(@"/t\s+(\d+)");

    public static int LowBattery
    {
        get { var m = RxLow.Match(SafeRead(Paths.UpsConf)); return m.Success ? int.Parse(m.Groups[2].Value) : 15; }
    }

    // true = real shutdown.exe; false = the "disabled" stand-in that only shows a message
    public static bool ShutdownEnabled
    {
        get { var m = RxShut.Match(SafeRead(Paths.MonConf)); return !m.Success || m.Groups[2].Value.IndexOf("shutdown.exe", StringComparison.OrdinalIgnoreCase) >= 0; }
    }

    public static int CountdownSeconds
    {
        get { var m = RxShut.Match(SafeRead(Paths.MonConf)); var t = m.Success ? RxT.Match(m.Groups[2].Value) : null; return t != null && t.Success ? int.Parse(t.Groups[1].Value) : 30; }
    }

    public static string ShutdownLine(bool enabled, int seconds)
    {
        return enabled
            ? "\"C:\\\\Windows\\\\System32\\\\shutdown.exe /s /t " + seconds + " /c \\\"UPS battery low - NUT is shutting the PC down\\\"\""
            : "\"C:\\\\Windows\\\\System32\\\\msg.exe * UPS battery low - automatic shutdown is DISABLED in NutTray settings\"";
    }

    public static void Apply(int lowBattery, bool shutdownEnabled, int countdown)
    {
        string ups = File.ReadAllText(Paths.UpsConf);
        ups = RxLow.IsMatch(ups) ? RxLow.Replace(ups, "${1}" + lowBattery)
                                 : ups.TrimEnd() + "\r\n    ignorelb\r\n    override.battery.charge.low = " + lowBattery + "\r\n";
        File.WriteAllText(Paths.UpsConf, ups);

        string mon = File.ReadAllText(Paths.MonConf);
        string line = "SHUTDOWNCMD " + ShutdownLine(shutdownEnabled, countdown);
        mon = RxShut.IsMatch(mon) ? RxShut.Replace(mon, line.Replace("$", "$$")) : mon.TrimEnd() + "\r\n" + line + "\r\n";
        File.WriteAllText(Paths.MonConf, mon);
    }

    public static void RestartService(bool elevate)
    {
        var psi = new ProcessStartInfo(Paths.NutExe, "restart") { WindowStyle = ProcessWindowStyle.Hidden, UseShellExecute = true };
        if (elevate) psi.Verb = "runas";
        using (var p = Process.Start(psi)) { if (p != null) p.WaitForExit(60000); }
    }

    static string SafeRead(string path) { try { return File.ReadAllText(path); } catch { return ""; } }
}

// ---------------------------------------------------------------------------------------------- settings dialog
sealed class SettingsForm : Form
{
    readonly NumericUpDown _low = new NumericUpDown { Minimum = 5, Maximum = 90, Width = 70 };
    readonly CheckBox _shut = new CheckBox { Text = "Shut this PC down when the battery reaches the threshold", AutoSize = true };
    readonly NumericUpDown _count = new NumericUpDown { Minimum = 0, Maximum = 600, Width = 70 };
    readonly NumericUpDown _poll = new NumericUpDown { Minimum = 2, Maximum = 60, Width = 70 };
    readonly CheckBox _notify = new CheckBox { Text = "Show notifications on power events", AutoSize = true };
    readonly TraySettings _tray;

    public bool NutChanged { get; private set; }

    public SettingsForm(TraySettings tray, string model)
    {
        _tray = tray;
        Text = model + " — settings";
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen; ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.Dpi; Font = SystemFonts.MessageBoxFont;
        ClientSize = new Size(440, 300);

        _low.Value = Clamp(NutConfig.LowBattery, _low);
        _shut.Checked = NutConfig.ShutdownEnabled;
        _count.Value = Clamp(NutConfig.CountdownSeconds, _count);
        _poll.Value = Clamp(tray.PollSeconds, _poll);
        _notify.Checked = tray.Notify;

        var t = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(12), ColumnCount = 2, RowCount = 8 };
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        AddHeader(t, 0, "Low battery (NUT service — applies after a service restart)");
        AddRow(t, 1, "Low-battery threshold (%)  — the UPS reports 0, so NUT uses this instead", _low);
        t.Controls.Add(_shut, 0, 2); t.SetColumnSpan(_shut, 2);
        AddRow(t, 3, "Shutdown countdown (seconds)", _count);
        AddHeader(t, 4, "Tray icon");
        AddRow(t, 5, "Poll interval (seconds)", _poll);
        t.Controls.Add(_notify, 0, 6); t.SetColumnSpan(_notify, 2);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, AutoSize = true };
        var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(ok); buttons.Controls.Add(cancel);
        t.Controls.Add(buttons, 0, 7); t.SetColumnSpan(buttons, 2);
        AcceptButton = ok; CancelButton = cancel;
        Controls.Add(t);
        ok.Click += (s, e) => Save();
    }

    static decimal Clamp(int v, NumericUpDown n) { return Math.Max(n.Minimum, Math.Min(n.Maximum, v)); }
    static void AddHeader(TableLayoutPanel t, int row, string text)
    {
        var l = new Label { Text = text, AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold), Margin = new Padding(0, 8, 0, 4) };
        t.Controls.Add(l, 0, row); t.SetColumnSpan(l, 2);
    }
    static void AddRow(TableLayoutPanel t, int row, string label, Control c)
    {
        t.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 8, 0) }, 0, row);
        t.Controls.Add(c, 1, row);
    }

    void Save()
    {
        _tray.PollSeconds = (int)_poll.Value; _tray.Notify = _notify.Checked;
        try { _tray.Save(); } catch (Exception ex) { MessageBox.Show("Could not save tray settings: " + ex.Message, Text); }

        int lb = (int)_low.Value; bool sd = _shut.Checked; int cd = (int)_count.Value;
        bool changed = lb != NutConfig.LowBattery || sd != NutConfig.ShutdownEnabled || cd != NutConfig.CountdownSeconds;
        if (!changed) return;
        NutChanged = true;
        try
        {
            NutConfig.Apply(lb, sd, cd);
            NutConfig.RestartService(true);           // UAC prompt: the service restart needs admin
        }
        catch (UnauthorizedAccessException)
        {
            // etc\ not writable by this user: redo the whole thing elevated
            Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--apply " + lb + " " + (sd ? 1 : 0) + " " + cd) { Verb = "runas", UseShellExecute = true });
        }
        catch (Exception ex) { MessageBox.Show("Failed: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

// ---------------------------------------------------------------------------------------------- tray app
sealed class TrayApp : IDisposable
{
    const string Title = "UPS (NUT)";
    readonly string _ups, _host; readonly int _port;
    readonly NotifyIcon _icon = new NotifyIcon();
    readonly Timer _timer = new Timer();
    readonly TraySettings _cfg;
    string _lastStatus; bool _comm = true; bool _first = true;
    string _model = Title;

    public TrayApp(string ups, string host, int port)
    {
        _ups = ups; _host = host; _port = port;
        _cfg = TraySettings.Load();
        _timer.Interval = _cfg.PollSeconds * 1000;
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("Details…", null, (s, e) => ShowDetails()));
        menu.Items.Add(new ToolStripMenuItem("Settings…", null, (s, e) => ShowSettings()));
        menu.Items.Add(new ToolStripMenuItem("Restart NUT service", null, (s, e) => { try { NutConfig.RestartService(true); } catch (Exception ex) { MessageBox.Show(ex.Message, Title); } }));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Exit", null, (s, e) => { _icon.Visible = false; Application.Exit(); }));
        _icon.ContextMenuStrip = menu;
        _icon.DoubleClick += (s, e) => ShowDetails();
        _icon.Icon = IconFactory.Make(-1, State.NoComm);
        _icon.Text = Title + " — connecting…";
        _icon.Visible = true;
        _timer.Tick += (s, e) => Poll();
        Poll();
        _timer.Start();
    }

    // ---- upsd protocol: "LIST VAR <ups>" -> lines 'VAR <ups> <name> "<value>"' ... 'END LIST VAR <ups>'
    Dictionary<string, string> Fetch()
    {
        try
        {
            using (var c = new TcpClient())
            {
                var ar = c.BeginConnect(_host, _port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(1500)) return null;
                c.EndConnect(ar);
                c.ReceiveTimeout = 2000;
                using (var ns = c.GetStream())
                using (var w = new StreamWriter(ns, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" })
                using (var r = new StreamReader(ns, Encoding.UTF8))
                {
                    w.WriteLine("LIST VAR " + _ups);
                    var vars = new Dictionary<string, string>();
                    var rx = new Regex("^VAR \\S+ (\\S+) \"(.*)\"$");
                    string line;
                    while ((line = r.ReadLine()) != null)
                    {
                        if (line.StartsWith("END LIST")) break;
                        if (line.StartsWith("ERR")) return null;
                        var m = rx.Match(line);
                        if (m.Success) vars[m.Groups[1].Value] = m.Groups[2].Value;
                    }
                    w.WriteLine("LOGOUT");
                    return vars.ContainsKey("ups.status") ? vars : null;
                }
            }
        }
        catch { return null; }
    }

    void Poll()
    {
        var v = Fetch();
        if (v == null)
        {
            if (_comm && !_first) Balloon(6000, "Lost contact with the UPS (NUT service down or USB unplugged).", ToolTipIcon.Warning);
            _comm = false; _first = false;
            SetIcon(-1, State.NoComm, _model + "\nno data");
            return;
        }
        string st = v["ups.status"];
        int pct; if (!int.TryParse(Get(v, "battery.charge", "-1"), out pct)) pct = -1;
        if (v.ContainsKey("device.model")) _model = v["device.model"];
        bool ob = Has(st, "OB"), lb = Has(st, "LB"), ol = Has(st, "OL");
        var state = lb ? State.LowBattery : ob ? State.OnBattery : ol ? State.Online : State.Unknown;
        SetIcon(pct, state, _model + "\n" + pct + "% — " + Describe(st));

        if (!_comm && !_first) Balloon(3000, "Reconnected — " + pct + "%, " + Describe(st), ToolTipIcon.Info);
        else if (_lastStatus != null)
        {
            bool wasOB = Has(_lastStatus, "OB"), wasLB = Has(_lastStatus, "LB");
            if (lb && !wasLB)      Balloon(10000, "LOW BATTERY (" + pct + "%) — NUT will shut the PC down.", ToolTipIcon.Error);
            else if (ob && !wasOB) Balloon(8000, "Power lost — running on battery (" + pct + "%).", ToolTipIcon.Warning);
            else if (wasOB && !ob) Balloon(5000, "Mains power restored (" + pct + "%).", ToolTipIcon.Info);
        }
        _lastStatus = st; _comm = true; _first = false;
    }

    void SetIcon(int pct, State s, string tip)
    {
        var old = _icon.Icon;
        _icon.Icon = IconFactory.Make(pct, s);
        if (old != null) old.Dispose();
        _icon.Text = tip.Length > 127 ? tip.Substring(0, 127) : tip;
    }

    void Balloon(int ms, string text, ToolTipIcon kind) { if (_cfg.Notify) _icon.ShowBalloonTip(ms, _model, text, kind); }

    void ShowDetails()
    {
        var v = Fetch();
        string txt;
        if (v == null) txt = "No data — NUT service down or UPS unplugged.";
        else
        {
            var keys = new[] { "ups.status", "battery.charge", "battery.charge.low", "battery.voltage", "battery.runtime",
                               "ups.power.nominal", "device.mfr", "device.model", "device.serial", "driver.version.data" };
            var sb = new StringBuilder();
            foreach (var k in keys) if (v.ContainsKey(k)) sb.AppendLine(k.PadRight(22) + v[k]);
            sb.AppendLine();
            sb.AppendLine("Shutdown: " + (NutConfig.ShutdownEnabled ? "at " + NutConfig.LowBattery + "% with " + NutConfig.CountdownSeconds + " s countdown" : "DISABLED"));
            txt = sb.ToString();
        }
        MessageBox.Show(txt, _model, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void ShowSettings()
    {
        using (var f = new SettingsForm(_cfg, _model))
        {
            if (f.ShowDialog() != DialogResult.OK) return;
            _timer.Interval = _cfg.PollSeconds * 1000;
            if (f.NutChanged) Balloon(4000, "Settings saved — NUT service restarted.", ToolTipIcon.Info);
        }
    }

    static string Get(Dictionary<string, string> d, string k, string def) { string v; return d.TryGetValue(k, out v) ? v : def; }
    static bool Has(string status, string flag) { return Regex.IsMatch(status, "\\b" + flag + "\\b"); }
    static string Describe(string st)
    {
        var p = new List<string>();
        if (Has(st, "OL")) p.Add("On line");
        if (Has(st, "OB")) p.Add("ON BATTERY");
        if (Has(st, "LB")) p.Add("LOW BATTERY");
        if (Has(st, "CHRG")) p.Add("charging");
        if (Has(st, "DISCHRG")) p.Add("discharging");
        return p.Count > 0 ? string.Join(", ", p.ToArray()) : st;
    }

    public void Dispose() { _timer.Dispose(); _icon.Visible = false; _icon.Dispose(); }
}

enum State { Online, OnBattery, LowBattery, Unknown, NoComm }

static class IconFactory
{
    // Big bold percentage + a status bar underneath. Designed to be legible at 16x16 on a dark taskbar.
    public static Icon Make(int pct, State s)
    {
        const int size = 32;
        Color bar = s == State.Online ? Color.FromArgb(70, 200, 90)
                  : s == State.OnBattery ? Color.FromArgb(240, 170, 30)
                  : s == State.LowBattery ? Color.FromArgb(235, 60, 50)
                  : Color.FromArgb(140, 140, 140);
        Color text = s == State.NoComm ? Color.FromArgb(160, 160, 160) : Color.White;
        using (var bmp = new Bitmap(size, size))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                string label = pct < 0 ? "--" : pct >= 100 ? "100" : pct.ToString();
                float em = label.Length >= 3 ? 15f : 22f;
                using (var f = new Font("Segoe UI", em, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var b = new SolidBrush(text))
                {
                    var sz = g.MeasureString(label, f);
                    g.DrawString(label, f, b, (size - sz.Width) / 2f, (24 - sz.Height) / 2f);
                }
                // status bar: full width, fill proportional to charge
                using (var bg = new SolidBrush(Color.FromArgb(90, 255, 255, 255))) g.FillRectangle(bg, 2, 26, 28, 5);
                int w = pct < 0 ? 28 : (int)Math.Round(28 * Math.Max(0, Math.Min(100, pct)) / 100.0);
                using (var fb = new SolidBrush(bar)) g.FillRectangle(fb, 2, 26, Math.Max(w, 2), 5);
                if (s == State.OnBattery || s == State.LowBattery)
                {
                    // small badge top-right so on-battery is unmistakable even at 16px
                    using (var rb = new SolidBrush(bar)) g.FillEllipse(rb, 22, 0, 10, 10);
                }
            }
            IntPtr h = bmp.GetHicon();
            using (var tmp = Icon.FromHandle(h))
            {
                var ico = (Icon)tmp.Clone();
                DestroyIcon(h);
                return ico;
            }
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
}
