# 🧺 Pesticide Detection Project: GitHub-Ready Implementation

I have thoroughly reviewed all your data and files across the `v1` to `v4` workspaces and the root project directory. I have consolidated the most updated and high-performance components into a single, orderly structure located at:
`c:\Arpith\Final Mini Project\Mini Project\Mini Project\v4\GitHub_Pesticide_Detection\`

## 📂 Project Organization

The project is now divided into three logically separated modules for easier navigation on GitHub:

### 1. 🧮 MATLAB Implementation
Located in `/MATLAB`, this contains the heart of the research and model training.
- **`pesticide_detection_v4_linear_svm.m`**: The main script that performs feature extraction, trains the 3-stage SVM, and exports hardware-compatible `.hex` weights.
- **`ossl_mir_spectra_20.csv`**: The dataset for soil baseline spectra.
- **`/jdx_files`**: High-fidelity spectral signatures for specific pesticides.

### 2. ⚡ FPGA Hardware (Verilog)
Located in `/FPGA`, this contains the synthesizable hardware core.
- **`/HDL`**: The core logic modules:
  - `top_nexys4.v`: Board integration (Clocking, 7-Segment mapping, BRAM interfacing).
  - `svm_pesticide_detector.v`: The hierarchical SVM inference engine handling Stage 1 & 2.
  - `seven_seg_controller.v`: Logic to display detection results directly on the board.
- **`/Coefficients`**: Weight and Bias hex files exported from MATLAB. These are used to initialize BRAM on the FPGA.
- **`/Testbenches`**: Hardware simulation files to verify logic timing and accuracy.

### 3. 📝 Documentation & Results
Located in `/Docs`, containing the visual and technical evidence of system performance.
- **`README.md`**: A premium, formatted guide explaining the project's tech stack, math, and usage.
- **`/Images`**: Detailed results including:
  - Accuracy confusion matrices.
  - Hardware waveforms (Vivado).
  - Photos of the system running on the Nexys 4 board.
  - Mathematical breakdown of the SVM kernels.

---

## 🛠️ How to "Run" and Use

### Stage 1: Software Simulation (MATLAB)
1. Navigate to the `MATLAB/` folder.
2. Run `pesticide_detection_v4_linear_svm.m`.
3. **Observation**: The system will demonstrate ~99% accuracy in Stage 1 and generate detection results for various contamination levels (10% to 40%). It will also refresh the `.hex` files with the latest optimized weights.

### Stage 2: Hardware Verification (Vivado)
1. Import the files from `FPGA/HDL/` and `FPGA/Testbenches/`.
2. Map the `.hex` coefficients to the corresponding RAM initializers.
3. Run the behavioral simulation to see the `contaminated` and `family_id` signals update based on input features.

---

## ✅ Final Audit Status
The project has been audited for:
- [x] **Completeness**: All helper functions and data files are present.
- [x] **Readability**: Code is organized and README is professional.
- [x] **Portability**: All paths are relative within the GitHub folder structure.

> **Note**: This structure is now ready to be initialized as a Git repository and pushed to GitHub for your submission or portfolio.
