//============================================================================
// Seven-Segment Display Controller for Nexys 4 DDR (Artix-7)
//
// Displays SVM pesticide detection result on 8 seven-segment displays.
//
// DISPLAY MAPPING:
//   Clean:                "  CLEAn "
//   Processing:           "--------"
//   Load S2:              "LOAd S2 "
//
//   Pesticide 1 (Chlorpyrifos):   "CHLrPFOS"
//   Pesticide 2 (Bendiocarb):     "bndIOCrb"
//   Pesticide 3 (Acephate):       "ACEPHAtE"
//   Pesticide 4 (Butachlor):      "bUtACHLr"
//   Pesticide 5 (Captan):         "CAPtAn  "
//   Pesticide 6 (Carbofuran):     "CrbFUrAn"
//   Pesticide 7 (Chlorothalonil): "CHLrtHnL"
//   Pesticide 8 (Permethrin):     "PErEtHrn"
//
// Nexys 4 DDR 7-Segment:
//   Anodes:   AN[7:0] active-low
//   Cathodes: {DP,CG,CF,CE,CD,CC,CB,CA} active-low
//
//       AAA
//      F   B
//       GGG
//      E   C
//       DDD  (DP)
//============================================================================

`timescale 1ns / 1ps

module seven_seg_controller (
    input  wire        clk,
    input  wire        rst_n,
    
    // SVM detector interface
    input  wire        result_valid,
    input  wire        busy,
    input  wire        contaminated,
    input  wire [2:0]  family_id,
    input  wire [3:0]  pesticide_id,     // NEW: specific pesticide 1-8
    input  wire        done,
    
    // 7-segment outputs (active-low)
    output reg  [7:0]  seg,
    output reg  [7:0]  an
);

    //------------------------------------------------------------------
    // Character encoding (active-low)
    // {DP, G, F, E, D, C, B, A}
    //------------------------------------------------------------------
    localparam [7:0] CH_BLANK = 8'b1111_1111;
    localparam [7:0] CH_DASH  = 8'b1011_1111;
    
    // Letters
    localparam [7:0] CH_A = 8'b1000_1000;  // A
    localparam [7:0] CH_b = 8'b1000_0011;  // b
    localparam [7:0] CH_C = 8'b1100_0110;  // C
    localparam [7:0] CH_d = 8'b1010_0001;  // d
    localparam [7:0] CH_E = 8'b1000_0110;  // E
    localparam [7:0] CH_F = 8'b1000_1110;  // F
    localparam [7:0] CH_G = 8'b1100_0010;  // G
    localparam [7:0] CH_H = 8'b1000_1001;  // H
    localparam [7:0] CH_I = 8'b1111_1001;  // I
    localparam [7:0] CH_J = 8'b1110_0001;  // J
    localparam [7:0] CH_L = 8'b1100_0111;  // L
    localparam [7:0] CH_n = 8'b1010_1011;  // n
    localparam [7:0] CH_O = 8'b1100_0000;  // O
    localparam [7:0] CH_P = 8'b1000_1100;  // P
    localparam [7:0] CH_r = 8'b1010_1111;  // r
    localparam [7:0] CH_S = 8'b1001_0010;  // S
    localparam [7:0] CH_t = 8'b1000_0111;  // t
    localparam [7:0] CH_U = 8'b1100_0001;  // U
    localparam [7:0] CH_Y = 8'b1001_0001;  // Y
    
    // Numbers
    localparam [7:0] CH_0 = 8'b1100_0000;
    localparam [7:0] CH_1 = 8'b1111_1001;
    localparam [7:0] CH_2 = 8'b1010_0100;
    localparam [7:0] CH_3 = 8'b1011_0000;
    localparam [7:0] CH_4 = 8'b1001_1001;
    localparam [7:0] CH_5 = 8'b1001_0010;

    //------------------------------------------------------------------
    // Message storage (8 characters for display)
    //------------------------------------------------------------------
    reg [7:0] msg [0:7];
    
    //------------------------------------------------------------------
    // Display refresh counter
    //------------------------------------------------------------------
    reg [19:0] refresh_counter;
    wire [2:0] digit_select;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            refresh_counter <= 0;
        else
            refresh_counter <= refresh_counter + 1;
    end
    
    assign digit_select = refresh_counter[15:13];
    
    //------------------------------------------------------------------
    // Message selection based on SVM output
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msg[0] <= CH_BLANK; msg[1] <= CH_BLANK;
            msg[2] <= CH_BLANK; msg[3] <= CH_BLANK;
            msg[4] <= CH_BLANK; msg[5] <= CH_BLANK;
            msg[6] <= CH_BLANK; msg[7] <= CH_BLANK;
        end else if (busy) begin
            // Processing: "--------"
            msg[0] <= CH_DASH; msg[1] <= CH_DASH;
            msg[2] <= CH_DASH; msg[3] <= CH_DASH;
            msg[4] <= CH_DASH; msg[5] <= CH_DASH;
            msg[6] <= CH_DASH; msg[7] <= CH_DASH;
        end else if (done && !contaminated) begin
            // CLEAN: "  CLEAn "
            msg[0] <= CH_BLANK; msg[1] <= CH_BLANK;
            msg[2] <= CH_C;     msg[3] <= CH_L;
            msg[4] <= CH_E;     msg[5] <= CH_A;
            msg[6] <= CH_n;     msg[7] <= CH_BLANK;
        end else if (result_valid && contaminated) begin
            // Show specific pesticide name based on pesticide_id
            case (pesticide_id)
                4'd1: begin
                    // Chlorpyrifos: "CHLrPFOS"
                    msg[0] <= CH_C; msg[1] <= CH_H;
                    msg[2] <= CH_L; msg[3] <= CH_r;
                    msg[4] <= CH_P; msg[5] <= CH_F;
                    msg[6] <= CH_O; msg[7] <= CH_S;
                end
                4'd2: begin
                    // Bendiocarb: "bndIOCrb"
                    msg[0] <= CH_b; msg[1] <= CH_n;
                    msg[2] <= CH_d; msg[3] <= CH_I;
                    msg[4] <= CH_O; msg[5] <= CH_C;
                    msg[6] <= CH_r; msg[7] <= CH_b;
                end
                4'd3: begin
                    // Acephate: "ACEPHAtE"
                    msg[0] <= CH_A; msg[1] <= CH_C;
                    msg[2] <= CH_E; msg[3] <= CH_P;
                    msg[4] <= CH_H; msg[5] <= CH_A;
                    msg[6] <= CH_t; msg[7] <= CH_E;
                end
                4'd4: begin
                    // Butachlor: "bUtACHLr"
                    msg[0] <= CH_b; msg[1] <= CH_U;
                    msg[2] <= CH_t; msg[3] <= CH_A;
                    msg[4] <= CH_C; msg[5] <= CH_H;
                    msg[6] <= CH_L; msg[7] <= CH_r;
                end
                4'd5: begin
                    // Captan: "CAPtAn  "
                    msg[0] <= CH_C; msg[1] <= CH_A;
                    msg[2] <= CH_P; msg[3] <= CH_t;
                    msg[4] <= CH_A; msg[5] <= CH_n;
                    msg[6] <= CH_BLANK; msg[7] <= CH_BLANK;
                end
                4'd6: begin
                    // Carbofuran: "CrbFUrAn"
                    msg[0] <= CH_C; msg[1] <= CH_r;
                    msg[2] <= CH_b; msg[3] <= CH_F;
                    msg[4] <= CH_U; msg[5] <= CH_r;
                    msg[6] <= CH_A; msg[7] <= CH_n;
                end
                4'd7: begin
                    // Chlorothalonil: "CHLrtHnL"
                    msg[0] <= CH_C; msg[1] <= CH_H;
                    msg[2] <= CH_L; msg[3] <= CH_r;
                    msg[4] <= CH_t; msg[5] <= CH_H;
                    msg[6] <= CH_n; msg[7] <= CH_L;
                end
                4'd8: begin
                    // Permethrin: "PErEtHrn"
                    msg[0] <= CH_P; msg[1] <= CH_E;
                    msg[2] <= CH_r; msg[3] <= CH_E;
                    msg[4] <= CH_t; msg[5] <= CH_H;
                    msg[6] <= CH_r; msg[7] <= CH_n;
                end
                default: begin
                    // Unknown: "Err   P?"
                    msg[0] <= CH_E; msg[1] <= CH_r;
                    msg[2] <= CH_r; msg[3] <= CH_BLANK;
                    msg[4] <= CH_BLANK; msg[5] <= CH_BLANK;
                    msg[6] <= CH_P; msg[7] <= CH_0;
                end
            endcase
        end else if (done && contaminated && !result_valid) begin
            // S1 done, need S2: "LOAd S2 "
            msg[0] <= CH_L; msg[1] <= CH_O;
            msg[2] <= CH_A; msg[3] <= CH_d;
            msg[4] <= CH_BLANK; msg[5] <= CH_S;
            msg[6] <= CH_2; msg[7] <= CH_BLANK;
        end
    end
    
    //------------------------------------------------------------------
    // Anode driver (active-low)
    //------------------------------------------------------------------
    always @(*) begin
        an = 8'b1111_1111;
        an[digit_select] = 1'b0;
    end
    
    //------------------------------------------------------------------
    // Cathode driver
    //------------------------------------------------------------------
    always @(*) begin
        seg = msg[digit_select];
    end

endmodule
