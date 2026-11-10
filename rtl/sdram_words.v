// GW2AR-18C embedded 64-Mbit SDR SDRAM, 32-bit single-word transfers.
// The board supplies a memory clock 180 degrees after the controller clock.
module sdram_words (
    input wire clk, mem_clk, reset,
    input wire request, write,
    input wire [20:0] address,
    input wire [31:0] write_data,
    output wire ready,
    output reg read_valid,
    output reg [31:0] read_data,
    output wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n,
    output wire O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output reg [10:0] O_sdram_addr,
    output reg [1:0] O_sdram_ba,
    output wire [3:0] O_sdram_dqm,
    inout wire [31:0] IO_sdram_dq
);
    localparam WAIT_POWER = 0, INIT_PRE = 1, INIT_REF1 = 2, INIT_REF2 = 3,
               INIT_MODE = 4, IDLE = 5, ACCESS = 6, READ_WAIT = 7,
               WRITE_END = 8, WAIT_IDLE = 9;
    localparam NOP = 3'b111, PRECHARGE = 3'b010, REFRESH = 3'b001, MODE = 3'b000,
               ACTIVATE = 3'b011, WRITE = 3'b100, READ = 3'b101;

    reg [3:0] state;
    reg [13:0] power_wait;
    reg [2:0] wait_cycles;
    reg [9:0] refresh_age;
    reg [2:0] command;
    reg drive_data, writing;
    reg [7:0] column;
    reg [31:0] payload;

    assign ready = state == IDLE && refresh_age < 600;
    assign O_sdram_clk = mem_clk;
    assign O_sdram_cke = 1'b1;
    assign O_sdram_cs_n = 1'b0;
    assign {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = command;
    assign O_sdram_dqm = 4'b0000;
    assign IO_sdram_dq = drive_data ? payload : 32'bz;

    always @(posedge clk) begin
        read_valid <= 0;
        command <= NOP;
        if (wait_cycles != 0) wait_cycles <= wait_cycles - 1'b1;
        if (refresh_age < 1023) refresh_age <= refresh_age + 1'b1;

        if (reset) begin
            state <= WAIT_POWER;
            power_wait <= 10000;
            wait_cycles <= 0;
            refresh_age <= 0;
            drive_data <= 0;
            O_sdram_addr <= 0;
            O_sdram_ba <= 0;
            read_data <= 0;
        end else case (state)
            WAIT_POWER: if (power_wait == 0) state <= INIT_PRE;
                        else power_wait <= power_wait - 1'b1;
            INIT_PRE: begin
                command <= PRECHARGE;
                O_sdram_addr <= 11'b10000000000;
                wait_cycles <= 2;
                state <= INIT_REF1;
            end
            INIT_REF1: if (wait_cycles == 0) begin
                command <= REFRESH;
                wait_cycles <= 4;
                state <= INIT_REF2;
            end
            INIT_REF2: if (wait_cycles == 0) begin
                command <= REFRESH;
                wait_cycles <= 4;
                state <= INIT_MODE;
            end
            INIT_MODE: if (wait_cycles == 0) begin
                command <= MODE;
                O_sdram_addr <= 11'h020; // CAS 2, sequential, burst length 1
                O_sdram_ba <= 0;
                wait_cycles <= 2;
                refresh_age <= 0;
                state <= WAIT_IDLE;
            end
            IDLE: if (!ready) begin
                command <= REFRESH;
                refresh_age <= 0;
                wait_cycles <= 4;
                state <= WAIT_IDLE;
            end else if (request) begin
                command <= ACTIVATE;
                O_sdram_ba <= address[20:19];
                O_sdram_addr <= address[18:8];
                column <= address[7:0];
                writing <= write;
                payload <= write_data;
                wait_cycles <= 1;
                state <= ACCESS;
            end
            ACCESS: if (wait_cycles == 0) begin
                command <= writing ? WRITE : READ;
                O_sdram_addr <= {3'b100, column}; // Auto-precharge.
                if (writing) begin
                    drive_data <= 1;
                    state <= WRITE_END;
                end else begin
                    wait_cycles <= 2;
                    state <= READ_WAIT;
                end
            end
            READ_WAIT: if (wait_cycles == 0) begin
                read_data <= IO_sdram_dq;
                read_valid <= 1;
                wait_cycles <= 2;
                state <= WAIT_IDLE;
            end
            WRITE_END: begin
                drive_data <= 0;
                wait_cycles <= 3;
                state <= WAIT_IDLE;
            end
            WAIT_IDLE: if (wait_cycles == 0) state <= IDLE;
            default: state <= WAIT_POWER;
        endcase
    end
endmodule
