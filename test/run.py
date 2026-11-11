# SPDX-License-Identifier: Apache-2.0
"""Run the Tiny Tapeout simulations and write a JUnit report for Actions."""

import argparse
import os
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
SOURCE_DIR = TEST_DIR.parent / "src"
BUILD_DIR = TEST_DIR / "sim_build"


def run_test(suite, name, sources, defines=(), arguments=()):
    start = time.monotonic()
    executable = BUILD_DIR / f"{name}.vvp"
    case = ET.SubElement(suite, "testcase", name=name, classname="flyover")
    output = []
    try:
        commands = [
            ["iverilog", "-g2012", "-s", name, "-o", str(executable),
             *defines, *map(str, sources), str(TEST_DIR / f"{name}.sv")],
            ["vvp", str(executable), *arguments],
        ]
        for command in commands:
            result = subprocess.run(command, cwd=TEST_DIR, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output.append(result.stdout)
            result.check_returncode()
    except (OSError, subprocess.CalledProcessError) as error:
        ET.SubElement(case, "failure", message=str(error)).text = "".join(output)
        print(error, flush=True)
    case.set("time", f"{time.monotonic() - start:.3f}")
    ET.SubElement(case, "system-out").text = "".join(output)
    print(f"{name}: {'FAIL' if case.find('failure') is not None else 'PASS'}")
    print("".join(output), end="", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gates", action="store_true")
    args = parser.parse_args()
    BUILD_DIR.mkdir(exist_ok=True)
    suite = ET.Element("testsuite", name="flyover")
    if args.gates:
        models = Path(os.environ["PDK_ROOT"]) / "sky130A/libs.ref/sky130_fd_sc_hd/verilog"
        sources = [models / "primitives.v", models / "sky130_fd_sc_hd.v",
                   TEST_DIR / "gate_level_netlist.v"]
        defines = ["-DGL_TEST", "-DFUNCTIONAL", "-DUSE_POWER_PINS", "-DSIM", "-DUNIT_DELAY=#1"]
        run_test(suite, "tb_i2s", sources, defines)
    else:
        run_test(suite, "tb_i2s", sorted(SOURCE_DIR.glob("*.v")), arguments=["+chirp"])
        run_test(suite, "tb_glide_detector", [SOURCE_DIR / "glide_detector.v"])

    failures = len(suite.findall(".//failure"))
    suite.set("tests", str(len(suite.findall("testcase"))))
    suite.set("failures", str(failures))
    ET.ElementTree(suite).write(TEST_DIR / "results.xml", encoding="utf-8", xml_declaration=True)
    return int(failures != 0)


if __name__ == "__main__":
    raise SystemExit(main())
