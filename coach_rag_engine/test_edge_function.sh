#!/bin/bash
# Test Edge Function

SUPABASE_URL="https://uvhzppgwjbbiuqqkacfe.supabase.co"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV2aHpwcGd3amJiaXVxcWthY2ZlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTcyNjQ1NDIsImV4cCI6MjA3Mjg0MDU0Mn0.x8Sex-EC2MJTXexOs9FBkdyqHPbWtQUIXXmXeA0C2x8"

echo "Testing Coach RAG Edge Function..."
echo ""

curl -X POST \
  "${SUPABASE_URL}/functions/v1/coach-rag-strategy" \
  -H "Authorization: Bearer ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "performance_analysis": {
      "current_pace": 6.75,
      "target_pace": 6.0,
      "current_distance": 4200,
      "target_distance": 10000,
      "elapsed_time": 1320,
      "current_hr": 156,
      "average_hr": 148,
      "max_hr": 185,
      "current_zone": 3,
      "zone_percentages": {"1": 5, "2": 35, "3": 48, "4": 12, "5": 0},
      "pace_trend": "declining",
      "hr_trend": "rising",
      "fatigue_level": "moderate",
      "target_status": "slightly_behind",
      "performance_summary": "Pace declining 47s since km 1, HR rising",
      "heart_zone_analysis": "Zone 3 dominant (48%), cardiac drift detected",
      "interval_trends": "5:58 → 6:12 → 6:22 → 6:45 (positive splits)",
      "hr_variation_analysis": "",
      "injury_risk_signals": [],
      "adaptive_microstrategy": "",
      "pace_deviation": 12.5,
      "completed_intervals": 4,
      "interval_paces": [5.97, 6.2, 6.37, 6.75]
    },
    "personality": "strategist",
    "energy_level": "medium",
    "user_id": "test-user-12345",
    "run_id": "test-run-001"
  }' | python3 -m json.tool

