`timescale 1ns/1ps
module tb_fft;
    reg clk = 0, reset = 1, start = 0, inverse = 0, write_enable = 0;
    always #10 clk = !clk;
    reg [11:0] address;
    reg signed [23:0] write_real, write_imag;
    wire busy;
    wire signed [23:0] read_real, read_imag;
    fft4096 dut (.*);

    function [11:0] reverse12(input [11:0] index);
        for (integer i = 0; i < 12; i++) reverse12[i] = index[11-i];
    endfunction

    task transform(input bit backward);
        begin
            @(negedge clk); inverse = backward; start = 1;
            @(negedge clk); start = 0;
            while (busy) @(negedge clk);
        end
    endtask

    integer n, expected;
    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        // An imaginary Fourier pair at +128 and -128 produces a real sine.
        write_enable = 1;
        for (n = 0; n < 4096; n++) begin
            address = reverse12(n);
            write_real = 0;
            write_imag = n == 128 ? -24'sd1024000 : n == 3968 ? 24'sd1024000 : 24'sd0;
            @(negedge clk);
        end
        write_enable = 0;
        transform(1);
        for (n = 0; n < 4096; n++) begin
            address = n;
            expected = $rtoi(2048000.0 * $sin(n * 6.283185307179586 / 32.0));
            @(negedge clk);
            if (read_real < expected - 100 || read_real > expected + 100 || read_imag < -100 || read_imag > 100)
                $fatal(1, "IFFT sine mismatch at %0d: %0d + %0di versus %0d", n, read_real, read_imag, expected);
        end

        write_enable = 1;
        for (n = 0; n < 4096; n++) begin
            address = reverse12(n);
            write_real = $rtoi(2048000.0 * $sin(n * 6.283185307179586 / 32.0));
            write_imag = 0;
            @(negedge clk);
        end
        write_enable = 0;
        transform(0);
        for (n = 0; n < 4096; n++) begin
            address = n;
            expected = n == 128 ? -1024000 : n == 3968 ? 1024000 : 0;
            @(negedge clk);
            if (read_imag < expected - 25 || read_imag > expected + 25 || read_real < -25 || read_real > 25)
                $fatal(1, "FFT sine mismatch at %0d: %0d + %0di versus %0d", n, read_real, read_imag, expected);
        end
        $display("FFT/IFFT frequency, signs and scaling passed for all 4096 samples/bins.");
        $finish;
    end
    initial begin #10000000; $fatal(1, "Transform timeout"); end
endmodule
