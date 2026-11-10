`timescale 1ns/1ps
module tb_tracker;
    reg clk = 0, reset = 1, frame_start = 0, analyze = 0, peak_valid = 0;
    always #10 clk = !clk;
    reg [5:0] frame_slot = 0, render_slot = 0;
    reg [4:0] render_lane = 0;
    reg [17:0] peak_center;
    reg [23:0] peak_floor = 24'd64;
    wire busy, render_mark;
    wire [17:0] render_center;
    wire [23:0] render_floor;
    ridge_tracker dut (.*);

    task peak(input integer center);
        begin
            peak_center = center;
            peak_valid = 1;
            @(negedge clk);
            peak_valid = 0;
        end
    endtask

    integer frame, lane, marks;
    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        for (frame = 0; frame <= 43; frame++) begin
            frame_slot = frame;
            frame_start = 1;
            @(negedge clk);
            frame_start = 0;
            // A pair with less than the lone-ridge drop, and a steady control.
            peak(4096 - frame * 2);
            peak(8192 - frame * 4);
            peak(25600);
            analyze = 1;
            @(negedge clk);
            analyze = 0;
            while (busy) @(negedge clk);
        end
        marks = 0;
        for (lane = 0; lane < 32; lane++) begin
            render_lane = lane;
            @(negedge clk);
            if (render_mark === 1'b1) begin
                if ((render_center != 4096 && render_center != 8192) || render_floor != 64)
                    $fatal(1, "Unexpected mask at %0d", render_center);
                marks = marks + 1;
            end
        end
        if (marks != 2) $fatal(1, "Expected two backdated masks, got %0d", marks);
        $display("Tracker confirmed paired shallow sweeps, backdated their masks, and preserved a steady tone.");
        $finish;
    end
    initial begin #5000000; $fatal(1, "Tracker timeout"); end
endmodule
