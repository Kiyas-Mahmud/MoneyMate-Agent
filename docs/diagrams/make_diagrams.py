"""
Generates the MoneyMate diagrams (SVG) in one shared style: short labels only, right-angle arrows, the details
live in the documents under each picture.

    python docs/diagrams/make_diagrams.py        # writes docs/diagrams/*.svg
"""

from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent

INK, MUTED, LINE, SOFT, WHITE = "#111111", "#6B6B6B", "#D4D4D4", "#F4F4F4", "#FFFFFF"
TONES = {  # fill, stroke, title colour
    "ok": ("#E7F4EC", "#B9DCC7", "#1E6B41"),
    "warn": ("#FFF3D6", "#EBD39A", "#8A5300"),
    "danger": ("#FDECEB", "#F0C3BF", "#A8231A"),
}


class Diagram:
    def __init__(self, name, w, h, title=None):
        self.name, self.w, self.h, self.parts = name, w, h, []
        if title:
            self.text(32, 40, title, size=17, weight=600)

    # ---- primitives ------------------------------------------------------------------------------------
    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=13, weight=400, color=INK, anchor="start", mono=False, spacing=0):
        fam = "'JetBrains Mono', Menlo, Consolas, monospace" if mono else "inherit"
        ls = f' letter-spacing="{spacing}"' if spacing else ""
        self.add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" '
                 f'text-anchor="{anchor}" font-family="{fam}"{ls}>{escape(s)}</text>')

    def group(self, x, y, w, h, label=None, dashed=False):
        dash = ' stroke="#D4D4D4" stroke-width="1.2" stroke-dasharray="6 5" fill="#FAFAFA"' if dashed \
            else f' fill="{SOFT}"'
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="22"{dash}/>')
        if label:
            self.text(x + 20, y + 28, label.upper(), size=11.5, weight=600, color="#8A8A8A", spacing=1.1)

    def node(self, x, y, w, h, title, sub=None, kind="plain"):
        if kind == "dark":
            fill, stroke, tc, sc = INK, INK, WHITE, "#BDBDBD"
        elif kind == "soft":
            fill, stroke, tc, sc = SOFT, SOFT, INK, MUTED
        elif kind in TONES:
            fill, stroke, tc = TONES[kind]
            sc = tc
        else:
            fill, stroke, tc, sc = WHITE, LINE, INK, MUTED
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{fill}" stroke="{stroke}" '
                 f'stroke-width="1.2"/>')
        cx = x + w / 2
        if sub:
            self.text(cx, y + h / 2 - 3, title, size=15, weight=600, color=tc, anchor="middle")
            self.text(cx, y + h / 2 + 16, sub, size=12, color=sc, anchor="middle")
        else:
            self.text(cx, y + h / 2 + 5, title, size=15, weight=600, color=tc, anchor="middle")
        return (x, y, w, h)

    def diamond(self, cx, cy, w, h, lines):
        pts = f"{cx},{cy - h / 2} {cx + w / 2},{cy} {cx},{cy + h / 2} {cx - w / 2},{cy}"
        self.add(f'<polygon points="{pts}" fill="{WHITE}" stroke="{INK}" stroke-width="1.4"/>')
        top = cy - (len(lines) - 1) * 9 + 5
        for i, s in enumerate(lines):
            self.text(cx, top + i * 18, s, size=13.5, weight=600, anchor="middle")

    def badge(self, cx, cy, n):
        self.add(f'<circle cx="{cx}" cy="{cy}" r="12" fill="{INK}" stroke="{WHITE}" stroke-width="2.5"/>')
        self.text(cx, cy + 4, str(n), size=11.5, weight=700, color=WHITE, anchor="middle")

    def label(self, x, y, s):
        """Arrow label on a white pill, so it never sits on top of a line."""
        w = len(s) * 6.7 + 16
        self.add(f'<rect x="{x - w / 2}" y="{y - 12}" width="{w}" height="22" rx="11" fill="{WHITE}"/>')
        self.text(x, y + 4, s, size=12, color="#444444", anchor="middle")

    def arrow(self, pts, dashed=False, color=INK, start=False, end=True):
        """Right-angle polyline with rounded corners."""
        r = 8
        d = f"M{pts[0][0]},{pts[0][1]}"
        for i in range(1, len(pts) - 1):
            (x0, y0), (x1, y1), (x2, y2) = pts[i - 1], pts[i], pts[i + 1]
            ux, uy = _unit(x1 - x0, y1 - y0)
            vx, vy = _unit(x2 - x1, y2 - y1)
            rr = min(r, _dist(x0, y0, x1, y1) / 2, _dist(x1, y1, x2, y2) / 2)
            d += f" L{x1 - ux * rr},{y1 - uy * rr} Q{x1},{y1} {x1 + vx * rr},{y1 + vy * rr}"
        d += f" L{pts[-1][0]},{pts[-1][1]}"
        mk = "g" if color != INK else "k"
        dash = ' stroke-dasharray="6 5"' if dashed else ""
        ms = f' marker-start="url(#s{mk})"' if start else ""
        me = f' marker-end="url(#e{mk})"' if end else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.5"{dash}{ms}{me}/>')

    def line(self, x1, y1, x2, y2, color=LINE, width=1.2, dashed=False):
        dash = ' stroke-dasharray="5 5"' if dashed else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{width}"{dash}/>')

    def save(self):
        defs = f"""<defs>
  <marker id="ek" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0.5 L10,5 L0,9.5 z" fill="{INK}"/></marker>
  <marker id="sk" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0.5 L10,5 L0,9.5 z" fill="{INK}"/></marker>
  <marker id="eg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0.5 L10,5 L0,9.5 z" fill="#8A8A8A"/></marker>
  <marker id="sg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0.5 L10,5 L0,9.5 z" fill="#8A8A8A"/></marker>
</defs>"""
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" '
               f'height="{self.h}" font-family="Inter, \'Helvetica Neue\', Arial, sans-serif">\n'
               f'<style>@import url(\'https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&amp;display=block\');</style>\n'
               f'{defs}\n<rect width="{self.w}" height="{self.h}" fill="{WHITE}"/>\n' + "\n".join(self.parts) + "\n</svg>\n")
        (OUT / f"{self.name}.svg").write_text(svg)
        print("wrote", self.name)


def _dist(x0, y0, x1, y1):
    return ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** .5


def _unit(dx, dy):
    n = (dx * dx + dy * dy) ** .5 or 1
    return dx / n, dy / n


# =========================================================================================================
def architecture():
    d = Diagram("architecture", 1200, 640)
    d.group(30, 30, 250, 586, "Student's phone")
    d.group(330, 30, 560, 586, "MoneyMate backend")
    d.group(940, 30, 230, 586, "External services", dashed=True)
    # phone
    d.node(55, 80, 200, 56, "MoneyMate app", "Flutter")
    d.node(55, 440, 200, 56, "Android Keystore", "key + fingerprint", kind="dark")
    d.node(55, 530, 200, 56, "On-device OCR", "ML Kit")
    # backend rows
    d.node(360, 80, 500, 56, "REST API", "HTTPS · JWT")
    d.node(360, 170, 240, 56, "Daily monitor", "scheduled checks")
    d.node(620, 170, 240, 56, "AI agent", "Gemini + fallback")
    d.node(360, 260, 500, 56, "Payment pipeline", "one path for every payment", kind="dark")
    d.node(360, 350, 153, 56, "Payee check", "registry")
    d.node(533, 350, 153, 56, "Risk model", "6 models")
    d.node(706, 350, 154, 56, "Policy", "T0 · T2 · T3")
    d.node(360, 440, 240, 56, "Verification", "signature check")
    d.node(620, 440, 240, 56, "Notifications", "in-app · push")
    d.node(360, 530, 153, 56, "Receipts", "HMAC code")
    d.node(533, 530, 153, 56, "Database", "SQLite / Postgres")
    d.node(706, 530, 154, 56, "Audit log", "hash chain")
    # external
    d.node(960, 170, 190, 56, "Google Gemini", "optional")
    d.node(960, 260, 190, 56, "Exchange rates", "live FX")
    d.node(960, 440, 190, 56, "Firebase", "push, optional")
    d.node(960, 530, 190, 56, "Ethereum Sepolia", "test blockchain")
    # phone <-> backend
    d.arrow([(255, 108), (360, 108)], start=True)
    d.label(307, 96, "HTTPS")
    d.arrow([(155, 136), (155, 440)])
    d.label(155, 290, "sign")
    d.arrow([(255, 468), (360, 468)])
    d.label(307, 456, "signature")
    # inside backend
    d.arrow([(740, 136), (740, 170)])
    d.arrow([(610, 136), (610, 260)])
    d.arrow([(740, 226), (740, 260)])
    d.arrow([(480, 226), (480, 260)])
    for x in (436, 609, 783):
        d.arrow([(x, 316), (x, 350)])
    d.arrow([(783, 406), (783, 440)])
    d.arrow([(436, 496), (436, 530)])
    # backend -> external
    d.arrow([(860, 198), (960, 198)])
    d.arrow([(860, 288), (960, 288)])
    d.arrow([(860, 468), (960, 468)])
    d.arrow([(860, 558), (960, 558)])
    d.label(910, 546, "anchor")
    d.save()


def payment_lifecycle():
    d = Diagram("payment-lifecycle", 1200, 440)
    for i, s in enumerate(("Agent chat", "App screen", "Daily monitor")):
        d.node(30, 70 + i * 100, 170, 56, s, kind="soft")
    d.node(270, 160, 190, 76, "Prepared", "checks + risk score")
    for i in range(3):
        d.line(200, 98 + i * 100, 235, 98 + i * 100, color=INK, width=1.5)
    d.line(235, 98, 235, 298, color=INK, width=1.5)
    d.arrow([(235, 198), (270, 198)])
    d.node(630, 60, 220, 64, "Blocked", "T3 · refused", kind="danger")
    d.node(630, 250, 220, 76, "Awaiting verification", "T2 · fingerprint needed", kind="dark")
    d.arrow([(460, 198), (510, 198), (510, 92), (630, 92)])
    d.arrow([(460, 198), (510, 198), (510, 288), (630, 288)])
    d.label(570, 80, "block rule")
    d.label(570, 276, "allowed")
    d.node(990, 160, 185, 56, "Paid", "receipt issued", kind="ok")
    d.node(990, 260, 185, 56, "Rejected", "nothing moves")
    d.node(990, 360, 185, 56, "Expired", "nothing moves")
    d.arrow([(850, 288), (880, 288), (880, 188), (990, 188)])
    d.arrow([(850, 288), (990, 288)])
    d.arrow([(880, 288), (880, 388), (990, 388)])
    d.label(935, 176, "fingerprint")
    d.label(935, 276, "declined")
    d.label(935, 376, "timed out")
    d.save()


def verification_sequence():
    d = Diagram("verification-sequence", 1200, 650)
    d.group(290, 18, 540, 90, None)
    d.text(306, 40, "STUDENT'S PHONE", size=11.5, weight=600, color="#8A8A8A", spacing=1.1)
    lanes = {"Student": 130, "Keystore": 420, "App": 700, "Backend": 1040}
    for name, x in lanes.items():
        title = {"Keystore": "Android Keystore", "App": "MoneyMate app"}.get(name, name)
        d.node(x - 95, 50, 190, 46, title, kind="dark" if name == "Backend" else ("soft" if name == "Student" else "plain"))
        d.line(x, 96, x, 620, color="#BDBDBD", dashed=True)
    S, K, A, B = lanes["Student"], lanes["Keystore"], lanes["App"], lanes["Backend"]

    def msg(n, y, x1, x2, text, dashed=False):
        d.arrow([(x1, y), (x2, y)], dashed=dashed)
        d.badge(x1 + (16 if x2 > x1 else -16), y - 15, n)
        d.text((x1 + x2) / 2, y - 9, text, size=12.5, color="#333333", anchor="middle")

    d.node(B - 85, 120, 170, 36, "prepare + nonce")
    d.badge(B - 104, 138, 1)
    msg(2, 192, B, A, "verify request", dashed=True)
    msg(3, 236, S, A, "tap Verify")
    msg(4, 280, A, B, "get challenge")
    msg(5, 324, B, A, "challenge", dashed=True)
    msg(6, 368, A, K, "sign")
    msg(7, 412, K, S, "fingerprint prompt")
    msg(8, 456, S, K, "fingerprint")
    msg(9, 500, K, A, "signature", dashed=True)
    msg(10, 544, A, B, "submit signature")
    d.node(B - 85, 556, 170, 36, "check + settle")
    d.badge(B - 104, 574, 11)
    msg(12, 616, B, A, "receipt", dashed=True)
    d.save()


def security_layers():
    d = Diagram("security-layers", 1200, 250)
    steps = [("Sign-in", "password + JWT"), ("Payee check", "registry"), ("Fraud model", "risk score"),
             ("Policy", "block or verify"), ("Fingerprint", "student only"), ("Settlement", "balance re-check"),
             ("Audit log", "hash + anchor")]
    w, gap, x0, y = 146, 20, 31, 46
    for i, (t, s) in enumerate(steps):
        x = x0 + i * (w + gap)
        d.node(x, y, w, 92, t, s, kind="dark" if t == "Fingerprint" else "plain")
        d.badge(x + w / 2, y, i + 1)
        if i < len(steps) - 1:
            d.arrow([(x + w, y + 46), (x + w + gap, y + 46)])
    # brackets
    def bracket(i0, i1, text):
        xa, xb = x0 + i0 * (w + gap), x0 + i1 * (w + gap) + w
        yb = y + 92 + 26
        d.add(f'<path d="M{xa},{yb - 8} L{xa},{yb} L{xb},{yb} L{xb},{yb - 8}" fill="none" stroke="#BDBDBD" stroke-width="1.2"/>')
        d.text((xa + xb) / 2, yb + 24, text, size=13, weight=600, color=MUTED, anchor="middle")
    bracket(0, 3, "Before the student is asked")
    bracket(4, 4, "Student decides")
    bracket(5, 6, "After approval")
    d.save()


def hybrid_risk_model():
    d = Diagram("hybrid-risk-model", 1200, 520)
    d.node(24, 218, 120, 60, "Payment")
    d.node(184, 210, 150, 76, "20 features", "per payment")
    models = ["Logistic regression", "Random forest", "XGBoost", "Gradient boosting", "Neural network", "Autoencoder"]
    ys = [86 + i * 56 for i in range(6)]
    for y, m in zip(ys, models):
        d.node(384, y, 190, 44, m)
    centers = [y + 22 for y in ys]
    # features -> models (bracket)
    d.arrow([(144, 248), (184, 248)])
    d.line(359, centers[0], 359, centers[-1], color=INK, width=1.5)
    d.line(334, 248, 359, 248, color=INK, width=1.5)
    for c in centers:
        d.arrow([(359, c), (384, c)])
    # models -> meta (bracket)
    for c in centers:
        d.line(574, c, 599, c, color=INK, width=1.5)
    d.line(599, centers[0], 599, centers[-1], color=INK, width=1.5)
    d.node(624, 205, 150, 86, "Meta-learner", "stacking", kind="dark")
    d.arrow([(599, 248), (624, 248)])
    # score -> levels
    levels = [("Low", "< 0.10", "ok", 140), ("Medium", "0.10 – 0.70", "warn", 225), ("High", "≥ 0.70", "danger", 310)]
    d.line(774, 248, 799, 248, color=INK, width=1.5)
    d.line(799, 163, 799, 333, color=INK, width=1.5)
    for t, s, k, y in levels:
        d.node(824, y, 150, 46, t, s, kind=k)
        d.arrow([(799, y + 23), (824, y + 23)])
    # levels -> tiers
    d.node(1024, 170, 152, 56, "T2 · Verify", "fingerprint needed", kind="dark")
    d.node(1024, 305, 152, 56, "T3 · Block", "refused", kind="danger")
    d.arrow([(974, 163), (999, 163), (999, 198), (1024, 198)])
    d.arrow([(974, 248), (999, 248), (999, 198), (1024, 198)])
    d.arrow([(974, 333), (1024, 333)])
    # hard rules
    d.node(624, 420, 150, 56, "Hard rules", "mule · fake account")
    d.arrow([(774, 448), (1100, 448), (1100, 361)])
    d.label(940, 436, "always block")
    d.save()


def audit_anchoring():
    d = Diagram("audit-anchoring", 1200, 480)
    d.group(20, 24, 740, 150, "Database")
    d.group(800, 24, 380, 150, "Public blockchain", dashed=True)
    d.text(44, 117, "…", size=22, weight=600, color=MUTED)
    for i, (t, s, k) in enumerate((("Record 202", "SHA-256 hash", "plain"), ("Record 203", "SHA-256 hash", "plain"),
                                   ("Record 204", "latest hash", "plain"))):
        x = 80 + i * 230
        d.node(x, 74, 190, 66, t, s, kind=k)
        if i:
            d.arrow([(x - 40, 107), (x, 107)])
    d.arrow([(64, 107), (80, 107)])
    d.node(830, 74, 320, 66, "Sepolia transaction", "record id + hash", kind="dark")
    d.arrow([(730, 107), (830, 107)])
    d.label(780, 95, "daily")
    # checks
    d.node(80, 250, 280, 64, "Check 1 · Hash chain", "recompute every hash")
    d.node(850, 250, 280, 64, "Check 2 · Blockchain", "compare with Sepolia")
    d.arrow([(220, 174), (220, 250)])
    d.arrow([(990, 174), (990, 250)])
    d.diamond(605, 282, 190, 96, ["Both", "match?"])
    d.arrow([(360, 282), (510, 282)])
    d.arrow([(850, 282), (700, 282)])
    d.node(420, 400, 160, 50, "Log intact", kind="ok")
    d.node(630, 400, 160, 50, "Mismatch", kind="danger")
    d.line(605, 330, 605, 350, color=INK, width=1.5)
    d.arrow([(605, 350), (500, 350), (500, 400)])
    d.arrow([(605, 350), (710, 350), (710, 400)])
    d.label(500, 376, "yes")
    d.label(710, 376, "no")
    d.save()


def permission_tiers():
    d = Diagram("permission-tiers", 1200, 420)
    d.node(30, 172, 150, 56, "Agent action", "proposed by AI")
    d.diamond(300, 200, 170, 100, ["Moves", "money?"])
    d.arrow([(180, 200), (215, 200)])
    d.node(380, 52, 190, 56, "T0 · Read", "runs now", kind="ok")
    d.arrow([(300, 150), (300, 80), (380, 80)])
    d.label(300, 116, "no")
    d.diamond(560, 200, 200, 110, ["Block rule or", "high risk?"])
    d.arrow([(385, 200), (460, 200)])
    d.label(422, 200, "yes")
    d.node(470, 320, 180, 60, "T3 · Block", "refused + reasons", kind="danger")
    d.arrow([(560, 255), (560, 320)])
    d.label(560, 288, "yes")
    d.node(720, 172, 180, 56, "T2 · Verify", "prepared, waits", kind="dark")
    d.arrow([(660, 200), (720, 200)])
    d.label(690, 200, "no")
    d.diamond(1000, 200, 150, 100, ["Fingerprint?"])
    d.arrow([(900, 200), (925, 200)])
    d.node(1095, 175, 85, 50, "Paid", kind="ok")
    d.arrow([(1075, 200), (1095, 200)])
    d.node(930, 320, 140, 60, "Not paid", "declined · expired")
    d.arrow([(1000, 250), (1000, 320)])
    d.label(1000, 286, "no")
    d.save()


if __name__ == "__main__":
    for f in (architecture, payment_lifecycle, verification_sequence, security_layers, hybrid_risk_model,
              audit_anchoring, permission_tiers):
        f()
