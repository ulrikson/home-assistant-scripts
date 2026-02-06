#!/bin/bash
set -euo pipefail

# Required environment variables:
# - GEMINI_KEY: API key for Gemini
# - HA_TOKEN: Home Assistant long-lived access token
# - NORDPOOL_SENSOR: NordPool sensor entity ID (e.g., sensor.nordpool_kwh_se3_sek_0_10_0)

# Validate required environment variables
if [ -z "${GEMINI_KEY:-}" ]; then
  echo "Error: GEMINI_KEY environment variable is not set"
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

# Extract prices
TODAY=$(echo "$SENSOR_DATA" | jq -r '.attributes.raw_today[]?' 2>/dev/null)
TOMORROW=$(echo "$SENSOR_DATA" | jq -r '.attributes.raw_tomorrow[]?' 2>/dev/null)

if [ -z "$TODAY" ]; then
  echo "Error: Could not extract price data from sensor"
  echo "Sensor data: $SENSOR_DATA"
  exit 1
fi

# Format prices (quarterly: 00:00, 00:15, 00:30, 00:45)
format_prices() {
  local prices="$1"
  local output=""
  local index=0

  while IFS= read -r price; do
    local hour=$((index / 4))
    local minute=$((index % 4 * 15))
    output+="$(printf '%02d:%02d - %.2f öre/kWh\n' $hour $minute $price)"
    ((index++))
  done <<< "$prices"

  echo "$output"
}

PRICES=$(format_prices "$TODAY")

if [ -n "$TOMORROW" ]; then
  PRICES+="\n\nMorgondagens priser:\n"
  PRICES+=$(format_prices "$TOMORROW")
fi

# Inline prompt (Swedish)
read -r -d '' PROMPT <<EOF || true
Här är dagens elpriser i Sverige (öre/kWh):

${PRICES}

Analysera och ge:
1. De 3 billigaste kvartersperioderna att använda el (med priser)
2. De 3 dyraste kvartersperioderna att undvika (med priser)
3. Ett praktiskt tips för dagen

Håll svaret kort - max 4-5 meningar totalt. Svara på svenska.
EOF

# Call Gemini
ANALYSIS=$(curl -sf "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=$GEMINI_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg prompt "$PROMPT" '{contents:[{parts:[{text:$prompt}]}]}')" | \
  jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$ANALYSIS" ]; then
  echo "Error: Failed to get response from Gemini"
  exit 1
fi

# Send notification to Home Assistant
curl -sf -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg msg "$ANALYSIS" '{title:"⚡ Dagens elpriser",message:$msg}')" \
  "http://homeassistant.local:8123/api/services/notify/notify"

if [ $? -ne 0 ]; then
  echo "Error: Failed to send notification to Home Assistant"
  exit 1
fi

echo "Notification sent successfully"