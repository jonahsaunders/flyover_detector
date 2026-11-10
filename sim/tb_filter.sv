`timescale 1ns/1ps
module tb_filter;
    reg clk = 0, reset = 1, sample_valid = 0;
    always #10 clk = !clk;
    reg signed [23:0] capture = 0;
    wire signed [23:0] playback;
    wire audio_ready, filtering, fault;
    wire memory_request, memory_write, memory_ready, memory_read_valid;
    wire [20:0] memory_address;
    wire [31:0] memory_write_data, memory_read_data;
    filter_core dut (.*);

    wire dram_clk, cke, cs_n, ras_n, cas_n, wen_n;
    wire [10:0] dram_address;
    wire [1:0] bank;
    wire [3:0] dqm;
    wire [31:0] dq;
    sdram_words controller (.clk(clk), .mem_clk(~clk), .reset(reset),
        .request(memory_request), .write(memory_write), .address(memory_address), .write_data(memory_write_data),
        .ready(memory_ready), .read_valid(memory_read_valid), .read_data(memory_read_data),
        .O_sdram_clk(dram_clk), .O_sdram_cke(cke), .O_sdram_cs_n(cs_n), .O_sdram_ras_n(ras_n),
        .O_sdram_cas_n(cas_n), .O_sdram_wen_n(wen_n), .O_sdram_addr(dram_address),
        .O_sdram_ba(bank), .O_sdram_dqm(dqm), .IO_sdram_dq(dq));
    sdram_model ram (.clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .wen_n(wen_n),
        .address(dram_address), .bank(bank), .dqm(dqm), .dq(dq));

    localparam integer HOP = 1024, DELAY = 48 * HOP;
    real tau = 6.283185307179586;
    function real aircraft(input integer index);
        real t, phase;
        begin
            t = index / 48000.0;
            phase = tau * (148.0 * t - 13.0 * t * t);
            aircraft = 1300000.0 * $sin(phase) + 600000.0 * $sin(2.0 * phase) + 300000.0 * $sin(4.0 * phase);
        end
    endfunction
    function real control(input integer index);
        control = 250000.0 * $sin(tau * 1750.0 * index / 48000.0);
    endfunction

    integer hop, sample, n, source, cycles, max_cycles = 0, observations = 0;
    real before_energy = 0, residual_energy = 0, error, attenuation;
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        while (!memory_ready) @(negedge clk);
        for (hop = 0; hop < 60; hop++) begin
            for (sample = 0; sample < HOP; sample++) begin
                n = hop * HOP + sample;
                source = n - DELAY;
                capture = $rtoi(aircraft(n) + control(n));
                sample_valid = 1;
                @(negedge clk);
                sample_valid = 0;
                if (fault) $fatal(1, "Unexpected pipeline fault at sample %0d", n);
                if (source < 0 && playback !== 0) $fatal(1, "Startup emitted nonzero audio");
                // After the four-window startup ramp, compare to the clean signal.
                if (source >= 3072) begin
                    if (!audio_ready || (^playback) === 1'bx) $fatal(1, "Invalid delayed PCM at %0d", source);
                    error = $itor(playback) - control(source);
                    residual_energy = residual_energy + error * error;
                    before_energy = before_energy + aircraft(source) * aircraft(source);
                    observations = observations + 1;
                end
                repeat (2) @(negedge clk);
            end
            // Skip the unused time between real I2S samples. Measure real compute cycles.
            cycles = 0;
            while (dut.state != 1) begin
                @(negedge clk);
                cycles = cycles + 1;
                if (cycles >= 1048573) $fatal(1, "Exceeded the 21.33 ms hop deadline");
            end
            if (cycles > max_cycles) max_cycles = cycles;
        end
        attenuation = 10.0 * $log10(before_energy / residual_energy);
        if (observations < 9000 || attenuation < 15.0)
            $fatal(1, "Mixed-signal attenuation was only %0.1f dB", attenuation);
        $display("Fixed-point mixed-signal suppression: %0.1f dB over %0d samples.", attenuation, observations);
        $display("Longest hop used %0d of 1048576 system clocks; 49152-sample delay verified.", max_cycles);

        // Hold the work engine busy at the next hop boundary and check fail-closed output.
        force dut.state = 2;
        repeat (HOP) begin
            sample_valid = 1;
            @(negedge clk);
            sample_valid = 0;
            repeat (2) @(negedge clk);
        end
        if (!fault || playback !== 0) $fatal(1, "Deadline failure did not mute the output");
        release dut.state;
        $display("Deadline fault latches mute.");
        $finish;
    end
endmodule
