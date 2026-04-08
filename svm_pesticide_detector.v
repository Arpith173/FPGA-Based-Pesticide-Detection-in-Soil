//============================================================================
// SVM Pesticide Detector - 32-BIT, 3-STAGE PIPELINE (v3)
// Target: Xilinx Artix-7 (Nexys 4)
// Format: Q16.16 (32-bit signed, 16 fractional bits)
//
// ARCHITECTURE:
//   Stage 1: Binary Detection      (Clean vs Contaminated)
//            19 features, 1 SVM → score >= 0 means contaminated
//   Stage 2: Family Classification  (5 chemical families)
//            35 features, 5 SVMs → argmax determines family
//   Stage 3: Specific Pesticide ID  (within multi-member families)
//            54 features (19+35), 1 binary SVM per multi-member family
//            Families 3,5: single member → skip Stage 3
//            Families 1,2,4: binary SVM → sign(w'x + b) picks pesticide
//
// PESTICIDE IDS:
//   1 = Chlorpyrifos  (Family 1: Organophosphate)
//   2 = Bendiocarb    (Family 2: Carbamate)
//   3 = Acephate      (Family 1: Organophosphate)
//   4 = Butachlor     (Family 4: Pyrethroid/Amide)
//   5 = Captan        (Family 5: Other)
//   6 = Carbofuran    (Family 2: Carbamate)
//   7 = Chlorothalonil(Family 3: Chlorinated)
//   8 = Permethrin    (Family 4: Pyrethroid/Amide)
//
// SIGNAL PROTOCOL:
//   1. Load S1 features → pulse start → wait done
//   2. If contaminated: load S2 features → pulse start → wait done
//   3. result_valid=1 when FULL result ready (family_id + pesticide_id)
//============================================================================

`timescale 1ns / 1ps

module svm_pesticide_detector #(
    parameter N_FEATURES_S1 = 19,
    parameter N_FEATURES_S2 = 35,
    parameter N_FEATURES_S3 = 54,   // S1 + S2 combined
    parameter N_FAMILIES    = 5,
    parameter DATA_WIDTH    = 32,
    parameter FRAC_BITS     = 16,
    parameter ACCUM_WIDTH   = 64
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    output reg                      done,
    output reg                      busy,

    // Feature Input Interface
    input  wire                     feature_valid,
    input  wire signed [DATA_WIDTH-1:0] feature_data,
    input  wire [5:0]               feature_index,
    input  wire                     feature_stage,   // 0=stage1, 1=stage2

    // Classification Result
    output reg                      contaminated,
    output reg [2:0]                family_id,       // 1-5
    output reg [3:0]                pesticide_id,    // 1-8 (specific pesticide)
    output reg                      result_valid
);

    //----------------------------------------------------------------------
    // State Machine
    //----------------------------------------------------------------------
    localparam S_IDLE       = 4'd0;
    localparam S_COMPUTE_S1 = 4'd1;
    localparam S_CHECK_S1   = 4'd2;
    localparam S_DONE_S1    = 4'd3;   // Pause: wait for S2 features + start
    localparam S_COMPUTE_S2 = 4'd4;
    localparam S_CHECK_S2   = 4'd5;
    localparam S_COMPUTE_S3 = 4'd6;   // NEW: Stage 3 computation
    localparam S_CHECK_S3   = 4'd7;   // NEW: Stage 3 decision
    localparam S_REPORT     = 4'd8;

    reg [3:0] state;
    reg [5:0] counter;

    // Stage 1 Storage
    reg signed [DATA_WIDTH-1:0] s1_features [0:N_FEATURES_S1-1];
    reg signed [DATA_WIDTH-1:0] s1_weights  [0:N_FEATURES_S1-1];
    reg signed [DATA_WIDTH-1:0] s1_bias_rom [0:0];

    // Stage 2 Storage
    reg signed [DATA_WIDTH-1:0] s2_features [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_weights_f1 [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_weights_f2 [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_weights_f3 [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_weights_f4 [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_weights_f5 [0:N_FEATURES_S2-1];
    reg signed [DATA_WIDTH-1:0] s2_bias_rom   [0:4];

    // Stage 3 Storage (only for multi-member families: 1, 2, 4)
    // Each has 54 weights = 19 (S1 features) + 35 (S2 features)
    reg signed [DATA_WIDTH-1:0] s3_weights_f1 [0:N_FEATURES_S3-1];
    reg signed [DATA_WIDTH-1:0] s3_weights_f2 [0:N_FEATURES_S3-1];
    reg signed [DATA_WIDTH-1:0] s3_weights_f4 [0:N_FEATURES_S3-1];
    reg signed [DATA_WIDTH-1:0] s3_bias_rom   [0:4];

    // Stage 3 class labels: [neg_label, pos_label] for each family
    // neg_label = ClassNames(1) when score < 0
    // pos_label = ClassNames(2) when score >= 0
    reg [7:0] s3_class_labels [0:9]; // 5 families × 2 labels

    // Computation - Stage 1
    reg signed [ACCUM_WIDTH-1:0] accumulator;

    // Computation - Stage 2 (dedicated per-family accumulators)
    reg signed [ACCUM_WIDTH-1:0] s2_acc [0:N_FAMILIES-1];

    // Computation - Stage 3
    reg signed [ACCUM_WIDTH-1:0] s3_acc;
    
    integer i;

    //----------------------------------------------------------------------
    // Multiplier Products (computed inline as blocking assignments)
    //----------------------------------------------------------------------
    reg signed [ACCUM_WIDTH-1:0] s1_product;
    reg signed [ACCUM_WIDTH-1:0] s2_product1, s2_product2, s2_product3, s2_product4, s2_product5;
    reg signed [ACCUM_WIDTH-1:0] s3_product;

    // Current feature value for Stage 3 (mux between S1 and S2 features)
    reg signed [DATA_WIDTH-1:0] s3_current_feature;
    // Current weight for Stage 3 (mux based on winning family)
    reg signed [DATA_WIDTH-1:0] s3_current_weight;

    // ROM Initialization
    initial begin
        $readmemh("stage1_weights.hex",    s1_weights);
        $readmemh("stage1_bias.hex",       s1_bias_rom);
        $readmemh("stage2_weights_f1.hex", s2_weights_f1);
        $readmemh("stage2_weights_f2.hex", s2_weights_f2);
        $readmemh("stage2_weights_f3.hex", s2_weights_f3);
        $readmemh("stage2_weights_f4.hex", s2_weights_f4);
        $readmemh("stage2_weights_f5.hex", s2_weights_f5);
        $readmemh("stage2_bias.hex",       s2_bias_rom);
        $readmemh("stage3_weights_f1.hex", s3_weights_f1);
        $readmemh("stage3_weights_f2.hex", s3_weights_f2);
        $readmemh("stage3_weights_f4.hex", s3_weights_f4);
        $readmemh("stage3_bias.hex",       s3_bias_rom);
        $readmemh("stage3_class_labels.hex", s3_class_labels);
    end

    //----------------------------------------------------------------------
    // Feature Loading (Always Active - Independent of FSM)
    //----------------------------------------------------------------------
    always @(posedge clk) begin
        if (feature_valid) begin
            if (feature_stage == 0)
                s1_features[feature_index] <= feature_data;
            else
                s2_features[feature_index] <= feature_data;
        end
    end

    //----------------------------------------------------------------------
    // Stage 3 Feature & Weight MUX
    // S3 features = [s1_features[0:18], s2_features[0:34]] (concatenated)
    // The weight source depends on which family won Stage 2
    //----------------------------------------------------------------------
    always @(*) begin
        // Feature mux: first 19 come from S1, next 35 from S2
        if (counter < N_FEATURES_S1)
            s3_current_feature = s1_features[counter];
        else
            s3_current_feature = s2_features[counter - N_FEATURES_S1];

        // Weight mux: select based on winning family_id
        case (family_id)
            3'd1:    s3_current_weight = s3_weights_f1[counter];
            3'd2:    s3_current_weight = s3_weights_f2[counter];
            3'd4:    s3_current_weight = s3_weights_f4[counter];
            default: s3_current_weight = 0;
        endcase
    end

    //----------------------------------------------------------------------
    // Main FSM
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 0;
            busy         <= 0;
            contaminated <= 0;
            family_id    <= 0;
            pesticide_id <= 0;
            result_valid <= 0;
            counter      <= 0;
            accumulator  <= 0;
            s3_acc       <= 0;
            for (i = 0; i < N_FAMILIES; i = i + 1) s2_acc[i] <= 0;
        end else begin
            case (state)

                //----------------------------------------------------------
                // IDLE: Wait for 'start' pulse.
                //----------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        if (contaminated) begin
                            // Stage 2 start
                            state   <= S_COMPUTE_S2;
                            busy    <= 1;
                            done    <= 0;
                            counter <= 0;
                            for (i = 0; i < N_FAMILIES; i = i + 1)
                                s2_acc[i] <= {{(ACCUM_WIDTH-DATA_WIDTH){s2_bias_rom[i][DATA_WIDTH-1]}}, s2_bias_rom[i]};
                        end else begin
                            // Stage 1 start
                            state        <= S_COMPUTE_S1;
                            busy         <= 1;
                            done         <= 0;
                            result_valid <= 0;
                            pesticide_id <= 0;
                            counter      <= 0;
                            accumulator  <= {{(ACCUM_WIDTH-DATA_WIDTH){s1_bias_rom[0][DATA_WIDTH-1]}}, s1_bias_rom[0]};
                        end
                    end
                end

                //----------------------------------------------------------
                // STAGE 1: Compute dot product w' * x + b
                //----------------------------------------------------------
                S_COMPUTE_S1: begin
                    if (counter < N_FEATURES_S1) begin
                        s1_product = $signed(s1_weights[counter]) * $signed(s1_features[counter]);
                        accumulator <= accumulator + (s1_product >>> FRAC_BITS);
                        counter     <= counter + 1;
                    end else begin
                        state <= S_CHECK_S1;
                    end
                end

                //----------------------------------------------------------
                // CHECK S1: score >= 0 => contaminated
                //----------------------------------------------------------
                S_CHECK_S1: begin
                    if (accumulator >= 0) begin
                        contaminated <= 1;
                        state        <= S_DONE_S1;
                    end else begin
                        contaminated <= 0;
                        family_id    <= 0;
                        pesticide_id <= 0;
                        state        <= S_REPORT;
                    end
                end

                //----------------------------------------------------------
                // DONE_S1: Signal S1 complete, wait for S2 features
                //----------------------------------------------------------
                S_DONE_S1: begin
                    done  <= 1;
                    busy  <= 0;
                    state <= S_IDLE;
                end

                //----------------------------------------------------------
                // STAGE 2: Compute 5 family scores
                //----------------------------------------------------------
                S_COMPUTE_S2: begin
                    if (counter < N_FEATURES_S2) begin
                        s2_product1 = $signed(s2_weights_f1[counter]) * $signed(s2_features[counter]);
                        s2_product2 = $signed(s2_weights_f2[counter]) * $signed(s2_features[counter]);
                        s2_product3 = $signed(s2_weights_f3[counter]) * $signed(s2_features[counter]);
                        s2_product4 = $signed(s2_weights_f4[counter]) * $signed(s2_features[counter]);
                        s2_product5 = $signed(s2_weights_f5[counter]) * $signed(s2_features[counter]);

                        s2_acc[0] <= s2_acc[0] + (s2_product1 >>> FRAC_BITS);
                        s2_acc[1] <= s2_acc[1] + (s2_product2 >>> FRAC_BITS);
                        s2_acc[2] <= s2_acc[2] + (s2_product3 >>> FRAC_BITS);
                        s2_acc[3] <= s2_acc[3] + (s2_product4 >>> FRAC_BITS);
                        s2_acc[4] <= s2_acc[4] + (s2_product5 >>> FRAC_BITS);

                        counter <= counter + 1;
                    end else begin
                        state <= S_CHECK_S2;
                    end
                end

                //----------------------------------------------------------
                // CHECK S2: Find family with maximum score (argmax)
                // Then decide: single-member family → S_REPORT
                //              multi-member family  → S_COMPUTE_S3
                //----------------------------------------------------------
                S_CHECK_S2: begin
                    // Argmax
                    family_id <= 1;
                    if      (s2_acc[1] > s2_acc[0] && s2_acc[1] > s2_acc[2] && s2_acc[1] > s2_acc[3] && s2_acc[1] > s2_acc[4])
                        family_id <= 2;
                    else if (s2_acc[2] > s2_acc[0] && s2_acc[2] > s2_acc[1] && s2_acc[2] > s2_acc[3] && s2_acc[2] > s2_acc[4])
                        family_id <= 3;
                    else if (s2_acc[3] > s2_acc[0] && s2_acc[3] > s2_acc[1] && s2_acc[3] > s2_acc[2] && s2_acc[3] > s2_acc[4])
                        family_id <= 4;
                    else if (s2_acc[4] > s2_acc[0] && s2_acc[4] > s2_acc[1] && s2_acc[4] > s2_acc[2] && s2_acc[4] > s2_acc[3])
                        family_id <= 5;

                    state <= 4'd9; // Go to family check/branch state
                end

                // One-cycle delay to let family_id NBA settle, then branch
                4'd9: begin
                    // Check if multi-member family (needs Stage 3)
                    if (family_id == 3 || family_id == 5) begin
                        // Single-member family: assign pesticide directly
                        if (family_id == 3)
                            pesticide_id <= 4'd7;  // Chlorothalonil
                        else
                            pesticide_id <= 4'd5;  // Captan
                        state <= S_REPORT;
                    end else begin
                        // Multi-member family: run Stage 3 SVM
                        counter <= 0;
                        s3_acc  <= {{(ACCUM_WIDTH-DATA_WIDTH){s3_bias_rom[family_id-1][DATA_WIDTH-1]}}, s3_bias_rom[family_id-1]};
                        state   <= S_COMPUTE_S3;
                    end
                end

                //----------------------------------------------------------
                // STAGE 3: Binary SVM within multi-member family
                // Features = [s1_features[0:18], s2_features[0:34]]
                // Combined 54 features
                //----------------------------------------------------------
                S_COMPUTE_S3: begin
                    if (counter < N_FEATURES_S3) begin
                        s3_product = $signed(s3_current_weight) * $signed(s3_current_feature);
                        s3_acc  <= s3_acc + (s3_product >>> FRAC_BITS);
                        counter <= counter + 1;
                    end else begin
                        state <= S_CHECK_S3;
                    end
                end

                //----------------------------------------------------------
                // CHECK S3: sign(score) → select pesticide
                // score >= 0 → positive class (ClassNames(2))
                // score <  0 → negative class (ClassNames(1))
                //----------------------------------------------------------
                S_CHECK_S3: begin
                    if (s3_acc >= 0) begin
                        // Positive class: label at index (family_id-1)*2 + 1
                        pesticide_id <= s3_class_labels[(family_id-1)*2 + 1][3:0];
                    end else begin
                        // Negative class: label at index (family_id-1)*2
                        pesticide_id <= s3_class_labels[(family_id-1)*2][3:0];
                    end
                    state <= S_REPORT;
                end

                //----------------------------------------------------------
                // REPORT: Assert done and result_valid
                //----------------------------------------------------------
                S_REPORT: begin
                    result_valid <= 1;
                    done         <= 1;
                    busy         <= 0;
                    if (start) begin
                        // Reset for new classification
                        state        <= S_COMPUTE_S1;
                        busy         <= 1;
                        done         <= 0;
                        result_valid <= 0;
                        contaminated <= 0;
                        family_id    <= 0;
                        pesticide_id <= 0;
                        counter      <= 0;
                        accumulator  <= {{(ACCUM_WIDTH-DATA_WIDTH){s1_bias_rom[0][DATA_WIDTH-1]}}, s1_bias_rom[0]};
                    end
                end

            endcase
        end
    end

endmodule
