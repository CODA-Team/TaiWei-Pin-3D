# RC rule extraction from 3D LEF using patterns + OpenRCX

The key idea:

- Treat the heterogeneous 3D stack (e.g., ASAP7 + NanGate45 F2F) as a **single “big 2D stack”** in LEF.
- Use OpenRCX’s **pattern benches** to sample a wide variety of wire length / width / spacing combinations on all metal layers.
- Use **Cadence Innovus** to extract parasitics for those patterns (today: LEF/emulate RC; future: QRC).
- Feed the golden SPEF back into OpenRCX to **fit pattern-based RC rules**, and write out a `.rules` file that OpenROAD can use for parasitic extraction.

------

## 1. Inputs and tool assumptions

### 1.1 Inputs

- `input/asap7_nangate45_3D.tech.lef`
   A unified tech LEF that describes:
  - All bottom-die routing layers (e.g., M1–M10),
  - All top-die routing layers (e.g., M1_m–M2_add),
  - Bonding/interface layers as needed.

This LEF is the only technology input for now. No QRC/cap table/ICT is used yet.

### 1.2 Tools / environments

- **OpenROAD + OpenRCX** in Docker
   Binary defined in `env.sh` as:

  ```bash
  export OPENROAD_BIN=/scripts/ORFS-Research/tools/install/OpenROAD/bin/openroad
  ```

- **Cadence Innovus** on the host machine (`console5`)
   Defined in `env.sh` as:

  ```bash
  export CDS_BIN=$(which innovus)
  ```

- **SSH connectivity** from the Docker container to the host:

  - Docker path: `/scripts/ORFS-Research/flow-Pin3D/platforms/rc_extract`
  - Host path: `/export/home/zhiyuzheng/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D/platforms/rc_extract`

------

## 2. Workspace structure

Under `platforms/rc_extract/`:

```text
rc_extract/
  env.sh

  01_gen_patterns.sh
  02_cds_extract.sh
  03_gen_rules.sh       # OpenROAD rule generation

  run_rcx_flow.sh       # orchestrator (Docker + host)

  script/
    01_gen_patterns.tcl   # OpenROAD pattern generation
    02_cds_extract.tcl    # Innovus extraction (LEF/emulate RC)
    03_ord_gen_rules.tcl  # OpenRCX rule fitting

  input/
    asap7_nangate45_3D.tech.lef

  work/
    cds/      # Cadence SPEF outputs (patterns.spef)
    ord/      # OpenRCX rule outputs (asap7_nangate45_3D.rcx_patterns.rules)
    log/      # logs from all steps
```

All scripts assume they are executed from this directory and that `env.sh` is present.

------

## 3. Common environment (env.sh)

`env.sh` centralizes configuration and is sourced by each step:

```bash
export PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tools
export OPENROAD_BIN=/scripts/ORFS-Research/tools/install/OpenROAD/bin/openroad
export CDS_BIN=$(which innovus)
export NUM_CORES=32

# Optional RC setup (future QRC/MMMC)
export CDS_RC_SETUP_TCL=""

# Tcl scripts
export TCL_GEN_PATTERNS="$PROJ_ROOT/script/01_gen_patterns.tcl"
export TCL_CDS_EXTRACT="$PROJ_ROOT/script/02_cds_extract.tcl"
export TCL_GEN_RULES="$PROJ_ROOT/script/03_ord_gen_rules.tcl"

# Input tech LEF
export TECH_LEF="$PROJ_ROOT/input/asap7_nangate45_3D.tech.lef"

# Work / output paths
export WORK_DIR="$PROJ_ROOT/work"
export CDS_OUT_DIR="$WORK_DIR/cds"
export ORD_OUT_DIR="$WORK_DIR/ord"
export LOG_DIR="$WORK_DIR/log"

# Pattern DEF / Verilog from Step 1
export PATTERN_DEF="$WORK_DIR/patterns.def"
export PATTERN_V="$WORK_DIR/patterns.v"

# Golden SPEF from Step 2
export PATTERN_SPEF="$CDS_OUT_DIR/patterns.spef"

# Final OpenRCX rules from Step 3
export RCX_RULES="$ORD_OUT_DIR/asap7_nangate45_3D.rcx_patterns.rules"

mkdir -p "$WORK_DIR" "$CDS_OUT_DIR" "$ORD_OUT_DIR" "$LOG_DIR"
```

This guarantees consistent paths for all three steps, both inside Docker and on the host (since the project directory is shared/mounted).

------

## 4. Step 1 – Generate patterns from LEF (OpenROAD/OpenRCX)

**Goal:** From the unified 3D LEF, generate a synthetic testbench of wires that spans all routing layers and a range of wire lengths / spacings, and write the result to `patterns.def` and `patterns.v`.

### 4.1 Shell driver – `01_gen_patterns.sh`

- Sources `env.sh`
- Checks `OPENROAD_BIN`, `TECH_LEF`, Tcl script
- Invokes OpenROAD with multiple threads

Key call:

```bash
"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_PATTERNS}" 2>&1 | tee "${LOG_FILE}"
```

Outputs:

- `work/patterns.def`
- `work/patterns.v`

### 4.2 Tcl – `script/01_gen_patterns.tcl`

Core logic:

```tcl
set tech_lef    $::env(TECH_LEF)
set pattern_def $::env(PATTERN_DEF)
set pattern_v   $::env(PATTERN_V)

file mkdir [file dirname $pattern_def]
file mkdir [file dirname $pattern_v]

read_lef $tech_lef
```

Configure wire pattern parameters:

```tcl
set LEN     100
```

Generate patterns:

```tcl
bench_wires \
  -all \
  -len $LEN

bench_verilog $pattern_v
write_def     $pattern_def
```

This uses OpenRCX’s `bench_wires` to create parameterized wire patterns for every routing layer and spacing combination, and dumps them into a DEF/Verilog pair that other tools (Innovus) can read.

------

## 5. Step 2 – Extract RC on patterns (Innovus, LEF-based / emulate RC)

**Goal:** Use Innovus to read the patterns (DEF + LEF) and perform RC extraction with the current LEF/emulate RC model to produce a “golden” SPEF for calibration.

### 5.1 Shell driver – `02_cds_extract.sh`

Runs on the host (`console5`):

- Sources `env.sh`
- Checks that `patterns.def` and `patterns.v` exist
- Calls Innovus in batch mode

Key call:

```bash
"${CDS_BIN}" -64 -overwrite -no_gui -init "${TCL_CDS_EXTRACT}" -log "${LOG_FILE}"
```

Output:

- `work/cds/patterns.spef`

### 5.2 Tcl – `script/02_cds_extract.tcl`

Main steps:

1. **Read environment**

```tcl
set tech_lef    $::env(TECH_LEF)
set pattern_def $::env(PATTERN_DEF)
set pattern_v   ""
if {[info exists ::env(PATTERN_V)]} {
  set pattern_v $::env(PATTERN_V)
}
set out_spef    $::env(PATTERN_SPEF)
set rc_setup_tcl ""
if {[info exists ::env(CDS_RC_SETUP_TCL)]} {
  set rc_setup_tcl $::env(CDS_RC_SETUP_TCL)
}
```

1. **Optional PDK RC setup (future)**

```tcl
if {$rc_setup_tcl ne ""} {
  if {[file exists $rc_setup_tcl]} {
    source $rc_setup_tcl
  } else {
    puts "WARN: [CDS] RC setup script not found: $rc_setup_tcl"
  }
}
```

1. **Import LEF/DEF/(optional) netlist**

```tcl
set lef_list [split $tech_lef " "]
read_physical -lef $lef_list

if {$pattern_v ne "" && [file exists $pattern_v]} {
  read_netlist $pattern_v
}

defIn $pattern_def
```

1. **Set CPU usage and RC extraction mode**

```tcl
setMultiCpuUsage -localCpu $::env(NUM_CORES)

set_db extract_rc_engine        post_route
set_db extract_rc_effort_level  low
set_db extract_rc_coupled       true
```

At this stage we are using Innovus’s internal LEF/emulated RC, not a QRC tech file.

1. **Ensure an RC corner exists (simple emulate corner)**

```tcl
set rc_corner_name "default_emulate_rc_corner"
set rc_corner_exists 0
foreach c [get_db rc_corners] {
  if {[get_db $c .name] eq $rc_corner_name} {
    set rc_corner_exists 1
    break
  }
}

if {!$rc_corner_exists} {
  create_rc_corner -name $rc_corner_name
}
```

1. **Run extraction and write SPEF**

```tcl
extractRC
rcOut -spef $out_spef
exit
```

This produces `work/cds/patterns.spef`. The RC values are currently based on Innovus’s LEF/emulate model; once a real QRC tech/cap table is integrated, the same script will produce signoff-quality RC.

------

## 6. Step 3 – Fit RC rules with OpenRCX

**Goal:** Use OpenRCX to read the LEF, pattern DEF, and golden SPEF, then solve for pattern-based RC rules and write an `.rules` file for later use in OpenROAD flows.

### 6.1 Shell driver – `03_gen_rules.sh`

- Sources `env.sh`
- Checks `TECH_LEF`, `PATTERN_DEF`, `PATTERN_SPEF`
- Invokes OpenROAD:

```bash
"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_RULES}" 2>&1 | tee "${LOG_FILE}"
```

If `RCX_RULES` is not present but `ORD_OUT_DIR/extRules` exists, it copies from there as a fallback.

Output:

- `work/ord/asap7_nangate45_3D.rcx_patterns.rules`

### 6.2 Tcl – `script/03_ord_gen_rules.tcl`

Core logic:

1. **Read environment**

```tcl
set tech_lef     $::env(TECH_LEF)
set pattern_def  $::env(PATTERN_DEF)
set pattern_spef $::env(PATTERN_SPEF)
set rcx_rules    $::env(RCX_RULES)

file mkdir [file dirname $rcx_rules]
```

1. **Read LEF/DEF for benches**

```tcl
read_lef $tech_lef
read_def $pattern_def
```

1. **Rebuild bench DB and read golden SPEF**

```tcl
bench_wires -db_only
bench_read_spef $pattern_spef
```

`bench_wires -db_only` rebuilds the internal pattern database from the existing DEF (no new patterns generated). `bench_read_spef` associates the extracted RC values from the commercial tool with the bench patterns.

1. **Write RC rules**

```tcl
set rules_dir  [file dirname $rcx_rules]
set rules_name [file tail   $rcx_rules]

write_rules -dir $rules_dir -name $rules_name
exit
```

The resulting rules file encodes RC as functions of layer, width, spacing, and context depth, suitable for OpenRCX’s `extract_parasitics -ext_model_file ...` on real designs.

------

## 7. Orchestrating Docker (OpenROAD) and host (Cadence)

Because OpenROAD is in Docker and Cadence runs on `console5`, a top-level script `run_rcx_flow.sh` orchestrates all three steps:

1. **Step 1 – local (Docker)**

```bash
cd ${LOCAL_PROJECT_DIR}
bash 01_gen_patterns.sh
```

1. **Step 2 – remote (Cadence host)**

```bash
ssh -tt zhiyuzheng@console5 "
  cd \"/export/home/zhiyuzheng/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D/platforms/rc_extract\"
  bash 02_cds_extract.sh
"
```

1. **Step 3 – local (Docker)**

```bash
cd ${LOCAL_PROJECT_DIR}
bash 03_gen_rules.sh
```

1. **Summary**

At the end, it sources `env.sh` and prints:

```bash
Golden SPEF  (Step 2): ${PATTERN_SPEF}
RCX rules    (Step 3): ${RCX_RULES}
```

From inside Docker, the entire flow is launched with:

```bash
bash run_rcx_flow.sh
```

------

## 8. Conceptual summary: “From LEF to RC rules”

- **LEF → patterns**
   The unified 3D LEF defines all routing layers and design rules.
   `bench_wires` uses this information to generate synthetic RC patterns that cover:
  - all layers (bottom + top),
  - multiple wire lengths,
  - multiple width/spacing combinations.
- **patterns → golden RC (SPEF)**
   Innovus reads the LEF and DEF for these patterns and computes distributed parasitics:
  - initially with LEF/emulate RC,
  - later, with real QRC/cap table for signoff accuracy.
- **SPEF + patterns → OpenRCX rules**
   OpenRCX consumes:
  - the geometric patterns (DEF) and tech LEF, and
  - the golden parasitics (SPEF),
     and solves for a compact RC model per layer/spacing.
     The result is a `.rules` file that can be plugged back into OpenROAD for parasitic extraction on actual designs using `extract_parasitics -ext_model_file`.

This completes the 2025-12-01 work: a working three-step calibration flow from 3D LEF → patterns → Innovus RC → OpenRCX rules, with Docker–host orchestration and all scripts consolidated under `platforms/rc_extract/`.