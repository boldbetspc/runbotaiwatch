# Coach RAG AI Engine

A **separate, self-learning** coaching strategy engine for Runbot Watch.

## Overview

The Coach RAG Engine is **independent** from the Performance Analysis RAG and AI Coaching feedback systems. It focuses specifically on **strategy selection and adaptation**.

```
┌─────────────────────────────────────────────────────────────────────┐
│              COACH RAG AI ENGINE (Next-Gen Vector RAG)              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  INPUTS:                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│  │ Performance RAG │  │ Coach Settings  │  │   User ID       │     │
│  │ Analysis Output │  │ • Personality   │  │ (for Mem0)      │     │
│  │ • Pace trends   │  │ • Energy level  │  │                 │     │
│  │ • HR trends     │  │                 │  │                 │     │
│  │ • Fatigue       │  │                 │  │                 │     │
│  │ • Target status │  │                 │  │                 │     │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘     │
│           │                    │                    │               │
│           └────────────────────┼────────────────────┘               │
│                                ▼                                     │
│                   ┌─────────────────────┐                           │
│                   │  Situation Context   │                           │
│                   │  Builder            │                           │
│                   └──────────┬──────────┘                           │
│                              │                                       │
│                              ▼                                       │
│                   ┌─────────────────────┐                           │
│                   │  Generate Embedding  │  ◄── OpenAI              │
│                   │  (text-embedding-3)  │                           │
│                   └──────────┬──────────┘                           │
│                              │                                       │
│                              ▼                                       │
│           ┌──────────────────┼──────────────────┐                   │
│           ▼                  ▼                  ▼                    │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐       │
│  │ VECTOR SEARCH    │ │ Mem0 Coaching  │ │ User's Top      │       │
│  │ (pgvector)       │ │ Memories        │ │ Strategies      │       │
│  │ • Cosine sim     │ │ • What worked   │ │ (Self-learning) │       │
│  │ • Distance filter│ │ • Preferences   │ │                 │       │
│  │ • Level filter   │ │                 │ │                 │       │
│  │ • Hybrid ranking │ │                 │ │                 │       │
│  └────────┬─────────┘ └────────┬────────┘ └────────┬────────┘       │
│           │                     │                   │                 │
│           └─────────────────────┼───────────────────┘                 │
│                                 ▼                                     │
│                   ┌─────────────────────┐                           │
│                   │  LLM Condition      │                           │
│                   │  Matching           │                           │
│                   │  (conditions_to_use │                           │
│                   │   / when_not_to_use)│                           │
│                   └──────────┬──────────┘                           │
│                              │                                       │
│                              ▼                                       │
│                   ┌─────────────────────┐                           │
│                   │  LLM Strategy       │                           │
│                   │  Selection & Adapt  │                           │
│                   │  (GPT-4o-mini)      │                           │
│                   └──────────┬──────────┘                           │
│                              │                                       │
│                              ▼                                       │
│                   ┌─────────────────────┐                           │
│                   │  Adaptive Strategy  │  ◄── OUTPUT               │
│                   │  (Short, Actionable)│      (max 40 words)       │
│                   └──────────┬──────────┘                           │
│                              │                                       │
│                              ▼                                       │
│                   ┌─────────────────────┐                           │
│                   │  Execution Tracking │  ◄── SELF-LEARNING        │
│                   │  + Outcome Monitor  │      (evolves KB)         │
│                   └─────────────────────┘                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Security Model

✅ **Secrets Never Exposed** - API keys stored in Edge Function environment variables  
✅ **Secrets Used Internally** - Edge Function makes API calls directly  
✅ **Only Results Returned** - Client receives final strategy, never secrets  
✅ **No .env Files Needed** - Only Supabase URL + anon key required client-side  

**How it works**:
1. Python engine calls Edge Function with performance data
2. Edge Function uses secrets internally (from env vars)
3. Edge Function calls OpenAI/Mem0 APIs directly
4. Edge Function returns final strategy (secrets never leave server)

## Key Features

### 1. **Next-Gen Vector RAG Strategy Retrieval**
- **Vector Semantic Search**: Uses pgvector cosine similarity (text-embedding-3-small, 1536 dims)
- **Hybrid Ranking**: Combines vector similarity (50%) + success rate (30%) + effectiveness (20%)
- **Distance-based Filtering**: Strategies filtered by target distance (casual/5k/10k/half/full)
- **Runner Level Matching**: Filters by runner level (beginner/intermediate/advanced)
- **LLM Condition Matching**: Refines matches using conditions_to_use / when_not_to_use
- **Self-Learning**: Success rates evolve based on outcomes

### 2. **Mem0 Coaching Memories**
- Fetches what works for THIS runner
- Historical coaching feedback
- Runner preferences and patterns
- Injury/form insights

### 3. **Self-Learning Feedback Loop**
- Records every strategy execution
- Monitors outcomes (did it help?)
- Updates strategy success rates
- Prioritizes effective strategies over time

### 4. **LLM-Powered Adaptation**
- GPT-4o-mini selects and adapts strategies
- Combines multiple inputs into one coherent strategy
- Matches coach personality and energy
- Outputs short, actionable text (max 40 words)

## Installation

```bash
cd coach_rag_engine
pip install -r requirements.txt
```

## Environment Variables

**Minimal setup** (secrets handled by Edge Function):

```bash
export SUPABASE_URL="your-supabase-url"
export SUPABASE_ANON_KEY="your-supabase-anon-key"
```

**Secrets are stored in Edge Function environment** (set in Supabase Dashboard):
- `OPENAI_API_KEY` - Set in Dashboard → Edge Functions → Secrets
- `MEM0_API_KEY` - Set in Dashboard → Edge Functions → Secrets (optional)

**Security**: Secrets never exposed to client code!

## Supabase Setup

### 1. Run SQL Migration

```sql
-- Run: supabase/migrations/002_coaching_strategies_kb.sql
```

Creates:
- `coaching_strategies_kb` - Knowledge base with 50 strategies
- `strategy_executions` - Execution tracking for self-learning
- `strategy_effectiveness_evolution` - KB evolution tracking
- RPC functions for vector search and recording

### 2. Deploy Edge Function

```bash
cd supabase/functions/coach-rag-strategy
supabase functions deploy coach-rag-strategy
```

**Set secrets in Dashboard**:
- Go to Edge Functions → coach-rag-strategy → Settings → Secrets
- Add `OPENAI_API_KEY`, `MEM0_API_KEY` (optional)

## KB Initialization

After running the migration, generate embeddings for all strategies:

```bash
python -m coach_rag_engine.initialize_kb_embeddings
```

This will:
1. Generate embeddings for all 50 strategies using OpenAI
2. Store embeddings in `coaching_strategies_kb.strategy_embedding`
3. Enable vector-based semantic search

**Note**: Embeddings are generated from: `title + conditions_to_use + strategy_text + distance + type + runner_level`

## Usage

```python
import asyncio
from coach_rag_engine import CoachRAGEngine, PerformanceAnalysis, CoachPersonality, CoachEnergy

async def main():
    # Initialize engine (secrets handled by Edge Function)
    engine = CoachRAGEngine(
        supabase_url=os.getenv("SUPABASE_URL"),
        supabase_anon_key=os.getenv("SUPABASE_ANON_KEY")
    )
    
    # Create performance analysis (from Performance RAG)
    perf = PerformanceAnalysis(
        current_pace=6.75,
        target_pace=6.0,
        current_distance=4200,
        target_distance=10000,
        elapsed_time=22 * 60,
        current_hr=156,
        current_zone=3,
        pace_trend=PaceTrend.DECLINING,
        hr_trend=HRTrend.RISING,
        fatigue_level=FatigueLevel.MODERATE,
        target_status=TargetStatus.SLIGHTLY_BEHIND
    )
    
    # Get adaptive strategy
    strategy = await engine.get_adaptive_strategy(
        performance_analysis=perf,
        personality=CoachPersonality.STRATEGIST,
        energy_level=CoachEnergy.MEDIUM,
        user_id="user-uuid-123"
    )
    
    print(f"Strategy: {strategy.strategy_text}")
    print(f"Confidence: {strategy.confidence_score:.0%}")
    
    await engine.close()

asyncio.run(main())
```

## Example Output

```
🎯 STRATEGY: Cardiac Drift Management
📝 Classic drift pattern. Ease 15 sec/km for next 500m. Focus on efficiency, not speed. Let HR settle.

📋 Situation: declining pace, moderate fatigue
🤔 Reason: Best match: 78% success rate
📊 Confidence: 82%
🎯 Expected: Pace stabilizes, HR drops to Zone 3
```

## Self-Learning Loop

```python
# After strategy is delivered, assess effectiveness
was_effective, score, reason = await engine.assess_strategy_effectiveness(
    execution_id=strategy.execution_id,
    before_metrics={"pace": 6.75, "hr": 156, "zone": 3},
    after_metrics={"pace": 6.55, "hr": 152, "zone": 3}  # Improved!
)

print(f"Effective: {was_effective}, Score: {score:.0%}")
# Output: Effective: True, Score: 70%
```

## Strategy Categories

| Category | Tags | Example Strategy |
|----------|------|------------------|
| Pace Management | `pace_decline`, `pace_stable`, `pace_improving` | Cadence Reset |
| HR Management | `hr_rising`, `hr_stable`, `cardiac_drift` | Zone Control Breathing |
| Target Achievement | `target_behind`, `target_ahead`, `target_on_track` | Gap Closing Protocol |
| Fatigue Management | `fatigue_low`, `fatigue_moderate`, `fatigue_high` | Active Recovery |
| Safety | `injury_risk`, `form_breakdown` | Injury Prevention Protocol |
| Mental | `motivation_boost`, `focus_needed` | Second Wind Protocol |

## Differences from Performance RAG

| Aspect | Performance RAG | Coach Strategy Engine |
|--------|-----------------|----------------------|
| **Purpose** | Analyze current run state | Select adaptive strategy |
| **Output** | Comprehensive analysis (9 sections) | Short actionable strategy (40 words) |
| **Vector Search** | Similar past runs | **KB strategies by semantic similarity** |
| **Knowledge Base** | None | **50 strategies (casual/5k/10k/half/full)** |
| **Condition Matching** | Rule-based | **LLM matches conditions_to_use/when_not_to_use** |
| **Learning** | None | **Self-learning via outcome tracking + KB evolution** |
| **Integration** | Feeds into AI Coaching | **NOT integrated yet** |

## Next-Gen Vector RAG Flow

1. **Situation Embedding**: Generate embedding for current situation (pace, HR, fatigue, etc.)
2. **Vector Search**: Find semantically similar strategies using pgvector cosine similarity
3. **Hybrid Ranking**: Combine vector similarity (50%) + success rate (30%) + effectiveness (20%)
4. **LLM Refinement**: Match `conditions_to_use` and `when_not_to_use` with current situation
5. **Strategy Selection**: LLM selects and adapts best strategy
6. **Self-Learning**: Track outcomes → update success rates → evolve KB

## File Structure

```
coach_rag_engine/
├── __init__.py          # Package exports
├── engine.py            # Main CoachRAGEngine class
├── models.py            # Data models (PerformanceAnalysis, Strategy, etc.)
├── example_usage.py     # Usage examples
├── requirements.txt     # Python dependencies
└── README.md            # This file
```

## Not Integrated Yet

⚠️ **This engine is standalone and NOT integrated into the app flow.**

It does NOT impact:
- Start of run AI coaching
- Interval AI coaching
- End of run AI coaching

Future integration will feed this engine's output into the coaching prompt for even more adaptive coaching.


