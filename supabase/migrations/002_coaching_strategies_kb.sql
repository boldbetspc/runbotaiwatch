-- ============================================================================
-- COACH RAG AI ENGINE - Knowledge Base Driven Strategy System
-- ============================================================================
-- 
-- This migration creates a KB-driven coaching strategy system:
-- 1. coaching_strategies_kb - Knowledge base of strategies (JSON-based)
-- 2. strategy_executions - Tracks execution and outcomes (self-learning)
-- 3. strategy_effectiveness - Evolves KB based on what works
-- 4. RPC functions for intelligent KB querying
--
-- Strategies are classified by:
-- - Distance (casual, 5k, 10k, half, full)
-- - Type (core, micro)
-- - Conditions to use / when not to use (LLM-matched)
-- - Runner level (all, beginner, intermediate, advanced)
-- ============================================================================

-- Enable pgvector if not already enabled
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================================
-- 1. COACHING STRATEGIES KNOWLEDGE BASE
-- ============================================================================
-- Stores strategies as structured KB entries with semantic embeddings

CREATE TABLE IF NOT EXISTS coaching_strategies_kb (
    id TEXT PRIMARY KEY,  -- e.g., "C01", "F01", "T01", "H01", "M01"
    
    -- Strategy metadata
    title TEXT NOT NULL,
    distance TEXT NOT NULL,  -- 'casual', '5k', '10k', 'half', 'full'
    type TEXT NOT NULL,      -- 'core', 'micro'
    runner_level TEXT NOT NULL DEFAULT 'all',  -- 'all', 'beginner', 'intermediate', 'advanced'
    
    -- Strategy content
    strategy_text TEXT NOT NULL,  -- The actual coaching text
    
    -- Condition matching (LLM will match these)
    conditions_to_use TEXT NOT NULL,    -- When to use this strategy
    when_not_to_use TEXT NOT NULL,      -- When NOT to use this strategy
    
    -- Vector embedding for semantic search (1536 dims)
    -- Embedding of: title + conditions_to_use + strategy_text
    strategy_embedding vector(1536),
    
    -- Derived tags for filtering (auto-extracted from conditions)
    tags TEXT[] DEFAULT '{}',
    
    -- Effectiveness tracking (self-learning)
    times_used INTEGER DEFAULT 0,
    times_successful INTEGER DEFAULT 0,
    success_rate REAL GENERATED ALWAYS AS (
        CASE WHEN times_used > 0 THEN times_successful::REAL / times_used::REAL ELSE 0.0 END
    ) STORED,
    avg_effectiveness_score REAL DEFAULT 0.0,
    
    -- KB evolution tracking
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT true,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS coaching_strategies_kb_distance_idx 
ON coaching_strategies_kb(distance);

CREATE INDEX IF NOT EXISTS coaching_strategies_kb_type_idx 
ON coaching_strategies_kb(type);

CREATE INDEX IF NOT EXISTS coaching_strategies_kb_runner_level_idx 
ON coaching_strategies_kb(runner_level);

CREATE INDEX IF NOT EXISTS coaching_strategies_kb_embedding_idx 
ON coaching_strategies_kb 
USING ivfflat (strategy_embedding vector_cosine_ops) 
WITH (lists = 50);

CREATE INDEX IF NOT EXISTS coaching_strategies_kb_tags_idx 
ON coaching_strategies_kb 
USING GIN (tags);

CREATE INDEX IF NOT EXISTS coaching_strategies_kb_success_rate_idx 
ON coaching_strategies_kb(success_rate DESC);

-- ============================================================================
-- 2. STRATEGY EXECUTIONS TABLE (Self-Learning Feedback Loop)
-- ============================================================================

CREATE TABLE IF NOT EXISTS strategy_executions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- References
    user_id UUID NOT NULL,
    run_id UUID,
    strategy_id TEXT REFERENCES coaching_strategies_kb(id) ON DELETE SET NULL,
    
    -- Context at execution time
    execution_context JSONB NOT NULL,
    -- Example: {
    --   "pace": 6.5, "hr": 156, "zone": 3, 
    --   "distance": "10k", "current_km": 4.2,
    --   "pace_trend": "declining", "hr_trend": "rising",
    --   "fatigue": "moderate", "target_status": "behind",
    --   "runner_level": "intermediate"
    -- }
    
    -- The strategy that was delivered
    strategy_delivered TEXT NOT NULL,
    strategy_title TEXT,
    
    -- Outcome tracking (filled in after interval/run end)
    outcome_measured BOOLEAN DEFAULT false,
    outcome_metrics JSONB,
    -- Example: {
    --   "pace_change": -0.2, "hr_change": 5, 
    --   "zone_change": 0, "target_status_after": "on_track",
    --   "km_completed": 5.0
    -- }
    
    -- Effectiveness assessment
    was_effective BOOLEAN,
    effectiveness_score REAL,  -- 0.0 to 1.0
    effectiveness_reason TEXT,
    
    -- Condition matching quality (how well conditions matched)
    condition_match_score REAL,  -- 0.0 to 1.0 (LLM-assessed)
    
    -- Timestamps
    executed_at TIMESTAMPTZ DEFAULT NOW(),
    outcome_measured_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS strategy_executions_user_idx 
ON strategy_executions(user_id);

CREATE INDEX IF NOT EXISTS strategy_executions_strategy_idx 
ON strategy_executions(strategy_id);

CREATE INDEX IF NOT EXISTS strategy_executions_run_idx 
ON strategy_executions(run_id);

-- ============================================================================
-- 3. STRATEGY EFFECTIVENESS EVOLUTION
-- ============================================================================
-- Tracks how strategies evolve based on outcomes

CREATE TABLE IF NOT EXISTS strategy_effectiveness_evolution (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id TEXT REFERENCES coaching_strategies_kb(id) ON DELETE CASCADE,
    
    -- Evolution data
    effectiveness_trend JSONB,  -- Historical success rates over time
    best_conditions JSONB,     -- Conditions where strategy works best
    worst_conditions JSONB,     -- Conditions where strategy fails
    
    -- Adaptation suggestions (from LLM analysis)
    adaptation_suggestions TEXT[],
    
    -- Metadata
    analyzed_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 4. RPC FUNCTION: Vector-Based Semantic Search (Next-Gen RAG)
-- ============================================================================

-- Drop existing functions if exists
DO $$ 
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args 
              FROM pg_proc 
              WHERE proname IN ('query_coaching_strategies_kb', 'semantic_search_strategies_kb')) LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.proname || '(' || r.args || ') CASCADE;';
    END LOOP;
END $$;

-- Next-gen vector similarity search
CREATE OR REPLACE FUNCTION semantic_search_strategies_kb(
    p_situation_embedding vector(1536),
    p_distance TEXT,
    p_runner_level TEXT DEFAULT 'all',
    p_strategy_type TEXT DEFAULT NULL,
    p_match_threshold REAL DEFAULT 0.65,
    p_match_count INTEGER DEFAULT 15
)
RETURNS TABLE (
    id TEXT,
    title TEXT,
    distance TEXT,
    type TEXT,
    runner_level TEXT,
    strategy_text TEXT,
    conditions_to_use TEXT,
    when_not_to_use TEXT,
    tags TEXT[],
    times_used INTEGER,
    success_rate REAL,
    avg_effectiveness_score REAL,
    similarity REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cs.id,
        cs.title,
        cs.distance,
        cs.type,
        cs.runner_level,
        cs.strategy_text,
        cs.conditions_to_use,
        cs.when_not_to_use,
        cs.tags,
        cs.times_used,
        cs.success_rate,
        cs.avg_effectiveness_score,
        -- Cosine similarity: 1 - (embedding <=> query_embedding)
        1 - (cs.strategy_embedding <=> p_situation_embedding) AS similarity
    FROM coaching_strategies_kb cs
    WHERE cs.is_active = true
        AND cs.strategy_embedding IS NOT NULL
        AND cs.distance = p_distance
        AND (cs.runner_level = 'all' OR cs.runner_level = p_runner_level)
        AND (p_strategy_type IS NULL OR cs.type = p_strategy_type)
        -- Vector similarity threshold
        AND (1 - (cs.strategy_embedding <=> p_situation_embedding)) >= p_match_threshold
    ORDER BY 
        -- Hybrid ranking: similarity + success rate + effectiveness
        -- Weight: 50% similarity, 30% success_rate, 20% effectiveness
        (
            (1 - (cs.strategy_embedding <=> p_situation_embedding)) * 0.5 +
            COALESCE(cs.success_rate, 0.0) * 0.3 +
            COALESCE(cs.avg_effectiveness_score, 0.0) * 0.2
        ) DESC,
        cs.times_used DESC
    LIMIT p_match_count;
END;
$$;

-- Fallback: Query KB by Distance + Conditions (non-vector)
CREATE OR REPLACE FUNCTION query_coaching_strategies_kb(
    p_distance TEXT,
    p_runner_level TEXT DEFAULT 'all',
    p_strategy_type TEXT DEFAULT NULL,
    p_situation_description TEXT DEFAULT NULL,
    p_match_count INTEGER DEFAULT 10
)
RETURNS TABLE (
    id TEXT,
    title TEXT,
    distance TEXT,
    type TEXT,
    runner_level TEXT,
    strategy_text TEXT,
    conditions_to_use TEXT,
    when_not_to_use TEXT,
    tags TEXT[],
    times_used INTEGER,
    success_rate REAL,
    avg_effectiveness_score REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cs.id,
        cs.title,
        cs.distance,
        cs.type,
        cs.runner_level,
        cs.strategy_text,
        cs.conditions_to_use,
        cs.when_not_to_use,
        cs.tags,
        cs.times_used,
        cs.success_rate,
        cs.avg_effectiveness_score
    FROM coaching_strategies_kb cs
    WHERE cs.is_active = true
        AND cs.distance = p_distance
        AND (cs.runner_level = 'all' OR cs.runner_level = p_runner_level)
        AND (p_strategy_type IS NULL OR cs.type = p_strategy_type)
    ORDER BY 
        cs.success_rate DESC NULLS LAST,
        cs.avg_effectiveness_score DESC NULLS LAST,
        cs.times_used DESC
    LIMIT p_match_count;
END;
$$;

-- ============================================================================
-- 5. RPC FUNCTION: Record Strategy Execution
-- ============================================================================

CREATE OR REPLACE FUNCTION record_strategy_execution_kb(
    p_user_id UUID,
    p_run_id UUID DEFAULT NULL,
    p_strategy_id TEXT DEFAULT NULL,
    p_execution_context JSONB DEFAULT '{}',
    p_strategy_delivered TEXT DEFAULT '',
    p_strategy_title TEXT DEFAULT NULL,
    p_condition_match_score REAL DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    result_id UUID;
BEGIN
    INSERT INTO strategy_executions (
        user_id,
        run_id,
        strategy_id,
        execution_context,
        strategy_delivered,
        strategy_title,
        condition_match_score
    )
    VALUES (
        p_user_id,
        p_run_id,
        p_strategy_id,
        p_execution_context,
        p_strategy_delivered,
        p_strategy_title,
        p_condition_match_score
    )
    RETURNING id INTO result_id;
    
    -- Increment times_used for the strategy
    IF p_strategy_id IS NOT NULL THEN
        UPDATE coaching_strategies_kb 
        SET times_used = times_used + 1,
            updated_at = NOW()
        WHERE id = p_strategy_id;
    END IF;
    
    RETURN result_id;
END;
$$;

-- ============================================================================
-- 6. RPC FUNCTION: Record Strategy Outcome (Self-Learning)
-- ============================================================================

CREATE OR REPLACE FUNCTION record_strategy_outcome_kb(
    p_execution_id UUID,
    p_outcome_metrics JSONB,
    p_was_effective BOOLEAN,
    p_effectiveness_score REAL DEFAULT NULL,
    p_effectiveness_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_strategy_id TEXT;
    v_current_times_successful INTEGER;
    v_current_avg_score REAL;
    v_current_times_used INTEGER;
BEGIN
    -- Get the strategy_id from the execution
    SELECT strategy_id INTO v_strategy_id
    FROM strategy_executions
    WHERE id = p_execution_id;
    
    -- Update the execution record
    UPDATE strategy_executions
    SET 
        outcome_measured = true,
        outcome_metrics = p_outcome_metrics,
        was_effective = p_was_effective,
        effectiveness_score = p_effectiveness_score,
        effectiveness_reason = p_effectiveness_reason,
        outcome_measured_at = NOW()
    WHERE id = p_execution_id;
    
    -- Update strategy effectiveness stats (self-learning)
    IF v_strategy_id IS NOT NULL THEN
        -- Get current stats
        SELECT times_successful, avg_effectiveness_score, times_used
        INTO v_current_times_successful, v_current_avg_score, v_current_times_used
        FROM coaching_strategies_kb
        WHERE id = v_strategy_id;
        
        -- Update times_successful if effective
        IF p_was_effective THEN
            UPDATE coaching_strategies_kb
            SET times_successful = times_successful + 1,
                updated_at = NOW()
            WHERE id = v_strategy_id;
        END IF;
        
        -- Update rolling average effectiveness score
        IF p_effectiveness_score IS NOT NULL AND v_current_times_used > 0 THEN
            UPDATE coaching_strategies_kb
            SET avg_effectiveness_score = (
                (v_current_avg_score * (v_current_times_used - 1) + p_effectiveness_score) / v_current_times_used
            ),
            updated_at = NOW()
            WHERE id = v_strategy_id;
        END IF;
    END IF;
    
    RETURN true;
END;
$$;

-- ============================================================================
-- 7. RPC FUNCTION: Get User's Top Strategies (Self-Learning)
-- ============================================================================

CREATE OR REPLACE FUNCTION get_user_top_strategies_kb(
    p_user_id UUID,
    p_distance TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    strategy_id TEXT,
    title TEXT,
    strategy_text TEXT,
    distance TEXT,
    user_times_used INTEGER,
    user_success_rate REAL,
    user_avg_effectiveness REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cs.id AS strategy_id,
        cs.title,
        cs.strategy_text,
        cs.distance,
        COUNT(se.id)::INTEGER AS user_times_used,
        (COUNT(CASE WHEN se.was_effective THEN 1 END)::REAL / NULLIF(COUNT(se.id), 0)) AS user_success_rate,
        AVG(se.effectiveness_score) AS user_avg_effectiveness
    FROM coaching_strategies_kb cs
    JOIN strategy_executions se ON se.strategy_id = cs.id
    WHERE se.user_id = p_user_id
        AND se.outcome_measured = true
        AND (p_distance IS NULL OR cs.distance = p_distance)
    GROUP BY cs.id, cs.title, cs.strategy_text, cs.distance
    HAVING COUNT(se.id) >= 2  -- At least 2 uses for reliability
    ORDER BY 
        (COUNT(CASE WHEN se.was_effective THEN 1 END)::REAL / NULLIF(COUNT(se.id), 0)) DESC,
        AVG(se.effectiveness_score) DESC
    LIMIT p_limit;
END;
$$;

-- ============================================================================
-- 8. SEED: Knowledge Base Strategies (50 strategies from JSON)
-- ============================================================================

-- Insert all 50 strategies from the knowledge base
INSERT INTO coaching_strategies_kb (
    id, title, distance, type, runner_level, strategy_text, conditions_to_use, when_not_to_use
) VALUES
    -- CASUAL (<3K) — 10 STRATEGIES
    ('C01', 'Calm Start', 'casual', 'core', 'all', 'Settle pace to avoid early burnout.', 'km1 pace spiking fast.', 'pace steady.'),
    ('C02', 'Short-Stride Cadence Fix', 'casual', 'micro', 'all', 'Use short quick steps to reset rhythm.', 'cadence dropping early.', 'cadence stable.'),
    ('C03', 'Early Pace Smooth', 'casual', 'core', 'all', 'Smooth output and reduce spikes.', 'pace swinging between sections.', 'pace stable.'),
    ('C04', 'Mini Surge Align', 'casual', 'micro', 'all', 'Add brief gentle lift to realign.', 'pace drifting below normal.', 'pace on track.'),
    ('C05', 'Breathing Reset', 'casual', 'micro', 'all', 'Relax shoulders and steady breathing.', 'cadence irregular + slight slow.', 'flow steady.'),
    ('C06', 'Short Burst Control', 'casual', 'core', 'all', 'Pull back lightly and stabilize pace.', 'over-speeding multiple times.', 'speed calm.'),
    ('C07', 'Turn Efficiency', 'casual', 'micro', 'all', 'Take cleaner lines to reduce slowdowns.', 'pace drop around turns.', 'turns smooth.'),
    ('C08', 'Mini Flow Reset', 'casual', 'micro', 'all', 'Return to even pacing pattern.', 'output feels irregular (from data variability).', 'steady metrics.'),
    ('C09', 'Fatigue Quick Check', 'casual', 'core', 'beginner', 'Ease slightly then re-stabilize.', 'pace suddenly dipping at km2.', 'pace stable.'),
    ('C10', 'Finish Lift Prep', 'casual', 'micro', 'all', 'Add small form lift to finish clean.', 'last segment pace flattening.', 'pace rising.'),
    
    -- 5K — 10 STRATEGIES
    ('F01', 'Controlled Opening', '5k', 'core', 'all', 'Settle early to avoid fade.', 'km1 pace too fast.', 'km1 stable.'),
    ('F02', 'Mid-Run Cadence Hold', '5k', 'core', 'all', 'Maintain quick steps to keep speed.', 'cadence dropping mid-race.', 'cadence steady.'),
    ('F03', 'Pace Bounce Fix', '5k', 'core', 'all', 'Smooth output for even effort.', 'pace swings across km.', 'pace stable.'),
    ('F04', 'Controlled Push', '5k', 'micro', 'intermediate', 'Apply brief lift to restore rhythm.', 'pace trending low while HR steady.', 'HR rising.'),
    ('F05', 'Line Efficiency', '5k', 'core', 'all', 'Run tighter lines to conserve energy.', 'distance drift growing.', 'distance aligned.'),
    ('F06', 'Mid-Race Settle', '5k', 'core', 'all', 'Ease slightly to stay sustainable.', 'km2–3 too fast.', 'pace controlled.'),
    ('F07', 'Late Kick Prep', '5k', 'micro', 'all', 'Lift posture and increase stride pop.', '1 km left: pace flattening.', 'trend improving.'),
    ('F08', 'Pace Reconnect', '5k', 'micro', 'beginner', 'Re-establish target pace line.', 'irregular pace trend.', 'steady pattern.'),
    ('F09', 'Effort Cooldown', '5k', 'micro', 'all', 'Dial back slightly to stabilize.', 'HR drifting up early.', 'low HR trend.'),
    ('F10', 'Aggressive Finish', '5k', 'core', 'advanced', 'Add sustained controlled push.', 'last km HR stable + pace stable.', 'HR rising fast.'),
    
    -- 10K — 10 STRATEGIES
    ('T01', 'Calm First 2K', '10k', 'core', 'all', 'Ease into rhythm to prevent fade.', 'first km over-target pace.', 'opening steady.'),
    ('T02', 'Cadence Line Hold', '10k', 'core', 'all', 'Stabilize turnover for smooth pacing.', 'cadence inconsistent km-to-km.', 'cadence stable.'),
    ('T03', 'Effort Drift Guard', '10k', 'core', 'all', 'Reduce effort briefly to resync.', 'HR rising but pace dropping.', 'HR/pace aligned.'),
    ('T04', 'Mid-Race Lift', '10k', 'core', 'intermediate', 'Apply gentle lift to return to target.', 'km4–6 pace drifting low.', 'pace on plan.'),
    ('T05', 'Pace Smooth Reset', '10k', 'micro', 'all', 'Level out pacing between km.', 'spiky pace trend.', 'smooth line.'),
    ('T06', 'HR Balance', '10k', 'core', 'all', 'Back off lightly to stabilize HR.', 'zone time rising too fast.', 'zones balanced.'),
    ('T07', 'Cadence Restore', '10k', 'micro', 'all', 'Add small quick-step segment.', 'falling cadence.', 'turnover steady.'),
    ('T08', 'Mid-Race Efficiency', '10k', 'core', 'intermediate', 'Refine form to regain speed.', 'pace drop without HR change.', 'pace on trend.'),
    ('T09', 'Distance Drift Fix', '10k', 'micro', 'all', 'Tighten route line.', 'distance reading increasing vs markers.', 'aligned.'),
    ('T10', 'Late Controlled Push', '10k', 'core', 'advanced', 'Increase pace gradually to finish strong.', 'last 2k stable HR + stable cadence.', 'unstable HR.'),
    
    -- HALF MARATHON — 10 STRATEGIES
    ('H01', 'Easy First 3K', 'half', 'core', 'all', 'Slow slightly to lock sustainable effort.', 'opening pace too high.', 'opening controlled.'),
    ('H02', 'HR Drift Guard', 'half', 'core', 'all', 'Lightly reduce effort to avoid overload.', 'steady HR rise km-to-km.', 'HR flat.'),
    ('H03', 'Cadence Preservation', 'half', 'core', 'all', 'Shorten stride to recover cadence.', 'cadence drop mid-race.', 'cadence stable.'),
    ('H04', 'Mid-Race Stability', 'half', 'core', 'all', 'Smooth effort to hold middle-section form.', 'pace wobbling between km.', 'pace steady.'),
    ('H05', 'HR Zone Balance', 'half', 'core', 'intermediate', 'Reduce pace slightly to rebalance load.', 'too much time in upper zone.', 'zone mix steady.'),
    ('H06', 'Mini Pace Restore', 'half', 'micro', 'all', 'Add tiny controlled lift.', 'pace slowly falling.', 'pace stable.'),
    ('H07', 'Route Efficiency', 'half', 'core', 'all', 'Run cleaner lines to save energy.', 'distance overrun rising.', 'distance tight.'),
    ('H08', 'Flow Rebuild', 'half', 'micro', 'all', 'Rebuild even rhythm.', 'metrics inconsistent.', 'metrics smooth.'),
    ('H09', 'Pre-Finish Settle', 'half', 'micro', 'all', 'Even out pace before final push.', 'km17–19 pace unstable.', 'stable effort.'),
    ('H10', 'Controlled Finish Drive', 'half', 'core', 'advanced', 'Add consistent lift to finish strong.', 'HR stable + cadence steady at km19–20.', 'HR rising quick.'),
    
    -- FULL MARATHON — 10 STRATEGIES
    ('M01', 'Easy First 5K', 'full', 'core', 'all', 'Slow early to protect late stages.', 'opening pace above plan.', 'controlled start.'),
    ('M02', 'Cadence Conservation', 'full', 'core', 'all', 'Shorter steps to maintain efficiency.', 'early cadence drop.', 'steady turnover.'),
    ('M03', 'HR Drift Shield', 'full', 'core', 'all', 'Ease effort to delay fatigue.', 'gradual HR climb.', 'HR flat.'),
    ('M04', 'Mid-Race Rhythm Hold', 'full', 'core', 'all', 'Keep steady output for economy.', 'pace wobbling around km15–25.', 'pace steady.'),
    ('M05', 'Distance Efficiency', 'full', 'core', 'all', 'Run clean lines to save meters.', 'distance drift increasing.', 'distance sharp.'),
    ('M06', 'Fatigue-Control Lift', 'full', 'micro', 'intermediate', 'Add small controlled lift to hold pace.', 'pace fading slowly.', 'pace stable.'),
    ('M07', 'Cadence Reset', 'full', 'micro', 'all', 'Quick small-step reset.', 'cadence dropping late.', 'cadence stable.'),
    ('M08', 'Form Rebuild', 'full', 'micro', 'all', 'Straighten posture and return to smooth form.', 'form indicators degrading (cadence/pace mismatch).', 'aligned metrics.'),
    ('M09', 'Controlled Late Pace', 'full', 'core', 'all', 'Lift gently to maintain forward momentum.', 'km32–38 pace dropping.', 'pace steady.'),
    ('M10', 'Final Controlled Drive', 'full', 'core', 'advanced', 'Add sustainable final push.', 'cadence stable + HR controlled after km38.', 'HR rising sharply.')
ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title,
    strategy_text = EXCLUDED.strategy_text,
    conditions_to_use = EXCLUDED.conditions_to_use,
    when_not_to_use = EXCLUDED.when_not_to_use,
    updated_at = NOW();

-- ============================================================================
-- 9. ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE coaching_strategies_kb ENABLE ROW LEVEL SECURITY;
ALTER TABLE strategy_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE strategy_effectiveness_evolution ENABLE ROW LEVEL SECURITY;

-- Strategies are readable by all authenticated users
CREATE POLICY "KB strategies readable by authenticated users"
ON coaching_strategies_kb FOR SELECT
TO authenticated
USING (true);

-- Executions are user-specific
CREATE POLICY "Users can view own executions"
ON strategy_executions FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own executions"
ON strategy_executions FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own executions"
ON strategy_executions FOR UPDATE
TO authenticated
USING (auth.uid() = user_id);

-- Evolution data is readable by all (aggregated)
CREATE POLICY "Evolution data readable by all"
ON strategy_effectiveness_evolution FOR SELECT
TO authenticated
USING (true);

-- ============================================================================
-- 10. RPC FUNCTION: Update Strategy Embeddings (for KB evolution)
-- ============================================================================

CREATE OR REPLACE FUNCTION update_strategy_embedding_kb(
    p_strategy_id TEXT,
    p_embedding vector(1536)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE coaching_strategies_kb
    SET strategy_embedding = p_embedding,
        updated_at = NOW()
    WHERE id = p_strategy_id;
    
    RETURN FOUND;
END;
$$;

-- ============================================================================
-- 11. GRANT PERMISSIONS
-- ============================================================================

GRANT EXECUTE ON FUNCTION semantic_search_strategies_kb TO authenticated;
GRANT EXECUTE ON FUNCTION query_coaching_strategies_kb TO authenticated;
GRANT EXECUTE ON FUNCTION record_strategy_execution_kb TO authenticated;
GRANT EXECUTE ON FUNCTION record_strategy_outcome_kb TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_top_strategies_kb TO authenticated;
GRANT EXECUTE ON FUNCTION update_strategy_embedding_kb TO authenticated;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE coaching_strategies_kb IS 'Knowledge base of coaching strategies. LLM matches conditions_to_use/when_not_to_use with current situation.';
COMMENT ON TABLE strategy_executions IS 'Tracks strategy execution and outcomes for self-learning feedback loop.';
COMMENT ON TABLE strategy_effectiveness_evolution IS 'Tracks how strategies evolve based on effectiveness data.';
COMMENT ON FUNCTION query_coaching_strategies_kb IS 'Query KB by distance, runner level, and situation. Returns strategies ordered by success rate.';
COMMENT ON FUNCTION record_strategy_execution_kb IS 'Records when a strategy is delivered to a runner.';
COMMENT ON FUNCTION record_strategy_outcome_kb IS 'Records outcome of strategy execution for self-learning.';
COMMENT ON FUNCTION get_user_top_strategies_kb IS 'Returns strategies that work best for a specific user.';

