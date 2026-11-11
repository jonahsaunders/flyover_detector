// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none

module tb_i2s;
    localparam realtime CLOCK_PERIOD = 40.690;
    reg clk = 0;
    always #(CLOCK_PERIOD / 2.0) clk = !clk;
    reg rst_n = 0, ena = 1;
    reg [7:0] ui_in = 0, uio_in = 8'ha5;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire mclk = uo_out[0], bclk = uo_out[1], lrclk = uo_out[2];
    wire dac_data = uo_out[3], detected = uo_out[4], filtering = uo_out[5], ready = uo_out[6];
    tt_um_jonahsaunders_flyover_detector dut (
`ifdef GL_TEST
        .VPWR(1'b1), .VGND(1'b0),
`endif
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe)
    );

    integer mclk_edges = 0;
    always @(posedge mclk) mclk_edges = mclk_edges + 1;

    task automatic frame(
        input [23:0] adc_left, adc_right,
        output [23:0] dac_left, dac_right
    );
        integer bit_number, slot_bit, last_mclk_edges;
        realtime last_bclk_edge, interval;
        begin
            dac_left = 0;
            dac_right = 0;
            last_bclk_edge = 0;
            last_mclk_edges = 0;
            for (bit_number = 0; bit_number < 64; bit_number++) begin
                slot_bit = bit_number % 32;
                @(posedge bclk);
                #2;
                if (bit_number != 0) begin
                    interval = $realtime - last_bclk_edge;
                    if (interval < 8.0 * CLOCK_PERIOD - 1.0 ||
                        interval > 8.0 * CLOCK_PERIOD + 1.0 ||
                        mclk_edges - last_mclk_edges != 4)
                        $fatal(1, "Unexpected I2S clock ratio");
                end
                last_bclk_edge = $realtime;
                last_mclk_edges = mclk_edges;
                if (lrclk !== (bit_number >= 32))
                    $fatal(1, "Incorrect LRCLK at frame bit %0d", bit_number);
                if (slot_bit >= 1 && slot_bit <= 24) begin
                    if (bit_number < 32) dac_left = {dac_left[22:0], dac_data};
                    else                dac_right = {dac_right[22:0], dac_data};
                end else if (dac_data !== 1'b0)
                    $fatal(1, "Nonzero I2S delay or padding at frame bit %0d", bit_number);
                @(negedge bclk);
                // Exercise late ADC data with about 18 ns of setup at BCLK.
                #145;
                if (slot_bit < 24)
                    ui_in[0] = bit_number < 32 ? adc_left[23-slot_bit] : adc_right[23-slot_bit];
                else
                    ui_in[0] = 0;
            end
        end
    endtask

    task automatic expect_frame(input [23:0] adc_left, adc_right, expected);
        reg [23:0] dac_left, dac_right;
        begin
            frame(adc_left, adc_right, dac_left, dac_right);
            if (dac_left !== expected || dac_right !== expected)
                $fatal(1, "Expected %h on both channels, read %h and %h", expected, dac_left, dac_right);
            if ({uo_out[7], detected, filtering} !== 3'b0 || ready !== 1'b1 ||
                uio_oe !== 8'b0 || uio_out !== 8'b0)
                $fatal(1, "Incorrect ready, detection or unused pins");
        end
    endtask

    task automatic expect_reset;
        begin
            repeat (8) @(negedge clk);
            if (uo_out !== 8'b0 || uio_oe !== 8'b0 || uio_out !== 8'b0)
                $fatal(1, "Reset did not clear the interface");
        end
    endtask

    localparam real TAU = 6.283185307179586;
    function automatic real aircraft(input integer n);
        real t, phase_angle;
        begin
            t = n / 48000.0;
            phase_angle = TAU * (148.0 * t - 13.0 * t * t);
            aircraft = 1300000.0 * $sin(phase_angle) +
                600000.0 * $sin(2.0 * phase_angle) + 300000.0 * $sin(4.0 * phase_angle);
        end
    endfunction

    function automatic real control(input integer n);
        control = 250000.0 * $sin(TAU * 1750.0 * n / 48000.0);
    endfunction

    integer n, value, active_samples;
    reg [23:0] left_word, right_word;
    real before_energy, residual_energy, residual, reduction;
    initial begin
        expect_reset();
        rst_n = 1;
        expect_frame(24'h7fffff, 24'h4bde02, 0);
        expect_frame(24'h800000, 24'h12bcde, 24'h7fffff);
        expect_frame(24'habc165, 24'h010203, 24'h800000);
        expect_frame(24'h012345, 24'hf9db78, 24'habc165);
        expect_frame(0, 0, 24'h012345);

        ena = 0;
        expect_reset();
        ena = 1;
        expect_frame(24'hffffff, 24'hda9874, 0);
        expect_frame(0, 0, 24'hffffff);
        rst_n = 0;
        expect_reset();
        $display("I2S clocks, left capture, dual-mono playback, and reset passed.");

        if ($test$plusargs("chirp")) begin
            rst_n = 1;
            before_energy = 0;
            residual_energy = 0;
            active_samples = 0;
            for (n = 0; n < 21600; n++) begin
                value = $rtoi(aircraft(n) + control(n));
                frame(value[23:0], 24'h800000, left_word, right_word);
                if ((^left_word) === 1'bx || left_word !== right_word)
                    $fatal(1, "Invalid output on frame %0d", n);
                if (n >= 16800) begin
                    residual = $itor($signed(left_word)) - control(n - 1);
                    before_energy = before_energy + aircraft(n - 1) * aircraft(n - 1);
                    residual_energy = residual_energy + residual * residual;
                    if (detected && filtering) active_samples++;
                end
            end
            reduction = 10.0 * $log10(before_energy / residual_energy);
            if (active_samples < 4560 || reduction < 15.0)
                $fatal(1, "Falling chirp suppressed by only %0.1f dB, active for %0d/4800 frames",
                       reduction, active_samples);
            $display("24-bit I2S mixed-signal suppression: %0.1f dB over 4800 frames.", reduction);

            ui_in[1] = 1;
            for (n = 21600; n < 21700; n++) begin
                value = $rtoi(aircraft(n) + control(n));
                frame(value[23:0], 0, left_word, right_word);
            end
            value = $rtoi(aircraft(21698) + control(21698));
            if (left_word !== value[23:0] || left_word !== right_word ||
                detected !== 1'b1 || filtering !== 1'b0)
                $fatal(1, "Bypass did not restore bit-exact PCM while detection continued");
            $display("Bypass ramp and independent detection passed.");
        end
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1, "I2S test timed out");
    end
endmodule

`default_nettype wire
