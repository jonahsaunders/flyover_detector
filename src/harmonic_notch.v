// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module harmonic_notch (
    input  wire               clk, reset, sample_valid,
    input  wire signed [23:0] pcm,
    input  wire [12:0]        center,
    input  wire               attenuate,
    output reg  signed [23:0] playback,
    output wire               filtering,
    output reg                ready
);
    localparam [3:0] IDLE = 0, PREPARE = 1, MUL_HIGH = 2, UPDATE_BAND = 3,
                     MUL_BAND = 4, UPDATE_LOW = 5, MIX = 6, MUL_MIX = 7, FINISH = 8;
    reg [3:0] state;
    reg [1:0] section;
    reg [14:0] frequency;
    reg [6:0] gain;
    reg signed [22:0] band [0:2], low [0:2];
    reg signed [22:0] signal_in;
    wire signed [22:0] scaled_pcm = {{4{pcm[23]}}, pcm[23:5]};
    wire signed [22:0] band_value = band[section];
    wire signed [22:0] low_value = low[section];
    wire signed [24:0] damped = {{4{band_value[22]}}, band_value[22:2]};
    wire signed [24:0] notched = {{2{signal_in[22]}}, signal_in} - damped;
    wire signed [24:0] high = notched - {{2{low_value[22]}}, low_value};
    assign filtering = gain != 0;

    // One signed-by-unsigned, bit-serial Q16 multiplier shared by all
    // sections and the output crossfade. No wide parallel multiplier.
    reg signed [23:0] multiplicand, product;
    reg [15:0] multiplier;
    reg [3:0] bit_count;
    wire signed [24:0] partial_sum = {product[23], product} +
        (multiplier[0] ? {multiplicand[23], multiplicand} : 25'b0);
    wire _unused_fraction = partial_sum[0];
    wire signed [24:0] band_update = {{2{band_value[22]}}, band_value} + {product[23], product};
    wire signed [24:0] low_update = {{2{low_value[22]}}, low_value} + {product[23], product};
    wire signed [23:0] difference = {signal_in[22], signal_in} - {scaled_pcm[22], scaled_pcm};
    wire signed [23:0] correction = gain == 7'd64 ? difference : product;
    wire signed [29:0] mixed = {{6{pcm[23]}}, pcm} + {correction[23], correction, 5'b0};

    function signed [22:0] clamp_state;
        input signed [24:0] value;
        begin
            if (value[24:22] == {3{value[22]}}) clamp_state = value[22:0];
            else clamp_state = value[24] ? 23'sh400000 : 23'sh3fffff;
        end
    endfunction

    wire signed [22:0] next_band = clamp_state(band_update);
    wire signed [23:0] clipped_pcm = mixed[29:23] == {7{mixed[23]}} ?
        mixed[23:0] : (mixed[29] ? 24'sh800000 : 24'sh7fffff);

    integer index;
    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            gain <= 0;
            playback <= 0;
            ready <= 0;
            for (index = 0; index < 3; index = index + 1) begin
                band[index] <= 0;
                low[index] <= 0;
            end
        end else begin
            case (state)
                IDLE: if (sample_valid) begin
                    if (attenuate && gain < 7'd64) gain <= gain + 1'b1;
                    else if (!attenuate && gain != 0) gain <= gain - 1'b1;
                    if (center == 0) begin
                        playback <= pcm;
                        ready <= 1;
                    end else begin
                        section <= 0;
                        frequency <= {2'b0, center};
                        signal_in <= scaled_pcm;
                        state <= PREPARE;
                    end
                end
                // State-variable notch. At each of 1x, 2x and 4x:
                // y = x - band/4; band += f*(y-low); low += f*band.
                PREPARE: begin
                    signal_in <= clamp_state(notched);
                    multiplicand <= {high[24], clamp_state(high)};
                    multiplier <= {1'b0, frequency};
                    product <= 0;
                    bit_count <= 0;
                    state <= MUL_HIGH;
                end
                MUL_HIGH, MUL_BAND, MUL_MIX: begin
                    product <= partial_sum[24:1];
                    multiplier <= {1'b0, multiplier[15:1]};
                    bit_count <= bit_count + 1'b1;
                    if (&bit_count) begin
                        case (state)
                            MUL_HIGH: state <= UPDATE_BAND;
                            MUL_BAND: state <= UPDATE_LOW;
                            default:  state <= FINISH;
                        endcase
                    end
                end
                UPDATE_BAND: begin
                    band[section] <= next_band;
                    multiplicand <= {next_band[22], next_band};
                    multiplier <= {1'b0, frequency};
                    product <= 0;
                    bit_count <= 0;
                    state <= MUL_BAND;
                end
                UPDATE_LOW: begin
                    low[section] <= clamp_state(low_update);
                    if (section == 2) state <= MIX;
                    else begin
                        section <= section + 1'b1;
                        frequency <= frequency << 1;
                        state <= PREPARE;
                    end
                end
                MIX: begin
                    if (gain == 0 || gain == 7'd64) state <= FINISH;
                    else begin
                        multiplicand <= difference;
                        multiplier <= {gain[5:0], 10'b0};
                        product <= 0;
                        bit_count <= 0;
                        state <= MUL_MIX;
                    end
                end
                FINISH: begin
                    playback <= gain == 0 ? pcm : clipped_pcm;
                    ready <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
