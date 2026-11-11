// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module glide_detector (
    input  wire               clk, reset, sample_valid,
    input  wire signed [18:0] pcm,
    output reg  [12:0]        center,
    output reg                detected
);
    localparam [9:0] MIN_PERIOD = 10'd96, MAX_PERIOD = 10'd600;
    localparam signed [19:0] HYSTERESIS = 20'sd1024;

    // Two low-pass poles reduce upper harmonics before the period
    // measurement. Subtract a slowly moving DC estimate from that band.
    reg signed [18:0] fast, slow, dc;
    wire signed [19:0] fast_error = {pcm[18], pcm} - {fast[18], fast};
    wire signed [19:0] slow_error = {fast[18], fast} - {slow[18], slow};
    wire signed [19:0] ac = {slow[18], slow} - {dc[18], dc};
    wire _unused_fraction = &{1'b0, fast_error[3:0], slow_error[4:0]};

    reg armed, have_edge, have_window;
    reg [9:0] period_count, first_period;
    reg [11:0] window_samples;
    reg [23:0] window_numerator;
    wire crossing = armed && ac >= HYSTERESIS;
    wire [9:0] period = period_count + 1'b1;
    wire [9:0] tolerance = (first_period >> 3) + 10'd4;
    wire consistent = first_period == 0 ||
        (period + tolerance >= first_period && period <= first_period + tolerance);
    wire [11:0] next_samples = window_samples + {2'b0, period};
    // Each observed cycle contributes round(2*pi*2^16) to the numerator.
    wire [23:0] next_numerator = window_numerator + 24'd411775;

    // A restoring divider produces the Q16 angular frequency once per
    // window. It finishes well before the next 48 kHz sample arrives.
    reg [4:0] divide_count;
    reg [23:0] dividend;
    reg [11:0] remainder, divisor;
    wire [12:0] shifted = {remainder, dividend[23]};
    wire [12:0] trial = shifted - {1'b0, divisor};
    wire accept_bit = !trial[12];
    wire [23:0] quotient = {dividend[22:0], accept_bit};
    wire [12:0] next_center = quotient[12:0];
    wire [13:0] drop = {1'b0, center} - {1'b0, next_center};
    // Allow small pitch jitter but discard discontinuous jumps.
    wire falling = !drop[13] && drop > ({1'b0, center} >> 8) + 14'd2 &&
        drop < ({1'b0, center} >> 3);
    reg [1:0] falling_windows;
    reg missed_window;

    always @(posedge clk) begin
        if (reset) begin
            fast <= 0;
            slow <= 0;
            dc <= 0;
            armed <= 0;
            have_edge <= 0;
            have_window <= 0;
            period_count <= 0;
            first_period <= 0;
            window_samples <= 0;
            window_numerator <= 0;
            divide_count <= 0;
            center <= 0;
            detected <= 0;
            falling_windows <= 0;
            missed_window <= 0;
        end else begin
            if (divide_count != 0) begin
                dividend <= quotient;
                remainder <= accept_bit ? trial[11:0] : shifted[11:0];
                divide_count <= divide_count - 1'b1;
                if (divide_count == 1) begin
                    center <= next_center;
                    have_window <= 1;
                    if (have_window && falling) begin
                        missed_window <= 0;
                        if (falling_windows != 3) falling_windows <= falling_windows + 1'b1;
                        if (falling_windows >= 2) detected <= 1;
                    end else begin
                        falling_windows <= 0;
                        missed_window <= 1;
                        if (missed_window) detected <= 0;
                    end
                end
            end

            if (sample_valid) begin
                fast <= fast + {{3{fast_error[19]}}, fast_error[19:4]};
                slow <= slow + {{4{slow_error[19]}}, slow_error[19:5]};
                dc <= dc + {{8{ac[19]}}, ac[19:9]};
                if (ac <= -HYSTERESIS) armed <= 1;
                else if (crossing)    armed <= 0;

                if (crossing) begin
                    period_count <= 0;
                    have_edge <= 1;
                end else if (have_edge) begin
                    period_count <= period;
                    if (period == MAX_PERIOD) have_edge <= 0;
                end

                if (crossing && have_edge && period >= MIN_PERIOD && consistent) begin
                    // Close the window at a crossing after at least 64 ms.
                    if (next_samples >= 12'd3072) begin
                        dividend <= next_numerator;
                        divisor <= next_samples;
                        remainder <= 0;
                        divide_count <= 5'd24;
                        first_period <= 0;
                        window_samples <= 0;
                        window_numerator <= 0;
                    end else begin
                        if (first_period == 0) first_period <= period;
                        window_samples <= next_samples;
                        window_numerator <= next_numerator;
                    end
                end else if (crossing || (have_edge && period == MAX_PERIOD)) begin
                    first_period <= 0;
                    window_samples <= 0;
                    window_numerator <= 0;
                    have_window <= 0;
                    falling_windows <= 0;
                    missed_window <= 0;
                    detected <= 0;
                end
            end
        end
    end
endmodule

`default_nettype wire
