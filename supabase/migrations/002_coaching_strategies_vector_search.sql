-- ============================================================================
-- COACH RAG AI ENGINE - Strategy Vector Search
-- ============================================================================
-- 
-- This migration creates the infrastructure for the Coach RAG AI Engine:
-- 1. coaching_strategies - Stores coaching strategies with vector embeddings
-- 2. strategy_executions - Tracks strategy execution and outcomes (self-learning)
-- 3. strategy_tags - Tag system for strategy categorization
-- 4. RPC functions for semantic strategy search
--
-- The Coach Engine is SEPARATE from Performance Analysis RAG.
-- It uses performance analysis + personality to select adaptive strategies.
-- ============================================================================

-- Enable pgvector if not already enabled
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================================
-- 1. COACHING STRATEGIES TABLE
-- ============================================================================
-- Stores coaching strategies with semantic embeddings for RAG retrieval
-- Tags enable categorical filtering before vector search

CREATE TABLE IF NOT EXISTS coaching_strategies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Strategy content
    strategy_name TEXT NOT NULL,
    strategy_text TEXT NOT NULL,  -- The actual coaching strategy (concise, actionable)
    strategy_context TEXT,        -- When to use this strategy (situation description)
    
    -- Vector embedding for semantic search (1536 dims for text-embedding-3-small)
    strategy_embedding vector(1536),
    
    -- Tags for categorical filtering (e.g., 'fatigue', 'pace_decline', 'hr_spike', 'injury_risk')
    tags TEXT[] DEFAULT '{}',
    
    -- Coaching parameters
    applicable_personalities TEXT[] DEFAULT '{"strategist", "pacer", "finisher"}',
    applicable_energy_levels TEXT[] DEFAULT '{"low", "medium", "high"}',
    min_fatigue_level TEXT DEFAULT 'none',  -- none, low, moderate, high, severe
    
    -- Situation triggers (when this strategy is most applicable)
    trigger_conditions JSONB DEFAULT '{}',
    -- Example: {"pace_trend": "declining", "hr_trend": "rising", "target_status": "behind"}
    
    -- Effectiveness tracking (self-learning)
    times_used INTEGER DEFAULT 0,
    times_successful INTEGER DEFAULT 0,
    success_rate REAL GENERATED ALWAYS AS (
        CASE WHEN times_used > 0 THEN times_successful::REAL / times_used::REAL ELSE 0.0 END
    ) STORED,
    avg_effectiveness_score REAL DEFAULT 0.0,
    
    -- Source and metadata
    source TEXT DEFAULT 'manual',  -- 'manual', 'ai_generated', 'learned'
    is_active BOOLEAN DEFAULT true,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for vector similarity search
CREATE INDEX IF NOT EXISTS coaching_strategies_embedding_idx 
ON coaching_strategies 
USING ivfflat (strategy_embedding vector_cosine_ops) 
WITH (lists = 50);

-- Index for tag filtering
CREATE INDEX IF NOT EXISTS coaching_strategies_tags_idx 
ON coaching_strategies 
USING GIN (tags);

-- Index for personality filtering
CREATE INDEX IF NOT EXISTS coaching_strategies_personality_idx 
ON coaching_strategies 
USING GIN (applicable_personalities);

-- ============================================================================
-- 2. STRATEGY EXECUTIONS TABLE (Self-Learning Feedback Loop)
-- ============================================================================
-- Tracks when strategies are used and their outcomes
-- This enables the coach to learn what works and adapt

CREATE TABLE IF NOT EXISTS strategy_executions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- References
    user_id UUID NOT NULL,
    run_id UUID,  -- Optional: link to specific run
    strategy_id UUID REFERENCES coaching_strategies(id) ON DELETE SET NULL,
    
    -- Context at execution time
    execution_context JSONB NOT NULL,
    -- Example: {"pace": 6.5, "hr": 156, "zone": 3, "fatigue": "moderate", "target_status": "behind"}
    
    -- The strategy that was delivered
    strategy_delivered TEXT NOT NULL,
    
    -- Outcome tracking (filled in after interval/run end)
    outcome_measured BOOLEAN DEFAULT false,
    outcome_metrics JSONB,
    -- Example: {"pace_change": -0.2, "hr_change": 5, "zone_change": 0, "target_status_after": "on_track"}
    
    -- Effectiveness assessment
    was_effective BOOLEAN,  -- Did the runner improve after this strategy?
    effectiveness_score REAL,  -- 0.0 to 1.0 scale
    effectiveness_reason TEXT,  -- Why it was/wasn't effective
    
    -- Runner feedback (optional)
    runner_rating INTEGER,  -- 1-5 stars
    runner_feedback TEXT,
    
    -- Timestamps
    executed_at TIMESTAMPTZ DEFAULT NOW(),
    outcome_measured_at TIMESTAMPTZ
);

-- Index for user lookups
CREATE INDEX IF NOT EXISTS strategy_executions_user_idx 
ON strategy_executions(user_id);

-- Index for strategy effectiveness queries
CREATE INDEX IF NOT EXISTS strategy_executions_strategy_idx 
ON strategy_executions(strategy_id);

-- ============================================================================
-- 3. STRATEGY TAGS TABLE (Categorical System)
-- ============================================================================
-- Defines available tags and their descriptions

CREATE TABLE IF NOT EXISTS strategy_tags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tag_name TEXT UNIQUE NOT NULL,
    tag_category TEXT NOT NULL,  -- 'situation', 'goal', 'physical', 'mental'
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert default tags
INSERT INTO strategy_tags (tag_name, tag_category, description) VALUES
    -- Situation tags
    ('pace_decline', 'situation', 'Runner pace is declining over intervals'),
    ('pace_stable', 'situation', 'Runner pace is stable'),
    ('pace_improving', 'situation', 'Runner pace is improving (negative splits)'),
    ('hr_rising', 'situation', 'Heart rate is trending upward'),
    ('hr_stable', 'situation', 'Heart rate is stable'),
    ('hr_spiking', 'situation', 'Heart rate showing sudden spikes'),
    ('cardiac_drift', 'situation', 'Pace declining while HR rising'),
    ('zone_too_high', 'situation', 'Too much time in Zone 4-5'),
    ('zone_optimal', 'situation', 'Good Zone 2-3 distribution'),
    
    -- Goal tags
    ('target_behind', 'goal', 'Runner is behind target pace/distance'),
    ('target_on_track', 'goal', 'Runner is on track for target'),
    ('target_ahead', 'goal', 'Runner is ahead of target'),
    ('recovery_needed', 'goal', 'Runner needs active recovery'),
    ('push_possible', 'goal', 'Runner has capacity to push harder'),
    
    -- Physical tags
    ('fatigue_low', 'physical', 'Low fatigue detected'),
    ('fatigue_moderate', 'physical', 'Moderate fatigue detected'),
    ('fatigue_high', 'physical', 'High fatigue detected'),
    ('injury_risk', 'physical', 'Potential injury risk signals'),
    ('form_breakdown', 'physical', 'Form breakdown indicators'),
    
    -- Mental tags
    ('motivation_boost', 'mental', 'Runner needs motivation boost'),
    ('focus_needed', 'mental', 'Runner needs focus/concentration'),
    ('confidence_build', 'mental', 'Build runner confidence'),
    ('calm_down', 'mental', 'Runner needs to calm/relax')
ON CONFLICT (tag_name) DO NOTHING;

-- ============================================================================
-- 4. RPC FUNCTION: Semantic Strategy Search
-- ============================================================================
-- Finds strategies matching the current situation using vector similarity

-- Drop existing function if exists (handle overloads)
DO $$ 
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args 
              FROM pg_proc 
              WHERE proname = 'match_coaching_strategies') LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.proname || '(' || r.args || ') CASCADE;';
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION match_coaching_strategies(
    query_embedding vector(1536),
    match_threshold REAL DEFAULT 0.6,
    match_count INTEGER DEFAULT 5,
    filter_tags TEXT[] DEFAULT NULL,
    filter_personality TEXT DEFAULT NULL,
    filter_energy TEXT DEFAULT NULL,
    filter_fatigue TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID,
    strategy_name TEXT,
    strategy_text TEXT,
    strategy_context TEXT,
    tags TEXT[],
    trigger_conditions JSONB,
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
        cs.strategy_name,
        cs.strategy_text,
        cs.strategy_context,
        cs.tags,
        cs.trigger_conditions,
        cs.times_used,
        cs.success_rate,
        cs.avg_effectiveness_score,
        1 - (cs.strategy_embedding <=> query_embedding) AS similarity
    FROM coaching_strategies cs
    WHERE cs.is_active = true
        AND cs.strategy_embedding IS NOT NULL
        AND (1 - (cs.strategy_embedding <=> query_embedding)) > match_threshold
        -- Tag filtering (if provided, strategy must have at least one matching tag)
        AND (filter_tags IS NULL OR cs.tags && filter_tags)
        -- Personality filtering
        AND (filter_personality IS NULL OR filter_personality = ANY(cs.applicable_personalities))
        -- Energy filtering
        AND (filter_energy IS NULL OR filter_energy = ANY(cs.applicable_energy_levels))
        -- Fatigue level filtering (strategy applies if runner's fatigue >= strategy's min_fatigue)
        AND (filter_fatigue IS NULL OR 
             CASE filter_fatigue
                 WHEN 'severe' THEN cs.min_fatigue_level IN ('none', 'low', 'moderate', 'high', 'severe')
                 WHEN 'high' THEN cs.min_fatigue_level IN ('none', 'low', 'moderate', 'high')
                 WHEN 'moderate' THEN cs.min_fatigue_level IN ('none', 'low', 'moderate')
                 WHEN 'low' THEN cs.min_fatigue_level IN ('none', 'low')
                 ELSE cs.min_fatigue_level = 'none'
             END)
    ORDER BY 
        -- Prioritize by: success rate > effectiveness > similarity
        cs.success_rate DESC,
        cs.avg_effectiveness_score DESC,
        similarity DESC
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- 5. RPC FUNCTION: Record Strategy Execution
-- ============================================================================

CREATE OR REPLACE FUNCTION record_strategy_execution(
    p_user_id UUID,
    p_run_id UUID DEFAULT NULL,
    p_strategy_id UUID DEFAULT NULL,
    p_execution_context JSONB DEFAULT '{}',
    p_strategy_delivered TEXT DEFAULT ''
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
        strategy_delivered
    )
    VALUES (
        p_user_id,
        p_run_id,
        p_strategy_id,
        p_execution_context,
        p_strategy_delivered
    )
    RETURNING id INTO result_id;
    
    -- Increment times_used for the strategy
    IF p_strategy_id IS NOT NULL THEN
        UPDATE coaching_strategies 
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

CREATE OR REPLACE FUNCTION record_strategy_outcome(
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
    v_strategy_id UUID;
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
        FROM coaching_strategies
        WHERE id = v_strategy_id;
        
        -- Update times_successful if effective
        IF p_was_effective THEN
            UPDATE coaching_strategies
            SET times_successful = times_successful + 1,
                updated_at = NOW()
            WHERE id = v_strategy_id;
        END IF;
        
        -- Update rolling average effectiveness score
        IF p_effectiveness_score IS NOT NULL AND v_current_times_used > 0 THEN
            UPDATE coaching_strategies
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
-- 7. RPC FUNCTION: Get Top Strategies for User
-- ============================================================================
-- Returns strategies that have worked best for a specific user

CREATE OR REPLACE FUNCTION get_user_top_strategies(
    p_user_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    strategy_id UUID,
    strategy_name TEXT,
    strategy_text TEXT,
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
        cs.strategy_name,
        cs.strategy_text,
        COUNT(se.id)::INTEGER AS user_times_used,
        (COUNT(CASE WHEN se.was_effective THEN 1 END)::REAL / NULLIF(COUNT(se.id), 0)) AS user_success_rate,
        AVG(se.effectiveness_score) AS user_avg_effectiveness
    FROM coaching_strategies cs
    JOIN strategy_executions se ON se.strategy_id = cs.id
    WHERE se.user_id = p_user_id
        AND se.outcome_measured = true
    GROUP BY cs.id, cs.strategy_name, cs.strategy_text
    HAVING COUNT(se.id) >= 2  -- At least 2 uses for reliability
    ORDER BY 
        (COUNT(CASE WHEN se.was_effective THEN 1 END)::REAL / NULLIF(COUNT(se.id), 0)) DESC,
        AVG(se.effectiveness_score) DESC
    LIMIT p_limit;
END;
$$;

-- ============================================================================
-- 8. SEED: Default Coaching Strategies
-- ============================================================================
-- Pre-populate with proven coaching strategies

INSERT INTO coaching_strategies (
    strategy_name, 
    strategy_text, 
    strategy_context, 
    tags, 
    applicable_personalities,
    trigger_conditions,
    source
) VALUES
    -- Pace decline strategies
    (
        'Cadence Reset',
        'Quick feet, light steps. Count to 180. Shorten stride, lift knees slightly. Find your rhythm.',
        'When pace is declining due to form breakdown, not fatigue',
        ARRAY['pace_decline', 'form_breakdown'],
        ARRAY['pacer', 'strategist'],
        '{"pace_trend": "declining", "fatigue_level": ["low", "moderate"]}',
        'manual'
    ),
    (
        'Active Recovery Segment',
        'Next 500m: easy pace, Zone 2 only. Shake out arms, relax shoulders. Breathe deep. Recharge.',
        'When pace declining and fatigue is high, need active recovery',
        ARRAY['pace_decline', 'fatigue_high', 'recovery_needed'],
        ARRAY['strategist', 'pacer'],
        '{"pace_trend": "declining", "fatigue_level": ["high", "severe"]}',
        'manual'
    ),
    (
        'Mental Reset Push',
        'Dig deep! This is where champions are made. 30 seconds of focus - attack this next section!',
        'When pace declining but physically capable, needs mental boost',
        ARRAY['pace_decline', 'motivation_boost', 'push_possible'],
        ARRAY['finisher'],
        '{"pace_trend": "declining", "fatigue_level": ["low", "moderate"], "target_status": "behind"}',
        'manual'
    ),
    
    -- HR management strategies
    (
        'Zone Control Breathing',
        'Inhale 3, exhale 3. Slow it down. Drop to Zone 3. Let HR settle before pushing again.',
        'When HR is rising or spiking, need to regain control',
        ARRAY['hr_rising', 'hr_spiking', 'zone_too_high'],
        ARRAY['pacer', 'strategist'],
        '{"hr_trend": ["rising", "spiking"]}',
        'manual'
    ),
    (
        'Cardiac Drift Management',
        'Classic drift pattern. Ease 15 sec/km for next 500m. Focus on efficiency, not speed. Rebuild.',
        'When cardiac drift detected (pace down, HR up)',
        ARRAY['cardiac_drift', 'hr_rising', 'pace_decline'],
        ARRAY['strategist', 'pacer'],
        '{"pace_trend": "declining", "hr_trend": "rising"}',
        'manual'
    ),
    (
        'HR Headroom Push',
        'You have HR capacity! Zone 3-4 is your sweet spot now. Push pace 10 sec/km. Use it!',
        'When HR is stable and low, runner can push harder',
        ARRAY['hr_stable', 'push_possible', 'target_behind'],
        ARRAY['finisher', 'strategist'],
        '{"hr_trend": "stable", "target_status": "behind"}',
        'manual'
    ),
    
    -- Target-based strategies
    (
        'Gap Closing Protocol',
        'You''re behind but recoverable. Next km: pick up 10 sec/km. Stay in Zone 3-4. Controlled push.',
        'When slightly behind target, need controlled acceleration',
        ARRAY['target_behind', 'push_possible'],
        ARRAY['strategist', 'pacer'],
        '{"target_status": "slightly_behind"}',
        'manual'
    ),
    (
        'Maintain Lead Strategy',
        'Ahead of target - smart running! Hold this pace, don''t overextend. Bank time for final km.',
        'When ahead of target, focus on maintaining efficiency',
        ARRAY['target_ahead', 'pace_stable'],
        ARRAY['strategist'],
        '{"target_status": "ahead"}',
        'manual'
    ),
    (
        'Damage Control Mode',
        'Way behind target. New goal: finish strong. Focus on steady pace, good form. Every km counts.',
        'When way behind target, shift to completion goal',
        ARRAY['target_behind', 'fatigue_high', 'motivation_boost'],
        ARRAY['finisher', 'strategist'],
        '{"target_status": "way_behind"}',
        'manual'
    ),
    
    -- Injury risk strategies
    (
        'Injury Prevention Protocol',
        'Warning signs detected. Ease pace immediately. Shorter strides, land softly. Listen to your body.',
        'When injury risk signals detected',
        ARRAY['injury_risk', 'form_breakdown'],
        ARRAY['pacer', 'strategist', 'finisher'],
        '{"injury_risk": true}',
        'manual'
    ),
    (
        'Form Check Recovery',
        'Form breaking down. Quick check: shoulders down, core tight, arms 90°. Reset your mechanics.',
        'When form breakdown detected but no injury risk',
        ARRAY['form_breakdown', 'pace_decline'],
        ARRAY['pacer'],
        '{"form_breakdown": true, "injury_risk": false}',
        'manual'
    ),
    
    -- Fatigue management
    (
        'Second Wind Protocol',
        'Push through the wall! Your body is adapting. 60 more seconds of discomfort, then it gets easier.',
        'When moderate fatigue but runner can push through',
        ARRAY['fatigue_moderate', 'motivation_boost'],
        ARRAY['finisher'],
        '{"fatigue_level": "moderate"}',
        'manual'
    ),
    (
        'Energy Conservation Mode',
        'Conserve energy for final push. Cruise at current pace, Zone 3 max. Save reserves for last 2km.',
        'When fatigue building, need to conserve for finish',
        ARRAY['fatigue_moderate', 'target_on_track'],
        ARRAY['strategist'],
        '{"fatigue_level": "moderate", "target_status": ["on_track", "ahead"]}',
        'manual'
    ),
    
    -- Zone optimization
    (
        'Zone 2 Base Building',
        'Lock into Zone 2. This is aerobic development time. Comfortable pace, controlled breathing. Build base.',
        'When runner should focus on Zone 2 training',
        ARRAY['zone_optimal', 'fatigue_low'],
        ARRAY['pacer', 'strategist'],
        '{"current_zone": 2}',
        'manual'
    ),
    (
        'Zone 4 Threshold Push',
        'Threshold time! Zone 4 for next 400m. Hard but controlled. This is where fitness improves.',
        'When runner should push Zone 4 for threshold training',
        ARRAY['push_possible', 'fatigue_low'],
        ARRAY['pacer', 'finisher'],
        '{"current_zone": [3, 4], "fatigue_level": "low"}',
        'manual'
    )
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 9. ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE coaching_strategies ENABLE ROW LEVEL SECURITY;
ALTER TABLE strategy_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE strategy_tags ENABLE ROW LEVEL SECURITY;

-- Strategies are readable by all authenticated users
CREATE POLICY "Strategies readable by authenticated users"
ON coaching_strategies FOR SELECT
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

-- Tags are readable by all
CREATE POLICY "Tags readable by all"
ON strategy_tags FOR SELECT
TO authenticated
USING (true);

-- ============================================================================
-- 10. GRANT PERMISSIONS
-- ============================================================================

GRANT EXECUTE ON FUNCTION match_coaching_strategies TO authenticated;
GRANT EXECUTE ON FUNCTION record_strategy_execution TO authenticated;
GRANT EXECUTE ON FUNCTION record_strategy_outcome TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_top_strategies TO authenticated;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE coaching_strategies IS 'Coaching strategies with vector embeddings for RAG retrieval. Self-learning via effectiveness tracking.';
COMMENT ON TABLE strategy_executions IS 'Tracks strategy execution and outcomes for self-learning feedback loop.';
COMMENT ON TABLE strategy_tags IS 'Tag definitions for strategy categorization and filtering.';
COMMENT ON FUNCTION match_coaching_strategies IS 'Semantic search for coaching strategies using pgvector similarity.';
COMMENT ON FUNCTION record_strategy_execution IS 'Records when a strategy is delivered to a runner.';
COMMENT ON FUNCTION record_strategy_outcome IS 'Records outcome of strategy execution for self-learning.';
COMMENT ON FUNCTION get_user_top_strategies IS 'Returns strategies that work best for a specific user.';



