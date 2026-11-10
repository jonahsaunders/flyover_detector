// Associates a bounded set of peaks and marks the previous 43 frames on confirmation.
module ridge_tracker (
    input wire clk, reset,
    input wire frame_start, analyze,
    input wire [5:0] frame_slot,
    input wire peak_valid,
    input wire [17:0] peak_center,
    input wire [23:0] peak_floor,
    output wire busy,
    input wire [5:0] render_slot,
    input wire [4:0] render_lane,
    output wire render_mark,
    output wire [17:0] render_center,
    output wire [23:0] render_floor
);
    localparam IDLE = 0, LANE = 1, MATCH = 2, ASSIGN = 3, HIST_READ = 4,
               HIST_EVAL = 5, MEASURE = 6, PAIR_LANE = 7, PAIR_OTHER = 8,
               PAIR_RATIO = 9, MARK_READ = 10, MARK_WRITE = 11,
               ALLOCATE = 12, NEXT_LANE = 13, PREDICT_GAPS = 14, MATCH_EVAL = 15;
    reg [3:0] state;
    assign busy = state != IDLE;

    reg [17:0] peak_bins [0:31];
    reg [23:0] peak_floors [0:31];
    reg [5:0] peak_count;
    reg [31:0] used;
    reg [5:0] lane, candidate, other;
    reg [3:0] ratio;
    wire [4:0] lane_index = lane[4:0];
    wire [4:0] candidate_index = candidate[4:0];
    wire [4:0] other_index = other[4:0];

    reg [31:0] active, confirmed, gliding, strong_glide;
    reg [5:0] age [0:31];
    reg [1:0] misses [0:31];
    reg [17:0] last_center [0:31];
    reg [23:0] last_floor [0:31];
    reg signed [19:0] speed [0:31];
    reg [17:0] earlier [0:31];

    // {mask, valid observation, Q8 center, local background amplitude}.
    (* ram_style = "block" *) reg [43:0] history [0:2047];
    reg [43:0] read_history;
    reg [5:0] back, span;
    wire [5:0] past_slot = frame_slot - back;
    wire [10:0] scan_address = {past_slot, lane_index};
    wire [10:0] render_address = {render_slot, render_lane};
    wire [10:0] read_address = state == IDLE ? render_address : scan_address;
    assign render_mark = read_history[43];
    assign render_center = read_history[41:24];
    assign render_floor = read_history[23:0];
    wire observed = read_history[42];
    wire [17:0] observed_center = read_history[41:24];

    reg [17:0] prediction, best_distance;
    reg [4:0] best_peak;
    reg found;
    wire [17:0] current_peak = peak_bins[candidate_index];
    reg signed [18:0] match_delta;
    wire [18:0] distance = match_delta[18] ? -match_delta : match_delta;
    wire [17:0] best_center = peak_bins[best_peak];
    wire [23:0] best_floor = peak_floors[best_peak];
    wire [17:0] last = last_center[lane_index];
    wire signed [19:0] old_speed = speed[lane_index];
    wire signed [19:0] displacement = $signed({2'b0, best_center}) - $signed({2'b0, last});
    wire signed [19:0] extrapolation = misses[lane_index] == 0 ? old_speed :
                                      misses[lane_index] == 1 ? old_speed <<< 1 :
                                      misses[lane_index] == 2 ? old_speed + (old_speed <<< 1) : old_speed <<< 2;
    wire signed [19:0] next_center = $signed({2'b0, last}) + extrapolation;
    wire [17:0] bounded_center = next_center < 0 ? 18'd0 : next_center > 20'sd175000 ? 18'd175000 : next_center[17:0];
    wire [17:0] step_limit = 18'd256 + (last >> 7);

    reg [5:0] hits, falling, votes;
    reg [17:0] oldest_center, lookback [0:3];
    wire [17:0] drop = oldest_center > last ? oldest_center - last : 0;
    // Approximately 0.15% with harmonic corroboration, 0.9% for a lone track.
    wire [17:0] small_drop = (oldest_center >> 10) + (oldest_center >> 11);
    wire [17:0] large_drop = (oldest_center >> 7) + (oldest_center >> 10);
    wire [8:0] covered = (hits << 2) + hits;
    wire [8:0] span_target = span << 2;
    wire [8:0] fall_score = (falling << 2) + falling;
    wire [8:0] vote_target = votes << 2;

    wire lower_lane = earlier[lane_index] <= earlier[other_index];
    wire [17:0] low_early = lower_lane ? earlier[lane_index] : earlier[other_index];
    wire [17:0] high_early = lower_lane ? earlier[other_index] : earlier[lane_index];
    wire [17:0] low_late = lower_lane ? last_center[lane_index] : last_center[other_index];
    wire [17:0] high_late = lower_lane ? last_center[other_index] : last_center[lane_index];
    reg [21:0] harmonic_early, harmonic_late;
    reg signed [22:0] early_error, late_error;

    reg write_history;
    reg [10:0] history_address;
    reg [43:0] history_data;
    always @* begin
        write_history = 0;
        history_address = {frame_slot, lane_index};
        history_data = 0;
        if (state == ASSIGN) begin
            write_history = 1;
            if (found) history_data = {confirmed[lane_index], 1'b1, best_center, best_floor};
            else if (active[lane_index] && confirmed[lane_index] && misses[lane_index] < 3)
                history_data = {1'b1, 1'b0, bounded_center, last_floor[lane_index]};
        end else if (state == ALLOCATE && lane < 32 && !active[lane_index] && candidate < peak_count && !used[candidate_index]) begin
            write_history = 1;
            history_data = {2'b01, current_peak, peak_floors[candidate_index]};
        end else if (state == MARK_WRITE && observed) begin
            write_history = 1;
            history_address = scan_address;
            history_data = {1'b1, read_history[42:0]};
        end else if (state == PREDICT_GAPS) begin
            write_history = 1;
            history_address = scan_address;
            history_data = {1'b1, 1'b0, best_center, best_floor};
        end
    end

    reg [1:0] ratio_stage;
    always @(posedge clk) begin
        read_history <= history[read_address];
        if (write_history) history[history_address] <= history_data;

        if (frame_start) peak_count <= 0;
        else if (peak_valid && peak_count < 32) begin
            peak_bins[peak_count[4:0]] <= peak_center;
            peak_floors[peak_count[4:0]] <= peak_floor;
            peak_count <= peak_count + 1'b1;
        end

        if (reset) begin
            state <= IDLE;
            peak_count <= 0;
            active <= 0;
            confirmed <= 0;
            gliding <= 0;
            strong_glide <= 0;
            used <= 0;
        end else case (state)
            IDLE: if (analyze) begin
                lane <= 0;
                used <= 0;
                gliding <= 0;
                strong_glide <= 0;
                state <= LANE;
            end
            LANE: if (lane == 32) begin
                lane <= 0;
                state <= PAIR_LANE;
            end else begin
                found <= 0;
                best_distance <= step_limit + (misses[lane_index] != 0 ? 18'd512 : 18'd0);
                prediction <= bounded_center;
                candidate <= 0;
                state <= active[lane_index] && peak_count != 0 ? MATCH : ASSIGN;
            end
            MATCH: begin
                match_delta <= $signed({1'b0, current_peak}) - $signed({1'b0, prediction});
                state <= MATCH_EVAL;
            end
            MATCH_EVAL: begin
                if (!used[candidate_index] && distance < best_distance) begin
                    best_distance <= distance[17:0];
                    best_peak <= candidate_index;
                    found <= 1;
                end
                candidate <= candidate + 1'b1;
                state <= candidate + 1'b1 == peak_count ? ASSIGN : MATCH;
            end
            ASSIGN: begin
                if (!active[lane_index]) state <= NEXT_LANE;
                else if (found) begin
                    used[best_peak] <= 1;
                    last_center[lane_index] <= best_center;
                    last_floor[lane_index] <= best_floor;
                    speed[lane_index] <= misses[lane_index] == 0 ? old_speed - (old_speed >>> 2) + (displacement >>> 2) : old_speed;
                    misses[lane_index] <= 0;
                    if (age[lane_index] < 44) age[lane_index] <= age[lane_index] + 1'b1;
                    if (confirmed[lane_index] && misses[lane_index] != 0) begin
                        back <= misses[lane_index];
                        state <= PREDICT_GAPS;
                    end else if (!confirmed[lane_index] && age[lane_index] >= 21) begin
                        span <= age[lane_index] < 44 ? age[lane_index] + 1'b1 : 6'd44;
                        back <= 0;
                        hits <= 0;
                        falling <= 0;
                        votes <= 0;
                        oldest_center <= best_center;
                        state <= HIST_READ;
                    end else state <= NEXT_LANE;
                end else begin
                    if (misses[lane_index] == 3) begin
                        active[lane_index] <= 0;
                        confirmed[lane_index] <= 0;
                    end else begin
                        misses[lane_index] <= misses[lane_index] + 1'b1;
                        if (age[lane_index] < 44) age[lane_index] <= age[lane_index] + 1'b1;
                    end
                    state <= NEXT_LANE;
                end
            end
            PREDICT_GAPS: begin
                back <= back - 1'b1;
                if (back == 1) state <= NEXT_LANE;
            end
            HIST_READ: state <= HIST_EVAL;
            HIST_EVAL: begin
                if (observed) begin
                    oldest_center <= observed_center;
                    hits <= hits + 1'b1;
                    lookback[0] <= observed_center;
                    lookback[1] <= lookback[0];
                    lookback[2] <= lookback[1];
                    lookback[3] <= lookback[2];
                    if (hits >= 4) begin
                        votes <= votes + 1'b1;
                        if ({1'b0, observed_center} + 19'd15 >= {1'b0, lookback[3]})
                            falling <= falling + 1'b1;
                    end
                end
                back <= back + 1'b1;
                state <= back + 1'b1 == span ? MEASURE : HIST_READ;
            end
            MEASURE: begin
                earlier[lane_index] <= oldest_center;
                gliding[lane_index] <= hits >= 22 && covered >= span_target && fall_score >= vote_target &&
                                       drop >= 14 && drop >= small_drop;
                strong_glide[lane_index] <= drop >= 108 && drop >= large_drop;
                state <= NEXT_LANE;
            end
            NEXT_LANE: begin
                lane <= lane + 1'b1;
                state <= LANE;
            end
            PAIR_LANE: if (lane == 32) begin
                lane <= 0;
                candidate <= 0;
                state <= ALLOCATE;
            end else if (!gliding[lane_index]) lane <= lane + 1'b1;
            else if (strong_glide[lane_index]) begin
                confirmed[lane_index] <= 1;
                back <= 0;
                state <= MARK_READ;
            end else begin
                other <= 0;
                state <= PAIR_OTHER;
            end
            PAIR_OTHER: if (other == 32) begin
                lane <= lane + 1'b1;
                state <= PAIR_LANE;
            end else if (other == lane || !gliding[other_index] ||
                         age[lane_index] > age[other_index] + 4 || age[other_index] > age[lane_index] + 4) begin
                other <= other + 1'b1;
            end else begin
                ratio <= 2;
                ratio_stage <= 0;
                state <= PAIR_RATIO;
            end
            PAIR_RATIO: if (ratio_stage == 0) begin
                harmonic_early <= low_early * ratio;
                harmonic_late <= low_late * ratio;
                ratio_stage <= 1;
            end else if (ratio_stage == 1) begin
                early_error <= $signed({1'b0, harmonic_early}) - $signed({5'b0, high_early});
                late_error <= $signed({1'b0, harmonic_late}) - $signed({5'b0, high_late});
                ratio_stage <= 2;
            end else if (early_error > -23'sd90 && early_error < 23'sd90 &&
                         late_error > -23'sd90 && late_error < 23'sd90) begin
                confirmed[lane_index] <= 1;
                back <= 0;
                state <= MARK_READ;
            end else if (ratio == 8) begin
                other <= other + 1'b1;
                state <= PAIR_OTHER;
            end else begin
                ratio <= ratio + 1'b1;
                ratio_stage <= 0;
            end
            MARK_READ: state <= MARK_WRITE;
            MARK_WRITE: if (back + 1'b1 == age[lane_index]) begin
                lane <= lane + 1'b1;
                state <= PAIR_LANE;
            end else begin
                back <= back + 1'b1;
                state <= MARK_READ;
            end
            ALLOCATE: if (lane == 32 || candidate == peak_count) state <= IDLE;
            else if (active[lane_index]) lane <= lane + 1'b1;
            else begin
                candidate <= candidate + 1'b1;
                if (!used[candidate_index]) begin
                    active[lane_index] <= 1;
                    confirmed[lane_index] <= 0;
                    age[lane_index] <= 1;
                    misses[lane_index] <= 0;
                    last_center[lane_index] <= current_peak;
                    last_floor[lane_index] <= peak_floors[candidate_index];
                    speed[lane_index] <= 0;
                    lane <= lane + 1'b1;
                end
            end
            default: state <= IDLE;
        endcase
    end
endmodule
