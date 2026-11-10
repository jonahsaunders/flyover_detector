module flyover_top (
    input wire ref_clk, adc_data,
    output wire mclk, bclk, lrclk, dac_data,
    output wire ready_led_n, filter_led_n, fault_led_n,
    output wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n,
    output wire O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    output wire [3:0] O_sdram_dqm,
    inout wire [31:0] IO_sdram_dq
);
    wire clk, mem_clk, locked;
    clocks clock_generator (.ref_clk(ref_clk), .clk(clk), .mem_clk(mem_clk), .locked(locked));
    reg [7:0] reset_pipe = 0;
    always @(posedge clk or negedge locked) begin
        if (!locked) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[6:0], 1'b1};
    end
    wire reset = !reset_pipe[7];

    wire sample_valid, audio_ready, filtering, fault;
    wire signed [23:0] capture, playback;
    assign ready_led_n = !audio_ready;
    assign filter_led_n = !(audio_ready && filtering);
    assign fault_led_n = !fault;
    i2s_audio audio (
        .clk(clk), .reset(reset), .adc_data(adc_data), .playback(playback),
        .mclk(mclk), .bclk(bclk), .lrclk(lrclk), .dac_data(dac_data),
        .sample_valid(sample_valid), .capture(capture)
    );

    wire memory_request, memory_write, memory_ready, memory_read_valid;
    wire [20:0] memory_address;
    wire [31:0] memory_write_data, memory_read_data;
    filter_core filter (
        .clk(clk), .reset(reset), .sample_valid(sample_valid), .capture(capture),
        .playback(playback), .audio_ready(audio_ready), .filtering(filtering), .fault(fault),
        .memory_request(memory_request), .memory_write(memory_write), .memory_address(memory_address),
        .memory_write_data(memory_write_data), .memory_ready(memory_ready),
        .memory_read_valid(memory_read_valid), .memory_read_data(memory_read_data)
    );
    sdram_words memory (
        .clk(clk), .mem_clk(mem_clk), .reset(reset), .request(memory_request), .write(memory_write),
        .address(memory_address), .write_data(memory_write_data), .ready(memory_ready),
        .read_valid(memory_read_valid), .read_data(memory_read_data),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba), .O_sdram_dqm(O_sdram_dqm),
        .IO_sdram_dq(IO_sdram_dq)
    );
endmodule
