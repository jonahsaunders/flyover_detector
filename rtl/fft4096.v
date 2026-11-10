// Radix-2 DIT. The caller writes input in bit-reversed order.
// Forward scales by 1/4096. Inverse is unscaled. Data is signed 24-bit PCM.
module fft4096 (
    input wire clk, reset,
    input wire start, inverse,
    output wire busy,
    input wire [11:0] address,
    input wire write_enable,
    input wire signed [23:0] write_real, write_imag,
    output wire signed [23:0] read_real, read_imag
);
    localparam IDLE = 0, READ_A = 1, READ_B = 2, PRODUCTS = 3,
               ROTATE = 4, SUMS = 5, WRITE_A = 6, WRITE_B = 7;
    reg [2:0] state;
    assign busy = state != IDLE;

    reg [11:0] group_base, position, half_span;
    reg [3:0] stage;
    reg [11:0] twiddle_step;
    reg [10:0] twiddle_address;
    reg invert;
    wire [11:0] index_a = group_base + position;
    wire [11:0] index_b = index_a + half_span;
    wire [11:0] next_group = group_base + (half_span << 1);
    wire group_end = group_base == ((~((half_span << 1) - 1'b1)) & 12'hfff);

    (* ram_style = "block" *) reg [47:0] scratch [0:4095];
    (* ram_style = "block" *) reg [35:0] twiddle [0:2047];
    initial $readmemh("tables/twiddle.mem", twiddle);
    reg [47:0] read_pair;
    reg [35:0] twiddle_pair;
    wire [11:0] read_address = state == READ_A ? index_a : state == READ_B ? index_b : address;
    wire memory_write = state == WRITE_A || state == WRITE_B || (state == IDLE && write_enable);
    wire [11:0] write_address = state == WRITE_A ? index_a : state == WRITE_B ? index_b : address;
    reg signed [23:0] a_real, a_imag;
    wire signed [17:0] cosine = twiddle_pair[35:18];
    wire signed [17:0] forward_sine = twiddle_pair[17:0];
    wire signed [17:0] sine = invert ? -forward_sine : forward_sine;
    assign read_real = read_pair[47:24];
    assign read_imag = read_pair[23:0];
    reg signed [41:0] ac, bd, ad, bc;
    wire signed [42:0] real_product = $signed({ac[41], ac}) - $signed({bd[41], bd});
    wire signed [42:0] imag_product = $signed({ad[41], ad}) + $signed({bc[41], bc});
    reg signed [25:0] rotated_real, rotated_imag;
    reg signed [26:0] plus_real, plus_imag, minus_real, minus_imag;

    function [23:0] narrow;
        input signed [26:0] value;
        input scale;
        reg signed [26:0] shifted;
        begin
            shifted = scale ? (value + 27'sd1) >>> 1 : value;
            if (shifted > 27'sd8388607) narrow = 24'h7fffff;
            else if (shifted < -27'sd8388608) narrow = 24'h800000;
            else narrow = shifted[23:0];
        end
    endfunction

    wire [47:0] memory_data = state == WRITE_A ? {narrow(plus_real, !invert), narrow(plus_imag, !invert)} :
                            state == WRITE_B ? {narrow(minus_real, !invert), narrow(minus_imag, !invert)} :
                                               {write_real, write_imag};
    always @(posedge clk) begin
        read_pair <= scratch[read_address];
        twiddle_pair <= twiddle[twiddle_address];
        if (memory_write) scratch[write_address] <= memory_data;

        if (reset) state <= IDLE;
        else case (state)
            IDLE: if (start) begin
                group_base <= 0;
                position <= 0;
                half_span <= 1;
                stage <= 0;
                twiddle_step <= 2048;
                twiddle_address <= 0;
                invert <= inverse;
                state <= READ_A;
            end
            READ_A: state <= READ_B;
            READ_B: begin
                a_real <= read_real;
                a_imag <= read_imag;
                state <= PRODUCTS;
            end
            PRODUCTS: begin
                ac <= read_real * cosine;
                bd <= read_imag * sine;
                ad <= read_real * sine;
                bc <= read_imag * cosine;
                state <= ROTATE;
            end
            ROTATE: begin
                rotated_real <= (real_product + 43'sd32768) >>> 16;
                rotated_imag <= (imag_product + 43'sd32768) >>> 16;
                state <= SUMS;
            end
            SUMS: begin
                plus_real <= a_real + rotated_real;
                plus_imag <= a_imag + rotated_imag;
                minus_real <= a_real - rotated_real;
                minus_imag <= a_imag - rotated_imag;
                state <= WRITE_A;
            end
            WRITE_A: state <= WRITE_B;
            WRITE_B: begin
                state <= READ_A;
                if (position + 1'b1 == half_span) begin
                    position <= 0;
                    twiddle_address <= 0;
                    if (group_end) begin
                        group_base <= 0;
                        if (stage == 11) state <= IDLE;
                        else begin
                            stage <= stage + 1'b1;
                            half_span <= half_span << 1;
                            twiddle_step <= twiddle_step >> 1;
                        end
                    end else group_base <= next_group;
                end else begin
                    position <= position + 1'b1;
                    twiddle_address <= twiddle_address + twiddle_step;
                end
            end
            default: state <= IDLE;
        endcase
    end
endmodule
