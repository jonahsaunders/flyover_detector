module i2s_audio (
    input wire clk, reset,
    input wire adc_data,
    input wire signed [23:0] playback,
    output wire mclk, bclk, lrclk,
    output reg dac_data,
    output reg sample_valid,
    output reg signed [23:0] capture
);
    reg [9:0] phase;
    reg [23:0] receive_shift, transmit_shift;
    reg [23:0] stereo_sample;

    assign mclk = phase[1];
    assign bclk = phase[3];
    assign lrclk = phase[9];

    always @(posedge clk) begin
        sample_valid <= 0;
        if (reset) begin
            phase <= 0;
            dac_data <= 0;
            receive_shift <= 0;
            transmit_shift <= 0;
            stereo_sample <= 0;
            capture <= 0;
        end else begin
            phase <= phase + 1'b1;
            // Left slot, sampled on the rising bit clock. Bit zero is the I2S delay.
            if (phase[3:0] == 7 && !lrclk && phase[8:4] >= 1 && phase[8:4] <= 24) begin
                receive_shift <= {receive_shift[22:0], adc_data};
                if (phase[8:4] == 24) begin
                    capture <= {receive_shift[22:0], adc_data};
                    sample_valid <= 1;
                end
            end

            if (phase == 1023) stereo_sample <= playback;
            // Change data at the falling bit clock for the next rising edge.
            if (phase[3:0] == 15) begin
                if (phase[8:4] == 0) begin
                    dac_data <= stereo_sample[23];
                    transmit_shift <= {stereo_sample[22:0], 1'b0};
                end else if (phase[8:4] <= 23) begin
                    dac_data <= transmit_shift[23];
                    transmit_shift <= {transmit_shift[22:0], 1'b0};
                end else dac_data <= 0;
            end
        end
    end
endmodule
