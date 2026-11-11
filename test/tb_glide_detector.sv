// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none

module tb_glide_detector;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1, sample_valid = 0;
    reg signed [18:0] pcm = 0;
    wire [12:0] center;
    wire detected;
    glide_detector dut (.clk(clk), .reset(reset), .sample_valid(sample_valid),
        .pcm(pcm), .center(center), .detected(detected));

    task automatic sample(input integer value);
        begin
            pcm = value[18:0];
            sample_valid = 1;
            @(negedge clk);
            sample_valid = 0;
            repeat (25) @(negedge clk);
        end
    endtask

    task automatic reset_detector;
        begin
            reset = 1;
            repeat (4) @(negedge clk);
            if ({center, detected} !== 14'b0)
                $fatal(1, "Detector reset failed");
            reset = 0;
        end
    endtask

    localparam real TAU = 6.283185307179586;
    integer n, direction, confirmed_samples, sample_value;
    real t, phase_angle;
    initial begin
        for (direction = -1; direction <= 1; direction++) begin
            reset_detector();
            confirmed_samples = 0;
            for (n = 0; n < 24000; n++) begin
                t = n / 48000.0;
                phase_angle = TAU * (148.0 * t + direction * 13.0 * t * t);
                sample_value = $rtoi(5000.0 + 40000.0 * $sin(phase_angle) +
                    18000.0 * $sin(2.0 * phase_angle) +
                    8000.0 * $sin(TAU * 1750.0 * t));
                sample(sample_value);
                if (detected === 1'b1) confirmed_samples++;
                else if (detected !== 1'b0) $fatal(1, "Unknown detector output");
            end
            if (center < 1000 || center > 1500)
                $fatal(1, "Expected a valid frequency estimate, got %0d", center);
            if (direction == -1 && confirmed_samples < 5000)
                $fatal(1, "Falling sweep detected for only %0d samples", confirmed_samples);
            if (direction != -1 && confirmed_samples != 0)
                $fatal(1, "False detection for direction %0d", direction);
            repeat (1500) sample(0);
            if (detected !== 1'b0) $fatal(1, "Detection persisted after silence");
        end
        $display("Falling, steady, rising, and track loss cases passed.");
        $finish;
    end
endmodule

`default_nettype wire
