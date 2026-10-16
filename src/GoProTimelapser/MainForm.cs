using System.Diagnostics;
using System.Globalization;

namespace GoProTimelapser;

public sealed class Clip
{
    public required string Path { get; init; }
    public string Name => System.IO.Path.GetFileName(Path);
    public DateTime? Recorded { get; init; }
    public TimeSpan? Duration { get; init; }
}

public sealed class MainForm : Form
{
    private static readonly string[] VideoExtensions = [".mp4", ".mov"];

    private static readonly (string Label, int? Height)[] Resolutions =
    [
        ("720p", 720),
        ("1080p", 1080),
        ("1440p", 1440),
        ("4K (2160p)", 2160),
        ("Original", null),
    ];

    private const int MinSpeed = 2, MaxSpeed = 400;
    private const int BestQuality = 18, WorstQuality = 40;

    private readonly List<Clip> _clips = [];

    private readonly ListView _list = new();
    private readonly Label _clipSummary = new();
    private readonly TrackBar _speedSlider = new();
    private readonly NumericUpDown _speedBox = new();
    private readonly Label _speedInfo = new();
    private readonly ComboBox _resolution = new();
    private readonly TrackBar _qualitySlider = new();
    private readonly Label _qualityLabel = new();
    private readonly ComboBox _encoder = new();
    private readonly ComboBox _fps = new();
    private readonly TextBox _output = new();
    private readonly Button _start = new();
    private readonly Button _cancel = new();
    private readonly ProgressBar _progress = new();
    private readonly Label _status = new();
    private readonly CheckBox _showLog = new();
    private readonly TextBox _log = new();
    private readonly List<Control> _lockWhileRunning = [];

    private TimelapseJob? _job;
    private bool _syncingSpeed;
    private bool _outputEdited;

    public MainForm(string[]? initialPaths = null)
    {
        Text = "GoPro Timelapser";
        Font = new Font("Segoe UI", 9F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(860, 800);
        MinimumSize = new Size(700, 720);
        StartPosition = FormStartPosition.CenterScreen;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            Padding = new Padding(10),
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));   // clips
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // speed
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // quality
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // output
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // run
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));    // log (toggled)
        Controls.Add(root);

        root.Controls.Add(BuildClipsGroup(), 0, 0);
        root.Controls.Add(BuildSpeedGroup(), 0, 1);
        root.Controls.Add(BuildQualityGroup(), 0, 2);
        root.Controls.Add(BuildOutputGroup(), 0, 3);
        root.Controls.Add(BuildRunPanel(root), 0, 4);

        _log.Multiline = true;
        _log.ReadOnly = true;
        _log.ScrollBars = ScrollBars.Both;
        _log.WordWrap = false;
        _log.Font = new Font("Consolas", 8.5F);
        _log.Dock = DockStyle.Fill;
        root.Controls.Add(_log, 0, 5);

        SetSpeed(40);
        UpdateQualityLabel();
        UpdateClipSummary();
        UpdateButtons();

        // Files dropped onto the exe icon in Explorer arrive as command-line arguments.
        if (initialPaths is { Length: > 0 })
            Shown += (_, _) => AddPaths(initialPaths);

        FormClosing += (_, e) =>
        {
            if (_job == null) return;
            if (MessageBox.Show(this, "A timelapse is still being created. Cancel it and exit?",
                    Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                _job.Cancel();
            else
                e.Cancel = true;
        };
    }

    // ---------------------------------------------------------------- layout

    private Control BuildClipsGroup()
    {
        var group = new GroupBox { Text = "Clips — drag GoPro files here, then put them in order", Dock = DockStyle.Fill, Padding = new Padding(8) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        _list.Dock = DockStyle.Fill;
        _list.View = View.Details;
        _list.FullRowSelect = true;
        _list.GridLines = true;
        _list.HideSelection = false;
        _list.AllowDrop = true;
        _list.HeaderStyle = ColumnHeaderStyle.Nonclickable;
        _list.Columns.Add("#", 40, HorizontalAlignment.Right);
        _list.Columns.Add("File name", 260);
        _list.Columns.Add("Recorded", 170);
        _list.Columns.Add("Duration", 90, HorizontalAlignment.Right);
        _list.Columns.Add("Folder", 220);
        _list.DragEnter += List_DragOver;
        _list.DragOver += List_DragOver;
        _list.DragLeave += (_, _) => _list.InsertionMark.Index = -1;
        _list.DragDrop += List_DragDrop;
        _list.ItemDrag += (_, _) =>
        {
            if (_job == null && _list.SelectedIndices.Count > 0)
                _list.DoDragDrop(new ReorderData(_list.SelectedIndices.Cast<int>().ToArray()), DragDropEffects.Move);
        };
        _list.SelectedIndexChanged += (_, _) => UpdateButtons();
        _list.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Delete) RemoveSelected();
            else if (e.Alt && e.KeyCode == Keys.Up) { MoveSelected(-1); e.Handled = true; }
            else if (e.Alt && e.KeyCode == Keys.Down) { MoveSelected(1); e.Handled = true; }
            else if (e.Control && e.KeyCode == Keys.A)
                foreach (ListViewItem it in _list.Items) it.Selected = true;
        };
        _list.Resize += (_, _) => FitLastColumn();
        layout.Controls.Add(_list, 0, 0);

        var buttons = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            Dock = DockStyle.Fill,
            WrapContents = false,
            Padding = new Padding(6, 0, 0, 0),
        };
        buttons.Controls.Add(MakeButton("Add files…", (_, _) => BrowseForClips(), lockWhileRunning: true));
        buttons.Controls.Add(MakeButton("▲  Move up", (_, _) => MoveSelected(-1), lockWhileRunning: true, name: "up"));
        buttons.Controls.Add(MakeButton("▼  Move down", (_, _) => MoveSelected(1), lockWhileRunning: true, name: "down"));
        buttons.Controls.Add(MakeButton("Move to top", (_, _) => MoveSelectedToEdge(top: true), lockWhileRunning: true, name: "top"));
        buttons.Controls.Add(MakeButton("Move to bottom", (_, _) => MoveSelectedToEdge(top: false), lockWhileRunning: true, name: "bottom"));
        buttons.Controls.Add(MakeButton("Sort by time", (_, _) => SortByTime(), lockWhileRunning: true, name: "sort"));
        buttons.Controls.Add(MakeButton("Remove", (_, _) => RemoveSelected(), lockWhileRunning: true, name: "remove"));
        buttons.Controls.Add(MakeButton("Clear all", (_, _) => ClearClips(), lockWhileRunning: true, name: "clear"));
        layout.Controls.Add(buttons, 1, 0);

        _clipSummary.AutoSize = true;
        _clipSummary.Padding = new Padding(0, 4, 0, 0);
        layout.Controls.Add(_clipSummary, 0, 1);
        layout.SetColumnSpan(_clipSummary, 2);

        group.Controls.Add(layout);

        // Allow dropping onto the whole group, not just the list.
        group.AllowDrop = true;
        group.DragEnter += List_DragOver;
        group.DragOver += List_DragOver;
        group.DragDrop += List_DragDrop;
        return group;
    }

    private Control BuildSpeedGroup()
    {
        var group = new GroupBox { Text = "Speed", Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 3 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        // Logarithmic slider so 2x-20x gets as much travel as 40x-400x.
        _speedSlider.Minimum = 0;
        _speedSlider.Maximum = 1000;
        _speedSlider.TickFrequency = 100;
        _speedSlider.SmallChange = 5;
        _speedSlider.LargeChange = 50;
        _speedSlider.Dock = DockStyle.Fill;
        _speedSlider.ValueChanged += (_, _) =>
        {
            if (_syncingSpeed) return;
            SetSpeed(SliderToSpeed(_speedSlider.Value), fromSlider: true);
        };
        layout.Controls.Add(_speedSlider, 0, 0);

        _speedBox.Minimum = MinSpeed;
        _speedBox.Maximum = MaxSpeed;
        _speedBox.Width = 70;
        _speedBox.TextAlign = HorizontalAlignment.Right;
        _speedBox.Anchor = AnchorStyles.Left;
        _speedBox.ValueChanged += (_, _) =>
        {
            if (_syncingSpeed) return;
            SetSpeed((int)_speedBox.Value, fromBox: true);
        };
        layout.Controls.Add(_speedBox, 1, 0);
        layout.Controls.Add(new Label { Text = "× faster", AutoSize = true, Anchor = AnchorStyles.Left }, 2, 0);

        var presets = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill, WrapContents = false };
        presets.Controls.Add(new Label { Text = "Presets:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        foreach (var p in new[] { 2, 5, 10, 20, 40, 60, 100, 200, 400 })
        {
            var b = MakeButton($"{p}×", (_, _) => SetSpeed(p), lockWhileRunning: true);
            b.AutoSize = false;
            b.MinimumSize = Size.Empty;
            b.Width = 56;
            presets.Controls.Add(b);
        }
        layout.Controls.Add(presets, 0, 1);
        layout.SetColumnSpan(presets, 3);

        _speedInfo.AutoSize = true;
        _speedInfo.Padding = new Padding(0, 2, 0, 0);
        layout.Controls.Add(_speedInfo, 0, 2);
        layout.SetColumnSpan(_speedInfo, 3);

        _lockWhileRunning.Add(_speedSlider);
        _lockWhileRunning.Add(_speedBox);
        group.Controls.Add(layout);
        return group;
    }

    private Control BuildQualityGroup()
    {
        var group = new GroupBox { Text = "Quality", Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 4 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        _resolution.DropDownStyle = ComboBoxStyle.DropDownList;
        foreach (var r in Resolutions) _resolution.Items.Add(r.Label);
        _resolution.SelectedIndex = 1; // 1080p
        _resolution.Dock = DockStyle.Fill;
        _resolution.SelectedIndexChanged += (_, _) => SuggestOutputName();
        layout.Controls.Add(MakeLabel("Resolution:"), 0, 0);
        layout.Controls.Add(_resolution, 1, 0);

        _fps.DropDownStyle = ComboBoxStyle.DropDownList;
        _fps.Items.AddRange(["24", "25", "30", "50", "60"]);
        _fps.SelectedItem = "30";
        _fps.Dock = DockStyle.Fill;
        layout.Controls.Add(MakeLabel("Output frame rate:"), 2, 0);
        layout.Controls.Add(_fps, 3, 0);

        // Slider: left = smaller file, right = better quality.
        _qualitySlider.Minimum = 0;
        _qualitySlider.Maximum = WorstQuality - BestQuality;
        _qualitySlider.Value = WorstQuality - 26;
        _qualitySlider.TickFrequency = 2;
        _qualitySlider.Dock = DockStyle.Fill;
        _qualitySlider.ValueChanged += (_, _) => UpdateQualityLabel();
        var qualityRow = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3, Margin = Padding.Empty };
        qualityRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        qualityRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        qualityRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        qualityRow.Controls.Add(new Label { Text = "Smaller file", AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = SystemColors.GrayText }, 0, 0);
        qualityRow.Controls.Add(_qualitySlider, 1, 0);
        qualityRow.Controls.Add(new Label { Text = "Better quality", AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = SystemColors.GrayText }, 2, 0);
        layout.Controls.Add(MakeLabel("Quality:"), 0, 1);
        layout.Controls.Add(qualityRow, 1, 1);
        layout.SetColumnSpan(qualityRow, 2);
        _qualityLabel.AutoSize = true;
        _qualityLabel.Anchor = AnchorStyles.Left;
        layout.Controls.Add(_qualityLabel, 3, 1);

        _encoder.DropDownStyle = ComboBoxStyle.DropDownList;
        _encoder.Items.AddRange(["Auto (Intel QuickSync, fall back to CPU)", "Intel QuickSync only", "Software / CPU (x264)"]);
        _encoder.SelectedIndex = 0;
        _encoder.Dock = DockStyle.Fill;
        layout.Controls.Add(MakeLabel("Encoder:"), 0, 2);
        layout.Controls.Add(_encoder, 1, 2);
        layout.SetColumnSpan(_encoder, 3);

        _lockWhileRunning.AddRange([_resolution, _fps, _qualitySlider, _encoder]);
        group.Controls.Add(layout);
        return group;
    }

    private Control BuildOutputGroup()
    {
        var group = new GroupBox { Text = "Output file", Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 2 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _output.Dock = DockStyle.Fill;
        _output.TextChanged += (_, _) => { if (_output.Focused) _outputEdited = true; UpdateButtons(); };
        layout.Controls.Add(_output, 0, 0);
        layout.Controls.Add(MakeButton("Browse…", (_, _) => BrowseForOutput(), lockWhileRunning: true), 1, 0);
        _lockWhileRunning.Add(_output);
        group.Controls.Add(layout);
        return group;
    }

    private Control BuildRunPanel(TableLayoutPanel root)
    {
        var layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 4, Padding = new Padding(0, 6, 0, 0) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        _start.Text = "Create timelapse";
        _start.AutoSize = true;
        _start.Padding = new Padding(10, 4, 10, 4);
        _start.Font = new Font(Font, FontStyle.Bold);
        _start.Click += async (_, _) => await StartAsync();
        layout.Controls.Add(_start, 0, 0);

        _cancel.Text = "Cancel";
        _cancel.AutoSize = true;
        _cancel.Padding = new Padding(6, 4, 6, 4);
        _cancel.Enabled = false;
        _cancel.Click += (_, _) => _job?.Cancel();
        layout.Controls.Add(_cancel, 1, 0);

        _progress.Dock = DockStyle.Fill;
        _progress.Maximum = 1000;
        _progress.Margin = new Padding(8, 8, 8, 8);
        layout.Controls.Add(_progress, 2, 0);

        _showLog.Text = "Show log";
        _showLog.AutoSize = true;
        _showLog.Anchor = AnchorStyles.Right;
        _showLog.CheckedChanged += (_, _) =>
        {
            root.RowStyles[5] = _showLog.Checked
                ? new RowStyle(SizeType.Absolute, 160)
                : new RowStyle(SizeType.Absolute, 0);
            if (_showLog.Checked && Height < 820) Height += 160;
        };
        layout.Controls.Add(_showLog, 3, 0);

        _status.AutoSize = true;
        _status.Text = "Ready.";
        layout.Controls.Add(_status, 0, 1);
        layout.SetColumnSpan(_status, 4);
        return layout;
    }

    private Button MakeButton(string text, EventHandler onClick, bool lockWhileRunning = false, string? name = null)
    {
        var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(110, 0), Margin = new Padding(3, 2, 3, 2), Name = name ?? "" };
        b.Click += onClick;
        if (lockWhileRunning) _lockWhileRunning.Add(b);
        return b;
    }

    private static Label MakeLabel(string text) => new() { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 6, 6, 3) };

    // ---------------------------------------------------------------- clips

    private sealed record ReorderData(int[] Indices);

    private void List_DragOver(object? sender, DragEventArgs e)
    {
        if (_job != null) { e.Effect = DragDropEffects.None; return; }

        if (e.Data?.GetDataPresent(typeof(ReorderData)) == true)
        {
            e.Effect = DragDropEffects.Move;
            _list.InsertionMark.Index = InsertionIndexAt(new Point(e.X, e.Y), out bool after);
            _list.InsertionMark.AppearsAfterItem = after;
        }
        else if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true)
        {
            e.Effect = DragDropEffects.Copy;
        }
        else
        {
            e.Effect = DragDropEffects.None;
        }
    }

    private void List_DragDrop(object? sender, DragEventArgs e)
    {
        _list.InsertionMark.Index = -1;
        if (_job != null) return;

        if (e.Data?.GetData(typeof(ReorderData)) is ReorderData reorder)
        {
            int idx = InsertionIndexAt(new Point(e.X, e.Y), out bool after);
            int target = idx < 0 ? _clips.Count : idx + (after ? 1 : 0);
            MoveIndicesTo(reorder.Indices, target);
        }
        else if (e.Data?.GetData(DataFormats.FileDrop) is string[] paths)
        {
            AddPaths(paths);
        }
    }

    private int InsertionIndexAt(Point screenPoint, out bool after)
    {
        var pt = _list.PointToClient(screenPoint);
        after = false;
        if (_list.Items.Count == 0) return -1;
        var item = _list.GetItemAt(5, pt.Y);
        if (item == null)
        {
            // Below the last item -> after the last; above the first -> before it.
            var last = _list.Items[^1];
            if (pt.Y > last.Bounds.Bottom) { after = true; return last.Index; }
            return 0;
        }
        after = pt.Y > item.Bounds.Top + item.Bounds.Height / 2;
        return item.Index;
    }

    private void BrowseForClips()
    {
        using var dlg = new OpenFileDialog
        {
            Title = "Add GoPro clips",
            Filter = "Video files (*.mp4;*.mov)|*.mp4;*.mov|All files (*.*)|*.*",
            Multiselect = true,
        };
        if (dlg.ShowDialog(this) == DialogResult.OK) AddPaths(dlg.FileNames);
    }

    private void AddPaths(IEnumerable<string> paths)
    {
        var files = new List<string>();
        foreach (var p in paths)
        {
            if (Directory.Exists(p))
                files.AddRange(Directory.EnumerateFiles(p, "*", SearchOption.TopDirectoryOnly).Where(IsVideo).OrderBy(f => f));
            else if (File.Exists(p) && IsVideo(p))
                files.Add(p);
        }

        var existing = new HashSet<string>(_clips.Select(c => c.Path), StringComparer.OrdinalIgnoreCase);
        var added = new List<Clip>();
        Cursor = Cursors.WaitCursor;
        try
        {
            foreach (var f in files)
            {
                var full = Path.GetFullPath(f);
                if (!existing.Add(full)) continue;
                var info = Mp4Metadata.Read(full);
                DateTime? recorded = info.CreationTime;
                if (recorded == null)
                    try { recorded = File.GetLastWriteTime(full); } catch { }
                added.Add(new Clip { Path = full, Recorded = recorded, Duration = info.Duration });
            }
        }
        finally { Cursor = Cursors.Default; }

        if (added.Count == 0) return;
        // Newly dropped clips go on the end in recording order; the user can reorder afterwards.
        added.Sort(CompareByTime);
        _clips.AddRange(added);
        RefreshList(added.Select(a => _clips.IndexOf(a)));
        SuggestOutputName();
    }

    private static bool IsVideo(string path) =>
        VideoExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    private static int CompareByTime(Clip a, Clip b)
    {
        int c = Nullable.Compare(a.Recorded, b.Recorded);
        return c != 0 ? c : GoProOrderKey(a.Name).CompareTo(GoProOrderKey(b.Name));
    }

    /// <summary>
    /// GoPro names are like GX010123.MP4 / GOPR0123.MP4 / GP010123.MP4: chapter is digits 3-4,
    /// recording number is the last four. Sort by recording then chapter as a tie-breaker.
    /// </summary>
    private static string GoProOrderKey(string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name).ToUpperInvariant();
        if (stem.Length == 8 && stem.StartsWith('G') && stem[4..].All(char.IsDigit))
        {
            var chapter = stem.StartsWith("GOPR") ? "00" : stem[2..4];
            return stem[4..] + chapter;
        }
        return stem;
    }

    private void SortByTime()
    {
        var selected = SelectedClips();
        _clips.Sort(CompareByTime);
        RefreshList(selected.Select(c => _clips.IndexOf(c)));
    }

    private void MoveSelected(int delta)
    {
        var sel = _list.SelectedIndices.Cast<int>().OrderBy(i => i).ToList();
        if (sel.Count == 0) return;
        if (delta < 0 && sel[0] == 0) return;
        if (delta > 0 && sel[^1] == _clips.Count - 1) return;

        var ordered = delta < 0 ? sel : Enumerable.Reverse(sel).ToList();
        foreach (var i in ordered)
            (_clips[i], _clips[i + delta]) = (_clips[i + delta], _clips[i]);
        RefreshList(sel.Select(i => i + delta));
    }

    private void MoveSelectedToEdge(bool top)
    {
        var sel = _list.SelectedIndices.Cast<int>().ToArray();
        if (sel.Length == 0) return;
        MoveIndicesTo(sel, top ? 0 : _clips.Count);
    }

    private void MoveIndicesTo(int[] indices, int target)
    {
        var moving = indices.OrderBy(i => i).Select(i => _clips[i]).ToList();
        int before = indices.Count(i => i < target);
        foreach (var c in moving) _clips.Remove(c);
        int insertAt = Math.Clamp(target - before, 0, _clips.Count);
        _clips.InsertRange(insertAt, moving);
        RefreshList(Enumerable.Range(insertAt, moving.Count));
    }

    private void RemoveSelected()
    {
        var sel = _list.SelectedIndices.Cast<int>().OrderByDescending(i => i).ToList();
        if (sel.Count == 0) return;
        foreach (var i in sel) _clips.RemoveAt(i);
        int next = Math.Min(sel[^1], _clips.Count - 1);
        RefreshList(next >= 0 ? [next] : []);
    }

    private void ClearClips()
    {
        if (_clips.Count == 0) return;
        _clips.Clear();
        _outputEdited = false;
        _output.Text = "";
        RefreshList([]);
    }

    private List<Clip> SelectedClips() => _list.SelectedIndices.Cast<int>().Select(i => _clips[i]).ToList();

    private void RefreshList(IEnumerable<int> select)
    {
        var toSelect = select.ToHashSet();
        _list.BeginUpdate();
        _list.Items.Clear();
        for (int i = 0; i < _clips.Count; i++)
        {
            var c = _clips[i];
            var item = new ListViewItem((i + 1).ToString(CultureInfo.CurrentCulture));
            item.SubItems.Add(c.Name);
            item.SubItems.Add(c.Recorded?.ToString("yyyy-MM-dd  HH:mm:ss", CultureInfo.CurrentCulture) ?? "unknown");
            item.SubItems.Add(c.Duration is TimeSpan d ? FormatDuration(d) : "?");
            item.SubItems.Add(Path.GetDirectoryName(c.Path) ?? "");
            item.ToolTipText = c.Path;
            item.Selected = toSelect.Contains(i);
            _list.Items.Add(item);
        }
        _list.EndUpdate();
        if (toSelect.Count > 0)
        {
            var first = toSelect.Min();
            if (first < _list.Items.Count) { _list.EnsureVisible(first); _list.FocusedItem = _list.Items[first]; }
        }
        FitLastColumn();
        UpdateClipSummary();
        UpdateButtons();
    }

    private void FitLastColumn()
    {
        if (_list.Columns.Count == 0) return;
        int used = 0;
        for (int i = 0; i < _list.Columns.Count - 1; i++) used += _list.Columns[i].Width;
        int w = _list.ClientSize.Width - used - 4;
        if (w > 80) _list.Columns[^1].Width = w;
    }

    private TimeSpan TotalDuration() => _clips.Aggregate(TimeSpan.Zero, (t, c) => t + (c.Duration ?? TimeSpan.Zero));

    private void UpdateClipSummary()
    {
        if (_clips.Count == 0)
        {
            _clipSummary.Text = "No clips yet. Drag .MP4 files (or a folder) from Explorer into the list above.";
        }
        else
        {
            var unknown = _clips.Count(c => c.Duration == null);
            _clipSummary.Text = $"{_clips.Count} clip{(_clips.Count == 1 ? "" : "s")}, total {FormatDuration(TotalDuration())}" +
                                (unknown > 0 ? $"  ({unknown} with unknown duration)" : "") +
                                "    Tip: drag rows to reorder, Alt+Up/Down to move, Del to remove.";
        }
        UpdateSpeedInfo();
    }

    // ---------------------------------------------------------------- speed / quality

    private static int SliderToSpeed(int v) =>
        (int)Math.Round(MinSpeed * Math.Pow((double)MaxSpeed / MinSpeed, v / 1000.0));

    private static int SpeedToSlider(int speed) =>
        (int)Math.Round(1000 * Math.Log((double)speed / MinSpeed) / Math.Log((double)MaxSpeed / MinSpeed));

    private void SetSpeed(int speed, bool fromSlider = false, bool fromBox = false)
    {
        speed = Math.Clamp(speed, MinSpeed, MaxSpeed);
        _syncingSpeed = true;
        try
        {
            if (!fromSlider) _speedSlider.Value = Math.Clamp(SpeedToSlider(speed), 0, 1000);
            if (!fromBox) _speedBox.Value = speed;
        }
        finally { _syncingSpeed = false; }
        UpdateSpeedInfo();
        SuggestOutputName();
    }

    private int Speed => (int)_speedBox.Value;

    private void UpdateSpeedInfo()
    {
        var total = TotalDuration();
        var perSecond = Speed / 1.0;
        var text = $"{Speed}× — every second of output covers {FormatSeconds(perSecond)} of footage.";
        if (total > TimeSpan.Zero)
            text += $"  Output length ≈ {FormatDuration(total / Speed)}.";
        _speedInfo.Text = text;
    }

    private static string FormatSeconds(double s) =>
        s < 60 ? $"{s:0} s" : s < 3600 ? $"{s / 60:0.#} min" : $"{s / 3600:0.#} h";

    private int QualityValue => WorstQuality - _qualitySlider.Value;

    private void UpdateQualityLabel()
    {
        var q = QualityValue;
        string word = q <= 21 ? "very high" : q <= 25 ? "high" : q <= 29 ? "medium" : q <= 34 ? "low" : "very low";
        _qualityLabel.Text = $"{q}  ({word})";
    }

    // ---------------------------------------------------------------- output

    private void SuggestOutputName()
    {
        if (_outputEdited || _clips.Count == 0) return;
        var dir = Path.GetDirectoryName(_clips[0].Path) ?? Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        var res = Resolutions[Math.Max(0, _resolution.SelectedIndex)].Height is int h ? $"{h}p" : "orig";
        var stem = Path.GetFileNameWithoutExtension(_clips[0].Name);
        _output.Text = Path.Combine(dir, $"{stem}_timelapse_{Speed}x_{res}.mp4");
    }

    private void BrowseForOutput()
    {
        using var dlg = new SaveFileDialog
        {
            Title = "Save timelapse as",
            Filter = "MP4 video (*.mp4)|*.mp4",
            DefaultExt = "mp4",
            AddExtension = true,
            OverwritePrompt = true,
        };
        if (!string.IsNullOrWhiteSpace(_output.Text))
        {
            try
            {
                dlg.InitialDirectory = Path.GetDirectoryName(_output.Text);
                dlg.FileName = Path.GetFileName(_output.Text);
            }
            catch { }
        }
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            _output.Text = dlg.FileName;
            _outputEdited = true;
        }
    }

    // ---------------------------------------------------------------- run

    private void UpdateButtons()
    {
        bool idle = _job == null;
        bool hasSel = _list.SelectedIndices.Count > 0;
        foreach (var c in _lockWhileRunning)
        {
            c.Enabled = idle && c.Name switch
            {
                "up" or "down" or "top" or "bottom" or "remove" => hasSel,
                "sort" or "clear" => _clips.Count > 0,
                _ => true,
            };
        }
        _start.Enabled = idle && _clips.Count > 0 && !string.IsNullOrWhiteSpace(_output.Text);
        _cancel.Enabled = !idle;
    }

    private async Task StartAsync()
    {
        if (_clips.Count == 0) return;
        var output = _output.Text.Trim();
        try { output = Path.GetFullPath(output); }
        catch
        {
            MessageBox.Show(this, "The output path is not valid.", Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (!output.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)) output += ".mp4";
        if (_clips.Any(c => string.Equals(c.Path, output, StringComparison.OrdinalIgnoreCase)))
        {
            MessageBox.Show(this, "The output file can't be one of the input clips.", Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (File.Exists(output) &&
            MessageBox.Show(this, $"{Path.GetFileName(output)} already exists. Overwrite it?", Text,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
            return;
        var outDir = Path.GetDirectoryName(output);
        if (!string.IsNullOrEmpty(outDir)) Directory.CreateDirectory(outDir);
        _output.Text = output;

        var settings = new TimelapseSettings
        {
            Inputs = _clips.Select(c => c.Path).ToList(),
            OutputPath = output,
            Speed = Speed,
            Height = Resolutions[_resolution.SelectedIndex].Height,
            Quality = QualityValue,
            Fps = int.Parse((string)_fps.SelectedItem!, CultureInfo.InvariantCulture),
            Encoder = (EncoderChoice)_encoder.SelectedIndex,
            TotalDuration = TotalDuration(),
        };

        var job = new TimelapseJob(settings);
        var sw = Stopwatch.StartNew();
        job.Log += line => BeginInvoke(() => AppendLog(line));
        job.Progress += (p, speed) => BeginInvoke(() =>
        {
            _progress.Value = (int)(p * 1000);
            var eta = p > 0.01 ? TimeSpan.FromSeconds(sw.Elapsed.TotalSeconds * (1 - p) / p) : (TimeSpan?)null;
            _status.Text = $"Encoding… {p:P0}" +
                           (string.IsNullOrEmpty(speed) || speed == "N/A" ? "" : $"   ffmpeg speed {speed}") +
                           $"   elapsed {FormatDuration(sw.Elapsed)}" +
                           (eta is TimeSpan e ? $"   remaining ≈ {FormatDuration(e)}" : "");
        });

        _job = job;
        _log.Clear();
        _progress.Value = 0;
        _status.Text = "Starting ffmpeg…";
        UpdateButtons();

        try
        {
            var used = await job.RunAsync();
            _progress.Value = 1000;
            _status.Text = $"Done in {FormatDuration(sw.Elapsed)} using {TimelapseJob.Describe(used)}.  {output}";
            if (MessageBox.Show(this, $"Timelapse created:\n{output}\n\nOpen the folder?", Text,
                    MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
            {
                try { Process.Start("explorer.exe", $"/select,\"{output}\""); } catch { }
            }
        }
        catch (OperationCanceledException)
        {
            _progress.Value = 0;
            _status.Text = "Cancelled.";
        }
        catch (Exception ex)
        {
            _progress.Value = 0;
            _status.Text = "Failed: " + ex.Message;
            _showLog.Checked = true;
            MessageBox.Show(this, ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _job = null;
            UpdateButtons();
        }
    }

    private void AppendLog(string line)
    {
        if (_log.TextLength > 200_000) _log.Text = _log.Text[^100_000..];
        _log.AppendText(line + Environment.NewLine);
    }

    private static string FormatDuration(TimeSpan t) =>
        t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
}
