// Single-word model of the SDRAM pin protocol used by the firmware.
module sdram_model (
    input wire clk, cke, cs_n, ras_n, cas_n, wen_n,
    input wire [10:0] address,
    input wire [1:0] bank,
    input wire [3:0] dqm,
    inout wire [31:0] dq
);
    reg [31:0] memory [0:2097151];
    reg [10:0] row [0:3];
    reg [3:0] active = 0;
    reg [1:0] delay_clocks = 0;
    reg [20:0] read_address;
    reg [31:0] data;
    reg drive = 0;
    integer refresh_count = 0;
    reg initialized = 0;
    assign dq = drive ? data : 32'bz;

    always @(posedge clk) begin
        drive <= delay_clocks == 1;
        if (delay_clocks != 0) delay_clocks <= delay_clocks - 1'b1;
        if (delay_clocks == 1) data <= memory[read_address];
        if (cke && !cs_n) case ({ras_n, cas_n, wen_n})
            3'b000: begin
                if (address !== 11'h020 || refresh_count < 2) $fatal(1, "Bad SDRAM initialization");
                initialized <= 1;
            end
            3'b001: begin
                if (active != 0) $fatal(1, "Refresh with an active row");
                refresh_count <= refresh_count + 1;
            end
            3'b010: active <= 0;
            3'b011: begin
                if (!initialized || active[bank]) $fatal(1, "Invalid bank activate");
                row[bank] <= address;
                active[bank] <= 1;
            end
            3'b100: begin
                if (!active[bank] || dqm !== 0 || (^dq) === 1'bx) $fatal(1, "Invalid SDRAM write");
                memory[{bank, row[bank], address[7:0]}] <= dq;
                if (address[10]) active[bank] <= 0;
            end
            3'b101: begin
                if (!active[bank] || dqm !== 0) $fatal(1, "Invalid SDRAM read");
                read_address <= {bank, row[bank], address[7:0]};
                delay_clocks <= 2;
                if (address[10]) active[bank] <= 0;
            end
        endcase
    end
endmodule
