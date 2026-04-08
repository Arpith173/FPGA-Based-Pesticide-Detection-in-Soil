//============================================================================
// Testbench for top_nexys4 — Full System Simulation
// Tests all 8 BRAM samples + 3 Demo modes
//
// IMPORTANT: The Nexys4 has a ~5.2ms debounce on BTNC (bit[19] of counter).
// To speed up simulation, we hold BTNC HIGH for enough cycles for the
// debounce to trigger, then release. Each button press simulates ~5.3ms.
//
// Expected results (from sample mapping):
//   Sample 0: Clean soil            → CLEAN (contaminated=0)
//   Sample 1: Chlorpyrifos          → Family 1, Pesticide 1
//   Sample 2: Bendiocarb            → Family 2, Pesticide 2
//   Sample 3: Acephate              → Family 1, Pesticide 3
//   Sample 4: Butachlor             → Family 4, Pesticide 4
//   Sample 5: Captan                → Family 5, Pesticide 5
//   Sample 6: Carbofuran            → Family 2, Pesticide 6
//   Sample 7: Chlorothalonil        → Family 3, Pesticide 7
//
//   Demo 01 (+2.0)  → CLEAN
//   Demo 10 (-2.0)  → CONTAMINATED
//   Demo 11 (-0.5)  → CONTAMINATED
//============================================================================

`timescale 1ns / 1ps

module tb_top_nexys4;

    //------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------
    reg         CLK100MHZ;
    reg         BTNC;
    reg         BTNU;
    reg  [15:0] SW;
    wire [7:0]  SEG;
    wire [7:0]  AN;
    wire [15:0] LED;

    //------------------------------------------------------------------
    // Instantiate DUT
    //------------------------------------------------------------------
    top_nexys4 uut (
        .CLK100MHZ(CLK100MHZ),
        .BTNC(BTNC),
        .BTNU(BTNU),
        .SW(SW),
        .SEG(SEG),
        .AN(AN),
        .LED(LED)
    );

    //------------------------------------------------------------------
    // Clock generation: 100 MHz → 10 ns period
    //------------------------------------------------------------------
    initial CLK100MHZ = 0;
    always #5 CLK100MHZ = ~CLK100MHZ;

    //------------------------------------------------------------------
    // Convenience aliases from LEDs
    //------------------------------------------------------------------
    wire        led_busy         = LED[0];
    wire        led_done         = LED[1];
    wire        led_contaminated = LED[2];
    wire        led_result_valid = LED[3];
    wire [2:0]  led_family_id    = LED[6:4];
    wire        led_loader_active= LED[7];
    wire [3:0]  led_pesticide_id = LED[11:8];
    wire [2:0]  led_sample_echo  = LED[14:12];
    wire        led_heartbeat    = LED[15];

    //------------------------------------------------------------------
    // Pesticide name lookup (for display)
    //------------------------------------------------------------------
    function [8*20-1:0] pesticide_name;
        input [3:0] pid;
        begin
            case (pid)
                4'd0:  pesticide_name = "CLEAN";
                4'd1:  pesticide_name = "Chlorpyrifos";
                4'd2:  pesticide_name = "Bendiocarb";
                4'd3:  pesticide_name = "Acephate";
                4'd4:  pesticide_name = "Butachlor";
                4'd5:  pesticide_name = "Captan";
                4'd6:  pesticide_name = "Carbofuran";
                4'd7:  pesticide_name = "Chlorothalonil";
                4'd8:  pesticide_name = "Permethrin";
                default: pesticide_name = "UNKNOWN";
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Task: press the start button (with debounce time)
    // Debounce counter bit[19] needs 2^19+1 = 524289 clocks when
    // BTNC differs from btn_stable. At 10ns/clock = ~5.243ms
    //------------------------------------------------------------------
    task press_start;
        begin
            BTNC = 1;
            #5_250_000;   // 5.25 ms — enough for debounce bit[19]
            BTNC = 0;
            #200;         // Let the edge detect catch the rising edge of btn_stable
        end
    endtask

    //------------------------------------------------------------------
    // Task: wait for result_valid (LED[3]) or timeout
    //------------------------------------------------------------------
    task wait_for_result;
        input integer timeout_ns;
        integer elapsed;
        begin
            elapsed = 0;
            while (!led_result_valid && !led_done && elapsed < timeout_ns) begin
                @(posedge CLK100MHZ);
                elapsed = elapsed + 10;
            end
            // If only done is high (CLEAN result from S1), it signals clean
            // If result_valid is high, full result is ready
            // For BRAM mode: the loader handles multi-stage automatically
            // Give extra time for loader to finish full pipeline
            if (led_done && !led_result_valid && led_contaminated) begin
                // Stage 1 done, contaminated → loader will continue to S2/S3
                elapsed = 0;
                while (!led_result_valid && elapsed < timeout_ns) begin
                    @(posedge CLK100MHZ);
                    elapsed = elapsed + 10;
                end
            end
            
            if (!led_result_valid && !led_done)
                $display("  *** TIMEOUT waiting for result! ***");
        end
    endtask

    //------------------------------------------------------------------
    // Task: run a BRAM-mode test on a given sample
    //------------------------------------------------------------------
    task run_bram_sample;
        input [2:0] sample;
        begin
            SW = {2'b00, 13'd0, sample};
            #100;

            $display("------------------------------------------------------------");
            $display("BRAM Sample %0d: Starting classification...", sample);
            $display("  Start Time = %0t ns", $time);

            press_start;

            // Wait for the BRAM loader to complete the full pipeline
            wait_for_result(10_000_000);  // 10 ms timeout

            // Extra settling time
            #1000;

            $display("  End Time   = %0t ns", $time);
            $display("  LED[15:0]  = %016b", LED);
            $display("  Busy       = %b", led_busy);
            $display("  Done       = %b", led_done);
            $display("  Contaminated = %b", led_contaminated);
            $display("  Result Valid = %b", led_result_valid);
            $display("  Family ID    = %0d", led_family_id);
            $display("  Pesticide ID = %0d", led_pesticide_id);
            if (led_contaminated && led_result_valid)
                $display("  >>> CONTAMINATED: %0s (Family %0d, Pesticide %0d)",
                         pesticide_name(led_pesticide_id), led_family_id, led_pesticide_id);
            else if (led_done && !led_contaminated)
                $display("  >>> CLEAN");
            else
                $display("  >>> RESULT INCOMPLETE");
            $display("");

            // Reset between samples
            BTNU = 1; #1000;
            BTNU = 0; #1000;
        end
    endtask

    //------------------------------------------------------------------
    // Task: run a Demo-mode test
    //------------------------------------------------------------------
    task run_demo_mode;
        input [1:0] mode;
        reg [31:0] feature_val;
        begin
            case (mode)
                2'b01:   feature_val = 32'h0002_0000;  // +2.0
                2'b10:   feature_val = 32'hFFFE_0000;  // -2.0
                2'b11:   feature_val = 32'hFFFF_8000;  // -0.5
                default: feature_val = 32'h0000_0000;
            endcase

            SW = {mode, 14'd0};
            #100;

            $display("------------------------------------------------------------");
            $display("DEMO Mode %02b: All features = 0x%08h", mode, feature_val);
            $display("  Start Time = %0t ns", $time);

            press_start;

            // Wait for result
            wait_for_result(20_000_000);  // 20 ms timeout
            #1000;

            $display("  End Time   = %0t ns", $time);
            $display("  LED[15:0]  = %016b", LED);
            $display("  Busy       = %b", led_busy);
            $display("  Done       = %b", led_done);
            $display("  Contaminated = %b", led_contaminated);
            $display("  Result Valid = %b", led_result_valid);
            $display("  Family ID    = %0d", led_family_id);
            $display("  Pesticide ID = %0d", led_pesticide_id);
            if (led_contaminated && led_result_valid)
                $display("  >>> CONTAMINATED: %0s (Family %0d, Pesticide %0d)",
                         pesticide_name(led_pesticide_id), led_family_id, led_pesticide_id);
            else if ((led_done || led_result_valid) && !led_contaminated)
                $display("  >>> CLEAN");
            else
                $display("  >>> RESULT INCOMPLETE");
            $display("");

            // Reset between tests
            BTNU = 1; #1000;
            BTNU = 0; #1000;
        end
    endtask

    //------------------------------------------------------------------
    // VCD dump for waveform viewing
    //------------------------------------------------------------------
    initial begin
        $dumpfile("top_nexys4_sim.vcd");
        $dumpvars(0, tb_top_nexys4);
    end

    //------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------
    integer test_num;
    initial begin
        // Initialize
        CLK100MHZ = 0;
        BTNC = 0;
        BTNU = 0;
        SW   = 16'd0;

        $display("");
        $display("============================================================");
        $display("  SVM Pesticide Detector - Full System Simulation");
        $display("  Target: Nexys 4 DDR (Artix-7 XC7A100T)");
        $display("  Format: Q16.16 fixed-point, 3-stage SVM pipeline");
        $display("============================================================");
        $display("");

        // Global reset
        BTNU = 1;
        #1000;
        BTNU = 0;
        #1000;

        // ============ Phase 1: BRAM Mode Tests ============
        $display("============================================================");
        $display("=== Phase 1: BRAM Mode Tests (SW[15:14] = 00) ===");
        $display("  Pre-loaded test samples from feature_bram_init.hex");
        $display("============================================================");
        $display("");

        // Test all 8 BRAM samples
        for (test_num = 0; test_num < 8; test_num = test_num + 1) begin
            run_bram_sample(test_num[2:0]);
        end

        // ============ Phase 2: Demo Mode Tests ============
        $display("============================================================");
        $display("=== Phase 2: Demo Mode Tests ===");
        $display("  Uniform feature values for quick validation");
        $display("============================================================");
        $display("");

        run_demo_mode(2'b01);   // +2.0 → should be CLEAN
        run_demo_mode(2'b10);   // -2.0 → should be CONTAMINATED
        run_demo_mode(2'b11);   // -0.5 → should be CONTAMINATED

        // ============ Summary ============
        $display("============================================================");
        $display("  Simulation Complete!");
        $display("  Total simulated time: %0t ns", $time);
        $display("============================================================");

        #1000;
        $finish;
    end

    //------------------------------------------------------------------
    // Simulation timeout safety
    //------------------------------------------------------------------
    initial begin
        #500_000_000;  // 500 ms absolute timeout
        $display("!!! SIMULATION TIMEOUT — aborting after 500 ms !!!");
        $finish;
    end

endmodule
