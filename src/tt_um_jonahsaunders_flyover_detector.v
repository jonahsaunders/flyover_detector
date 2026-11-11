// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module tt_um_jonahsaunders_flyover_detector (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire run = rst_n && ena;
    reg [1:0] reset_release;
    always @(posedge clk or negedge run) begin
        if (!run) reset_release <= 2'b00;
        else      reset_release <= {reset_release[0], 1'b1};
    end
    wire reset = !reset_release[1];

    reg [1:0] adc_sync, bypass_sync;
    reg [8:0] phase;
    reg [23:0] adc_shift, frame_pcm;
    reg dac_data;
    localparam [2:0] ADC_CAPTURE_PHASE = 3'd6;
    wire [4:0] slot_bit = phase[7:3];
    wire sample_valid = !reset && phase == {1'b0, 5'd24, ADC_CAPTURE_PHASE + 3'd1};
    wire signed [23:0] playback;
    wire detected, filtering, ready;
    wire [12:0] center;

    // A 24.576 MHz input clock produces 12.288 MHz MCLK, 3.072 MHz
    // BCLK and 48 kHz LRCLK. Each I2S slot is 32 bits with a one-bit delay.
    assign uo_out = {1'b0, ready, filtering, detected, dac_data, phase[8], phase[2], phase[0]};
    assign uio_out = 8'b0;
    assign uio_oe = 8'b0;
    wire _unused_ok = &{1'b0, ui_in[7:2], uio_in};

    always @(posedge clk) begin
        if (reset) begin
            adc_sync <= 0;
            bypass_sync <= 0;
            phase <= 0;
            adc_shift <= 0;
            frame_pcm <= 0;
            dac_data <= 0;
        end else begin
            adc_sync <= {adc_sync[0], ui_in[0]};
            bypass_sync <= {bypass_sync[0], ui_in[1]};
            phase <= phase + 1'b1;
            // With the two input flops, phase 6 reads the data sampled
            // one system clock after the internal rising BCLK edge.
            if (!phase[8] && phase[2:0] == ADC_CAPTURE_PHASE &&
                slot_bit != 0 && slot_bit <= 5'd24)
                adc_shift <= {adc_shift[22:0], adc_sync[1]};

            // Load once before the next left slot and play the same sample
            // in both slots. Launch data on falling BCLK.
            if (&phase) frame_pcm <= playback;
            if (&phase[2:0]) begin
                if (slot_bit < 5'd24) dac_data <= frame_pcm[5'd23 - slot_bit];
                else                  dac_data <= 1'b0;
            end
        end
    end

    glide_detector detector (
        .clk(clk), .reset(reset), .sample_valid(sample_valid),
        .pcm(adc_shift[23:5]), .center(center), .detected(detected)
    );
    harmonic_notch cleaner (
        .clk(clk), .reset(reset), .sample_valid(sample_valid),
        .pcm(adc_shift), .center(center), .attenuate(detected && !bypass_sync[1]),
        .playback(playback), .filtering(filtering), .ready(ready)
    );
endmodule

`default_nettype wire
