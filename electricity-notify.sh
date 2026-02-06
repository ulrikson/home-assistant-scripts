#!/bin/bash
set -euo pipefail

# Required environment variables:
# - ANTHROPIC_API_KEY: API key for Claude
# - HA_TOKEN: Home Assistant long-lived access token
# - NORDPOOL_SENSOR: NordPool sensor entity ID (e.g., sensor.nordpool_kwh_se3_sek_0_10_0)

# Validate required environment variables
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Error: ANTHROPIC_API_KEY environment variable is not set"
  exit 1
fi

if [ -z "${HA_TOKEN:-}" ]; then
  echo "Error: HA_TOKEN environment variable is not set"
  exit 1
fi

if [ -z "${NORDPOOL_SENSOR:-}" ]; then
  echo "Error: NORDPOOL_SENSOR environment variable is not set"
  echo "Example: export NORDPOOL_SENSOR=sensor.nordpool_kwh_se3_sek_0_10_0"
  exit 1
fi

# Get price data
SENSOR_DATA=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" \
  "http://homeassistant.local:8123/api/states/${NORDPOOL_SENSOR}")

if [ $? -ne 0 ] || [ -z "$SENSOR_DATA" ]; then
  echo "Error: Failed to fetch data from Home Assistant"
  exit 1
fi

# Extract today's prices as JSON
TODAY_JSON=$(echo "$SENSOR_DATA" | jq -c '.attributes.raw_today')

if [ -z "$TODAY_JSON" ] || [ "$TODAY_JSON" = "null" ]; then
  echo "Error: Could not extract price data from sensor"
  echo "Sensor data: $SENSOR_DATA"
  exit 1
fi

# Create prompt with JSON data
PROMPT=$(cat <<EOF
Du får elprisdata i JSON. Varje objekt har 'start' och 'value' (öre/kWh).

Data: $TODAY_JSON

Hitta 1-3 tidsperioder när det är DYRAST. Skriv EN mening på max 120 tecken:
"Undvik kl XX-XX och XX-XX (dyrt)"

Exempel: "Undvik kl 07-11 och 17-20 (dyrt)"

Endast timmar. Fokus på dyra perioder. Kort och tydlig.
EOF
)

# Call Claude Sonnet 4.5
ANALYSIS=$(curl -sf "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg prompt "$PROMPT" '{
    model: "claude-sonnet-4-5-20250929",
    max_tokens: 60,
    messages: [{role: "user", content: $prompt}]
  }')" | \
  jq -r '.content[0].text' 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$ANALYSIS" ]; then
  echo "Error: Failed to get response from Claude"
  exit 1
fi

# Truncate to 178 characters if needed (iOS notification limit)
if [ ${#ANALYSIS} -gt 178 ]; then
  ANALYSIS="${ANALYSIS:0:175}..."
  echo "Warning: Response truncated to 178 characters"
fi

# Store analysis in Home Assistant helper entity
curl -sf -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg msg "$ANALYSIS" '{entity_id:"input_text.electricity_analysis",value:$msg}')" \
  "http://homeassistant.local:8123/api/services/input_text/set_value"

if [ $? -ne 0 ]; then
  echo "Error: Failed to store analysis in Home Assistant"
  exit 1
fi

echo "Analysis stored successfully"