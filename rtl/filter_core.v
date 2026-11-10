// Audio samples arrive every 1024 system clocks. SDRAM stores the positive
// half of each normalized spectrum, two words per bin, in a 64-slot ring.
module filter_core (
    input wire clk, reset, sample_valid,
    input wire signed [23:0] capture,
    output wire signed [23:0] playback,
    output wire audio_ready,
    output reg filtering, fault,
    output wire memory_request, memory_write,
    output wire [20:0] memory_address,
    output wire [31:0] memory_write_data,
    input wire memory_ready, memory_read_valid,
    input wire [31:0] memory_read_data
);
    localparam CLEAR = 0, IDLE = 1, WINDOW_READ = 2, WINDOW_WEIGHT = 3, WINDOW_WRITE = 4,
               FORWARD = 5, FORWARD_WAIT = 6, STORE_START = 7, STORE_READ = 8,
               STORE_LATCH = 9, STORE_REAL = 10, STORE_IMAG = 11,
               TRACK_START = 12, TRACK_WAIT = 13, MASK_CLEAR = 14, MARK_READ = 15,
               MARK_LATCH = 16, BAND_READ = 17, BAND_WRITE = 18, NEXT_MARK = 19,
               FETCH_REAL = 20, WAIT_REAL = 21, FETCH_IMAG = 22, WAIT_IMAG = 23,
               REPAIR = 24, WRITE_POS = 25, WRITE_NEG = 26, INVERSE = 27, INVERSE_WAIT = 28,
               OVERLAP_READ = 29, OVERLAP_WEIGHT = 30, OVERLAP_SCALE = 31, OVERLAP_ADD = 32,
               OVERLAP_WRITE = 33, REPAIR_ABS = 34, REPAIR_LIMIT = 35, REPAIR_SIGN = 36;
    reg [5:0] state;
    reg [11:0] index;

    (* ram_style = "block" *) reg [23:0] input_ring [0:4095];
    reg [11:0] capture_pointer, window_start;
    wire [11:0] window_address = window_start + index;
    reg [1:0] capture_warmup;
    reg signed [23:0] input_sample;
    (* ram_style = "block" *) reg [17:0] hann [0:2047];
    initial $readmemh("tables/hann.mem", hann);
    wire [11:0] reflected = index[11] ? -index : index;
    reg signed [17:0] weight;
    reg signed [41:0] weighted;
    reg signed [41:0] synthesis_scaled;
    wire signed [25:0] weighted_sample = (weighted + 42'sd32768) >>> 16;
    wire signed [25:0] synthesis_sample = (synthesis_scaled + 42'sd32768) >>> 16;

    reg [5:0] store_slot, filled;
    wire [5:0] render_slot = store_slot - 6'd43;
    reg signed [23:0] stored_real, stored_imag;
    reg signed [23:0] repaired_real, repaired_imag;
    wire stored = state == STORE_REAL || state == STORE_IMAG;
    assign memory_request = stored || state == FETCH_REAL || state == FETCH_IMAG;
    assign memory_write = stored;
    assign memory_address = {2'b0, stored ? store_slot : render_slot, index,
                             state == STORE_IMAG || state == FETCH_IMAG};
    assign memory_write_data = state == STORE_IMAG ? {8'b0, stored_imag} : {8'b0, stored_real};

    function [11:0] reverse12;
        input [11:0] value;
        integer bit_number;
        begin
            for (bit_number = 0; bit_number < 12; bit_number = bit_number + 1)
                reverse12[bit_number] = value[11 - bit_number];
        end
    endfunction

    function [23:0] saturate24;
        input signed [26:0] value;
        begin
            if (value > 27'sd8388607) saturate24 = 24'h7fffff;
            else if (value < -27'sd8388608) saturate24 = 24'h800000;
            else saturate24 = value[23:0];
        end
    endfunction

    function [23:0] absolute24;
        input signed [23:0] value;
        begin
            absolute24 = value[23] ? -value : value;
        end
    endfunction

    function signed [23:0] blend;
        input signed [23:0] original, replacement;
        input [1:0] gain;
        reg signed [24:0] total;
        begin
            total = original + replacement;
            case (gain)
                1: blend = total >>> 1;
                2: blend = replacement;
                default: blend = original;
            endcase
        end
    endfunction

    wire fft_start = state == FORWARD || state == INVERSE;
    wire fft_busy;
    wire fft_write = state == WINDOW_WRITE || state == WRITE_POS || state == WRITE_NEG;
    wire [11:0] fft_address = state == WRITE_NEG ? reverse12(-index) :
                              fft_write ? reverse12(index) : index;
    wire signed [23:0] fft_real, fft_imag;
    wire signed [23:0] fft_input_real = state == WINDOW_WRITE ? weighted_sample[23:0] : repaired_real;
    wire signed [23:0] fft_input_imag = state == WINDOW_WRITE || index == 0 || index == 2048 ? 24'sd0 :
                                       state == WRITE_NEG ? -repaired_imag : repaired_imag;
    fft4096 transform (
        .clk(clk), .reset(reset), .start(fft_start), .inverse(state == INVERSE), .busy(fft_busy),
        .address(fft_address), .write_enable(fft_write), .write_real(fft_input_real),
        .write_imag(fft_input_imag), .read_real(fft_real), .read_imag(fft_imag)
    );

    wire peak_valid;
    wire [17:0] peak_center;
    wire [23:0] peak_floor;
    spectral_peaks peaks (
        .clk(clk), .reset(reset), .frame_start(state == STORE_START),
        .bin_valid(state == STORE_LATCH), .bin_index(index), .bin_real(fft_real), .bin_imag(fft_imag),
        .peak_valid(peak_valid), .peak_center(peak_center), .peak_floor(peak_floor)
    );

    reg [4:0] render_lane;
    wire mark, tracker_busy;
    wire [17:0] mark_center;
    wire [23:0] mark_floor;
    ridge_tracker tracks (
        .clk(clk), .reset(reset), .frame_start(state == STORE_START), .analyze(state == TRACK_START),
        .frame_slot(store_slot), .peak_valid(peak_valid), .peak_center(peak_center),
        .peak_floor(peak_floor), .busy(tracker_busy), .render_slot(render_slot),
        .render_lane(render_lane), .render_mark(mark), .render_center(mark_center), .render_floor(mark_floor)
    );

    (* ram_style = "block" *) reg [25:0] band [0:1023];
    reg [25:0] read_band;
    reg [23:0] band_floor;
    reg signed [11:0] band_bin;
    reg [3:0] band_offset;
    reg marked_frame;
    wire [10:0] rounded_center = ({1'b0, mark_center} + 19'd128) >> 8;
    wire [1:0] band_strength = band_offset == 0 || band_offset == 8 ? 2'd1 : 2'd2;
    wire band_in_range = band_bin > 0 && band_bin < 704;
    wire [9:0] band_address = state == BAND_READ || state == BAND_WRITE ? band_bin[9:0] : index[9:0];
    wire [1:0] active_strength = index < 704 ? read_band[25:24] : 0;
    reg [23:0] absolute_re, absolute_im, repair_floor;
    reg [1:0] repair_strength;
    wire [23:0] signal_amplitude = absolute_re > absolute_im ? absolute_re : absolute_im;
    reg signed [23:0] replacement, noise_real, noise_imag;
    reg [15:0] random_bits;

    (* ram_style = "block" *) reg [25:0] overlap_ring [0:4095];
    reg [11:0] overlap_start;
    wire [11:0] overlap_address = overlap_start + index;
    reg signed [25:0] old_overlap;
    reg signed [26:0] accumulated;
    (* ram_style = "block" *) reg [23:0] output_hops [0:2047];
    reg playback_bank, pending_output, playing;
    reg signed [23:0] output_sample, played_sample;
    assign audio_ready = playing && !fault;
    assign playback = audio_ready ? played_sample : 24'sd0;

    always @(posedge clk) begin
        input_sample <= input_ring[window_address];
        weight <= index == 2048 ? 18'sd65536 : $signed(hann[reflected[10:0]]);
        old_overlap <= overlap_ring[overlap_address];
        output_sample <= output_hops[{playback_bank, capture_pointer[9:0]}];
        read_band <= band[band_address];

        if (sample_valid && !reset) input_ring[capture_pointer] <= capture;
        if (state == MASK_CLEAR) band[index[9:0]] <= 0;
        else if (state == BAND_WRITE && band_in_range &&
                (read_band[25:24] < band_strength ||
                 (read_band[25:24] == band_strength && read_band[23:0] > band_floor)))
            band[band_bin[9:0]] <= {band_strength, band_floor};
        if (state == CLEAR) overlap_ring[index] <= 0;
        else if (state == OVERLAP_WRITE) begin
            if (index < 1024) begin
                overlap_ring[overlap_address] <= 0;
                output_hops[{!playback_bank, index[9:0]}] <= saturate24(accumulated);
            end else overlap_ring[overlap_address] <= accumulated[25:0];
        end

        if (reset) begin
            state <= CLEAR;
            index <= 0;
            capture_pointer <= 0;
            capture_warmup <= 0;
            window_start <= 0;
            store_slot <= 0;
            filled <= 0;
            overlap_start <= 0;
            playback_bank <= 0;
            pending_output <= 0;
            playing <= 0;
            played_sample <= 0;
            fault <= 0;
            filtering <= 0;
            random_bits <= 16'h3ca5;
        end else begin
            if (sample_valid) begin
                capture_pointer <= capture_pointer + 1'b1;
                played_sample <= playing ? output_sample : 24'sd0;
                if (&capture_pointer[9:0]) begin
                    if (pending_output) begin
                        playback_bank <= !playback_bank;
                        pending_output <= 0;
                        playing <= 1;
                    end else if (playing) fault <= 1;
                    if (capture_warmup != 3) capture_warmup <= capture_warmup + 1'b1;
                    else if (state != IDLE) fault <= 1;
                    else begin
                        window_start <= capture_pointer + 1'b1;
                        index <= 0;
                        state <= WINDOW_READ;
                    end
                end
            end

            case (state)
                CLEAR: begin
                    index <= index + 1'b1;
                    if (index == 4095) state <= IDLE;
                end
                IDLE: begin end
                WINDOW_READ: state <= WINDOW_WEIGHT;
                WINDOW_WEIGHT: begin
                    weighted <= input_sample * weight;
                    state <= WINDOW_WRITE;
                end
                WINDOW_WRITE: begin
                    index <= index + 1'b1;
                    state <= index == 4095 ? FORWARD : WINDOW_READ;
                end
                FORWARD: state <= FORWARD_WAIT;
                FORWARD_WAIT: if (!fft_busy) state <= STORE_START;
                STORE_START: state <= STORE_READ;
                STORE_READ: state <= STORE_LATCH;
                STORE_LATCH: begin
                    stored_real <= fft_real;
                    stored_imag <= fft_imag;
                    state <= STORE_REAL;
                end
                STORE_REAL: if (memory_ready) state <= STORE_IMAG;
                STORE_IMAG: if (memory_ready) begin
                    index <= index + 1'b1;
                    state <= index == 2048 ? TRACK_START : STORE_READ;
                end
                TRACK_START: state <= TRACK_WAIT;
                TRACK_WAIT: if (!tracker_busy) begin
                    if (filled == 43) begin
                        index <= 0;
                        marked_frame <= 0;
                        render_lane <= 0;
                        state <= MASK_CLEAR;
                    end else begin
                        filled <= filled + 1'b1;
                        store_slot <= store_slot + 1'b1;
                        state <= IDLE;
                    end
                end
                MASK_CLEAR: begin
                    index <= index + 1'b1;
                    if (index == 703) state <= MARK_READ;
                end
                MARK_READ: state <= MARK_LATCH;
                MARK_LATCH: if (mark) begin
                    band_bin <= $signed({1'b0, rounded_center}) - 12'sd4;
                    band_floor <= mark_floor;
                    band_offset <= 0;
                    marked_frame <= 1;
                    state <= BAND_READ;
                end else state <= NEXT_MARK;
                BAND_READ: state <= BAND_WRITE;
                BAND_WRITE: begin
                    band_bin <= band_bin + 1'b1;
                    band_offset <= band_offset + 1'b1;
                    state <= band_offset == 8 ? NEXT_MARK : BAND_READ;
                end
                NEXT_MARK: if (render_lane == 31) begin
                    index <= 0;
                    filtering <= marked_frame;
                    state <= FETCH_REAL;
                end else begin
                    render_lane <= render_lane + 1'b1;
                    state <= MARK_READ;
                end
                FETCH_REAL: if (memory_ready) state <= WAIT_REAL;
                WAIT_REAL: if (memory_read_valid) begin
                    stored_real <= memory_read_data[23:0];
                    state <= FETCH_IMAG;
                end
                FETCH_IMAG: if (memory_ready) state <= WAIT_IMAG;
                WAIT_IMAG: if (memory_read_valid) begin
                    stored_imag <= memory_read_data[23:0];
                    state <= REPAIR_ABS;
                end
                REPAIR_ABS: begin
                    absolute_re <= absolute24(stored_real);
                    absolute_im <= absolute24(stored_imag);
                    repair_floor <= read_band[23:0];
                    repair_strength <= active_strength;
                    state <= REPAIR_LIMIT;
                end
                REPAIR_LIMIT: begin
                    replacement <= signal_amplitude < repair_floor ?
                                   $signed({1'b0, signal_amplitude[23:1]}) : $signed({1'b0, repair_floor[23:1]});
                    state <= REPAIR_SIGN;
                end
                REPAIR_SIGN: begin
                    noise_real <= random_bits[0] ? replacement : -replacement;
                    noise_imag <= random_bits[5] ? replacement : -replacement;
                    state <= REPAIR;
                end
                REPAIR: begin
                    repaired_real <= blend(stored_real, noise_real, repair_strength);
                    repaired_imag <= blend(stored_imag, noise_imag, repair_strength);
                    random_bits <= {random_bits[14:0], random_bits[15] ^ random_bits[13] ^ random_bits[12] ^ random_bits[10]};
                    state <= WRITE_POS;
                end
                WRITE_POS: if (index == 2048) begin
                    index <= 0;
                    state <= INVERSE;
                end else if (index == 0) begin
                    index <= 1;
                    state <= FETCH_REAL;
                end else state <= WRITE_NEG;
                WRITE_NEG: begin
                    index <= index + 1'b1;
                    state <= FETCH_REAL;
                end
                INVERSE: state <= INVERSE_WAIT;
                INVERSE_WAIT: if (!fft_busy) state <= OVERLAP_READ;
                OVERLAP_READ: state <= OVERLAP_WEIGHT;
                OVERLAP_WEIGHT: begin
                    weighted <= fft_real * weight;
                    state <= OVERLAP_SCALE;
                end
                OVERLAP_SCALE: begin
                    // Q16 factor 43691 / 65536 is approximately 2/3.
                    synthesis_scaled <= weighted_sample * 17'sd43691;
                    state <= OVERLAP_ADD;
                end
                OVERLAP_ADD: begin
                    accumulated <= old_overlap + synthesis_sample;
                    state <= OVERLAP_WRITE;
                end
                OVERLAP_WRITE: begin
                    index <= index + 1'b1;
                    if (index == 4095) begin
                        overlap_start <= overlap_start + 12'd1024;
                        pending_output <= 1;
                        store_slot <= store_slot + 1'b1;
                        state <= IDLE;
                    end else state <= OVERLAP_READ;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
