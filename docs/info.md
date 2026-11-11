<!-- SPDX-License-Identifier: Apache-2.0 -->

## How it works

The Flyover Audio Filter takes the left channel of a 24-bit I²S input at
48 kHz and plays the processed signal in both output channels. It detects
a sustained fall in the pitch of a dominant low-frequency tone. A
low-pass filter and hysteresis prepare the signal for zero-crossing
measurements. The detector accepts periods in the 80–500 Hz range and
requires three successive drops across windows of at least 64 ms.

Once a fall is confirmed, three tracking notches attenuate the fundamental,
second harmonic and fourth harmonic. The filter crossfades over 64 samples
when it engages or disengages. The digital audio path has one frame of
latency. Detection takes several windows, so the opening portion of a
flyover can pass through. Weak tones, multiple competing tones, broadband
noise and falls outside the tracking range can remain audible. Other
sources with falling pitch can trigger the detector.

## How to test

1. Supply a 24.576 MHz clock to `clk`. Select the project and hold `rst_n`
   low for at least eight clock edges, then release it. Drive `BYPASS` low.
2. Check for 12.288 MHz on `MCLK`, 3.072 MHz on `BCLK` and 48 kHz on
   `LRCLK`. `READY` goes high after the first left sample has been processed.
   Each 32-bit slot has one I²S delay bit, 24 data bits and seven zero pad bits.
3. Feed a steady 148 Hz tone at line level into the left input. It should
   play on both output channels with `DETECTED` and `FILTERING` low.
4. Feed a 148-to-135 Hz sweep over half a second. At sufficient level,
   `DETECTED` and `FILTERING` rise during the fall and the later part of
   the sweep is attenuated. Raise `BYPASS` to compare. `FILTERING` falls
   after the 64-sample fade, and the detector continues to run.

## External hardware

Use a Digilent Pmod I2S2 with its ADC jumper in **Slave** mode, a
24.576 MHz clock source for the Tiny Tapeout clock input, and a line-level
source or microphone preamp. Wire the module with power disconnected.
Set the demo board inputs to accept external drive on `ADC_DATA`.

| Tiny Tapeout signal | Pmod I2S2 J1 pins |
| --- | --- |
| `uo[0]` MCLK | 1 and 7 |
| `uo[1]` BCLK | 3 and 9 |
| `uo[2]` LRCLK | 2 and 8 |
| `uo[3]` DAC_DATA | 4 |
| `ui[0]` ADC_DATA | 10 |
| Ground | 5 and 11 |
| 3.3 V | 6 and 12 |

Connect `ui[1]` to a defined logic level. Use 0 V for filtering and 3.3 V
for bypass. Use the board's external clock input configuration when
supplying a clock from an oscillator.
