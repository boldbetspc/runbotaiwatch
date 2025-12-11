# Coach RAG Strategy Edge Function

Secure Edge Function that gets adaptive coaching strategies using secrets internally.

## Security Model

✅ **Secrets never exposed** - OpenAI/Mem0 keys stored in Edge Function environment variables  
✅ **Secrets used internally** - Edge Function makes API calls directly  
✅ **Only results returned** - Client receives final strategy, never secrets  

## Setup

### 1. Deploy Edge Function

```bash
# From project root
cd supabase/functions/coach-rag-strategy
supabase functions deploy coach-rag-strategy
```

### 2. Set Secrets in Supabase Dashboard

1. Go to **Supabase Dashboard** → **Edge Functions** → **coach-rag-strategy**
2. Click **Settings** → **Secrets**
3. Add these secrets:
   - `OPENAI_API_KEY` = `sk-...`
   - `MEM0_API_KEY` = `m0-...` (optional)
   - `MEM0_BASE_URL` = `https://api.mem0.ai/v1` (optional)
   - `SUPABASE_URL` = `https://your-project.supabase.co` (auto-set)
   - `SUPABASE_SERVICE_ROLE_KEY` = `your-service-role-key` (auto-set)

### 3. Test

```bash
curl -X POST \
  'https://your-project.supabase.co/functions/v1/coach-rag-strategy' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "performance_analysis": {
      "current_pace": 6.75,
      "target_pace": 6.0,
      "current_distance": 4200,
      "target_distance": 10000,
      "elapsed_time": 1320,
      "current_hr": 156,
      "current_zone": 3,
      "pace_trend": "declining",
      "hr_trend": "rising",
      "fatigue_level": "moderate",
      "target_status": "slightly_behind",
      "zone_percentages": {},
      "performance_summary": "",
      "heart_zone_analysis": "",
      "interval_trends": "",
      "hr_variation_analysis": "",
      "injury_risk_signals": [],
      "adaptive_microstrategy": "",
      "pace_deviation": 12.5,
      "completed_intervals": 4,
      "interval_paces": [5.97, 6.2, 6.37, 6.75]
    },
    "personality": "strategist",
    "energy_level": "medium",
    "user_id": "test-user-123"
  }'
```

## Usage

The Coach RAG Engine calls this Edge Function instead of making direct API calls.

**Request:**
```json
{
  "performance_analysis": { ... },
  "personality": "strategist",
  "energy_level": "medium",
  "user_id": "user-uuid",
  "run_id": "run-uuid" // optional
}
```

**Response:**
```json
{
  "success": true,
  "strategy": {
    "strategy_text": "Reduce effort briefly to resync.",
    "strategy_name": "Effort Drift Guard",
    "situation_summary": "declining pace, moderate fatigue",
    "selection_reason": "Best match for cardiac drift",
    "confidence_score": 0.82,
    "expected_outcome": "HR stabilizes, pace improves",
    "strategy_id": "T03"
  }
}
```


