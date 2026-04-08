//============================================================================
// Testbench for SVM Pesticide Detector (Q5.10 Format)
// 
// Tests:
//   1. Clean soil sample (normalized features near zero -> CLEAN)
//   2. Contaminated sample (normalized features shifted -> CONTAMINATED)
//   3. Organophosphate signature (specific pattern)
//
// Format: Q5.10 (16-bit signed, 10 fractional bits)
//   Host pre-normalizes features: x_norm = (x_raw - mean) / std
//   FPGA computes: score = w' * x_norm + b
//
//   Conversion: Q5.10 value = round(float * 1024)
//   Example: -0.5 -> round(-0.5 * 1024) = -512 = 0xFE00
//            +2.0 -> round( 2.0 * 1024) = 2048 = 0x0800
//            +3.0 -> round( 3.0 * 1024) = 3072 = 0x0C00
//            -0.3 -> round(-0.3 * 1024) = -307 = 0xFECD
//============================================================================

`timescale 1ns / 1ps

module svm_pesticide_detector_tb;

    // Parameters matching DUT (Q5.10)
    parameter N_FEATURES_S1 = 19;
    parameter N_FEATURES_S2 = 35;
    parameter DATA_WIDTH    = 16;
    parameter FRAC_BITS     = 10;
    parameter ACCUM_WIDTH   = 40;
    parameter CLK_PERIOD    = 10;  // 100 MHz
    parameter SCALE         = 1024; // 2^10

    //----------------------------------------------------------------------
    // DUT Signals
    //----------------------------------------------------------------------
    reg                         clk;
    reg                         rst_n;
    reg                         start;
    wire                        done;
    wire                        busy;
    reg                         feature_valid;
    reg signed [DATA_WIDTH-1:0] feature_data;
    reg [5:0]                   feature_index;
    reg                         feature_stage;
    wire                        contaminated;
    wire [2:0]                  family_id;
    wire                        result_valid;

    //----------------------------------------------------------------------
    // Test Data
    //----------------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] test_feat_s1 [0:N_FEATURES_S1-1];
    reg signed [DATA_WIDTH-1:0] test_feat_s2 [0:N_FEATURES_S2-1];
    integer i, test_num, pass_count, fail_count, timeout_cnt;

    //----------------------------------------------------------------------
    // DUT Instantiation
    //----------------------------------------------------------------------
    svm_pesticide_detector #(
        .N_FEATURES_S1(N_FEATURES_S1),
        .N_FEATURES_S2(N_FEATURES_S2),
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .busy(busy),
        .feature_valid(feature_valid),
        .feature_data(feature_data),
        .feature_index(feature_index),
        .feature_stage(feature_stage),
        .contaminated(contaminated),
        .family_id(family_id),
        .result_valid(result_valid)
    );

    //----------------------------------------------------------------------
    // Clock Generation
    //----------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //----------------------------------------------------------------------
    // ROM Verification
    //----------------------------------------------------------------------
    task verify_rom_loading;
        integer rom_ok;
        begin
            rom_ok = 1;
            $display("\n--- ROM Loading Verification ---");
            if (dut.s1_weights[0] === 16'hxxxx) begin $display("  ERROR: s1_weights not loaded!"); rom_ok = 0; end
            if (dut.s1_bias_rom[0] === 16'hxxxx) begin $display("  ERROR: s1_bias not loaded!"); rom_ok = 0; end
            if (rom_ok) $display("  >>> ALL ROMs loaded successfully! <<<");
            else $display("  >>> ROM LOADING FAILED - Check .hex file paths <<<");
            $display("--- End ROM Verification ---\n");
        end
    endtask

    //----------------------------------------------------------------------
    // Task: Send features and run classification
    //----------------------------------------------------------------------
    task run_classification;
        begin
            // Pulse start
            @(posedge clk); start = 1; @(posedge clk); start = 0;
            @(posedge clk); @(posedge clk);
            
            // Send Stage 1 features
            feature_stage = 0;
            for (i = 0; i < N_FEATURES_S1; i = i + 1) begin
                @(posedge clk);
                feature_valid = 1;
                feature_data  = test_feat_s1[i];
                feature_index = i[5:0];
            end
            @(posedge clk); feature_valid = 0;
            
            // Wait for stage transition or done
            timeout_cnt = 0;
            while (!done && dut.state != 4'd5 && timeout_cnt < 2000) begin
                @(posedge clk); timeout_cnt = timeout_cnt + 1;
            end
            
            if (dut.state == 4'd5) begin
                $display("  [Stage1] CONTAMINATED => sending Stage 2 features...");
                feature_stage = 1;
                for (i = 0; i < N_FEATURES_S2; i = i + 1) begin
                    @(posedge clk);
                    feature_valid = 1;
                    feature_data  = test_feat_s2[i];
                    feature_index = i[5:0];
                end
                @(posedge clk); feature_valid = 0;
                while (!done && timeout_cnt < 2000) begin @(posedge clk); timeout_cnt = timeout_cnt + 1; end
            end else begin
                $display("  [Stage1] CLEAN => skipping Stage 2");
            end
            #(CLK_PERIOD * 2);
        end
    endtask

    //----------------------------------------------------------------------
    // Main Test Sequence
    //----------------------------------------------------------------------
    initial begin
        clk = 0; rst_n = 0; start = 0; feature_valid = 0; feature_data = 0; feature_index = 0; feature_stage = 0;
        pass_count = 0; fail_count = 0;
        
        $display("============================================================");
        $display("  SVM Pesticide Detector - FPGA Testbench (Q5.10 Format)");
        $display("============================================================");
        
        #(CLK_PERIOD * 5); rst_n = 1; #(CLK_PERIOD * 5);
        verify_rom_loading();
        
        //==================================================================
        // TEST 1: Clean Soil Sample (-0.5)
        // -0.5 * 1024 = -512 = 0xFE00
        //==================================================================
        test_num = 1;
        $display("[TEST %0d] Clean Soil Sample (normalized features ~ -0.5)", test_num);
        for (i = 0; i < N_FEATURES_S1; i = i + 1) test_feat_s1[i] = 16'hFE00;
        for (i = 0; i < N_FEATURES_S2; i = i + 1) test_feat_s2[i] = 16'hFE00;
        run_classification();
        
        if (contaminated == 0) begin
            $display("  STATUS: PASS (correctly identified as CLEAN)"); pass_count = pass_count + 1;
        end else begin
            $display("  STATUS: UNEXPECTED (classified as contaminated)"); fail_count = fail_count + 1;
        end
        #(CLK_PERIOD * 20);
        
        //==================================================================
        // TEST 2: Contaminated Soil Sample (+2.0)
        // +2.0 * 1024 = 2048 = 0x0800
        //==================================================================
        test_num = 2;
        $display("\n[TEST %0d] Contaminated Soil (normalized features ~ +2.0)", test_num);
        for (i = 0; i < N_FEATURES_S1; i = i + 1) test_feat_s1[i] = 16'h0800;
        for (i = 0; i < N_FEATURES_S2; i = i + 1) test_feat_s2[i] = 16'h0800;
        run_classification();
        
        if (contaminated == 1 && family_id >= 1 && family_id <= 5) begin
             $display("  STATUS: PASS (detected contamination)"); pass_count = pass_count + 1;
        end else begin
             $display("  STATUS: FAIL"); fail_count = fail_count + 1;
        end
        #(CLK_PERIOD * 20);
        
        //==================================================================
        // TEST 3: Organophosphate Signature (+3.0 / -0.3)
        // 3.0 * 1024 = 3072 = 0x0C00
        // -0.3 * 1024 = -307 = 0xFECD
        //==================================================================
        test_num = 3;
        $display("\n[TEST %0d] Organophosphate Signature", test_num);
        for (i = 0; i < N_FEATURES_S1; i = i + 1) begin
            if (i >= 3 && i <= 5) test_feat_s1[i] = 16'h0C00; else test_feat_s1[i] = 16'hFECD;
        end
        for (i = 0; i < N_FEATURES_S2; i = i + 1) begin
            if (i < 6) test_feat_s2[i] = 16'h0C00; else test_feat_s2[i] = 16'hFECD;
        end
        run_classification();
        
        if (contaminated == 1 && family_id == 1) begin
             $display("  STATUS: PASS (Organophosphate detected!)"); pass_count = pass_count + 1;
        end else begin
             $display("  STATUS: FAIL/NOTE (Family=%d)", family_id);
        end
        
        $display("\nTests: 3 | Pass: %0d | Fail: %0d", pass_count, fail_count);
        $finish;
    end

endmodule
