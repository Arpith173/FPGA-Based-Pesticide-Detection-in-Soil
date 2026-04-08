//============================================================================
// Top-Level Module: SVM Pesticide Detector + BRAM Feature Loader
// Target: Nexys 4 DDR (Digilent, Xilinx Artix-7 XC7A100T)
//
// This module integrates:
//   1. Feature BRAM (pre-loaded with 8 test samples)
//   2. BRAM Feature Loader (reads from BRAM → feeds SVM)
//   3. SVM Pesticide Detector (32-bit Q16.16, 3-stage pipeline)
//   4. 7-Segment Display Controller
//   5. Status LEDs
//
// NEXYS 4 DDR I/O MAPPING:
//   Inputs:
//     CLK100MHZ     -> 100 MHz oscillator (E3)
//     BTNC (start)  -> Center button (N17) — run classification
//     BTNU (reset)  -> Up button as active-low reset (M18)
//     SW[2:0]       -> Sample select (0-7: pick which test vector)
//     SW[15:14]     -> Mode select:
//                      00 = BRAM mode (use pre-loaded features)
//                      01 = Demo: All features = +2.0 (CLEAN)
//                      10 = Demo: All features = -2.0 (CONTAMINATED)
//                      11 = Demo: All features = -0.5 (CONTAMINATED)
//
//   Outputs:
//     SEG[7:0]      -> 7-segment cathodes (active-low)
//     AN[7:0]       -> 7-segment anodes (active-low)
//     LED[15:0]     -> Status LEDs
//
// LED MAPPING:
//     LED[0]  -> busy (processing)
//     LED[1]  -> done
//     LED[2]  -> contaminated
//     LED[3]  -> result_valid
//     LED[6:4] -> family_id (binary: 001-101)
//     LED[7]  -> loader active
//     LED[11:8] -> pesticide_id (1-8)
//     LED[14:12] -> sample_select echo
//     LED[15] -> heartbeat (blinks to show FPGA is alive)
//
// OPERATION (BRAM Mode, SW[15:14]=00):
//   1. Set SW[2:0] to select sample 0-7
//   2. Press BTNC → features read from BRAM → SVM processes
//   3. Result appears on 7-segment: pesticide name or "CLEAN"
//   4. Change switches, press BTNC again for another sample
//
// SAMPLE MAPPING (default, can be changed via MATLAB script):
//   Sample 0: Clean soil
//   Sample 1: Chlorpyrifos  (Family 1 - Organophosphate)
//   Sample 2: Bendiocarb    (Family 2 - Carbamate)
//   Sample 3: Acephate      (Family 1 - Organophosphate)
//   Sample 4: Butachlor     (Family 4 - Pyrethroid/Amide)
//   Sample 5: Captan        (Family 5 - Other)
//   Sample 6: Carbofuran    (Family 2 - Carbamate)
//   Sample 7: Chlorothalonil(Family 3 - Chlorinated)
//============================================================================

`timescale 1ns / 1ps

module top_nexys4 (
    input  wire        CLK100MHZ,    // 100 MHz clock
    input  wire        BTNC,         // Center button (start)
    input  wire        BTNU,         // Up button (reset, active-high on Nexys4)
    input  wire [15:0] SW,           // Switches
    
    output wire [7:0]  SEG,          // 7-segment cathodes {DP,G,F,E,D,C,B,A}
    output wire [7:0]  AN,           // 7-segment anodes
    output wire [15:0] LED           // Status LEDs
);

    //------------------------------------------------------------------
    // Internal signals
    //------------------------------------------------------------------
    wire        clk = CLK100MHZ;
    wire        rst_n;               // Active-low reset (derived from BTNU)
    
    // Debounced signals
    wire        start_debounced;
    wire        reset_btn;
    
    // SVM detector signals
    wire        svm_done;
    wire        svm_busy;
    wire        svm_contaminated;
    wire [2:0]  svm_family_id;
    wire [3:0]  svm_pesticide_id;
    wire        svm_result_valid;
    
    // Feature loading signals (muxed between BRAM loader and demo loader)
    reg         feature_valid;
    reg signed [31:0] feature_data;
    reg [5:0]   feature_index;
    reg         feature_stage;
    reg         svm_start;
    
    // BRAM loader signals
    wire        bram_feature_valid;
    wire signed [31:0] bram_feature_data;
    wire [5:0]  bram_feature_index;
    wire        bram_feature_stage;
    wire        bram_svm_start;
    wire        bram_svm_rst_n;     // Loader-controlled SVM reset
    wire [8:0]  bram_addr;
    wire [31:0] bram_rdata;
    wire [3:0]  bram_loader_state;
    
    // SVM effective reset: global AND bram-loader reset (in BRAM mode)
    wire        svm_effective_rst_n = bram_mode ? (rst_n & bram_svm_rst_n) : rst_n;
    
    // Demo loader signals
    reg         demo_feature_valid;
    reg signed [31:0] demo_feature_data;
    reg [5:0]  demo_feature_index;
    reg        demo_feature_stage;
    reg        demo_svm_start;
    
    // Start pulse (edge detect)
    reg         start_prev;
    wire        start_pulse;
    
    // Mode selection
    wire        bram_mode = (SW[15:14] == 2'b00);
    
    //------------------------------------------------------------------
    // Reset: BTNU is active-HIGH on Nexys 4, invert for active-low
    //------------------------------------------------------------------
    assign rst_n = ~BTNU;
    
    //------------------------------------------------------------------
    // Button debouncer for BTNC (start button)
    //------------------------------------------------------------------
    reg [19:0] debounce_cnt;
    reg        btn_stable;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debounce_cnt <= 0;
            btn_stable   <= 0;
        end else begin
            if (BTNC != btn_stable) begin
                debounce_cnt <= debounce_cnt + 1;
                if (debounce_cnt[19]) begin // ~5.2 ms debounce
                    btn_stable   <= BTNC;
                    debounce_cnt <= 0;
                end
            end else begin
                debounce_cnt <= 0;
            end
        end
    end
    
    // Edge detect: generate single-cycle start pulse
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            start_prev <= 0;
        else
            start_prev <= btn_stable;
    end
    assign start_pulse = btn_stable & ~start_prev;
    
    //------------------------------------------------------------------
    // Feature BRAM (pre-loaded with test samples)
    //------------------------------------------------------------------
    feature_bram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(9),
        .MEM_DEPTH(512),
        .INIT_FILE("feature_bram_init.hex")
    ) u_feature_bram (
        // Port A: unused write port (tie off)
        .clk_a(clk),
        .we_a(1'b0),
        .addr_a(9'd0),
        .din_a(32'd0),
        .dout_a(),           // unused
        
        // Port B: read port for loader
        .clk_b(clk),
        .addr_b(bram_addr),
        .dout_b(bram_rdata)
    );
    
    //------------------------------------------------------------------
    // BRAM Feature Loader (active when SW[15:14] == 00)
    //------------------------------------------------------------------
    bram_feature_loader #(
        .N_FEATURES_S1(19),
        .N_FEATURES_S2(35),
        .DATA_WIDTH(32),
        .ADDR_WIDTH(9),
        .SAMPLE_STRIDE(64)
    ) u_bram_loader (
        .clk(clk),
        .rst_n(rst_n),
        
        .start_pulse(bram_mode ? start_pulse : 1'b0),
        .sample_select(SW[2:0]),
        
        .bram_addr(bram_addr),
        .bram_data(bram_rdata),
        
        .svm_start(bram_svm_start),
        .svm_rst_n(bram_svm_rst_n),
        .svm_done(svm_done),
        .svm_contaminated(svm_contaminated),
        .svm_result_valid(svm_result_valid),
        .feature_valid(bram_feature_valid),
        .feature_data(bram_feature_data),
        .feature_index(bram_feature_index),
        .feature_stage(bram_feature_stage),
        
        .loader_state_out(bram_loader_state)
    );
    
    //------------------------------------------------------------------
    // Demo Feature Loader (active when SW[15:14] != 00)
    // Loads uniform feature values for quick testing
    //------------------------------------------------------------------
    localparam N_FEATURES_S1 = 19;
    localparam N_FEATURES_S2 = 35;
    
    // Demo mode state machine
    localparam DM_IDLE      = 3'd0;
    localparam DM_LOAD_S1   = 3'd1;
    localparam DM_START_S1  = 3'd2;
    localparam DM_WAIT_S1   = 3'd3;
    localparam DM_LOAD_S2   = 3'd4;
    localparam DM_START_S2  = 3'd5;
    localparam DM_WAIT_S2   = 3'd6;
    localparam DM_DONE      = 3'd7;
    
    reg [2:0]  dm_state;
    reg [5:0]  dm_counter;
    reg signed [31:0] demo_feature_val;
    
    always @(*) begin
        case (SW[15:14])
            2'b01:   demo_feature_val = 32'h0002_0000;  // +2.0 (CLEAN)
            2'b10:   demo_feature_val = 32'hFFFE_0000;  // -2.0 (CONTAMINATED)
            2'b11:   demo_feature_val = 32'hFFFF_8000;  // -0.5 (CONTAMINATED)
            default: demo_feature_val = 32'h0000_0000;  //  0.0
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dm_state           <= DM_IDLE;
            dm_counter         <= 0;
            demo_svm_start     <= 0;
            demo_feature_valid <= 0;
            demo_feature_data  <= 0;
            demo_feature_index <= 0;
            demo_feature_stage <= 0;
        end else begin
            demo_svm_start     <= 0;
            demo_feature_valid <= 0;
            
            case (dm_state)
                DM_IDLE: begin
                    if (start_pulse && !bram_mode) begin
                        dm_state   <= DM_LOAD_S1;
                        dm_counter <= 0;
                    end
                end
                
                DM_LOAD_S1: begin
                    if (dm_counter < N_FEATURES_S1) begin
                        demo_feature_valid <= 1;
                        demo_feature_data  <= demo_feature_val;
                        demo_feature_index <= dm_counter;
                        demo_feature_stage <= 0;
                        dm_counter         <= dm_counter + 1;
                    end else begin
                        dm_state <= DM_START_S1;
                    end
                end
                
                DM_START_S1: begin
                    demo_svm_start <= 1;
                    dm_state       <= DM_WAIT_S1;
                end
                
                DM_WAIT_S1: begin
                    if (svm_done) begin
                        if (svm_contaminated) begin
                            dm_state   <= DM_LOAD_S2;
                            dm_counter <= 0;
                        end else begin
                            dm_state <= DM_DONE;
                        end
                    end
                end
                
                DM_LOAD_S2: begin
                    if (dm_counter < N_FEATURES_S2) begin
                        demo_feature_valid <= 1;
                        demo_feature_data  <= demo_feature_val;
                        demo_feature_index <= dm_counter;
                        demo_feature_stage <= 1;
                        dm_counter         <= dm_counter + 1;
                    end else begin
                        dm_state <= DM_START_S2;
                    end
                end
                
                DM_START_S2: begin
                    demo_svm_start <= 1;
                    dm_state       <= DM_WAIT_S2;
                end
                
                DM_WAIT_S2: begin
                    if (svm_result_valid)
                        dm_state <= DM_DONE;
                end
                
                DM_DONE: begin
                    if (start_pulse)
                        dm_state <= DM_IDLE;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------
    // Feature/Start MUX: select between BRAM loader and Demo loader
    //------------------------------------------------------------------
    always @(*) begin
        if (bram_mode) begin
            feature_valid = bram_feature_valid;
            feature_data  = bram_feature_data;
            feature_index = bram_feature_index;
            feature_stage = bram_feature_stage;
            svm_start     = bram_svm_start;
        end else begin
            feature_valid = demo_feature_valid;
            feature_data  = demo_feature_data;
            feature_index = demo_feature_index;
            feature_stage = demo_feature_stage;
            svm_start     = demo_svm_start;
        end
    end
    
    //------------------------------------------------------------------
    // SVM Pesticide Detector
    //------------------------------------------------------------------
    svm_pesticide_detector #(
        .N_FEATURES_S1(19),
        .N_FEATURES_S2(35),
        .N_FEATURES_S3(54),
        .N_FAMILIES(5),
        .DATA_WIDTH(32),
        .FRAC_BITS(16),
        .ACCUM_WIDTH(64)
    ) u_svm (
        .clk(clk),
        .rst_n(svm_effective_rst_n),
        .start(svm_start),
        .done(svm_done),
        .busy(svm_busy),
        .feature_valid(feature_valid),
        .feature_data(feature_data),
        .feature_index(feature_index),
        .feature_stage(feature_stage),
        .contaminated(svm_contaminated),
        .family_id(svm_family_id),
        .pesticide_id(svm_pesticide_id),
        .result_valid(svm_result_valid)
    );
    
    //------------------------------------------------------------------
    // 7-Segment Display Controller
    //------------------------------------------------------------------
    seven_seg_controller u_display (
        .clk(clk),
        .rst_n(rst_n),
        .result_valid(svm_result_valid),
        .busy(svm_busy),
        .contaminated(svm_contaminated),
        .family_id(svm_family_id),
        .pesticide_id(svm_pesticide_id),
        .done(svm_done),
        .seg(SEG),
        .an(AN)
    );
    
    //------------------------------------------------------------------
    // Heartbeat LED (blinks ~1 Hz)
    //------------------------------------------------------------------
    reg [26:0] heartbeat_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= 0;
        else
            heartbeat_cnt <= heartbeat_cnt + 1;
    end
    
    //------------------------------------------------------------------
    // LED assignments
    //------------------------------------------------------------------
    assign LED[0]     = svm_busy;
    assign LED[1]     = svm_done;
    assign LED[2]     = svm_contaminated;
    assign LED[3]     = svm_result_valid;
    assign LED[6:4]   = svm_family_id;
    assign LED[7]     = (bram_mode && bram_loader_state != 4'd0)  // BRAM loader active
                      | (!bram_mode && dm_state != DM_IDLE);       // Demo loader active
    assign LED[11:8]  = svm_pesticide_id;
    assign LED[14:12] = SW[2:0];          // Echo sample selection
    assign LED[15]    = heartbeat_cnt[26]; // Heartbeat ~0.75 Hz

endmodule
