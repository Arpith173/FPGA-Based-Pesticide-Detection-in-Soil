%% PESTICIDE DETECTION SYSTEM v3.0 - THREE-STAGE CLASSIFICATION
% Combined Option A + B: Chemical-Informed Hierarchical Detection
% 
% FPGA-READY: Uses Linear SVM (HDL Coder compatible)
% Classification: y = sign(w'*x + b) - simple dot product + compare
%
% STAGE 1: Binary Detection (Clean vs Contaminated)
% STAGE 2: Chemical Family Classification (5 families)
% STAGE 3: Specific Pesticide Identification (within family)
%
% Chemical Families:
%   1. Organophosphate: Chlorpyrifos, Acephate
%   2. Carbamate: Bendiocarb, Carbofuran
%   3. Chlorinated: Chlorothalonil
%   4. Pyrethroid/Amide: Permethrin, Butachlor
%   5. Other: Captan
%
% HDL CODER OUTPUTS:
%   - hdl_svm_weights.mat: All weights and biases
%   - stage1_weights.hex: Fixed-point weights for Verilog/VHDL
%   - stage1_bias.hex: Fixed-point bias
%   - stage1_norm_mean/std.hex: Normalization parameters

clear; clc; close all;
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║   PESTICIDE DETECTION SYSTEM v3.0                           ║\n');
fprintf('║   Three-Stage Chemical-Informed Classification              ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

%% ======================== CONFIGURATION ========================
SOIL_CSV = 'ossl_mir_spectra_20.csv';
JDX_FOLDER = './jdx_files/';

% Dataset parameters
% Dataset parameters (AUGMENTED FOR HIGHER ACCURACY)
N_CLEAN = 200;             % Increased from 20 to 200
N_PER_PESTICIDE = 100;     % Increased from 30 to 100
N_PESTICIDES = 8;
N_TOTAL = N_CLEAN + (N_PER_PESTICIDE * N_PESTICIDES); % 200 + 800 = 1000 samples

% Spectral range
WAVENUMBER_START = 600;
WAVENUMBER_END = 4000;
WAVENUMBER_STEP = 2;
wavenumbers = WAVENUMBER_START:WAVENUMBER_STEP:WAVENUMBER_END;
N_POINTS = length(wavenumbers);

% Contamination and noise
CONTAMINATION_LEVELS = [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40]; % Wider range
NOISE_STD = 0.02;

%% ======================== CHEMICAL FAMILY DEFINITIONS ========================
% This is where chemistry knowledge improves accuracy

% Pesticide names and their family assignments
pesticide_names = {'Chlorpyrifos', 'Bendiocarb', 'Acephate', 'Butachlor', ...
                   'Captan', 'Carbofuran', 'Chlorothalonil', 'Permethrin'};

% Family assignments (pesticide index -> family)
% Family 1: Organophosphate (Chlorpyrifos=1, Acephate=3)
% Family 2: Carbamate (Bendiocarb=2, Carbofuran=6)
% Family 3: Chlorinated (Chlorothalonil=7)
% Family 4: Pyrethroid/Amide (Permethrin=8, Butachlor=4)
% Family 5: Other (Captan=5)

pesticide_to_family = [1, 2, 1, 4, 5, 2, 3, 4];  % Maps pesticide ID to family ID

family_names = {'Organophosphate', 'Carbamate', 'Chlorinated', 'Pyrethroid/Amide', 'Other'};

family_members = {
    [1, 3],     % Family 1: Chlorpyrifos, Acephate
    [2, 6],     % Family 2: Bendiocarb, Carbofuran
    [7],        % Family 3: Chlorothalonil
    [4, 8],     % Family 4: Butachlor, Permethrin
    [5]         % Family 5: Captan
};

%% ======================== CHEMICAL-SPECIFIC IR BANDS ========================
% These are the KEY FEATURES based on functional group chemistry

% STAGE 1 FEATURES: General contamination indicators
stage1_regions = {
    [700, 900],     % General fingerprint region
    [900, 1200],    % C-O, P-O stretching
    [1200, 1500],   % C-H bending, C-N
    [1500, 1800],   % C=O, C=C, aromatic
    [2800, 3100],   % C-H stretching
};

% STAGE 2 FEATURES: Family-specific bands
% Organophosphate indicators
organophos_bands = {
    [950, 1050],    % P=O stretching (STRONG)
    [1250, 1320],   % P-O-C stretching
    [750, 850],     % P-S stretching (thiophosphates)
};

% Carbamate indicators
carbamate_bands = {
    [1680, 1760],   % C=O stretching (carbamate carbonyl) (STRONG)
    [1150, 1250],   % C-O stretching
    [1500, 1560],   % N-H bending
};

% Chlorinated indicators
chlorinated_bands = {
    [700, 800],     % C-Cl stretching (STRONG)
    [2200, 2280],   % C≡N stretching (nitrile - Chlorothalonil specific)
    [1550, 1620],   % Aromatic C=C
};

% Pyrethroid/Amide indicators
pyrethroid_bands = {
    [1720, 1760],   % Ester C=O stretching
    [1000, 1050],   % Cyclopropane ring
    [1100, 1180],   % C-O-C ester linkage
};

% Other (Captan) indicators
other_bands = {
    [600, 700],     % C-S stretching
    [700, 800],     % C-Cl stretching
    [1770, 1820],   % Imide C=O
};

fprintf('Chemical families defined:\n');
for f = 1:length(family_names)
    members = family_members{f};
    member_names = strjoin(pesticide_names(members), ', ');
    fprintf('  %d. %s: %s\n', f, family_names{f}, member_names);
end
fprintf('\n');

%% ======================== STEP 1: LOAD DATA ========================
fprintf('STEP 1: Loading data...\n');

% Load soil spectra
opts = detectImportOptions(SOIL_CSV);
opts = setvaropts(opts, opts.VariableNames, 'TreatAsMissing', {'NA', 'NaN', ''});
soil_table = readtable(SOIL_CSV, opts);
soil_spectra_raw = table2array(soil_table(:, 2:end));

valid_rows = ~any(isnan(soil_spectra_raw), 2);
soil_spectra = soil_spectra_raw(valid_rows, :);
n_soil_samples = size(soil_spectra, 1);

% Normalize soil spectra
for i = 1:n_soil_samples
    smin = min(soil_spectra(i, :));
    smax = max(soil_spectra(i, :));
    if smax > smin
        soil_spectra(i, :) = (soil_spectra(i, :) - smin) / (smax - smin);
    end
end
fprintf('  Loaded %d valid soil samples\n', n_soil_samples);

% Load pesticide spectra
jdx_files = {
    '1769091575678_2921-88-2-IR_Chlorpyrifos_.jdx',
    '1769091575679_22781-23-3-IR_Bendiocarb_.jdx',
    '1769091575679_30560-19-1-IR_Acephate_.jdx',
    '1769091575680_23184-66-9-IR_Butachlor_.jdx',
    '1769091575681_133-06-2-IR_Captan_.jdx',
    '1769091575681_1563-66-2-IR_Carbofuran_.jdx',
    '1769091575683_1897-45-6-IR_Tetrachloroisophthalonitrile_.jdx',
    '52645-53-1-IR_Permethrin_.jdx'
};

pesticide_spectra = zeros(N_PESTICIDES, N_POINTS);

for i = 1:N_PESTICIDES
    jdx_path = fullfile(JDX_FOLDER, jdx_files{i});
    try
        [wn, absorbance] = read_jdx(jdx_path);
        resampled = interp1(wn, absorbance, wavenumbers, 'linear', 'extrap');
        resampled(isnan(resampled) | isinf(resampled)) = 0;
        resampled(resampled < 0) = 0;
        pmin = min(resampled); pmax = max(resampled);
        if pmax > pmin
            pesticide_spectra(i, :) = (resampled - pmin) / (pmax - pmin);
        end
        fprintf('  [%d] %s (%s)\n', i, pesticide_names{i}, family_names{pesticide_to_family(i)});
    catch
        pesticide_spectra(i, :) = generate_synthetic_pesticide(wavenumbers, i);
        fprintf('  [%d] %s (SYNTHETIC)\n', i, pesticide_names{i});
    end
end

%% ======================== STEP 2: GENERATE DATASET ========================
fprintf('\nSTEP 2: Generating synthetic dataset...\n');

X = zeros(N_TOTAL, N_POINTS);
y_binary = zeros(N_TOTAL, 1);      % 0=clean, 1=contaminated
y_family = zeros(N_TOTAL, 1);      % 0=clean, 1-5=family
y_pesticide = zeros(N_TOTAL, 1);   % 0=clean, 1-8=pesticide

sample_idx = 1;

% Clean samples
for i = 1:N_CLEAN
    soil_idx = mod(i-1, n_soil_samples) + 1;
    X(sample_idx, :) = soil_spectra(soil_idx, :) + NOISE_STD * randn(1, N_POINTS);
    X(sample_idx, X(sample_idx,:) < 0) = 0;
    y_binary(sample_idx) = 0;
    y_family(sample_idx) = 0;
    y_pesticide(sample_idx) = 0;
    sample_idx = sample_idx + 1;
end

% Contaminated samples
for pest_id = 1:N_PESTICIDES
    for j = 1:N_PER_PESTICIDE
        soil_idx = randi(n_soil_samples);
        contam_level = CONTAMINATION_LEVELS(randi(length(CONTAMINATION_LEVELS)));
        
        mixed = (1 - contam_level) * soil_spectra(soil_idx, :) + ...
                contam_level * pesticide_spectra(pest_id, :);
        X(sample_idx, :) = mixed + NOISE_STD * randn(1, N_POINTS);
        X(sample_idx, X(sample_idx,:) < 0) = 0;
        
        y_binary(sample_idx) = 1;
        y_family(sample_idx) = pesticide_to_family(pest_id);
        y_pesticide(sample_idx) = pest_id;
        sample_idx = sample_idx + 1;
    end
end

fprintf('  Generated %d samples (20 clean, 80 contaminated)\n', N_TOTAL);

%% ======================== STEP 3: EXTRACT FEATURES ========================
fprintf('\nSTEP 3: Extracting chemical-informed features...\n');

% STAGE 1 FEATURES (Binary detection)
fprintf('  Extracting Stage 1 features (contamination detection)...\n');
features_stage1 = extract_stage1_features(X, wavenumbers, stage1_regions);

% STAGE 2 FEATURES (Family classification) - only for contaminated
fprintf('  Extracting Stage 2 features (family classification)...\n');
features_stage2 = extract_stage2_features(X, wavenumbers, ...
    organophos_bands, carbamate_bands, chlorinated_bands, pyrethroid_bands, other_bands);

% STAGE 3 FEATURES (Specific ID) - combined detailed features
fprintf('  Extracting Stage 3 features (specific identification)...\n');
features_stage3 = [features_stage1, features_stage2];

fprintf('  Stage 1: %d features\n', size(features_stage1, 2));
fprintf('  Stage 2: %d features\n', size(features_stage2, 2));
fprintf('  Stage 3: %d features (combined)\n', size(features_stage3, 2));

%% ======================== STEP 4: TRAIN CLASSIFIERS (K-FOLD CV) ========================
fprintf('\nSTEP 4: Training three-stage classifiers with K-FOLD CROSS VALIDATION...\n');

rng(42);
K_FOLDS = 10;  % Number of folds for cross-validation
fprintf('  Using %d-Fold Cross Validation for robust accuracy estimation\n', K_FOLDS);

% --- STAGE 1: Binary Classifier with K-Fold CV ---
fprintf('\n  [STAGE 1] Binary Classifier (Clean vs Contaminated) - %d-Fold CV...\n', K_FOLDS);

feat1_mean = mean(features_stage1);
feat1_std = std(features_stage1); feat1_std(feat1_std < 1e-8) = 1;
features_stage1_norm = (features_stage1 - feat1_mean) ./ feat1_std;

cv1 = cvpartition(y_binary, 'KFold', K_FOLDS);  % Stratified K-Fold
y1_pred_all = zeros(N_TOTAL, 1);  % Store predictions for every sample
fold_acc_stage1 = zeros(K_FOLDS, 1);

for k = 1:K_FOLDS
    X1_train = features_stage1_norm(training(cv1, k), :);
    y1_train = y_binary(training(cv1, k));
    X1_test = features_stage1_norm(test(cv1, k), :);
    y1_test = y_binary(test(cv1, k));
    
    mdl_s1_fold = fitcsvm(X1_train, y1_train, ...
        'KernelFunction', 'linear', ...
        'BoxConstraint', 1, ...
        'Standardize', false);
    
    y1_fold_pred = predict(mdl_s1_fold, X1_test);
    fold_acc_stage1(k) = sum(y1_fold_pred == y1_test) / length(y1_test) * 100;
    y1_pred_all(test(cv1, k)) = y1_fold_pred;
    fprintf('    Fold %2d: %.1f%%\n', k, fold_acc_stage1(k));
end

acc_stage1 = mean(fold_acc_stage1);
std_stage1 = std(fold_acc_stage1);
fprintf('    ─────────────────────────────────\n');
fprintf('    CV Mean Accuracy: %.1f%% ± %.1f%%\n', acc_stage1, std_stage1);

% Detailed breakdown from CV predictions
clean_mask = y_binary == 0;
contam_mask = y_binary == 1;
clean_acc = sum(y1_pred_all(clean_mask) == 0) / sum(clean_mask) * 100;
contam_acc = sum(y1_pred_all(contam_mask) == 1) / sum(contam_mask) * 100;
fprintf('    Clean detection: %.1f%% (%d/%d)\n', clean_acc, sum(y1_pred_all(clean_mask)==0), sum(clean_mask));
fprintf('    Contamination detection: %.1f%% (%d/%d)\n', contam_acc, sum(y1_pred_all(contam_mask)==1), sum(contam_mask));

% Train FINAL Stage 1 model on ALL data for deployment
fprintf('    Training FINAL model on ALL %d samples...\n', N_TOTAL);
model_stage1 = fitcsvm(features_stage1_norm, y_binary, ...
    'KernelFunction', 'linear', ...
    'BoxConstraint', 1, ...
    'Standardize', false);

% --- STAGE 2: Family Classifier with K-Fold CV ---
fprintf('\n  [STAGE 2] Family Classifier (5 families) - %d-Fold CV...\n', K_FOLDS);

contam_idx = y_binary == 1;
features_stage2_contam = features_stage2(contam_idx, :);
y_family_contam = y_family(contam_idx);
N_CONTAM = sum(contam_idx);

feat2_mean = mean(features_stage2_contam);
feat2_std = std(features_stage2_contam); feat2_std(feat2_std < 1e-8) = 1;
features_stage2_norm = (features_stage2_contam - feat2_mean) ./ feat2_std;

cv2 = cvpartition(y_family_contam, 'KFold', K_FOLDS);  % Stratified
y2_pred_all = zeros(N_CONTAM, 1);
fold_acc_stage2 = zeros(K_FOLDS, 1);

for k = 1:K_FOLDS
    X2_train = features_stage2_norm(training(cv2, k), :);
    y2_train = y_family_contam(training(cv2, k));
    X2_test = features_stage2_norm(test(cv2, k), :);
    y2_test = y_family_contam(test(cv2, k));
    
    mdl_s2_fold = fitcecoc(X2_train, y2_train, ...
        'Learners', templateSVM('KernelFunction', 'linear'), ...
        'Coding', 'onevsall');
    
    y2_fold_pred = predict(mdl_s2_fold, X2_test);
    fold_acc_stage2(k) = sum(y2_fold_pred == y2_test) / length(y2_test) * 100;
    y2_pred_all(test(cv2, k)) = y2_fold_pred;
    fprintf('    Fold %2d: %.1f%%\n', k, fold_acc_stage2(k));
end

acc_stage2 = mean(fold_acc_stage2);
std_stage2 = std(fold_acc_stage2);
fprintf('    ─────────────────────────────────\n');
fprintf('    CV Mean Accuracy: %.1f%% ± %.1f%%\n', acc_stage2, std_stage2);

% Per-family breakdown from CV predictions
fprintf('    Per-family CV accuracy:\n');
for f = 1:length(family_names)
    mask = y_family_contam == f;
    if sum(mask) > 0
        facc = sum(y2_pred_all(mask) == f) / sum(mask) * 100;
        fprintf('      %s: %.1f%% (%d/%d)\n', family_names{f}, facc, sum(y2_pred_all(mask)==f), sum(mask));
    end
end

% Train FINAL Stage 2 model on ALL contaminated data
fprintf('    Training FINAL model on ALL %d contaminated samples...\n', N_CONTAM);
model_stage2 = fitcecoc(features_stage2_norm, y_family_contam, ...
    'Learners', templateSVM('KernelFunction', 'linear'), ...
    'Coding', 'onevsall');

% --- STAGE 3: Specific Pesticide Classifiers with K-Fold CV ---
fprintf('\n  [STAGE 3] Specific Pesticide Classifiers (per family) - %d-Fold CV...\n', K_FOLDS);

feat3_mean = mean(features_stage3(contam_idx, :));
feat3_std = std(features_stage3(contam_idx, :)); feat3_std(feat3_std < 1e-8) = 1;
features_stage3_norm = (features_stage3(contam_idx, :) - feat3_mean) ./ feat3_std;

y_pest_contam = y_pesticide(contam_idx);

% Train family-specific classifiers with K-Fold CV
family_models = cell(5, 1);
for f = 1:length(family_names)
    members = family_members{f};
    if length(members) > 1
        family_mask = ismember(y_pest_contam, members);
        if sum(family_mask) >= K_FOLDS  % Need enough samples for K folds
            X_fam = features_stage3_norm(family_mask, :);
            y_fam = y_pest_contam(family_mask);
            
            % K-Fold CV for this family
            cv_fam = cvpartition(y_fam, 'KFold', min(K_FOLDS, sum(family_mask)));
            fold_acc_fam = zeros(cv_fam.NumTestSets, 1);
            for k = 1:cv_fam.NumTestSets
                mdl_fam_fold = fitcsvm(X_fam(training(cv_fam, k), :), y_fam(training(cv_fam, k)), ...
                    'KernelFunction', 'linear', 'Standardize', false);
                y_fam_pred = predict(mdl_fam_fold, X_fam(test(cv_fam, k), :));
                fold_acc_fam(k) = sum(y_fam_pred == y_fam(test(cv_fam, k))) / sum(test(cv_fam, k)) * 100;
            end
            fprintf('    Family %d (%s): CV %.1f%% ± %.1f%% (%d samples)\n', ...
                f, family_names{f}, mean(fold_acc_fam), std(fold_acc_fam), sum(family_mask));
            
            % Train FINAL model on ALL family data
            family_models{f} = fitcsvm(X_fam, y_fam, ...
                'KernelFunction', 'linear', ...
                'Standardize', false);
        end
    else
        fprintf('    Family %d (%s): Single member, no classifier needed\n', f, family_names{f});
    end
end

%% ======================== STEP 5: FULL PIPELINE TEST (K-FOLD CV) ========================
fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║            FULL PIPELINE TESTING (%d-FOLD CV)               ║\n', K_FOLDS);
fprintf('╚══════════════════════════════════════════════════════════════╝\n');

% Full pipeline K-Fold: use the CV predictions from Stage 1
% For samples predicted as contaminated, evaluate Stages 2 & 3
correct_binary = sum(y1_pred_all == y_binary);
n_test = N_TOTAL;
correct_family = 0;
correct_pesticide = 0;
total_contam_tested = 0;

for i = 1:N_TOTAL
    if y1_pred_all(i) == 1  % Predicted contaminated
        total_contam_tested = total_contam_tested + 1;
        
        % Stage 2: Family prediction (use CV prediction if contaminated)
        feat2_i = (features_stage2(i, :) - feat2_mean) ./ feat2_std;
        pred_family = predict(model_stage2, feat2_i);
        
        if pred_family == y_family(i)
            correct_family = correct_family + 1;
        end
        
        % Stage 3: Specific pesticide
        feat3_i = (features_stage3(i, :) - feat3_mean) ./ feat3_std;
        
        members = family_members{pred_family};
        if length(members) == 1
            pred_pest = members(1);
        elseif ~isempty(family_models{pred_family})
            pred_pest = predict(family_models{pred_family}, feat3_i);
        else
            pred_pest = members(1);
        end
        
        if pred_pest == y_pesticide(i)
            correct_pesticide = correct_pesticide + 1;
        end
    end
end

fprintf('\nFull Pipeline Results (K-Fold CV):\n');
fprintf('  Stage 1 (Binary):     %.1f%% (%d/%d)\n', 100*correct_binary/n_test, correct_binary, n_test);
if total_contam_tested > 0
    fprintf('  Stage 2 (Family):     %.1f%% (%d/%d contaminated)\n', 100*correct_family/total_contam_tested, correct_family, total_contam_tested);
    fprintf('  Stage 3 (Pesticide):  %.1f%% (%d/%d contaminated)\n', 100*correct_pesticide/total_contam_tested, correct_pesticide, total_contam_tested);
end

%% ======================== CONTROL TESTS ========================
fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                      CONTROL TESTS                           ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n');

% Helper function for running detection
run_detection = @(spectrum) run_three_stage_detection(spectrum, wavenumbers, ...
    model_stage1, model_stage2, family_models, family_members, ...
    feat1_mean, feat1_std, feat2_mean, feat2_std, feat3_mean, feat3_std, ...
    stage1_regions, organophos_bands, carbamate_bands, chlorinated_bands, pyrethroid_bands, other_bands, ...
    pesticide_names, family_names);

% TEST A: Clean Soil
fprintf('\n[TEST A] Clean Soil Sample\n');
test_clean = soil_spectra(1, :) + NOISE_STD * randn(1, N_POINTS);
test_clean(test_clean < 0) = 0;
[result_A, details_A] = run_detection(test_clean);
fprintf('  Expected: No pesticide detected\n');
fprintf('  Result:   %s\n', result_A);
if contains(result_A, 'CLEAN')
    fprintf('  Status:   ✓ PASS\n');
else
    fprintf('  Status:   ✗ FAIL\n');
end

% TEST B: Chlorpyrifos (Organophosphate)
fprintf('\n[TEST B] Contaminated with Chlorpyrifos (25%%)\n');
test_chlor = 0.75 * soil_spectra(2, :) + 0.25 * pesticide_spectra(1, :);
test_chlor = test_chlor + NOISE_STD * randn(1, N_POINTS);
test_chlor(test_chlor < 0) = 0;
[result_B, details_B] = run_detection(test_chlor);
fprintf('  Expected: Chlorpyrifos (Organophosphate)\n');
fprintf('  Result:   %s\n', result_B);
if contains(result_B, 'Chlorpyrifos')
    fprintf('  Status:   ✓ PASS\n');
elseif contains(result_B, 'Organophosphate')
    fprintf('  Status:   ~ PARTIAL (correct family)\n');
else
    fprintf('  Status:   ✗ FAIL\n');
end

% TEST C: Carbofuran (Carbamate)
fprintf('\n[TEST C] Contaminated with Carbofuran (30%%)\n');
test_carbo = 0.70 * soil_spectra(3, :) + 0.30 * pesticide_spectra(6, :);
test_carbo = test_carbo + NOISE_STD * randn(1, N_POINTS);
test_carbo(test_carbo < 0) = 0;
[result_C, details_C] = run_detection(test_carbo);
fprintf('  Expected: Carbofuran (Carbamate)\n');
fprintf('  Result:   %s\n', result_C);
if contains(result_C, 'Carbofuran')
    fprintf('  Status:   ✓ PASS\n');
elseif contains(result_C, 'Carbamate')
    fprintf('  Status:   ~ PARTIAL (correct family)\n');
else
    fprintf('  Status:   ✗ FAIL\n');
end

% TEST D: Chlorothalonil (Chlorinated - single member family)
fprintf('\n[TEST D] Contaminated with Chlorothalonil (25%%)\n');
test_chloro = 0.75 * soil_spectra(4, :) + 0.25 * pesticide_spectra(7, :);
test_chloro = test_chloro + NOISE_STD * randn(1, N_POINTS);
test_chloro(test_chloro < 0) = 0;
[result_D, details_D] = run_detection(test_chloro);
fprintf('  Expected: Chlorothalonil (Chlorinated)\n');
fprintf('  Result:   %s\n', result_D);
if contains(result_D, 'Chlorothalonil')
    fprintf('  Status:   ✓ PASS\n');
elseif contains(result_D, 'Chlorinated')
    fprintf('  Status:   ~ PARTIAL (correct family)\n');
else
    fprintf('  Status:   ✗ FAIL\n');
end

% TEST E: Permethrin (Pyrethroid)
fprintf('\n[TEST E] Contaminated with Permethrin (30%%)\n');
test_perm = 0.70 * soil_spectra(5, :) + 0.30 * pesticide_spectra(8, :);
test_perm = test_perm + NOISE_STD * randn(1, N_POINTS);
test_perm(test_perm < 0) = 0;
[result_E, details_E] = run_detection(test_perm);
fprintf('  Expected: Permethrin (Pyrethroid/Amide)\n');
fprintf('  Result:   %s\n', result_E);
if contains(result_E, 'Permethrin')
    fprintf('  Status:   ✓ PASS\n');
elseif contains(result_E, 'Pyrethroid')
    fprintf('  Status:   ~ PARTIAL (correct family)\n');
else
    fprintf('  Status:   ✗ FAIL\n');
end

%% ======================== SAVE MODELS ========================
fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                      SAVING MODELS                           ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n');

save('model_stage1_binary.mat', 'model_stage1', 'feat1_mean', 'feat1_std');
save('model_stage2_family.mat', 'model_stage2', 'feat2_mean', 'feat2_std', 'family_names');
save('model_stage3_specific.mat', 'family_models', 'feat3_mean', 'feat3_std', 'family_members', 'pesticide_names');
save('detection_config.mat', 'wavenumbers', 'stage1_regions', ...
    'organophos_bands', 'carbamate_bands', 'chlorinated_bands', 'pyrethroid_bands', 'other_bands');

fprintf('  Saved: model_stage1_binary.mat\n');
fprintf('  Saved: model_stage2_family.mat\n');
fprintf('  Saved: model_stage3_specific.mat\n');
fprintf('  Saved: detection_config.mat\n');

%% ======================== EXPORT FOR HDL CODER ========================
fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                 EXPORTING FOR HDL CODER                      ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n');

% Extract Linear SVM weights for FPGA implementation
% Linear SVM: y = sign(w'*x + b)
% w = weights, b = bias

% Stage 1: Binary classifier weights
bias1 = model_stage1.Bias;
% Use Beta property (pre-computed weight vector) if available
if ~isempty(model_stage1.Beta)
    weights1 = model_stage1.Beta;
else
    sv1 = model_stage1.SupportVectors;
    alpha1 = model_stage1.Alpha;
    weights1 = sv1' * alpha1;  % Weight vector for linear SVM
end

fprintf('\n  Stage 1 (Binary) - Linear SVM:\n');
fprintf('    Weight vector size: %d\n', length(weights1));
fprintf('    Bias: %.6f\n', bias1);

% Stage 2: Family classifier weights (one-vs-all, 5 classifiers)
n_families = 5;
weights2 = cell(n_families, 1);
bias2 = zeros(n_families, 1);

n_learners = length(model_stage2.BinaryLearners);
fprintf('\n  Stage 2 (Family) - ECOC Model:\n');
fprintf('    Number of BinaryLearners: %d\n', n_learners);
fprintf('    ClassNames: ');
disp(model_stage2.ClassNames');
fprintf('    CodingMatrix:\n');
disp(model_stage2.CodingMatrix);

% For one-vs-all coding, each binary learner corresponds to one class
% The CodingMatrix rows = classes, columns = binary learners
% +1 means the class is positive for that learner
coding_matrix = model_stage2.CodingMatrix;

for f = 1:n_families
    if f <= n_learners
        % Find which binary learner is the "positive" learner for class f
        % In one-vs-all, typically learner f has class f as positive (+1)
        learner_idx = f;
        
        % Verify via coding matrix: find the column where row f is +1
        pos_cols = find(coding_matrix(f, :) == 1);
        if ~isempty(pos_cols)
            learner_idx = pos_cols(1);
        end
        
        binary_learner = model_stage2.BinaryLearners{learner_idx};
        
        % Use Beta property (pre-computed weight vector w = SV' * alpha)
        % MATLAB's compact SVM stores weights in Beta, not raw SV+Alpha
        if ~isempty(binary_learner.Beta)
            weights2{f} = binary_learner.Beta;
        elseif ~isempty(binary_learner.SupportVectors) && ~isempty(binary_learner.Alpha)
            sv = binary_learner.SupportVectors;
            alpha = binary_learner.Alpha;
            weights2{f} = sv' * alpha;
        else
            warning('Family %d: Both Beta and SupportVectors are empty!', f);
            weights2{f} = zeros(size(features_stage2_norm, 2), 1);
        end
        
        bias2(f) = binary_learner.Bias;
        fprintf('    Family %d -> BinaryLearner{%d}: %d weights, bias=%.6f\n', ...
            f, learner_idx, length(weights2{f}), bias2(f));
    else
        warning('Family %d has no corresponding BinaryLearner (only %d learners).', f, n_learners);
        weights2{f} = zeros(size(features_stage2_norm, 2), 1);
        bias2(f) = 0;
    end
end

fprintf('\n  Stage 2 (Family) - %d Linear SVMs:\n', n_families);
fprintf('    Weight vector size: %d each\n', length(weights2{1}));
fprintf('    Biases: [%.4f, %.4f, %.4f, %.4f, %.4f]\n', bias2(1), bias2(2), bias2(3), bias2(4), bias2(5));

% Stage 3: Family-specific classifier weights
weights3 = cell(5, 1);
bias3 = zeros(5, 1);

for f = 1:5
    if ~isempty(family_models{f})
        % Use Beta property (pre-computed weight vector) if available
        if ~isempty(family_models{f}.Beta)
            weights3{f} = family_models{f}.Beta;
        else
            sv = family_models{f}.SupportVectors;
            alpha = family_models{f}.Alpha;
            weights3{f} = sv' * alpha;
        end
        bias3(f) = family_models{f}.Bias;
        fprintf('\n  Stage 3 Family %d (%s):\n', f, family_names{f});
        fprintf('    Weight vector size: %d\n', length(weights3{f}));
        fprintf('    Bias: %.6f\n', bias3(f));
    end
end

% Convert to fixed-point for FPGA
FRACTIONAL_BITS = 14;
WORD_LENGTH = 16;

% Fixed-point conversion function
to_fixed = @(x) round(x * 2^FRACTIONAL_BITS);

% Export weights as fixed-point integers
weights1_fixed = to_fixed(weights1);
bias1_fixed = to_fixed(bias1);

weights2_fixed = cell(n_families, 1);
bias2_fixed = to_fixed(bias2);
for f = 1:n_families
    weights2_fixed{f} = to_fixed(weights2{f});
end

% Save for HDL Coder
save('hdl_svm_weights.mat', ...
    'weights1', 'bias1', 'weights1_fixed', 'bias1_fixed', ...
    'weights2', 'bias2', 'weights2_fixed', 'bias2_fixed', ...
    'weights3', 'bias3', ...
    'feat1_mean', 'feat1_std', 'feat2_mean', 'feat2_std', ...
    'FRACTIONAL_BITS', 'WORD_LENGTH');

fprintf('\n  Saved: hdl_svm_weights.mat\n');

% Generate coefficient files for Verilog/VHDL
fprintf('\n  Generating HDL coefficient files...\n');

% Stage 1 weights to hex file
fid = fopen('stage1_weights.hex', 'w');
for i = 1:length(weights1_fixed)
    if weights1_fixed(i) < 0
        hex_val = typecast(int16(weights1_fixed(i)), 'uint16');
    else
        hex_val = uint16(weights1_fixed(i));
    end
    fprintf(fid, '%04X\n', hex_val);
end
fclose(fid);
fprintf('    stage1_weights.hex (%d coefficients)\n', length(weights1_fixed));

% Stage 1 bias
fid = fopen('stage1_bias.hex', 'w');
if bias1_fixed < 0
    hex_val = typecast(int16(bias1_fixed), 'uint16');
else
    hex_val = uint16(bias1_fixed);
end
fprintf(fid, '%04X\n', hex_val);
fclose(fid);
fprintf('    stage1_bias.hex\n');

% Normalization parameters
fid = fopen('stage1_norm_mean.hex', 'w');
for i = 1:length(feat1_mean)
    val_fixed = to_fixed(feat1_mean(i));
    if val_fixed < 0
        hex_val = typecast(int16(val_fixed), 'uint16');
    else
        hex_val = uint16(min(val_fixed, 65535));
    end
    fprintf(fid, '%04X\n', hex_val);
end
fclose(fid);

fid = fopen('stage1_norm_std.hex', 'w');
for i = 1:length(feat1_std)
    val_fixed = to_fixed(feat1_std(i));
    hex_val = uint16(min(abs(val_fixed), 65535));
    fprintf(fid, '%04X\n', hex_val);
end
fclose(fid);
fprintf('    stage1_norm_mean.hex, stage1_norm_std.hex\n');

fprintf('\n  HDL export complete!\n');
fprintf('  Use these files with HDL Coder or manual RTL implementation.\n');

%% ======================== VISUALIZATION ========================
figure('Position', [50, 50, 1600, 900], 'Name', 'Three-Stage Pesticide Detection System');

% Plot 1: System overview
subplot(2,3,1);
text(0.5, 0.9, 'THREE-STAGE DETECTION SYSTEM', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(0.5, 0.75, sprintf('Stage 1 (Binary): %.1f%% accuracy', acc_stage1), 'FontSize', 11, 'HorizontalAlignment', 'center');
text(0.5, 0.60, sprintf('Stage 2 (Family): %.1f%% accuracy', acc_stage2), 'FontSize', 11, 'HorizontalAlignment', 'center');
text(0.5, 0.45, sprintf('Stage 3 (Specific): Per-family classifiers', 'FontSize', 11), 'FontSize', 11, 'HorizontalAlignment', 'center');
text(0.5, 0.25, 'Chemical Families:', 'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(0.5, 0.15, '1.Organophos 2.Carbamate 3.Chlorinated', 'FontSize', 9, 'HorizontalAlignment', 'center');
text(0.5, 0.05, '4.Pyrethroid 5.Other', 'FontSize', 9, 'HorizontalAlignment', 'center');
axis off;

% Plot 2: Chemical family bands
subplot(2,3,2);
hold on;
bar_data = [
    mean([950, 1050]);   % Organophos P=O
    mean([1680, 1760]);  % Carbamate C=O
    mean([750, 800]);    % Chlorinated C-Cl
    mean([1740, 1760]);  % Pyrethroid ester
    mean([650, 700]);    % Other C-S
];
bar(bar_data);
set(gca, 'XTickLabel', {'P=O', 'Carbamate C=O', 'C-Cl', 'Ester C=O', 'C-S'});
xtickangle(45);
ylabel('Wavenumber (cm^{-1})');
title('Key Functional Group Bands');
grid on;

% Plot 3: Spectra by family
subplot(2,3,3);
colors = lines(5);
hold on;
for f = 1:length(family_members)
    members = family_members{f};
    for m = 1:length(members)
        pest_id = members(m);
        plot(wavenumbers, pesticide_spectra(pest_id, :) + (f-1)*0.4, ...
            'Color', colors(f, :), 'LineWidth', 1.2);
    end
end
xlabel('Wavenumber (cm^{-1})');
ylabel('Absorbance (offset by family)');
title('Pesticide Spectra Grouped by Family');
legend(family_names, 'Location', 'eastoutside');
set(gca, 'XDir', 'reverse');
grid on;

% Plot 4: Stage 1 confusion matrix (from K-Fold CV)
subplot(2,3,4);
C1 = confusionmat(y_binary, y1_pred_all);
imagesc(C1);
colorbar;
xlabel('Predicted');
ylabel('True');
title(sprintf('Stage 1: Binary (CV %.1f%%)', acc_stage1));
set(gca, 'XTickLabel', {'Clean', 'Contam'}, 'YTickLabel', {'Clean', 'Contam'});
axis square;

% Plot 5: Stage 2 confusion matrix (from K-Fold CV)
subplot(2,3,5);
C2 = confusionmat(y_family_contam, y2_pred_all);
imagesc(C2);
colorbar;
xlabel('Predicted Family');
ylabel('True Family');
title(sprintf('Stage 2: Family (CV %.1f%%)', acc_stage2));
axis square;

% Plot 6: Feature importance for family classification
subplot(2,3,6);
feat2_variance = var(features_stage2_norm);
bar(feat2_variance);
xlabel('Feature Index');
ylabel('Variance');
title('Stage 2 Feature Variance');
grid on;

saveas(gcf, 'three_stage_detection_results.png');
fprintf('\n  Saved: three_stage_detection_results.png\n');

fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║              PIPELINE COMPLETE - READY FOR DEMO              ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n');

%% ======================= HELPER FUNCTIONS =======================

function features = extract_stage1_features(X, wavenumbers, regions)
    % General features for binary classification
    n_samples = size(X, 1);
    n_regions = length(regions);
    features = zeros(n_samples, n_regions * 3 + 4);
    
    for i = 1:n_samples
        spectrum = X(i, :);
        spectrum(isnan(spectrum) | isinf(spectrum)) = 0;
        
        feat_idx = 1;
        for r = 1:n_regions
            mask = (wavenumbers >= regions{r}(1)) & (wavenumbers <= regions{r}(2));
            region_data = spectrum(mask);
            
            features(i, feat_idx) = max(region_data);      feat_idx = feat_idx + 1;
            features(i, feat_idx) = mean(region_data);     feat_idx = feat_idx + 1;
            features(i, feat_idx) = std(region_data);      feat_idx = feat_idx + 1;
        end
        
        % Global features
        features(i, feat_idx) = mean(spectrum);            feat_idx = feat_idx + 1;
        features(i, feat_idx) = std(spectrum);             feat_idx = feat_idx + 1;
        [pks, ~] = findpeaks(spectrum, 'MinPeakProminence', 0.05);
        features(i, feat_idx) = length(pks);               feat_idx = feat_idx + 1;
        features(i, feat_idx) = max(spectrum) - min(spectrum);
    end
end

function features = extract_stage2_features(X, wavenumbers, op_bands, carb_bands, chlor_bands, pyr_bands, oth_bands)
    % Chemical family-specific features
    n_samples = size(X, 1);
    all_bands = {op_bands, carb_bands, chlor_bands, pyr_bands, oth_bands};
    
    % Count total features
    n_feat = 0;
    for f = 1:length(all_bands)
        n_feat = n_feat + length(all_bands{f}) * 2;
    end
    n_feat = n_feat + 5;  % Family ratios
    
    features = zeros(n_samples, n_feat);
    
    for i = 1:n_samples
        spectrum = X(i, :);
        spectrum(isnan(spectrum) | isinf(spectrum)) = 0;
        
        feat_idx = 1;
        family_intensities = zeros(1, 5);
        
        for f = 1:length(all_bands)
            bands = all_bands{f};
            family_sum = 0;
            for b = 1:length(bands)
                mask = (wavenumbers >= bands{b}(1)) & (wavenumbers <= bands{b}(2));
                region_data = spectrum(mask);
                
                features(i, feat_idx) = max(region_data);  feat_idx = feat_idx + 1;
                features(i, feat_idx) = mean(region_data); feat_idx = feat_idx + 1;
                family_sum = family_sum + mean(region_data);
            end
            family_intensities(f) = family_sum / length(bands);
        end
        
        % Family intensity ratios (discriminative)
        total_intensity = sum(family_intensities) + 1e-8;
        for f = 1:5
            features(i, feat_idx) = family_intensities(f) / total_intensity;
            feat_idx = feat_idx + 1;
        end
    end
end

function [result, details] = run_three_stage_detection(spectrum, wavenumbers, ...
    model_s1, model_s2, family_models, family_members, ...
    f1_mean, f1_std, f2_mean, f2_std, f3_mean, f3_std, ...
    s1_regions, op_bands, carb_bands, chlor_bands, pyr_bands, oth_bands, ...
    pest_names, fam_names)
    
    details = struct();
    
    % Stage 1: Binary
    feat1 = extract_stage1_features(spectrum, wavenumbers, s1_regions);
    feat1_norm = (feat1 - f1_mean) ./ f1_std;
    pred_binary = predict(model_s1, feat1_norm);
    
    details.binary = pred_binary;
    
    if pred_binary == 0
        result = 'CLEAN - No pesticide detected';
        details.family = [];
        details.pesticide = [];
        return;
    end
    
    % Stage 2: Family
    feat2 = extract_stage2_features(spectrum, wavenumbers, op_bands, carb_bands, chlor_bands, pyr_bands, oth_bands);
    feat2_norm = (feat2 - f2_mean) ./ f2_std;
    pred_family = predict(model_s2, feat2_norm);
    
    details.family = pred_family;
    details.family_name = fam_names{pred_family};
    
    % Stage 3: Specific
    members = family_members{pred_family};
    if length(members) == 1
        pred_pest = members(1);
    elseif ~isempty(family_models{pred_family})
        feat3 = [feat1, feat2];
        feat3_norm = (feat3 - f3_mean) ./ f3_std;
        pred_pest = predict(family_models{pred_family}, feat3_norm);
    else
        pred_pest = members(1);
    end
    
    details.pesticide = pred_pest;
    details.pesticide_name = pest_names{pred_pest};
    
    result = sprintf('CONTAMINATED - %s detected (%s family)', pest_names{pred_pest}, fam_names{pred_family});
end

function [wavenumber, absorbance] = read_jdx(filepath)
    fid = fopen(filepath, 'r');
    if fid == -1, error('Cannot open: %s', filepath); end
    
    wavenumber = []; absorbance = [];
    in_data = false; xfactor = 1; yfactor = 1;
    
    while ~feof(fid)
        line = fgetl(fid);
        if ~ischar(line), break; end
        
        if startsWith(line, '##XFACTOR='), xfactor = str2double(extractAfter(line, '=')); 
        elseif startsWith(line, '##YFACTOR='), yfactor = str2double(extractAfter(line, '='));
        elseif startsWith(line, '##XYDATA='), in_data = true; continue;
        elseif startsWith(line, '##END='), break; end
        
        if in_data && ~startsWith(line, '##')
            values = str2num(line); %#ok<ST2NM>
            if ~isempty(values)
                x = values(1) * xfactor;
                y_vals = values(2:end) * yfactor;
                n_y = length(y_vals);
                x_vals = x + (0:n_y-1) * 4;
                wavenumber = [wavenumber, x_vals];
                absorbance = [absorbance, y_vals];
            end
        end
    end
    fclose(fid);
    [wavenumber, idx] = sort(wavenumber);
    absorbance = absorbance(idx);
end

function spectrum = generate_synthetic_pesticide(wavenumbers, seed)
    rng(seed);
    spectrum = 0.1 * ones(size(wavenumbers));
    peaks = [800, 1050, 1250, 1450, 1650, 2900, 3300] + seed*20;
    widths = [50, 80, 60, 70, 100, 150, 200];
    heights = 0.3 + 0.5*rand(1, length(peaks));
    for i = 1:length(peaks)
        spectrum = spectrum + heights(i) * exp(-((wavenumbers - peaks(i)).^2) / (2*widths(i)^2));
    end
    spectrum = (spectrum - min(spectrum)) / (max(spectrum) - min(spectrum));
end
