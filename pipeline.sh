#!/bin/bash

# Load configuration
source config.txt

# Set environment variables from config
export WORKING_DIR=$WORKING_DIR
export INPUT_AB1=$INPUT_AB1
export CONTROL_AB1=$CONTROL_AB1
export GUIDE_RNA_SEQUENCE=$GUIDE_RNA_SEQUENCE
export OUTPUT_DIR=$OUTPUT_DIR
export ANALYSIS_TYPE=$ANALYSIS_TYPE
export BATCH_INPUT_FILE=$BATCH_INPUT_FILE


###### ENV SETUP ######

# Function to install Conda and set up the environment
setup_conda_env() {
    echo "✅ Pipeline Initiated!"
    # Check if conda is installed
    if ! command -v conda &> /dev/null; then
        echo "Conda not found! Please install Miniconda or Anaconda first."
        exit 1
    fi

    # Create a new Conda environment if not already present
    ENV_NAME="crispr_env"
    if ! conda info --envs | grep -q "$ENV_NAME"; then
        echo "Creating Conda environment: $ENV_NAME"
        conda create -y -n "$ENV_NAME" python=3.9 r-base=4.4.2 r-essentials git > /dev/null 2>&1
    else
        echo "Conda environment $ENV_NAME already exists."
    fi

    # Activate the environment
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "$ENV_NAME" > /dev/null 2>&1

    # Ensure all required packages are installed
    echo "Installing required packages..."
    conda update -y conda > /dev/null 2>&1
    conda install -y -c conda-forge r-quarto r-tidyverse > /dev/null 2>&1
    conda install -y -c conda-forge libxml2 libcurl zlib gcc gxx > /dev/null 2>&1
    conda install -y -c r r > /dev/null 2>&1
    conda install -y -c conda-forge proj pkg-config > /dev/null 2>&1


    # Install Docker manually (since it's not available in Conda)
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo apt-get update && sudo apt-get install -y docker.io  > /dev/null 2>&1
        sudo systemctl enable docker  > /dev/null 2>&1
        sudo systemctl start docker  > /dev/null 2>&1
        sudo usermod -aG docker "$USER"
        echo "Docker installed successfully. You may need to log out and log in again for permissions to take effect."
    fi

    # Ensure Quarto is installed correctly
    if ! command -v quarto &> /dev/null; then
        echo "Installing Quarto..."
        wget https://quarto.org/download/latest/quarto-linux-amd64.deb > /dev/null 2>&1
        sudo dpkg -i quarto-linux-amd64.deb > /dev/null 2>&1
        rm quarto-linux-amd64.deb
    fi

    # Ensure Git is installed correctly
    if ! command -v git &> /dev/null; then
        echo "Installing Git..."
        sudo apt-get install -y git > /dev/null 2>&1
    fi

    echo "✅ Environment setup complete!"
}

setup_conda_env


# Function to setup output directories
setup_output_dir() {
    mkdir -p "$OUTPUT_DIR/Outputs" || { echo "❌ Error creating output directory."; exit 1; }

    if [ "$ANALYSIS_TYPE" == "batch" ]; then
        # Create a directory for combined reports
         mkdir -p "$OUTPUT_DIR/Outputs/Combined_Reports" || { echo "❌ Error creating Combined_Reports directory."; exit 1; }
        

     elif [ "$ANALYSIS_TYPE" == "single" ]; then
        # Check if the specified AB1 file exists
        if [ ! -f "$INPUT_AB1" ]; then
            echo "❌ Error: Specified AB1 file $INPUT_AB1 does not exist."
            exit 1
        fi

        # Create the output directory and Plots subdirectory
        mkdir -p "$OUTPUT_DIR/Outputs/Plots" || { echo "❌ Error creating Plots directory."; exit 1; }
        mkdir -p "$OUTPUT_DIR/Outputs/Results" || { echo "❌ Error creating Results directory."; exit 1; }
    else
        echo "❌ Invalid analysis type specified in config.txt."
        exit 1
    fi
}

setup_output_dir


# Function to move files based on unique names from the batch analysis
move_results() {
    local combined_reports_dir="$1"
    local output_dir="$2"

    # Ensure no double slashes in the paths
    combined_reports_dir=$(echo "$combined_reports_dir" | sed 's:/*$::')
    output_dir=$(echo "$output_dir" | sed 's:/*$::')

    # Loop through files in the Combined_Reports directory
    for result_file in "$combined_reports_dir"/*; do
        # Extract the base file name (excluding the path)
        file_name=$(basename "$result_file")

        # Skip ice.results.* files
        if [[ "$file_name" == ice.results* ]]; then
            echo "Skipping $file_name"
            continue
        fi

        # Extract the unique name (before the first dot)
        unique_name=$(echo "$file_name" | cut -d'.' -f1)

        # Create the subdirectory under Outputs for the file's unique name
        output_subdir="$output_dir/Outputs/$unique_name/Results"
        mkdir -p "$output_subdir" || { echo "Error creating subdirectory $output_subdir"; exit 1; }
        mkdir -p "$output_dir/Outputs/$unique_name/Plots" || { echo "❌ Error creating subdirectory: Plots"; exit 1; }

        # Move the file to the appropriate subdirectory
        mv -f "$result_file" "$output_subdir/" || { echo "❌ Error moving $result_file to $output_subdir"; exit 1; }
    done
}


### SYNTHEGO_ICE ####

# Check if the user has permission to run Docker
if ! docker info &>/dev/null; then
    echo "Warning: You do not have permission to run Docker without sudo."
    echo "Please add your user to the docker group (recommended) or rerun with:"
    echo "sudo bash sanger_pipeline.sh"
    exit 1
fi

# Function to run Synthego ICE analysis
run_ice_analysis() {
    cd "$WORKING_DIR" || { echo "❌ Error accessing working directory."; exit 1; }

    echo "Pulling synthego/ice Docker image..."
    docker pull synthego/ice || { echo "❌ Error: Docker pull failed. Ensure you have proper permissions."; exit 1; }

    if [ "$ANALYSIS_TYPE" == "single" ]; then
        echo "Running Synthego ICE single analysis..."

        # Strip trailing slashes from OUTPUT_DIR
        results_dir="${OUTPUT_DIR%/}/Outputs/Results"

        # Run ICE analysis for single input
        docker run -it \
          -v $(dirname "$CONTROL_AB1"):/control_data \
          -v "$results_dir:/output_data" \
          -v $(dirname "$INPUT_AB1"):/edited_data \
          -w /ice -i synthego/ice:latest python ice_analysis_single.py \
          --control /control_data/$(basename "$CONTROL_AB1") \
          --edited /edited_data/$(basename "$INPUT_AB1") \
          --target "$GUIDE_RNA_SEQUENCE" \
          --out /output_data/$(basename "$INPUT_AB1") || { echo "❌ Error: Synthego ICE single analysis failed."; exit 1; } 

        echo "✅ Single analysis completed. Results saved to $results_dir."


    elif [ "$ANALYSIS_TYPE" == "batch" ]; then
        echo "Running Synthego ICE batch analysis..."

        # Check if the batch input file exists
        if [ ! -f "$BATCH_INPUT_FILE" ]; then
            echo "❌ Error: Specified batch input file $BATCH_INPUT_FILE does not exist."
            exit 1
        fi

        # Strip trailing slashes from OUTPUT_DIR
        results_dir="${OUTPUT_DIR%/}/Outputs/Results"
        
        # Run ICE analysis for batch input
        docker run -it \
          -v "$INPUT_AB1:/input_data" \
          -v "$OUTPUT_DIR/Outputs/Combined_Reports/:/output_data" \
          -v $(dirname "$BATCH_INPUT_FILE"):/batch_data \
          -w /ice -i synthego/ice:latest python ice_analysis_batch.py \
          --in /batch_data/$(basename "$BATCH_INPUT_FILE") \
          --data /input_data \
          --out /output_data || { echo "❌ Error: Synthego ICE batch analysis failed."; exit 1; }

    # Move the results to the correct subdirectories
    move_results "$OUTPUT_DIR/Outputs/Combined_Reports" "$OUTPUT_DIR"


        echo "✅ Batch analysis completed. Results saved to $results_dir."

    else
        echo "❌ Invalid analysis type. Please check config.txt."
        exit 1
    fi
}

run_ice_analysis

##### R STATISTICAL ANALYSIS #####
# Ensure 'WORKING_DIR' is set
if [ -z "$WORKING_DIR" ]; then
    echo "❌ ERROR: 'WORKING_DIR' not defined in config.txt"
    exit 1
fi

if [ ! -f "packages.yml" ]; then
    echo "❌ ERROR: 'packages.yml' not found!"
    exit 1
fi

# Move to working directory
cd "$WORKING_DIR" || { echo "❌ ERROR: Working directory not found!"; exit 1; }

# Check if CRISPR_Analysis exists, else clone
if [ ! -d "CRISPR_Analysis" ]; then
    echo "📂 Cloning CRISPR_Analysis GitHub repo..."
    git clone https://github.com/Akschya/CRISPR_Analysis.git
fi

# Move into CRISPR_Analysis
cd CRISPR_Analysis || { echo "❌ ERROR: Failed to navigate to CRISPR_Analysis"; exit 1; }

# Ensure we are on the correct branch and pull latest updates
git fetch --all
git reset --hard origin/dev
git pull



run_quarto_analysis() {

    if [ "$ANALYSIS_TYPE" == "single" ]; then
        echo "Processing single analysis..."
        
        # Run Quarto for the single result file
        quarto render test_quarto.qmd --to html > /dev/null 2>&1
        
        # Move the generated report to the results directory
        mv test_quarto.html "$OUTPUT_DIR/Outputs/analysis_report.html" 

    elif [ "$ANALYSIS_TYPE" == "batch" ]; then
        echo "Processing batch analysis..."

        # Iterate over each sample folder in the batch results
        for sample_folder in "$OUTPUT_DIR/Outputs/"*/; do
            sample_name=$(basename "$sample_folder")
            # Check if sample_name starts with a number
            if [[ $sample_name =~ ^[0-9] ]]; then
                echo "Running Quarto for sample: $sample_name"
        
                # Run Quarto for each sample 
                quarto render batch_quarto.qmd --to html --execute-param sample_name="$sample_name" > /dev/null 2>&1

                # Move the generated report to the respective sample folder
                mv batch_quarto.html "$sample_folder/${sample_name}_analysis_report.html"
            fi
        done
    else
        echo "❌ Invalid analysis type. Check config.txt."
        exit 1
    fi
}

# Call the Quarto analysis function
run_quarto_analysis

# Print success message
echo "Report generated successfully!"

echo "✅ Pipeline execution completed!"
