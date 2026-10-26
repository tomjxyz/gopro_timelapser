"""Builds GoPro-Timelapser-User-Guide.pdf from the screenshots in images/.

    python3 make_guide.py
"""
import os

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (Image, KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table,
                                TableStyle)

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, "images")
OUT = os.path.join(HERE, "GoPro-Timelapser-User-Guide.pdf")

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
pdfmetrics.registerFont(TTFont("Body", os.path.join(FONT_DIR, "DejaVuSans.ttf")))
pdfmetrics.registerFont(TTFont("Body-Bold", os.path.join(FONT_DIR, "DejaVuSans-Bold.ttf")))
pdfmetrics.registerFont(TTFont("Mono", os.path.join(FONT_DIR, "DejaVuSansMono.ttf")))
pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold", italic="Body", boldItalic="Body-Bold")

ACCENT = colors.HexColor("#0a63c9")
INK = colors.HexColor("#1d1d1f")
MUTED = colors.HexColor("#6e6e73")
TIP_BG = colors.HexColor("#eef5fd")
WARN_BG = colors.HexColor("#fff6e5")
RULE = colors.HexColor("#d2d2d7")

PAGE_W, PAGE_H = A4
MARGIN = 20 * mm
CONTENT_W = PAGE_W - 2 * MARGIN

styles = {
    "title": ParagraphStyle("title", fontName="Body-Bold", fontSize=30, leading=36, textColor=INK, spaceAfter=6),
    "subtitle": ParagraphStyle("subtitle", fontName="Body", fontSize=14, leading=19, textColor=MUTED, spaceAfter=18),
    "h1": ParagraphStyle("h1", fontName="Body-Bold", fontSize=19, leading=24, textColor=INK, spaceBefore=4, spaceAfter=10),
    "h2": ParagraphStyle("h2", fontName="Body-Bold", fontSize=13, leading=17, textColor=ACCENT, spaceBefore=12, spaceAfter=5),
    "body": ParagraphStyle("body", fontName="Body", fontSize=10.5, leading=15, textColor=INK, spaceAfter=6),
    "step": ParagraphStyle("step", fontName="Body", fontSize=10.5, leading=15, textColor=INK, leftIndent=18,
                           firstLineIndent=-18, spaceAfter=5),
    "bullet": ParagraphStyle("bullet", fontName="Body", fontSize=10.5, leading=15, textColor=INK, leftIndent=14,
                             firstLineIndent=-10, spaceAfter=3),
    "caption": ParagraphStyle("caption", fontName="Body", fontSize=8.5, leading=11, textColor=MUTED,
                              alignment=TA_CENTER, spaceBefore=3, spaceAfter=10),
    "box": ParagraphStyle("box", fontName="Body", fontSize=10, leading=14, textColor=INK),
    "cell": ParagraphStyle("cell", fontName="Body", fontSize=9.5, leading=13, textColor=INK),
    "cellhead": ParagraphStyle("cellhead", fontName="Body-Bold", fontSize=9.5, leading=13, textColor=colors.white),
    "toc": ParagraphStyle("toc", fontName="Body", fontSize=11, leading=19, textColor=INK),
}


def P(text, style="body"):
    return Paragraph(text, styles[style])


def steps(*items):
    return [P(f"<b>{i}.</b>&nbsp;&nbsp;{t}", "step") for i, t in enumerate(items, 1)]


def bullets(*items):
    return [P(f"•&nbsp;&nbsp;{t}", "bullet") for t in items]


def picture(name, caption=None, width=CONTENT_W):
    path = os.path.join(IMG, name)
    from PIL import Image as PILImage
    w, h = PILImage.open(path).size
    inner = width - 2  # leave room for the 0.6 pt frame so the picture never exceeds the text width
    img = Image(path, width=inner, height=inner * h / w)
    framed = Table([[img]], colWidths=[width])
    framed.setStyle(TableStyle([
        ("BOX", (0, 0), (-1, -1), 0.6, RULE),
        ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
    ]))
    parts = [framed]
    if caption:
        parts.append(P(caption, "caption"))
    else:
        parts.append(Spacer(1, 8))
    return KeepTogether(parts)


def callout(title, text, bg=TIP_BG, edge=ACCENT):
    t = Table([[P(f"<b>{title}</b>&nbsp;&nbsp;{text}", "box")]], colWidths=[CONTENT_W])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LINEBEFORE", (0, 0), (0, -1), 3, edge),
        ("LEFTPADDING", (0, 0), (-1, -1), 10), ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    return KeepTogether([t, Spacer(1, 8)])


def tip(text):
    return callout("Tip:", text)


def warn(text):
    return callout("Note:", text, bg=WARN_BG, edge=colors.HexColor("#e59400"))


def table(rows, widths):
    data = [[P(c, "cellhead") for c in rows[0]]] + [[P(c, "cell") for c in r] for r in rows[1:]]
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f5f5f7")]),
        ("BOX", (0, 0), (-1, -1), 0.6, RULE),
        ("LINEBELOW", (0, 0), (-1, -1), 0.3, RULE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return KeepTogether([t, Spacer(1, 10)])


def on_page(canvas, doc):
    canvas.saveState()
    if doc.page > 1:
        canvas.setFont("Body", 8.5)
        canvas.setFillColor(MUTED)
        canvas.drawString(MARGIN, 12 * mm, "GoPro Timelapser — User Guide")
        canvas.drawRightString(PAGE_W - MARGIN, 12 * mm, f"Page {doc.page}")
        canvas.setStrokeColor(RULE)
        canvas.setLineWidth(0.5)
        canvas.line(MARGIN, 15 * mm, PAGE_W - MARGIN, 15 * mm)
    canvas.restoreState()


story = []

# ---------------------------------------------------------------- cover
story += [
    Spacer(1, 25 * mm),
    P("GoPro Timelapser", "title"),
    P("User guide for Mac: turning GoPro clips into timelapses, and joining clips together", "subtitle"),
    picture("timelapse-window.jpg", width=CONTENT_W),
    Spacer(1, 6),
    P("<b>In this guide</b>", "h2"),
    P("1.&nbsp;&nbsp;Installing and opening the app<br/>"
      "2.&nbsp;&nbsp;Copying clips off the GoPro<br/>"
      "3.&nbsp;&nbsp;Making a timelapse<br/>"
      "4.&nbsp;&nbsp;Joining clips at normal speed<br/>"
      "5.&nbsp;&nbsp;Tips for an older MacBook<br/>"
      "6.&nbsp;&nbsp;If something goes wrong", "toc"),
    PageBreak(),
]

# ---------------------------------------------------------------- 1. install
story += [
    P("1.  Installing and opening the app", "h1"),
    P("GoPro Timelapser is a single app with nothing else to install. It works on any Mac running "
      "<b>macOS Catalina (10.15) or later</b>, including a 2016 MacBook. To check your version, click the "
      "Apple menu (the apple at the top-left of the screen) → <b>About This Mac</b>."),
    P("Installing", "h2"),
    *steps(
        "You will receive a file called <b>GoPro-Timelapser-mac.zip</b>. Double-click it to unzip it. "
        "You will get <b>GoPro Timelapser</b> (the app).",
        "Drag <b>GoPro Timelapser</b> into your <b>Applications</b> folder.",
    ),
    P("Opening it the first time", "h2"),
    P("Because the app doesn’t come from the App Store, macOS asks you to confirm the first time you "
      "open it. You only need to do this once."),
    *steps(
        "Open your <b>Applications</b> folder.",
        "<b>Right-click</b> (or hold <b>Control</b> and click) <b>GoPro Timelapser</b>, then choose "
        "<b>Open</b>.",
        "A message says the app is from an unidentified developer. Click <b>Open</b>.",
    ),
    P("From then on, open it like any other app: from Applications, Launchpad, or the Dock."),
    callout("If macOS still won’t open it:",
            "open <b>System Preferences → Security &amp; Privacy → General</b>. Near the bottom it says "
            "“GoPro Timelapser was blocked”. Click <b>Open Anyway</b>, then <b>Open</b>.",
            bg=WARN_BG, edge=colors.HexColor("#e59400")),
    tip("To keep the app in the Dock, right-click its Dock icon while it is open and choose "
        "<b>Options → Keep in Dock</b>."),

    P("2.  Copying clips off the GoPro", "h1"),
    *steps(
        "Put the GoPro’s memory card in a card reader (or connect the camera with its USB cable).",
        "In Finder, open the card and go to the <b>DCIM</b> folder, then <b>100GOPRO</b>.",
        "Copy the <b>.MP4</b> files you want into a folder on the Mac, for example a new folder in "
        "<b>Movies</b>. Working from the Mac is faster than working from the card.",
    ),
    P("You can ignore the <b>.LRV</b> and <b>.THM</b> files. They are small preview files the camera makes "
      "for its own use."),
    callout("About GoPro file names:",
            "a long recording is split into several files called <b>chapters</b>. "
            "<b>GX01</b>0123.MP4, <b>GX02</b>0123.MP4, <b>GX03</b>0123.MP4 are parts 1, 2 and 3 of "
            "recording number <b>0123</b>. The app puts them in the right order for you."),
    PageBreak(),
]

# ---------------------------------------------------------------- 3. timelapse
story += [
    P("3.  Making a timelapse", "h1"),
    P("A timelapse speeds the footage up, so an hour-long drive or sunset plays back in a minute or "
      "two. The <b>Timelapse</b> tab at the top of the window does this. The window is laid out "
      "top to bottom in the order you use it."),
    picture("timelapse-window.jpg", "The Timelapse tab", width=CONTENT_W * 0.8),
    P("Step 1: Add your clips", "h2"),
    picture("clips.jpg"),
    *bullets(
        "<b>Drag</b> clips from Finder into the list. You can also drag a whole folder in.",
        "Or click <b>Add Clips…</b> and choose them.",
        "Each row shows the file name, when it was recorded, and how long it is. "
        "Below the list is the number of clips and their total length.",
        "Clips are sorted by recording time as you add them. To change the order, <b>drag a row up "
        "or down</b>, or select it and use the <b>Move Up / Move Down / Move to Top / Move to Bottom</b> "
        "buttons. <b>Sort by Time</b> puts everything back in recording order.",
        "To take a clip out, select it and press <b>Delete</b> (or click <b>Remove</b>). "
        "<b>Clear All</b> empties the list.",
    ),
    tip("To select several clips at once, hold <b>⌘ Command</b> and click each one, or hold "
        "<b>Shift</b> and click the first and last of a range."),
    P("Step 2: Choose the speed", "h2"),
    picture("speed.jpg"),
    P("The speed is how many times faster than real life the timelapse plays. Drag the slider, type a "
      "number between <b>2</b> and <b>400</b>, or click one of the presets. Underneath, the app shows how "
      "long the finished timelapse will be."),
    table([
        ["Speed", "1 hour of footage becomes", "Good for"],
        ["10×", "6 minutes", "Walks, gentle sped-up action"],
        ["40×", "1½ minutes", "Drives, bike rides, hikes"],
        ["100×", "36 seconds", "Long journeys, clouds"],
        ["400×", "9 seconds", "Very long recordings, sunsets, all-day events"],
    ], [22 * mm, 55 * mm, CONTENT_W - 77 * mm]),
    tip("Not sure? Start with <b>40×</b>, look at the result, then adjust."),
    P("Step 3: Choose the quality", "h2"),
    picture("quality.jpg"),
    *bullets(
        "<b>Resolution</b>: the picture size. <b>1080p</b> (Full HD) is a good choice for watching on a laptop or "
        "TV and keeps files small. <b>Original</b> keeps the camera’s own size. The app never makes the "
        "picture bigger than the camera recorded it.",
        "<b>Frame rate</b>: <b>30</b> is smooth and standard. Leave it unless you have a reason to change it.",
        "<b>Codec</b>: leave this on <b>H.264 (most compatible)</b>. HEVC makes smaller files but is "
        "<b>much slower on a 2016 MacBook</b>.",
        "<b>Quality slider</b>: move left for smaller files, right for a sharper picture. The middle "
        "(“medium”) is fine for most things.",
    ),
    P("Step 4: Sound (optional)", "h2"),
    picture("sound.jpg"),
    P("Timelapses are normally silent. Tick <b>Include sound</b> to keep the clips’ sound, sped up to "
      "match the video. Then choose how it should sound:"),
    *bullets(
        "<b>Keep natural pitch</b>: voices and sounds keep their normal pitch and play as quick snippets.",
        "<b>Chipmunk</b>: like fast-forwarding a tape; the pitch rises the faster you go.",
    ),
    P("Above about 40× the sound becomes a very short, choppy blur. That’s expected at those speeds."),
    P("Step 5: Save and create", "h2"),
    picture("saveas.jpg"),
    P("Under <b>Save as</b>, the app suggests a name in the same folder as your first clip, for example "
      "<i>GX010231_timelapse_40x_1080p.mp4</i>. Click <b>Choose…</b> to save it somewhere else or give "
      "it a different name."),
    P("Click <b>Create Timelapse</b>. The progress bar fills as it works, and the line underneath shows "
      "how far it has got and roughly how long is left. When it finishes, a message appears. Click "
      "<b>Show in Finder</b> to go straight to the new video."),
    tip("Changed your mind? Click <b>Cancel</b>. The unfinished file is deleted automatically."),
    PageBreak(),
]

# ---------------------------------------------------------------- 4. join
story += [
    P("4.  Joining clips at normal speed", "h1"),
    P("The <b>Join Clips</b> tab sticks clips together end to end into one video at normal speed. It is "
      "handy for putting a recording’s chapters back into one file, or combining several clips from a "
      "day out. Click <b>Join Clips</b> at the top of the window to switch to it."),
    picture("join-window.jpg", "The Join Clips tab", width=CONTENT_W * 0.8),
    P("Add and order your clips exactly as on the Timelapse tab (see Step 1 above). Each tab has its own "
      "list."),
    P("Mode", "h2"),
    picture("join-mode.jpg"),
    *bullets(
        "<b>Lossless</b> (recommended): copies the video exactly as the camera recorded it. It is very "
        "fast, usually just seconds, with <b>no loss of quality</b>. The clips must come from the same "
        "camera with the same settings, which chapters of one recording always do.",
        "<b>Re-encode</b>: makes a new, usually smaller video. Use it to <b>shrink</b> a big file, change "
        "the resolution, or join clips recorded with different settings. The quality controls work "
        "the same as on the Timelapse tab. <b>Frame rate: Same as clips</b> keeps the original smoothness. "
        "This is much slower than Lossless.",
    ),
    P("Options", "h2"),
    picture("join-options.jpg"),
    *bullets(
        "<b>Include sound</b>: untick to make a silent video.",
        "<b>Keep original recording date</b>: gives the new video the date and time the first clip was "
        "recorded, so it appears in the right place in Photos and when sorting in Finder. "
        "Leave this ticked.",
        "<b>Cut from start / Cut from end</b>: trims a little off the beginning or end, for example "
        "fiddling with the camera. Type seconds (<b>15</b>) or minutes:seconds (<b>1:30</b>). "
        "The app shows how long the result will be.",
    ),
    P("Save and join", "h2"),
    picture("join-run.jpg"),
    P("Check the name under <b>Save as</b> (or click <b>Choose…</b>), then click <b>Join Clips</b>. "
      "A Lossless join usually finishes in seconds; Re-encode takes longer and shows its progress."),
    Spacer(1, 8),
]

# ---------------------------------------------------------------- 5. older MacBook
story += [
    P("5.  Tips for an older MacBook", "h1"),
    P("A 2016 MacBook handles all of this, but video work keeps it busy. These help:"),
    *bullets(
        "<b>Plug in the charger</b> before starting a long timelapse.",
        "Keep <b>Codec</b> on <b>H.264</b>. Your MacBook has hardware for making H.264 video, but HEVC "
        "has to be done the slow way.",
        "<b>1080p</b> is much quicker than 4K and looks great on the MacBook’s screen.",
        "Close other big apps (especially web browsers with many tabs) while it runs.",
        "Check you have enough <b>free space</b>. A Lossless join needs about as much space as the "
        "clips themselves. A timelapse is usually small: about 45 MB per minute at 1080p medium quality.",
        "The MacBook may get warm and its fan may run. That’s normal while making video.",
        "Speed doesn’t change how long a timelapse takes much, because the app still has to read through "
        "all the footage. Expect longer recordings to take a while; the progress line shows the time "
        "remaining.",
    ),
    tip("Try a short test first: add one or two clips, make a timelapse, and check you like the speed and "
        "quality before processing a whole day’s footage."),

    P("6.  If something goes wrong", "h1"),
    table([
        ["What you see", "What to do"],
        ["The app won’t open, or says it’s from an unidentified developer",
         "Right-click the app and choose <b>Open</b>. See section 1, including <b>Open Anyway</b>."],
        ["“These clips can’t be joined losslessly”",
         "The clips were recorded with different settings or cameras. Choose <b>Re-encode</b> on the "
         "Join Clips tab and try again."],
        ["A clip’s <b>Recorded</b> time is wrong",
         "The time comes from the camera’s clock. Set the clock in the GoPro (or the GoPro Quik app) "
         "for future recordings, and put clips in order by dragging them."],
        ["Clips are in the wrong order",
         "Drag rows up or down, or click <b>Sort by Time</b>."],
        ["The sound is choppy",
         "Normal at high speeds. Try a lower speed or switch the sound off."],
        ["“Something went wrong” message",
         "Tick <b>Show log</b> (bottom right) to see details. Check there is enough free disk space and "
         "that the clips play in QuickTime Player. If one clip is damaged, remove it and try again."],
        ["Can’t find the finished video",
         "It is saved where <b>Save as</b> says, normally the same folder as your first clip. "
         "Click <b>Show in Finder</b> in the message that appears when it finishes."],
        ["It’s very slow",
         "See section 5. Use H.264 and 1080p, plug in the charger, and close other apps."],
    ], [62 * mm, CONTENT_W - 62 * mm]),
    Spacer(1, 6),
    P("Quick reference", "h2"),
    table([
        ["To…", "Do this"],
        ["Add clips", "Drag files or a folder into the list, or click <b>Add Clips…</b>"],
        ["Reorder clips", "Drag rows, or select and use the Move buttons"],
        ["Remove a clip", "Select it and press <b>Delete</b>"],
        ["Select several clips", "<b>⌘ Command</b>-click, or <b>Shift</b>-click a range"],
        ["Stop a video being made", "Click <b>Cancel</b>"],
        ["See what the app is doing", "Tick <b>Show log</b>"],
        ["Quit", "<b>⌘ Command + Q</b>"],
    ], [55 * mm, CONTENT_W - 55 * mm]),
]


def bind_headings(flowables):
    """Keeps each heading on the same page as the block that follows it."""
    out, i = [], 0
    while i < len(flowables):
        f = flowables[i]
        if isinstance(f, Paragraph) and f.style.name in ("h1", "h2") and i + 1 < len(flowables):
            nxt = flowables[i + 1]
            # Flatten: a KeepTogether nested inside another one always starts a new page.
            inner = list(nxt._content) if isinstance(nxt, KeepTogether) else [nxt]
            out.append(KeepTogether([f] + inner))
            i += 2
        else:
            out.append(f)
            i += 1
    return out


story = bind_headings(story)

doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=MARGIN,
                        bottomMargin=22 * mm, title="GoPro Timelapser — User Guide",
                        author="GoPro Timelapser", subject="How to use GoPro Timelapser on a Mac")
doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
print("wrote", OUT)
