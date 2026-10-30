#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the AWS architecture diagram for deploy/aws.

Outputs (next to this script):
  architecture.drawio  editable draw.io diagram with AWS icons. This is the source.
  architecture.svg     static preview drawn from the same layout data
  architecture.png     PNG for README.md. Exported by draw.io when its CLI is installed,
                       otherwise rendered from the SVG preview with rsvg-convert.

Usage (from the repository root):
  python3 deploy/aws/docs/generate_diagram.py

Edit NODES / EDGES / STEPS below and re-run, or edit architecture.drawio in draw.io
(Desktop, app.diagrams.net, or the VS Code / Kiro "Draw.io Integration" extension)
and export the PNG from there with File > Export as > PNG.
"""
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

OUT = Path(__file__).resolve().parent
PAGE_W, PAGE_H = 1720, 1280

# ------------------------------------------------------------------ styles
COLOR = {"compute": "#ED7100", "storage": "#7AA116", "network": "#8C4FFF",
         "security": "#DD344C", "mgmt": "#E7157B", "actor": "#232F3D"}


def icon_style(res_icon, cat):
    return ("sketch=0;outlineConnect=0;fontColor=#232F3E;gradientColor=none;"
            f"fillColor={COLOR[cat]};strokeColor=#ffffff;dashed=0;verticalLabelPosition=bottom;"
            "verticalAlign=top;align=center;html=1;fontSize=12;fontStyle=0;aspect=fixed;"
            f"shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{res_icon};")


def resource_style(shape, cat):
    """Resource-level glyphs (NAT gateway, users, ...): no tile, filled glyph."""
    return ("sketch=0;outlineConnect=0;fontColor=#232F3E;gradientColor=none;"
            f"fillColor={COLOR[cat]};strokeColor=none;dashed=0;verticalLabelPosition=bottom;"
            "verticalAlign=top;align=center;html=1;fontSize=12;fontStyle=0;aspect=fixed;"
            f"pointerEvents=1;shape=mxgraph.aws4.{shape};")


GROUP_BASE = ("points=[[0,0],[0.25,0],[0.5,0],[0.75,0],[1,0],[1,0.25],[1,0.5],[1,0.75],[1,1],"
              "[0.75,1],[0.5,1],[0.25,1],[0,1],[0,0.75],[0,0.5],[0,0.25]];outlineConnect=0;"
              "gradientColor=none;html=1;whiteSpace=wrap;fontSize=12;fontStyle=0;container=1;"
              "pointerEvents=0;collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;"
              "verticalAlign=top;align=left;spacingLeft=30;")
GROUP_STYLE = {
    "cloud":   GROUP_BASE + "grIcon=mxgraph.aws4.group_aws_cloud_alt;strokeColor=#232F3E;fillColor=none;fontColor=#232F3E;dashed=0;",
    "region":  GROUP_BASE + "grIcon=mxgraph.aws4.group_region;strokeColor=#00A4A6;fillColor=none;fontColor=#147EBA;dashed=1;",
    "vpc":     GROUP_BASE + "grIcon=mxgraph.aws4.group_vpc2;strokeColor=#8C4FFF;fillColor=none;fontColor=#AAB7B8;dashed=0;",
    "public":  GROUP_BASE + "grIcon=mxgraph.aws4.group_security_group;grStroke=0;strokeColor=#7AA116;fillColor=#F2F6E8;fontColor=#248814;dashed=0;",
    "private": GROUP_BASE + "grIcon=mxgraph.aws4.group_security_group;grStroke=0;strokeColor=#00A4A6;fillColor=#E6F6F7;fontColor=#147EBA;dashed=0;",
    "logical": ("rounded=1;whiteSpace=wrap;html=1;dashed=1;fillColor=none;strokeColor=#879196;"
                "verticalAlign=top;align=left;spacingLeft=10;fontStyle=1;container=1;collapsible=0;"
                "fontColor=#232F3E;fontSize=12;arcSize=3;"),
    "ec2":     ("rounded=1;whiteSpace=wrap;html=1;dashed=0;fillColor=#FFFFFF;strokeColor=#ED7100;"
                "verticalAlign=top;align=left;spacingLeft=10;fontStyle=1;container=1;collapsible=0;"
                "fontColor=#ED7100;fontSize=12;arcSize=3;"),
}
BOX_STYLE = ("rounded=1;whiteSpace=wrap;html=1;fontSize=11;align=center;verticalAlign=middle;"
             "fillColor={fill};strokeColor={stroke};fontColor=#232F3E;arcSize=12;")
TITLE_STYLE = "text;html=1;fontSize=20;fontStyle=1;align=left;verticalAlign=middle;fontColor=#232F3E;"
SUBTITLE_STYLE = "text;html=1;fontSize=12;align=left;verticalAlign=middle;fontColor=#545B64;"
BADGE_STYLE = ("ellipse;whiteSpace=wrap;html=1;aspect=fixed;fillColor=#232F3E;fontColor=#FFFFFF;"
               "strokeColor=none;fontStyle=1;fontSize=12;")
LEGEND_STYLE = ("rounded=0;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor=#879196;"
                "align=left;verticalAlign=top;spacingLeft=12;spacingTop=8;fontSize=12;fontColor=#232F3E;")
EDGE_STYLE = ("edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;"
              "endArrow=block;endFill=1;strokeColor={color};strokeWidth=1.5;fontSize=11;"
              "fontColor=#232F3E;labelBackgroundColor=#FFFFFF;{extra}")

# ------------------------------------------------------------------ layout
# Absolute page coordinates (converted to parent-relative when written).
# Groups are listed before their children. Icons are 64x64 on the main grid, 48x48 inside EC2.
N = {}


def node(nid, kind, x, y, w, h, label="", parent=None, **kw):
    N[nid] = dict(kind=kind, x=x, y=y, w=w, h=h, label=label, parent=parent, **kw)


node("title", "title", 20, 18, 640, 36, "Astronomy Shop on AWS")
node("subtitle", "subtitle", 20, 52, 640, 24,
     "OpenTelemetry demo · one environment per AWS account · deploy/aws")
node("internet", "box", 600, 96, 300, 56,
     "<b>Internet</b><br>GitHub (your fork) · ghcr.io images", fill="#F5F5F5", stroke="#879196")

node("cloud", "group", 170, 190, 1520, 940, "AWS Cloud (one account per environment)", g="cloud")
node("edge", "group", 200, 240, 310, 770, "CloudFront edge (global)", g="logical", parent="cloud")
node("region", "group", 550, 220, 1120, 890, "Region us-east-1", g="region", parent="cloud")
node("vpc", "group", 580, 270, 780, 560, "VPC (per env)", g="vpc", parent="region")
node("pub", "group", 610, 330, 180, 190, "Public subnet", g="public", parent="vpc")
node("priv", "group", 820, 300, 510, 500, "Private subnets (2 AZ)", g="private", parent="vpc")
node("ec2grp", "group", 960, 330, 350, 450, "EC2 instance · Docker Compose", g="ec2", parent="priv")

# actors
node("visitors", "icon", 60, 500, 64, 64, "Shoppers<br>(any device)", style=resource_style("users", "actor"))
node("admin", "icon", 60, 720, 64, 64, "Admin", style=resource_style("user", "actor"))
node("operator", "icon", 60, 990, 64, 64, "Operator<br>(deploy/aws/scripts)", style=resource_style("user", "actor"))

# CloudFront edge
node("cff", "box", 285, 300, 140, 56, "<b>Block bypasses</b><br>(CloudFront Function)",
     parent="edge", fill="#F3EDFF", stroke="#8C4FFF")
node("cf", "icon", 323, 500, 64, 64, "Public HTTPS entry<br>(CloudFront)", parent="edge",
     style=icon_style("cloudfront", "network"))
node("ledge", "icon", 323, 900, 64, 64, "Admin login check<br>(Lambda@Edge)", parent="edge",
     style=icon_style("lambda", "compute"))

# VPC
node("igw", "icon", 720, 238, 64, 64, "", parent="vpc", style=resource_style("internet_gateway", "network"))
node("nat", "icon", 720, 390, 64, 64, "Outbound only<br>(NAT Gateway)", parent="pub",
     style=resource_style("nat_gateway", "network"))
node("alb", "icon", 850, 500, 64, 64, "Origin, CloudFront<br>IPs only (internal ALB)", parent="priv",
     style=icon_style("elastic_load_balancing", "network"))
node("ec2", "icon", 980, 380, 48, 48, "t4g.large<br>no public IP<br>(EC2)", parent="ec2grp",
     style=icon_style("ec2", "compute"), label_w=88)
node("vpce", "icon", 1328, 630, 64, 64, "", parent="vpc", style=resource_style("endpoints", "network"))

# containers on the instance
BOX = dict(fill="#FFFFFF", stroke="#ED7100")
HOT = dict(fill="#FFF4E8", stroke="#ED7100")
node("c_shop", "box", 1055, 380, 235, 34, "Storefront + ~15 services", parent="ec2grp", **BOX)
node("c_tools", "box", 1055, 424, 235, 34, "Locust · flagd · Grafana", parent="ec2grp", **BOX)
node("c_envoy", "box", 1055, 515, 235, 34, "<b>Envoy :8080</b> (only open port)", parent="ec2grp", **HOT)
node("c_otel", "box", 1055, 645, 235, 34, "<b>OTel Collector</b>", parent="ec2grp", **HOT)
node("c_store", "box", 1055, 720, 235, 44, "Jaeger · Prometheus · OpenSearch<br>(on EBS, 60 days)",
     parent="ec2grp", **BOX)

# regional services outside the VPC
node("ssmps", "icon", 1530, 300, 64, 64, "Settings + admin<br>password<br>(SSM Parameter Store)",
     parent="region", style=icon_style("systems_manager", "mgmt"))
node("s3", "icon", 1530, 630, 64, 64, "Telemetry archive<br>OTLP JSON, 90 days<br>(S3)",
     parent="region", style=icon_style("s3", "storage"))
node("cognito", "icon", 660, 900, 64, 64, "Admin users, login page<br>(Cognito)",
     parent="region", style=icon_style("cognito", "security"))
node("ssmsm", "icon", 1103, 990, 64, 64, "Shell or tunnel<br>(Session Manager)",
     parent="region", style=icon_style("systems_manager", "mgmt"))

# (id, source, target, label, color, dashed, extra style)
EDGES = [
    ("e_visit_cf", "visitors", "cf", "HTTPS", "#232F3E", False, ""),
    ("e_admin_cf", "admin", "cf", "HTTPS", "#232F3E", False, "exitX=1;exitY=0.5;entryX=0;entryY=0.75;"),
    ("e_cf_cff", "cf", "cff", "other paths", "#8C4FFF", True, "exitX=0.5;exitY=0;entryX=0.5;entryY=1;"),
    ("e_cf_ledge", "cf", "ledge", "admin paths", "#8C4FFF", True, "exitX=0.5;exitY=1;entryX=0.5;entryY=0;"),
    ("e_ledge_cognito", "ledge", "cognito", "verify login", "#DD344C", True, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_cf_alb", "cf", "alb", "VPC origin", "#8C4FFF", False, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_alb_envoy", "alb", "c_envoy", "HTTP :8080", "#8C4FFF", False, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_otel_vpce", "c_otel", "vpce", "", "#7AA116", False, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_vpce_s3", "vpce", "s3", "PutObject", "#7AA116", False, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_otel_store", "c_otel", "c_store", "export", "#ED7100", False, "exitX=0.5;exitY=1;entryX=0.5;entryY=0;"),
    ("e_ec2_ssm", "ec2grp", "ssmps", "read at boot", "#E7157B", True, "exitX=1;exitY=0.11;entryX=0;entryY=0.5;"),
    ("e_ec2_nat", "ec2", "nat", "outbound", "#545B64", True, "exitX=0;exitY=0.5;entryX=1;entryY=0.5;"),
    ("e_nat_igw", "nat", "igw", "", "#545B64", True, "exitX=0.5;exitY=0;entryX=0.5;entryY=1;"),
    ("e_igw_inet", "igw", "internet", "clone, pull", "#545B64", True, "exitX=0.5;exitY=0;entryX=0.6;entryY=1;"),
    ("e_op_ssm", "operator", "ssmsm", "tunnel.sh (optional)", "#E7157B", True, "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"),
    ("e_ssm_ec2", "ssmsm", "ec2grp", "", "#E7157B", True, "exitX=0.5;exitY=0;entryX=0.44;entryY=1;"),
]

# Numbered badges next to the main flow, explained in the legend.
BADGES = [("b1", "1", 200, 504), ("b2", "2", 600, 504), ("b3", "3", 925, 504),
          ("b4", "4", 340, 830), ("b5", "5", 1420, 628), ("b6", "6", 1460, 296)]
STEPS = [
    "<b>1</b>  Shoppers open the store over HTTPS. CloudFront is the only public entry point.",
    "<b>2</b>  CloudFront reaches the internal ALB through a VPC origin; the ALB accepts CloudFront IP ranges only.",
    "<b>3</b>  The ALB forwards to Envoy on the instance, which routes to the storefront, services and tools.",
    "<b>4</b>  Admin paths (/grafana /jaeger /feature /loadgen /telemetry) go through Lambda@Edge, which requires a Cognito login. Other spellings and /opamp get 403.",
    "<b>5</b>  The OTel Collector keeps 60 days on disk (Jaeger, Prometheus, OpenSearch) and archives everything to S3 through a gateway endpoint.",
    "<b>6</b>  At boot the instance reads its settings from Parameter Store and clones your fork through the NAT Gateway. No inbound access, no SSH.",
]
node("legend", "legend", 170, 1150, 1520, 0, "")  # height computed below
N["legend"]["h"] = 24 + 16 * len(STEPS)
N["legend"]["y"] = PAGE_H - N["legend"]["h"] - 20


# ------------------------------------------------------------------ icon color rule
# Service icons are a category-colored square with a WHITE glyph: strokeColor=#ffffff and
# gradientColor=none, always written explicitly. General icons (users, client) and
# no-square resource icons (NAT gateway, internet gateway, endpoint) are exempt.
OFFICIAL_FILLS = {"#ED7100", "#7AA116", "#C925D1", "#8C4FFF", "#01A88D", "#DD344C", "#E7157B"}


def style_dict(style):
    return dict(p.split("=", 1) for p in (style or "").split(";") if "=" in p)


def fix_icon_style(style):
    st = style_dict(style)
    if st.get("shape") == "mxgraph.aws4.resourceIcon":
        st["strokeColor"] = "#ffffff"
        st["gradientColor"] = "none"
        return ";".join(f"{k}={v}" for k, v in st.items()) + ";"
    return style


def check_icon_colors(path):
    errors = []
    for c in ET.parse(path).findall(".//mxCell"):
        st = style_dict(c.get("style"))
        if st.get("shape") == "mxgraph.aws4.resourceIcon":
            if st.get("strokeColor", "").lower() != "#ffffff":
                errors.append(f"{c.get('id')}: glyph not white (strokeColor={st.get('strokeColor')})")
            if st.get("fillColor", "").upper() not in OFFICIAL_FILLS:
                errors.append(f"{c.get('id')}: non official fillColor {st.get('fillColor')}")
            if st.get("gradientColor", "none") != "none":
                errors.append(f"{c.get('id')}: gradient not allowed")
    return errors


# ------------------------------------------------------------------ draw.io XML
def rel(nid):
    n = N[nid]
    p = n.get("parent")
    return (n["x"] - N[p]["x"], n["y"] - N[p]["y"]) if p else (n["x"], n["y"])


def build_drawio():
    mxfile = ET.Element("mxfile", host="app.diagrams.net")
    diagram = ET.SubElement(mxfile, "diagram", id="arch", name="Architecture")
    model = ET.SubElement(diagram, "mxGraphModel", dx="1400", dy="900", grid="1", gridSize="10",
                          guides="1", tooltips="1", connect="1", arrows="1", fold="1", page="1",
                          pageScale="1", pageWidth=str(PAGE_W), pageHeight=str(PAGE_H),
                          math="0", shadow="0", background="#FFFFFF")
    root = ET.SubElement(model, "root")
    ET.SubElement(root, "mxCell", id="0")
    ET.SubElement(root, "mxCell", id="1", parent="0")

    def vertex(cid, value, style, parent, x, y, w, h):
        c = ET.SubElement(root, "mxCell", id=cid, value=value, style=fix_icon_style(style),
                          vertex="1", parent=parent)
        ET.SubElement(c, "mxGeometry", x=str(x), y=str(y), width=str(w), height=str(h), **{"as": "geometry"})

    for nid, n in N.items():
        x, y = rel(nid)
        style = {"group": lambda: GROUP_STYLE[n["g"]],
                 "box": lambda: BOX_STYLE.format(fill=n["fill"], stroke=n["stroke"]),
                 "icon": lambda: n["style"], "title": lambda: TITLE_STYLE,
                 "subtitle": lambda: SUBTITLE_STYLE, "legend": lambda: LEGEND_STYLE}[n["kind"]]()
        value = "<br>".join(STEPS) if nid == "legend" else n["label"]
        vertex(nid, value, style, n.get("parent") or "1", x, y, n["w"], n["h"])

    for eid, s, t, label, color, dashed, extra in EDGES:
        style = EDGE_STYLE.format(color=color, extra=("dashed=1;" if dashed else "") + extra)
        c = ET.SubElement(root, "mxCell", id=eid, value=label, style=style, edge="1",
                          parent="1", source=s, target=t)
        ET.SubElement(c, "mxGeometry", relative="1", **{"as": "geometry"})

    for bid, text, x, y in BADGES:
        vertex(bid, text, BADGE_STYLE, "1", x, y, 24, 24)
    ET.indent(mxfile)
    return ET.ElementTree(mxfile)


# ------------------------------------------------------------------ validation
def label_lines(n):
    return len(n["label"].split("<br>")) if n["kind"] == "icon" and n["label"] else 0


def footprint(n):
    """Box including the label under an icon (approx. 14 px per line, 150 px wide)."""
    x, y, w, h = n["x"], n["y"], n["w"], n["h"]
    lines = label_lines(n)
    if lines:
        lw = n.get("label_w", max(w, 150))
        return x + w / 2 - lw / 2, y, lw, h + 4 + 14 * lines
    return x, y, w, h


def overlaps(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def validate(path):
    errors = []
    tree = ET.parse(path)                                        # 1. well formed
    cells = tree.findall(".//mxCell")
    ids = [c.get("id") for c in cells]
    if len(ids) != len(set(ids)):                                # 2. unique ids
        errors.append("duplicate ids")
    idset = set(ids)
    for c in cells:
        if c.get("id") != "0" and c.get("parent") not in idset:  # 3. parents exist
            errors.append(f"bad parent on {c.get('id')}")
        if c.get("edge") == "1" and not (c.get("source") in idset and c.get("target") in idset):
            errors.append(f"dangling edge {c.get('id')}")         # 4. edges attached
    straddle = {"igw", "vpce"}  # drawn on the VPC border on purpose
    for nid, n in N.items():                                     # 5. children inside containers
        p = n.get("parent")
        if p and nid not in straddle:
            q = N[p]
            fx, fy, fw, fh = (n["x"], n["y"], n["w"], n["h"])
            if not (fx >= q["x"] and fy >= q["y"] + 30 and fx + fw <= q["x"] + q["w"]
                    and fy + fh <= q["y"] + q["h"]):
                errors.append(f"{nid} does not fit inside {p} (with label padding)")
        if n["x"] + n["w"] > PAGE_W or n["y"] + n["h"] > PAGE_H:
            errors.append(f"{nid} is off the page")
    leaves = [k for k, n in N.items() if n["kind"] in ("icon", "box")]
    for i, a in enumerate(leaves):                               # 6. no overlapping shapes/labels
        for b in leaves[i + 1:]:
            if overlaps(footprint(N[a]), footprint(N[b])):
                errors.append(f"{a} overlaps {b}")
    errors += check_icon_colors(path)                            # 7. white glyphs, official fills
    return errors, len(cells)


# ------------------------------------------------------------------ SVG preview
PREVIEW_GROUP = {"cloud": ("#232F3E", "none", ""), "region": ("#00A4A6", "none", "6,4"),
                 "vpc": ("#8C4FFF", "none", ""), "public": ("#7AA116", "#F2F6E8", ""),
                 "private": ("#00A4A6", "#E6F6F7", ""), "logical": ("#879196", "none", "6,4"),
                 "ec2": ("#ED7100", "#FFFFFF", "")}
GLYPH = {"visitors": ("Users", "actor"), "admin": ("Admin", "actor"), "operator": ("CLI", "actor"),
         "cf": ("CloudFront", "network"), "ledge": ("λ@Edge", "compute"), "igw": ("IGW", "network"),
         "nat": ("NAT", "network"), "alb": ("ALB", "network"), "ec2": ("EC2", "compute"),
         "vpce": ("VPCE", "network"), "ssmps": ("SSM", "mgmt"), "s3": ("S3", "storage"),
         "cognito": ("Cognito", "security"), "ssmsm": ("SSM", "mgmt")}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def lines_of(label):
    text = re.sub(r"</?b>", "", label).replace("&lt;", "<").replace("&gt;", ">")
    return text.split("<br>")


def port(n, fx, fy):
    return n["x"] + n["w"] * fx, n["y"] + n["h"] * fy


def parse_ports(extra):
    vals = dict(re.findall(r"(exitX|exitY|entryX|entryY)=([0-9.]+)", extra))
    return {k: float(v) for k, v in vals.items()}


def route(a, b, extra):
    p = parse_ports(extra)
    ax, ay = port(a, p.get("exitX", 1), p.get("exitY", 0.5))
    bx, by = port(b, p.get("entryX", 0), p.get("entryY", 0.5))
    exit_vertical = p.get("exitY", 0.5) in (0, 1)
    entry_vertical = p.get("entryY", 0.5) in (0, 1)
    if abs(ax - bx) < 1 or abs(ay - by) < 1:
        return [(ax, ay), (bx, by)]
    if exit_vertical and entry_vertical:
        my = (ay + by) / 2
        return [(ax, ay), (ax, my), (bx, my), (bx, by)]
    if not exit_vertical and not entry_vertical:
        mx = (ax + bx) / 2
        return [(ax, ay), (mx, ay), (mx, by), (bx, by)]
    if exit_vertical:
        return [(ax, ay), (ax, by), (bx, by)]
    return [(ax, ay), (bx, ay), (bx, by)]


def build_svg():
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{PAGE_W}" height="{PAGE_H}" '
         f'viewBox="0 0 {PAGE_W} {PAGE_H}" font-family="Helvetica, Arial, sans-serif">',
         '<rect width="100%" height="100%" fill="#FFFFFF"/><defs>']
    for color in {e[4] for e in EDGES}:
        o.append(f'<marker id="m{color[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                 f'markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')
    o.append("</defs>")

    for nid, n in N.items():
        if n["kind"] == "group":
            stroke, fill, dash = PREVIEW_GROUP[n["g"]]
            d = f' stroke-dasharray="{dash}"' if dash else ""
            o.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="4" '
                     f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"{d}/>')
            color = "#545B64" if n["g"] == "vpc" else stroke
            o.append(f'<text x="{n["x"] + 12}" y="{n["y"] + 20}" font-size="12.5" font-weight="bold" '
                     f'fill="{color}">{esc(lines_of(n["label"])[0])}</text>')
        elif n["kind"] == "title":
            o.append(f'<text x="{n["x"]}" y="{n["y"] + 26}" font-size="22" font-weight="bold" fill="#232F3E">{esc(n["label"])}</text>')
        elif n["kind"] == "subtitle":
            o.append(f'<text x="{n["x"]}" y="{n["y"] + 17}" font-size="13" fill="#545B64">{esc(n["label"])}</text>')

    edge_labels = []
    for eid, s, t, label, color, dashed, extra in EDGES:
        pts = route(N[s], N[t], extra)
        d = " ".join(f"{x:.0f},{y:.0f}" for x, y in pts)
        dash = ' stroke-dasharray="6,4"' if dashed else ""
        o.append(f'<polyline points="{d}" fill="none" stroke="{color}" stroke-width="1.6"{dash} '
                 f'marker-end="url(#m{color[1:]})"/>')
        if label:
            seg = max(range(len(pts) - 1), key=lambda i: abs(pts[i][0] - pts[i + 1][0]) + abs(pts[i][1] - pts[i + 1][1]))
            (x1, y1), (x2, y2) = pts[seg], pts[seg + 1]
            edge_labels.append(((x1 + x2) / 2, (y1 + y2) / 2, label))

    for nid, n in N.items():
        if n["kind"] == "box":
            o.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="5" '
                     f'fill="{n["fill"]}" stroke="{n["stroke"]}"/>')
            ls = lines_of(n["label"])
            y0 = n["y"] + n["h"] / 2 - (len(ls) - 1) * 7 + 4
            for i, line in enumerate(ls):
                bold = ' font-weight="bold"' if i == 0 and n["label"].startswith("<b>") else ""
                o.append(f'<text x="{n["x"] + n["w"] / 2}" y="{y0 + i * 14}" font-size="11.5" '
                         f'text-anchor="middle"{bold} fill="#232F3E">{esc(line)}</text>')
        elif n["kind"] == "icon":
            text, cat = GLYPH[nid]
            o.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="6" fill="{COLOR[cat]}"/>')
            fs = 10 if len(text) > 6 else 12
            o.append(f'<text x="{n["x"] + n["w"] / 2}" y="{n["y"] + n["h"] / 2 + 4}" font-size="{fs}" '
                     f'font-weight="bold" text-anchor="middle" fill="#FFFFFF">{esc(text)}</text>')
            if n["label"]:
                for i, line in enumerate(lines_of(n["label"])):
                    o.append(f'<text x="{n["x"] + n["w"] / 2}" y="{n["y"] + n["h"] + 16 + i * 14}" '
                             f'font-size="11.5" text-anchor="middle" fill="#232F3E">{esc(line)}</text>')

    for x, y, label in edge_labels:
        w = len(label) * 6.3 + 10
        o.append(f'<rect x="{x - w / 2:.0f}" y="{y - 9:.0f}" width="{w:.0f}" height="17" fill="#FFFFFF"/>')
        o.append(f'<text x="{x:.0f}" y="{y + 4:.0f}" font-size="11" text-anchor="middle" fill="#232F3E">{esc(label)}</text>')

    for bid, text, x, y in BADGES:
        o.append(f'<circle cx="{x + 12}" cy="{y + 12}" r="12" fill="#232F3E"/>')
        o.append(f'<text x="{x + 12}" y="{y + 16}" font-size="12" font-weight="bold" text-anchor="middle" fill="#FFFFFF">{text}</text>')

    lg = N["legend"]
    o.append(f'<rect x="{lg["x"]}" y="{lg["y"]}" width="{lg["w"]}" height="{lg["h"]}" fill="#FFFFFF" stroke="#879196"/>')
    for i, step in enumerate(STEPS):
        num, rest = re.match(r"<b>(\d+)</b>\s+(.*)", step).groups()
        y = lg["y"] + 22 + i * 16
        o.append(f'<text x="{lg["x"] + 14}" y="{y}" font-size="12.5" fill="#232F3E">'
                 f'<tspan font-weight="bold">{num}</tspan>  {esc(rest)}</text>')
    o.append(f'<text x="{PAGE_W - 14}" y="{PAGE_H - 6}" font-size="10" text-anchor="end" fill="#879196">'
             "Preview rendered from the layout in generate_diagram.py; architecture.drawio has the AWS icons.</text>")
    o.append("</svg>")
    return "\n".join(o)


# ------------------------------------------------------------------ main
def main():
    drawio_path = OUT / "architecture.drawio"
    build_drawio().write(drawio_path, encoding="utf-8")
    errors, count = validate(drawio_path)
    if errors:
        sys.exit("diagram validation failed:\n  " + "\n  ".join(errors))
    icons = sum(1 for c in ET.parse(drawio_path).findall(".//mxCell")
                if style_dict(c.get("style")).get("shape") == "mxgraph.aws4.resourceIcon")
    print(f"OK {count} cells -> {drawio_path}")
    print(f"Icon colors OK ({icons} service icons: white glyph, official fill, no gradient)")

    svg_path = OUT / "architecture.svg"
    svg_path.write_text(build_svg(), encoding="utf-8")
    ET.parse(svg_path)
    print(f"wrote {svg_path}")

    png_path = OUT / "architecture.png"
    cli = shutil.which("drawio") or next((p for p in ["/Applications/draw.io.app/Contents/MacOS/draw.io"]
                                          if Path(p).exists()), None)
    if cli:
        subprocess.run([cli, "-x", "-f", "png", "-s", "2", "-o", str(png_path), str(drawio_path)], check=True)
        print(f"wrote {png_path} (draw.io export)")
    elif shutil.which("rsvg-convert"):
        subprocess.run(["rsvg-convert", "-z", "1.2", "-o", str(png_path), str(svg_path)], check=True)
        print(f"wrote {png_path} (SVG preview; draw.io CLI not found)")
    else:
        print("no PNG written: install draw.io Desktop or librsvg (rsvg-convert)")


if __name__ == "__main__":
    main()
