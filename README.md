# 🌿 FPGA-Based Pesticide Detection in Soil
### Using Hierarchical SVM & Mid-Infrared (MIR) Spectroscopy

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Hardware](https://img.shields.io/badge/FPGA-Artix--7-orange.svg)](FPGA/)
[![Language](https://img.shields.io/badge/Verilog-2001-green.svg)](FPGA/)
[![Software](https://img.shields.io/badge/MATLAB-Training-red.svg)](MATLAB/)

A state-of-the-art implementation for rapid, on-site pesticide detection in soil. This system uses a three-stage hierarchical SVM pipeline deployed on a Xilinx Artix-7 FPGA (Nexys 4) to classify chemical contamination from Infrared (IR) spectral data with high accuracy and low latency.

---

## 📺 Demo & Visuals

| Stage Classification Results | Hardware Waveform Simulation |
| :---: | :---: |
| ![Results](./Docs/Images/three_stage_detection_results.png) | ![Waveform](./Docs/Images/Simulation%20-%20Waveform%20in%20Vivado.png) |

| FPGA Board Testing | Board Results (7-Segment) |
| :---: | :---: |
| ![Board 1](./Docs/Images/Testing%20Combination%20on%20FPGA%20Board%20-Part%201.png) | ![Board 2](./Docs/Images/Testing%20Combination%20on%20FPGA%20Board%20-Part%202.png) |

---

## 🚀 Key Features

- **Hierarchical Detection Pipeline**: 
  - **Stage 1 (Binary)**: Contaminated vs. Clean Soil (~99% accuracy).
  - **Stage 2 (Family)**: Classification into 5 chemical families (Organophosphate, Carbamate, Chlorinated, Pyrethroid, Other).
  - **Stage 3 (Specific ID)**: Identification of 8 hazardous pesticides (Chlorpyrifos, Carbofuran, Captan, etc.).
- **Resource-Optimized HDL**: Custom Verilog implementation using fixed-point arithmetic (Q5.10/Q16.16) and BRAM for feature/weight storage.
- **Hardware Targets**: Fully compatible with Nexys 4 Artix-7 board; features 7-segment display output for immediate result readout.
- **Chemical-Informed Feature Engineering**: Extraction of spectral bands corresponding to P=O, C=O, C-Cl, and other functional groups.

---

## 📐 Mathematical Foundation

The system implements the Linear SVM decision function:
$$ f(x) = \text{sign}(\sum_{i=1}^{n} w_i x_i + b) $$

Where:
- $w$ is the weight vector (folded with normalization parameters).
- $x$ is the input spectral feature vector.
- $b$ is the bias constant.

For multi-class family identification (Stage 2), an **Error-Correcting Output Codes (ECOC)** framework is used with a One-Vs-All strategy.

---

## 📂 Repository Structure

```
.
├── MATLAB/
│   ├── pesticide_detection_v4_linear_svm.m     # System validation & weight generation
│   ├── ossl_mir_spectra_20.csv                 # Soil spectral dataset
│   └── jdx_files/                              # Pesticide spectral signatures
├── FPGA/
│   ├── HDL/
│   │   ├── top_nexys4.v                        # Top-level board integration
│   │   ├── svm_pesticide_detector.v            # SVM Core Inference Engine
│   │   ├── bram_feature_loader.v               # BRAM memory interface
│   │   └── seven_seg_controller.v              # Board display logic
│   ├── Testbenches/
│   │   └── tb_top_nexys4.v                     # Simulation testbench
│   └── Coefficients/
│       └── *.hex                               # Pre-trained SVM weights & biases
└── Docs/
    ├── Images/                                 # Hardware photos and result logs
    └── Project_Report.pdf                      # Full technical thesis
```

---

## 🛠️ Usage

### 1. Training & Export (MATLAB)
Navigate to `/MATLAB` and run:
`pesticide_detection_v4_linear_svm.m`
This will generate `.hex` files containing fixed-point weights and biases for the FPGA.

### 2. Hardware Implementation (Vivado)
1. Add all files from `FPGA/HDL/` to your Vivado project.
2. Ensure the `.hex` files in `FPGA/Coefficients/` are linked as memory initialization files.
3. Constrain the design for your target board (Nexys 4 XDC included in source references).
4. Generate Bitstream and program the FPGA.

---

## 📊 Performance Metrics

- **Inference Latency**: <1.5ms at 100MHz clock.
- **Accuracy**: Stage 1 (>99%), Stage 2 (>95%), Stage 3 (>85% within family).
- **Resource Usage**:
  - LUTs: Optimized for <20% of Artix-7 resources.
  - DSP48s: Efficient multiplier usage for dot-products.

---

## 📚 Acknowledgments & Research
This project utilizes the **Open Soil Spectroscopy Library (OSSL)** and chemical signatures from **NIST/OpenSource** JDX libraries.

---
*Created by [Arpith] as part of the Final Mini Project.*
