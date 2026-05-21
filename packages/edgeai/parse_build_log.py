#!/usr/bin/env python3
"""parse_build_log.py — Parse build_armbian.sh log and generate a BUILD_TIMES.md report.

Usage:
    python3 parse_build_log.py [LOG_FILE] [--output OUTPUT_FILE]

    LOG_FILE     path to build log (default: /tmp/build.log)
    --output     write markdown to this file instead of stdout
"""

import re
import sys
import argparse
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Regex helpers
# ---------------------------------------------------------------------------
ANSI_ESCAPE  = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
TIMESTAMP_RE = re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(.*)')
PHASE_RE     = re.compile(r'^===\s+([A-Z0-9]+):\s+(.+?)\s*===\s*$')
DONE_RE      = re.compile(r'^===\s*Build complete\s*===', re.IGNORECASE)
SEQ_RE       = re.compile(r'^===\s*Build sequence\s*===', re.IGNORECASE)
SDK_RE       = re.compile(r'SDK:\s+(\S+)')
SKIP_RE      = re.compile(r'--skip-(\S+)')
BOARD_RE     = re.compile(r"BOARD=(\S+)")
BRANCH_RE    = re.compile(r"BRANCH=(\S+)")


def strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub('', text)


def parse_timestamp(s: str) -> datetime | None:
    try:
        return datetime.strptime(s, '%Y-%m-%d %H:%M:%S')
    except ValueError:
        return None


def fmt_duration(delta: timedelta) -> str:
    total = int(delta.total_seconds())
    h, rem = divmod(total, 3600)
    m, s   = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def fmt_time(dt: datetime) -> str:
    return dt.strftime('%H:%M:%S')


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------
def parse_log(path: Path) -> dict:
    phases      = []        # list of {id, desc, start, end}
    current     = None
    build_date  = None
    sdk_path    = None
    skip_flags  = set()
    board       = "j784s4-evm"
    branch      = "vendor"
    in_seq      = False
    build_cmd   = None
    complete    = False
    last_ts     = None

    with open(path) as fh:
        for raw in fh:
            raw = raw.rstrip('\n')
            m   = TIMESTAMP_RE.match(raw)
            if not m:
                continue

            ts_str, rest = m.group(1), strip_ansi(m.group(2)).strip()
            ts = parse_timestamp(ts_str)
            if ts is None:
                continue

            last_ts = ts
            if build_date is None:
                build_date = ts.date()

            # Extract SDK path from the build-sequence header block
            if in_seq:
                sdk_m = SDK_RE.search(rest)
                if sdk_m:
                    sdk_path = sdk_m.group(1)

            # Detect build sequence block
            if SEQ_RE.match(rest):
                in_seq = True
                continue

            # Capture build command line (contains --sdk-path and --skip-* flags)
            if 'build_armbian.sh' in rest and '--sdk-path' in rest:
                build_cmd = 'bash packages/edgeai/build_armbian.sh ' + \
                            rest.split('build_armbian.sh', 1)[1].strip()
                for s in SKIP_RE.findall(rest):
                    skip_flags.add(s)
                bm = BOARD_RE.search(rest)
                if bm:
                    board = bm.group(1)

            # BOARD/BRANCH from Armbian parameter lines
            bom = BOARD_RE.search(rest)
            brm = BRANCH_RE.search(rest)
            if bom and 'BOARD' in rest:
                board = bom.group(1)
            if brm and 'BRANCH' in rest:
                branch = brm.group(1)

            # Phase start: === XX: description ===
            pm = PHASE_RE.match(rest)
            if pm:
                in_seq = False
                if current:
                    current['end'] = ts
                    phases.append(current)
                current = {'id': pm.group(1), 'desc': pm.group(2), 'start': ts, 'end': None}
                continue

            # Build complete sentinel
            if DONE_RE.match(rest):
                complete = True
                if current:
                    current['end'] = ts
                    phases.append(current)
                current = None

    # If build is still running, close the last open phase with last seen timestamp
    if current and current['end'] is None:
        current['end'] = last_ts
        current['partial'] = True
        phases.append(current)

    return {
        'phases':     phases,
        'build_date': build_date,
        'sdk_path':   sdk_path,
        'board':      board,
        'branch':     branch,
        'build_cmd':  build_cmd,
        'skip_flags': skip_flags,
        'complete':   complete,
        'last_ts':    last_ts,
    }


# ---------------------------------------------------------------------------
# Report generator
# ---------------------------------------------------------------------------
def generate_report(data: dict) -> str:
    phases     = data['phases']
    build_date = data['build_date'] or 'unknown'
    sdk_path   = data['sdk_path']   or '/mnt/DATA/UBUNTU/sdk_repos'
    board      = data['board']
    build_cmd  = data['build_cmd']  or f'bash packages/edgeai/build_armbian.sh --sdk-path {sdk_path}'
    complete   = data['complete']

    lines = []

    # Header
    lines.append(f"# Build Time Reference — {board} EdgeAI Full Clean Build")
    lines.append("")
    lines.append(f"Measured on: {build_date}  ")
    lines.append(f"Build command: `{build_cmd}`  ")
    if not complete:
        lines.append("> ⚠️ **Build still in progress** — times shown are partial.")
    lines.append("")

    # Phase table
    lines.append("## Phase Breakdown")
    lines.append("")
    lines.append("| Phase | Description | Start | End | Duration |")
    lines.append("|-------|-------------|-------|-----|----------|")

    total_start = phases[0]['start']  if phases else None
    total_end   = phases[-1]['end']   if phases else None

    for p in phases:
        start    = p['start']
        end      = p['end']
        partial  = p.get('partial', False)
        delta    = (end - start) if end else timedelta(0)
        dur_str  = fmt_duration(delta)
        if partial:
            dur_str += " *(partial)*"
        end_str  = fmt_time(end) if end else "—"
        lines.append(
            f"| {p['id']} | {p['desc']} "
            f"| {fmt_time(start)} | {end_str} | **{dur_str}** |"
        )

    if total_start and total_end:
        total_delta = total_end - total_start
        # Account for midnight rollover
        if total_delta.total_seconds() < 0:
            total_delta += timedelta(days=1)
        total_dur = fmt_duration(total_delta)
        suffix = " *(partial)*" if not complete else ""
        lines.append(
            f"| **Total** | | {fmt_time(total_start)} "
            f"| {fmt_time(total_end)} | **{total_dur}{suffix}** |"
        )

    lines.append("")

    # Auto-generated notes
    lines.append("## Notes")
    lines.append("")

    if phases:
        longest = max(phases, key=lambda p: (p['end'] - p['start']).total_seconds()
                      if p['end'] else 0)
        delta_l = longest['end'] - longest['start']
        lines.append(
            f"- **{longest['id']}** is the longest phase at "
            f"{fmt_duration(delta_l)} ({longest['desc']})"
        )

    skip = data['skip_flags']
    if 'kernel' in skip:
        lines.append("- Kernel phase was skipped (`--skip-kernel`); "
                     "B1 only assembled the final image")
    if 'gpu' in skip:
        lines.append("- GPU phases were skipped (`--skip-gpu`); "
                     "pre-built GPU debs were reused")
    if 'edgeai' in skip:
        lines.append("- EdgeAI phases were skipped (`--skip-edgeai`); "
                     "pre-built EdgeAI debs were reused")
    if not skip:
        lines.append("- Full build from source — no phases skipped")

    lines.append("")

    # Skip flags table
    lines.append("## Skip Flags for Incremental Builds")
    lines.append("")
    lines.append("| Goal | Command |")
    lines.append("|------|---------|")
    lines.append("| Rebuild image only (kernel + EdgeAI debs unchanged) "
                 "| `--skip-kernel --skip-gpu --skip-edgeai` |")
    lines.append("| Rebuild EdgeAI debs + image (kernel unchanged) "
                 "| `--skip-kernel --skip-gpu` |")
    lines.append("| Full rebuild from source | *(no skip flags)* |")
    lines.append("")

    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(
        description="Parse build_armbian.sh log and generate a BUILD_TIMES.md report."
    )
    ap.add_argument("log", nargs='?', default='/tmp/build.log',
                    help="Path to build log (default: /tmp/build.log)")
    ap.add_argument("--output", "-o", default=None,
                    help="Write markdown to this file (default: stdout)")
    args = ap.parse_args()

    log_path = Path(args.log)
    if not log_path.exists():
        print(f"Error: log file not found: {log_path}", file=sys.stderr)
        sys.exit(1)

    data   = parse_log(log_path)
    report = generate_report(data)

    if args.output:
        out = Path(args.output)
        out.write_text(report)
        print(f"Report written to {out}", file=sys.stderr)
    else:
        print(report)


if __name__ == '__main__':
    main()
