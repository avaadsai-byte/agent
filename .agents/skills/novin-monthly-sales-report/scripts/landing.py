"""Extract or refresh the Novin report fragment inside its standalone HTML."""

import argparse
from html.parser import HTMLParser
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


class ReportFrame(HTMLParser):
    def __init__(self):
        super().__init__()
        self.document = None

    def handle_starttag(self, tag, attrs):
        if tag == "iframe":
            attributes = dict(attrs)
            if attributes.get("id") == "codex-visualization":
                self.document = attributes.get("data-srcdoc")


def extract(report):
    parser = ReportFrame()
    parser.feed(report.read_text(encoding="utf-8"))
    frame = parser.document
    start_marker = "<style>\n  .crm-report"
    if not frame or start_marker not in frame:
        raise ValueError("The Novin report wrapper or landing stylesheet could not be located.")
    start = frame.index(start_marker)
    end = frame.index("</main>", start) + len("</main>")
    return frame[start:end]


def refresh(fragment, destination, renderer):
    source = fragment.read_text(encoding="utf-8").rstrip()
    with TemporaryDirectory(prefix=".novin-report-", dir=destination.parent) as temp:
        pending = Path(temp) / "crm-leads-report.html"
        subprocess.run(
            [sys.executable, str(renderer), str(fragment), str(pending),
             "--title", "گزارش ماهیانه فروش نوین"],
            check=True,
        )
        if extract(pending) != source:
            raise ValueError("The rendered landing did not preserve the reviewed fragment.")
        os.replace(pending, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    extraction = actions.add_parser("extract")
    extraction.add_argument("report", type=Path)
    extraction.add_argument("fragment", type=Path)
    render = actions.add_parser("refresh")
    render.add_argument("fragment", type=Path)
    render.add_argument("report", type=Path)
    render.add_argument("--renderer", type=Path, required=True)
    args = parser.parse_args()
    if args.fragment.resolve() == args.report.resolve():
        parser.error("Use separate report and fragment paths.")
    if args.action == "extract":
        args.fragment.write_text(extract(args.report), encoding="utf-8")
    else:
        refresh(args.fragment, args.report, args.renderer)


if __name__ == "__main__":
    main()