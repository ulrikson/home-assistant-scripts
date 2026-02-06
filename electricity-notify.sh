#!/bin/bash
set -euo pipefail

# Required environment variables:
# - ANTHROPIC_API_KEY: API key for Claude
# - HA_TOKEN: Home Assistant long-lived access token
# - NORDPOOL_SENSOR: NordPool sensor entity ID

# Optional environment variables:
HA_URL="${HA_URL:-http://homeassistant.local:8123}"

# Validate required environment variables
[[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "Error: ANTHROPIC_API_KEY not set"; exit 1; }
[[ -z "${HA_TOKEN:-}" ]] && { echo "Error: HA_TOKEN not set"; exit 1; }
[[ -z "${NORDPOOL_SENSOR:-}" ]] && { echo "Error: NORDPOOL_SENSOR not set"; exit 1; }

echo "Fetching price data from $HA_URL..."

# Get price data
SENSOR_DATA=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/states/${NORDPOOL_SENSOR}")

# Extract today's prices as JSON
TODAY_JSON=$(echo "$SENSOR_DATA" | jq -c '.attributes.raw_today')

if [[ -z "$TODAY_JSON" || "$TODAY_JSON" == "null" ]]; then
  echo "Error: Could not extract price data from sensor"
  echo "Sensor data: $SENSOR_DATA"
  exit 1
fi

# Calculate mean (average) price
MEAN=$(echo "$TODAY_JSON" | jq -r 'map(.value) | add / length')

if [[ -z "$MEAN" || "$MEAN" == "null" ]]; then
  echo "Error: Failed to calculate mean price"
  exit 1
fi

# Decide whether to use AI based on price level
if (($(echo "$MEAN < 100" | bc -l))); then
  FINAL_MESSAGE="Billig el idag! KBK!"
else
  # Determine prefix based on price
  if (($(echo "$MEAN < 200" | bc -l))); then
    PREFIX="Normala elpriser"
  else
    PREFIX="Dyr el"
  fi

  echo "Price level high (mean: $MEAN). Requesting AI analysis..."
  
  PROMPT=$(cat <<EOF
You are analyzing electricity prices to help a homeowner optimize their energy usage and reduce costs.

<data>
$TODAY_JSON
</data>

<instructions>
1. Analyze the JSON data. Each object contains 'start' (timestamp) and 'value' (price in öre/kWh).
2. Identify the 1-3 time periods with the HIGHEST prices today.
3. Write ONE concise warning message in Swedish.
4. Use ONLY hour format (e.g., "07-11" or "18-21"), not specific minutes.
5. Keep the message under 120 characters total.
6. Be direct and actionable - focus on when to avoid high usage.
</instructions>

<examples>
<example>Undvik kl 07-11 och 17-20 (dyrt)</example>
<example>Höga priser 07-10 och 18-21</example>
<example>Dyrast 06-09 och 17-19</example>
</examples>

<output_format>
Output ONLY the warning message in Swedish. No preamble, no explanation, just the message itself.
</output_format>
EOF
)

  ANALYSIS=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg prompt "$PROMPT" '{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 100,
      temperature: 0.5,
      messages: [{role: "user", content: $prompt}]
    }')" | jq -r '.content[0].text')

  if [[ -z "$ANALYSIS" || "$ANALYSIS" == "null" ]]; then
    echo "Error: Failed to get response from Claude"
    exit 1
  fi
  FINAL_MESSAGE="[$PREFIX] $ANALYSIS"
fi

# Truncate if needed (iOS notification limit)
if ((${#FINAL_MESSAGE} > 178)); then
  FINAL_MESSAGE="${FINAL_MESSAGE:0:175}..."
fi

echo "Storing analysis: $FINAL_MESSAGE"

# Store analysis in Home Assistant
curl -sf -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg msg "$FINAL_MESSAGE" '{entity_id:"input_text.electricity_analysis",value:$msg}')" \
  "$HA_URL/api/services/input_text/set_value" > /dev/null

echo "Done."