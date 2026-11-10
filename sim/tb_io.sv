`timescale 1ns/1ps
module tb_io;
    reg clk = 0, reset = 1;
    always #10 clk = !clk;
    localparam [23:0] SAMPLE = 24'h89abcd, PLAYBACK = 24'h56789a;
    reg adc = 0;
    wire mclk, bclk, lrclk, dac, sample_valid;
    wire [23:0] capture;
    i2s_audio audio (.clk(clk), .reset(reset), .adc_data(adc), .playback(PLAYBACK),
        .mclk(mclk), .bclk(bclk), .lrclk(lrclk), .dac_data(dac), .sample_valid(sample_valid), .capture(capture));

    integer bit_index = 0, captures = 0, dac_bits = 0;
    reg previous_lrclk = 0;
    always @(negedge bclk) begin
        #1;
        if (!reset) begin
            if (lrclk != previous_lrclk) bit_index = 0;
            else bit_index = bit_index + 1;
            previous_lrclk = lrclk;
            adc = bit_index >= 1 && bit_index <= 24 && !lrclk ? SAMPLE[24-bit_index] : 0;
        end
    end
    always @(posedge bclk) if (captures >= 3 && bit_index >= 1 && bit_index <= 24) begin
        if (dac !== PLAYBACK[24-bit_index]) $fatal(1, "DAC bit mismatch, slot index %0d", bit_index);
        dac_bits = dac_bits + 1;
    end
    always @(negedge clk) if (!reset && sample_valid) begin
        if (capture !== SAMPLE) $fatal(1, "ADC word mismatch %h", capture);
        captures = captures + 1;
    end

    reg request = 0, write = 0;
    reg [20:0] address;
    reg [31:0] payload;
    wire ready, read_valid;
    wire [31:0] result;
    wire dram_clk, cke, cs_n, ras_n, cas_n, wen_n;
    wire [10:0] dram_address;
    wire [1:0] bank;
    wire [3:0] dqm;
    wire [31:0] dq;
    sdram_words controller (.clk(clk), .mem_clk(~clk), .reset(reset), .request(request),
        .write(write), .address(address), .write_data(payload), .ready(ready),
        .read_valid(read_valid), .read_data(result), .O_sdram_clk(dram_clk), .O_sdram_cke(cke),
        .O_sdram_cs_n(cs_n), .O_sdram_ras_n(ras_n), .O_sdram_cas_n(cas_n), .O_sdram_wen_n(wen_n),
        .O_sdram_addr(dram_address), .O_sdram_ba(bank), .O_sdram_dqm(dqm), .IO_sdram_dq(dq));
    sdram_model ram (.clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .wen_n(wen_n),
        .address(dram_address), .bank(bank), .dqm(dqm), .dq(dq));

    task transfer(input [20:0] location, input store, input [31:0] value);
        begin
            @(negedge clk);
            while (!ready) @(negedge clk);
            address = location;
            write = store;
            payload = value;
            request = 1;
            @(negedge clk);
            request = 0;
            if (!store) begin
                while (!read_valid) @(negedge clk);
                if (result !== value) $fatal(1, "SDRAM read at %h was %h, expected %h", location, result, value);
            end
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        transfer(21'h000001, 1, 32'hbad2feed);
        transfer(21'h1ffeaa, 1, 32'h895a4321);
        repeat (2000) @(negedge clk);
        transfer(21'h000001, 0, 32'hbad2feed);
        transfer(21'h1ffeaa, 0, 32'h895a4321);
        if (ram.refresh_count < 5 || dac_bits < 100) $fatal(1, "Insufficient refresh or I2S coverage");
        $display("I2S 24-bit capture and mirrored playback passed. SDRAM initialization, refresh and round trip passed.");
        $finish;
    end
    initial begin #500000; $fatal(1, "I/O timeout"); end
endmodule
