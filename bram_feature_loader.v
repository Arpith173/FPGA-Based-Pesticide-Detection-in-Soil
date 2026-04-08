//============================================================================
// BRAM Feature Loader - Reads features from BRAM and feeds to SVM detector
// Target: Xilinx Artix-7 (Nexys 4 DDR)
//
// This module replaces the demo feature loader in top_nexys4.v.
// Instead of loading uniform test values, it reads real pre-computed
// features from BRAM.
//
// OPERATION:
//   1. Switch SW[2:0] selects sample index (0-7)
//   2. Press BTNC → module reads S1 features from BRAM → starts SVM S1
//   3. If contaminated: reads S2 features from BRAM → starts SVM S2+S3
//   4. result_valid goes high → classification complete
//
// BRAM ADDRESS CALCULATION:
//   base_addr = sample_index * 64
//   S1 features: base_addr + 0  to base_addr + 18
//   S2 features: base_addr + 19 to base_addr + 53
//
// TIMING:
//   BRAM read has 1-cycle latency, so the FSM accounts for this.
//   A brief SVM reset pulse is issued before each new classification
//   to clear the SVM's internal state (contaminated flag, etc).
//============================================================================

`timescale 1ns / 1ps

module bram_feature_loader #(
    parameter N_FEATURES_S1 = 19,
    parameter N_FEATURES_S2 = 35,
    parameter DATA_WIDTH    = 32,
    parameter ADDR_WIDTH    = 9,
    parameter SAMPLE_STRIDE = 64     // Address stride per sample
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // User interface
    input  wire                    start_pulse,      // Single-cycle trigger
    input  wire [2:0]              sample_select,    // Which sample (0-7)

    // BRAM read interface
    output reg  [ADDR_WIDTH-1:0]   bram_addr,
    input  wire [DATA_WIDTH-1:0]   bram_data,        // 1-cycle latency

    // SVM detector interface
    output reg                     svm_start,
    output reg                     svm_rst_n,        // SVM-local reset
    input  wire                    svm_done,
    input  wire                    svm_contaminated,
    input  wire                    svm_result_valid,
    output reg                     feature_valid,
    output reg signed [DATA_WIDTH-1:0] feature_data,
    output reg  [5:0]              feature_index,
    output reg                     feature_stage,

    // Status
    output reg  [3:0]              loader_state_out  // For debug LEDs
);

    //------------------------------------------------------------------
    // State Machine
    //------------------------------------------------------------------
    localparam LS_IDLE        = 4'd0;
    localparam LS_RESET_SVM   = 4'd1;   // Brief reset to clear SVM state
    localparam LS_RESET_DONE  = 4'd2;   // Release reset, wait 1 cycle
    localparam LS_PREP_S1     = 4'd3;   // Setup BRAM address for S1
    localparam LS_READ_S1     = 4'd4;   // Wait for BRAM read latency
    localparam LS_LOAD_S1     = 4'd5;   // Write feature to SVM
    localparam LS_START_S1    = 4'd6;   // Pulse start for Stage 1
    localparam LS_WAIT_S1     = 4'd7;   // Wait for S1 done
    localparam LS_PREP_S2     = 4'd8;   // Setup BRAM address for S2
    localparam LS_READ_S2     = 4'd9;   // Wait for BRAM read latency
    localparam LS_LOAD_S2     = 4'd10;  // Write feature to SVM
    localparam LS_START_S2    = 4'd11;  // Pulse start for Stage 2+3
    localparam LS_WAIT_RESULT = 4'd12;  // Wait for result_valid
    localparam LS_DONE        = 4'd13;  // Classification complete

    reg [3:0]  state;
    reg [5:0]  counter;               // Feature counter (0 to N-1)
    reg [ADDR_WIDTH-1:0] base_addr;   // Base address for current sample

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= LS_IDLE;
            counter       <= 0;
            base_addr     <= 0;
            bram_addr     <= 0;
            svm_start     <= 0;
            svm_rst_n     <= 1;      // SVM not in reset
            feature_valid <= 0;
            feature_data  <= 0;
            feature_index <= 0;
            feature_stage <= 0;
        end else begin
            // Defaults (single-cycle pulses)
            svm_start     <= 0;
            feature_valid <= 0;

            case (state)
                //------------------------------------------------------
                // IDLE: Wait for start button
                //------------------------------------------------------
                LS_IDLE: begin
                    svm_rst_n <= 1;  // Ensure SVM out of reset
                    if (start_pulse) begin
                        base_addr <= {sample_select, 6'b000000}; // sample * 64
                        counter   <= 0;
                        svm_rst_n <= 0;  // Assert SVM reset
                        state     <= LS_RESET_SVM;
                    end
                end

                //------------------------------------------------------
                // RESET_SVM: Hold reset for 1 cycle to clear state
                //------------------------------------------------------
                LS_RESET_SVM: begin
                    svm_rst_n <= 0;  // Keep reset active
                    state     <= LS_RESET_DONE;
                end

                //------------------------------------------------------
                // RESET_DONE: Release reset, wait 1 cycle
                //------------------------------------------------------
                LS_RESET_DONE: begin
                    svm_rst_n <= 1;  // Release reset
                    state     <= LS_PREP_S1;
                end

                //------------------------------------------------------
                // PREP_S1: Set BRAM address, wait 1 cycle for data
                //------------------------------------------------------
                LS_PREP_S1: begin
                    bram_addr <= base_addr + counter;
                    state     <= LS_READ_S1;
                end

                //------------------------------------------------------
                // READ_S1: BRAM data now valid, latch and write to SVM
                //------------------------------------------------------
                LS_READ_S1: begin
                    state <= LS_LOAD_S1;
                end

                //------------------------------------------------------
                // LOAD_S1: Write feature to SVM and advance
                //------------------------------------------------------
                LS_LOAD_S1: begin
                    feature_valid <= 1;
                    feature_data  <= bram_data;
                    feature_index <= counter;
                    feature_stage <= 0;   // Stage 1
                    counter       <= counter + 1;

                    if (counter < N_FEATURES_S1 - 1) begin
                        // More S1 features to load
                        bram_addr <= base_addr + counter + 1;
                        state     <= LS_READ_S1;
                    end else begin
                        // All S1 features loaded
                        state <= LS_START_S1;
                    end
                end

                //------------------------------------------------------
                // START_S1: Trigger Stage 1 computation
                //------------------------------------------------------
                LS_START_S1: begin
                    svm_start <= 1;
                    state     <= LS_WAIT_S1;
                end

                //------------------------------------------------------
                // WAIT_S1: Wait for Stage 1 done
                //------------------------------------------------------
                LS_WAIT_S1: begin
                    if (svm_done) begin
                        if (svm_contaminated) begin
                            // Need Stage 2: load S2 features from BRAM
                            counter <= 0;
                            state   <= LS_PREP_S2;
                        end else begin
                            // Clean: jump to done
                            state <= LS_DONE;
                        end
                    end
                end

                //------------------------------------------------------
                // PREP_S2: Set BRAM address for S2 features
                // S2 features start at offset 19 within the sample
                //------------------------------------------------------
                LS_PREP_S2: begin
                    bram_addr <= base_addr + N_FEATURES_S1 + counter;
                    state     <= LS_READ_S2;
                end

                //------------------------------------------------------
                // READ_S2: Wait for BRAM data
                //------------------------------------------------------
                LS_READ_S2: begin
                    state <= LS_LOAD_S2;
                end

                //------------------------------------------------------
                // LOAD_S2: Write S2 feature to SVM and advance
                //------------------------------------------------------
                LS_LOAD_S2: begin
                    feature_valid <= 1;
                    feature_data  <= bram_data;
                    feature_index <= counter;
                    feature_stage <= 1;   // Stage 2
                    counter       <= counter + 1;

                    if (counter < N_FEATURES_S2 - 1) begin
                        bram_addr <= base_addr + N_FEATURES_S1 + counter + 1;
                        state     <= LS_READ_S2;
                    end else begin
                        state <= LS_START_S2;
                    end
                end

                //------------------------------------------------------
                // START_S2: Trigger Stage 2 (+ auto Stage 3)
                //------------------------------------------------------
                LS_START_S2: begin
                    svm_start <= 1;
                    state     <= LS_WAIT_RESULT;
                end

                //------------------------------------------------------
                // WAIT_RESULT: Wait for result_valid (S2 + S3 complete)
                //------------------------------------------------------
                LS_WAIT_RESULT: begin
                    if (svm_result_valid)
                        state <= LS_DONE;
                end

                //------------------------------------------------------
                // DONE: Stay here until next start_pulse
                //------------------------------------------------------
                LS_DONE: begin
                    if (start_pulse) begin
                        base_addr <= {sample_select, 6'b000000};
                        counter   <= 0;
                        svm_rst_n <= 0;  // Assert SVM reset
                        state     <= LS_RESET_SVM;
                    end
                end
            endcase
        end
    end

    // Debug output
    always @(*) loader_state_out = state;

endmodule
