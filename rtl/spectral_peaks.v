// One bin at a time, in frequency order. There are at least 12 clocks per bin.
module spectral_peaks (
    input wire clk, reset, frame_start,
    input wire bin_valid,
    input wire [11:0] bin_index,
    input wire signed [23:0] bin_real, bin_imag,
    output reg peak_valid,
    output reg [17:0] peak_center,
    output reg [23:0] peak_floor
);
    reg valid_square, valid_power, valid_log;
    reg [11:0] index_square, index_power, index_log;
    reg [47:0] re_square, im_square, power;
    reg [13:0] log_power;

    function [13:0] log2_q8;
        input [47:0] value;
        integer index;
        reg [5:0] leading;
        reg [47:0] aligned;
        begin
            leading = 0;
            for (index = 0; index < 48; index = index + 1)
                if (value[index]) leading = index;
            aligned = value << (6'd47 - leading);
            log2_q8 = {leading, aligned[46:39]};
        end
    endfunction

    reg [13:0] previous [0:15];
    wire [13:0] left = previous[8], center = previous[7], right = previous[6];
    wire [15:0] low_sum = {2'b0, previous[12]} + {2'b0, previous[13]} +
                          {2'b0, previous[14]} + {2'b0, previous[15]};
    wire [15:0] high_sum = {2'b0, previous[2]} + {2'b0, previous[1]} +
                           {2'b0, previous[0]} + {2'b0, log_power};
    wire [13:0] floor_log = (index_log >= 16 && low_sum < high_sum) ? low_sum[15:2] : high_sum[15:2];
    wire [14:0] curvature = {center, 1'b0} - {1'b0, left} - {1'b0, right};
    wire [13:0] side_difference = left >= right ? left - right : right - left;
    reg [15:0] denominator, remainder;
    reg [7:0] quotient;
    reg [3:0] steps;
    reg negative;
    reg [17:0] integer_center;
    wire [16:0] doubled = {remainder, 1'b0};
    wire subtract = doubled >= {1'b0, denominator};
    wire [7:0] next_quotient = {quotient[6:0], subtract};
    integer tap;

    always @(posedge clk) begin
        peak_valid <= 0;
        if (reset || frame_start) begin
            valid_square <= 0;
            valid_power <= 0;
            valid_log <= 0;
            steps <= 0;
            for (tap = 0; tap < 16; tap = tap + 1) previous[tap] <= 0;
        end else begin
            valid_square <= bin_valid && bin_index <= 690;
            valid_power <= valid_square;
            valid_log <= valid_power;
            if (bin_valid) begin
                re_square <= bin_real * bin_real;
                im_square <= bin_imag * bin_imag;
                index_square <= bin_index;
            end
            if (valid_square) begin
                power <= re_square + im_square;
                index_power <= index_square;
            end
            if (valid_power) begin
                log_power <= log2_q8(power);
                index_log <= index_power;
            end

            if (steps != 0) begin
                remainder <= subtract ? doubled - denominator : doubled;
                quotient <= next_quotient;
                steps <= steps - 1'b1;
                if (steps == 1) begin
                    peak_center <= negative ? integer_center - next_quotient : integer_center + next_quotient;
                    peak_valid <= 1;
                end
            end

            if (valid_log) begin
                previous[0] <= log_power;
                for (tap = 1; tap < 16; tap = tap + 1) previous[tap] <= previous[tap - 1];
                if (index_log >= 11 && index_log <= 690 && center > left && center > right &&
                    {1'b0, center} >= {1'b0, floor_log} + 15'd850 && steps == 0) begin
                    // Parabolic interpolation in log power. Eight restoring steps give Q8 bins.
                    integer_center <= (index_log - 12'd8) << 8;
                    peak_floor <= floor_log < 512 ? 0 : (24'd1 << floor_log[13:9]);
                    negative <= left > right;
                    denominator <= {curvature, 1'b0};
                    remainder <= {2'b0, side_difference};
                    quotient <= 0;
                    steps <= 8;
                end
            end
        end
    end
endmodule
