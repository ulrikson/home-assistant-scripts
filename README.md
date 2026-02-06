# Home Assistant Scripts

### Electricity Notify (`electricity-notify.sh`)
Fetches NordPool prices from HA and uses AI (Claude) to generate Swedish energy-saving advice when prices are high. Stores results in `input_text.electricity_analysis`.

**Logic:**
- `< 100 öre`: "Billig el idag! KBK!"
- `100-200 öre`: `[Normala elpriser]` + AI Analysis
- `> 200 öre`: `[Dyr el]` + AI Analysis

**Requirements:** `curl`, `jq`, `bc`

**Setup:**
```bash
export ANTHROPIC_API_KEY="sk-..."
export HA_TOKEN="..."
export NORDPOOL_SENSOR="sensor.nordpool..."
./electricity-notify.sh
```